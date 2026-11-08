/**
 * @module sync-engine
 *
 * Orchestrates the full addon sync pipeline for DMGAssist.
 *
 * ## Architecture
 *
 * The sync engine is the central pipeline that ties together every other server
 * module (SimC parser, addon generator, storage, and CurseForge upload) into a
 * single atomic operation.  It is invoked in two ways:
 *
 * 1. **Scheduled** — A weekly interval timer in `server/scheduler.ts` calls
 *    `runSync("schedule")` once per week to keep addon data fresh.
 * 2. **Manual** — An admin triggers a sync from the Admin Dashboard, which
 *    calls `runSync("manual")` via the API route.
 *
 * ## Sync Lifecycle
 *
 * ```
 *  ┌──────────────────────────────────────────────────────────┐
 *  │ 1. Guard: reject if a sync is already running            │
 *  │ 2. Bump semantic version (patch increment)               │
 *  │ 3. Create SyncRun record (status = "running")            │
 *  │ 4. Discover available SimC tiers                         │
 *  │ 5. For each spec:                                        │
 *  │    a. Fetch SimC APL (or fall back to stored APL)        │
 *  │    b. Load HUD config (or create default)                │
 *  │    c. Load combat alerts                                 │
 *  │ 6. Generate full addon ZIP via addon-generator            │
 *  │ 7. Upload ZIP to CurseForge (if credentials present)     │
 *  │ 8. Finalize SyncRun record (success / error)             │
 *  └──────────────────────────────────────────────────────────┘
 * ```
 *
 * The engine guarantees mutual exclusion: only one sync can run at a time,
 * enforced via a `isRunning` flag in persistent sync state. The flag is
 * always cleared in a `finally` block to avoid deadlocks.
 */

import { randomUUID, createHash } from "crypto";
import { readFileSync, readdirSync } from "fs";
import { join } from "path";
import { storage, SPECS, DEFAULT_HUD } from "./storage";
import { fetchSimcApl, discoverAvailableTiers } from "./simc-parser";
import { generateAllSpecsAddonZip, setAddonVersion } from "./addon-generator";
import type { AllSpecsData } from "./addon-generator";
import type { SyncRun } from "@shared/schema";
import { getCommunityApl } from "./community-apls";

const SYNC_TIMEOUT_MS = 5 * 60 * 1000;
let syncAbortController: AbortController | null = null;

export function cancelSync(): boolean {
  if (syncAbortController) {
    syncAbortController.abort();
    return true;
  }
  return false;
}

/**
 * Increments the build segment of a 4-part version string (major.minor.patch.build).
 *
 * Only the build number (4th segment) is bumped on each sync. The base version
 * (major.minor.patch) stays stable and is only changed manually for feature releases.
 * This keeps version numbers sane over time — 52 weekly syncs per year produces
 * `1.5.0.52` instead of `1.57.0`.
 *
 * If the input has 3 parts (legacy format), the build segment starts at 1.
 *
 * @param version - A version string such as `"1.5.0"` or `"1.5.0.3"`.
 * @returns The bumped version, e.g. `"1.5.0.4"`.
 *
 * @example
 * ```ts
 * bumpVersion("1.5.0");    // "1.5.0.1"
 * bumpVersion("1.5.0.3");  // "1.5.0.4"
 * ```
 */
function bumpVersion(version: string): string {
  const parts = version.split(".").map(Number);
  if (parts.length <= 3) {
    parts[3] = 1;
  } else {
    parts[3] = (parts[3] || 0) + 1;
  }
  return parts.join(".");
}

/**
 * Aggregates addon data for every supported spec.
 *
 * For each spec in the global `SPECS` list:
 * - Attempts to fetch APL entries from the SimC GitHub repository.
 * - Falls back to locally stored APL entries if SimC fetch fails.
 * - Loads or creates a default HUD configuration.
 * - Loads any configured combat alerts.
 *
 * @returns An object containing:
 *   - `data` — The fully assembled {@link AllSpecsData} ready for ZIP generation.
 *   - `simcCount` — Number of specs whose APL was sourced from SimC.
 *   - `fallbackCount` — Number of specs that fell back to stored APL data.
 */
/**
 * Computes a SHA-256 fingerprint of all addon generator source files.
 *
 * Any change to the generator TypeScript files (engine, HUD, helpers, config,
 * etc.) produces a different hash, ensuring that core addon code changes
 * trigger a rebuild even when SimC APL data is unchanged.
 */
function computeGeneratorHash(): string {
  const hash = createHash("sha256");
  const generatorsDir = join(process.cwd(), "server", "generators");
  try {
    const files = readdirSync(generatorsDir).filter(f => f.endsWith(".ts")).sort();
    for (const file of files) {
      const content = readFileSync(join(generatorsDir, file), "utf-8");
      hash.update(file);
      hash.update(content);
    }
  } catch {
    hash.update("generators-unavailable");
  }
  const extraFiles = ["server/addon-generator.ts", "server/simc-parser.ts"];
  for (const rel of extraFiles) {
    try {
      const content = readFileSync(join(process.cwd(), rel), "utf-8");
      hash.update(rel);
      hash.update(content);
    } catch {}
  }
  return hash.digest("hex");
}

/**
 * Computes a SHA-256 content hash over all fetched APL data AND generator code.
 *
 * Combines two sources of change:
 * 1. SimC APL data (spell priorities, conditions, modes)
 * 2. Generator source code (engine logic, HUD rendering, helpers, etc.)
 *
 * This ensures a rebuild is triggered when either SimC data OR addon code changes.
 *
 * @param allSpecsData - The assembled spec data containing APL entries.
 * @returns A hex-encoded SHA-256 hash string.
 */
function computeDataHash(allSpecsData: AllSpecsData): string {
  const hash = createHash("sha256");
  hash.update(computeGeneratorHash());
  for (const entry of allSpecsData.specs) {
    hash.update(entry.spec.id);
    for (const apl of entry.aplEntries) {
      hash.update(`${apl.spellName}|${apl.priority}|${apl.condition ?? ""}|${apl.mode ?? ""}`);
    }
  }
  return hash.digest("hex");
}

async function buildAddonData(): Promise<{ data: AllSpecsData; simcCount: number; fallbackCount: number; dataHash: string }> {
  const specs = SPECS;
  const allSpecsData: AllSpecsData = { specs: [] };
  let simcCount = 0;
  let fallbackCount = 0;

  const total = specs.length;
  let idx = 0;
  for (const spec of specs) {
    idx++;
    const simcResult = await fetchSimcApl(spec.id);
    let aplEntries;
    let aplBranch: string | undefined;
    let aplTier: string | undefined;

    if (simcResult) {
      aplEntries = simcResult.entries;
      aplBranch = simcResult.branch;
      aplTier = simcResult.tier;
      simcCount++;
      console.log(`[Sync] ${spec.id}: SimC APL loaded (branch=${aplBranch}, tier=${aplTier}, ${aplEntries.length} entries)`);
    } else {
      const communityApl = getCommunityApl(spec.id);
      if (communityApl) {
        aplEntries = communityApl;
        aplBranch = "community";
        aplTier = "MID1-community";
        console.log(`[Sync] ${spec.id}: community APL loaded (tier=${aplTier}, ${communityApl.length} entries)`);
        simcCount++;
      } else {
        aplEntries = await storage.getAplEntries(spec.id);
        aplBranch = "fallback";
        console.log(`[Sync] ${spec.id}: DB fallback APL loaded (${aplEntries.length} entries)`);
        fallbackCount++;
      }
    }

    let hudConfig = await storage.getHudConfig(spec.id);
    if (!hudConfig) {
      hudConfig = await storage.upsertHudConfig({ ...DEFAULT_HUD, specId: spec.id });
    }
    const alerts = await storage.getCombatAlerts(spec.id);
    allSpecsData.specs.push({ spec, aplEntries, hudConfig, alerts, aplBranch, aplTier });

    if (idx % 10 === 0 || idx === total) {
      console.log(`[Sync] Fetching specs: ${idx}/${total}`);
    }
  }

  const dataHash = computeDataHash(allSpecsData);
  return { data: allSpecsData, simcCount, fallbackCount, dataHash };
}

/**
 * Uploads a generated addon ZIP to the CurseForge file hosting API.
 *
 * Constructs a `multipart/form-data` request manually (no external form-data
 * library) to POST the ZIP file along with release metadata.
 *
 * Required environment variables:
 * - `CF_API_TOKEN` — CurseForge API authentication token.
 * - `CF_PROJECT_ID` — Numeric project ID on CurseForge.
 *
 * @param zipBuffer - The in-memory ZIP archive as a raw `Buffer`.
 * @param version - The semantic version string for this release (used in
 *   changelog and display name).
 *
 * @throws {Error} If credentials are missing or the CurseForge API returns a
 *   non-OK response.
 */
async function uploadToCurseForge(zipBuffer: Buffer, version: string): Promise<void> {
  const apiToken = process.env.CF_API_TOKEN;
  const projectId = process.env.CF_PROJECT_ID;

  if (!apiToken || !projectId) {
    throw new Error("CurseForge credentials not configured (CF_API_TOKEN and CF_PROJECT_ID required)");
  }

  const metadata = JSON.stringify({
    changelog: `Automated sync - v${version}\nUpdated SimC priority data for all specs. Multi-signal highlight ranking.`,
    changelogType: "text",
    displayName: `DMGAssist ${version}`,
    gameVersions: [14422],
    releaseType: "release",
  });

  const boundary = `----FormBoundary${randomUUID().replace(/-/g, "")}`;
  const metadataPart = `--${boundary}\r\nContent-Disposition: form-data; name="metadata"\r\nContent-Type: application/json\r\n\r\n${metadata}\r\n`;
  const filePart = `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="DMGAssist-${version}.zip"\r\nContent-Type: application/zip\r\n\r\n`;
  const ending = `\r\n--${boundary}--\r\n`;

  const bodyParts = [
    Buffer.from(metadataPart, "utf-8"),
    Buffer.from(filePart, "utf-8"),
    zipBuffer,
    Buffer.from(ending, "utf-8"),
  ];
  const body = Buffer.concat(bodyParts);

  const response = await fetch(`https://wow.curseforge.com/api/projects/${projectId}/upload-file`, {
    method: "POST",
    headers: {
      "x-api-token": apiToken,
      "Content-Type": `multipart/form-data; boundary=${boundary}`,
    },
    body,
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`CurseForge upload failed (${response.status}): ${text}`);
  }
}

/**
 * Converts an `archiver` streaming archive into an in-memory `Buffer`.
 *
 * Collects all emitted data chunks, then resolves with the concatenated
 * result once the archive stream ends. Calls `archive.finalize()` to
 * trigger the stream flush.
 *
 * @param archive - A streaming archive instance returned by
 *   {@link generateAllSpecsAddonZip}.
 * @returns A promise that resolves to the complete ZIP file as a `Buffer`.
 */
function archiveToBuffer(archive: ReturnType<typeof generateAllSpecsAddonZip>): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    archive.on("data", (chunk: Buffer) => chunks.push(chunk));
    archive.on("end", () => resolve(Buffer.concat(chunks)));
    archive.on("error", reject);
    archive.finalize();
  });
}

/**
 * Executes the full sync pipeline: fetch APL data → generate addon ZIP → upload to CurseForge.
 *
 * This is the primary entry point for the sync engine. It is called by:
 * - The scheduler (`triggeredBy = "schedule"`) every 7 days.
 * - The admin API route (`triggeredBy = "manual"`) on demand.
 *
 * ## Concurrency Guard
 * Only one sync may run at a time. If a sync is already in progress, this
 * function throws immediately.
 *
 * ## Error Handling
 * - If the CurseForge upload fails but the ZIP was generated successfully,
 *   the run is marked as `"error"` only when CF credentials are configured.
 *   Without credentials the run is considered `"success"` (dev/preview mode).
 * - Any other unhandled error marks the run as `"error"` with the message.
 * - The `isRunning` flag is always reset in the `finally` block.
 *
 * @param triggeredBy - Whether this sync was initiated by the automated
 *   `"schedule"` or by an admin `"manual"` action.
 * @returns The completed {@link SyncRun} record with final status and metrics.
 * @throws {Error} If a sync is already running.
 */
export async function runSync(triggeredBy: "schedule" | "manual"): Promise<SyncRun> {
  const state = await storage.getSyncState();
  if (state.isRunning) {
    throw new Error("A sync is already running");
  }

  await storage.setSyncRunning(true);

  syncAbortController = new AbortController();
  const abortSignal = syncAbortController.signal;

  const timeoutId = setTimeout(() => {
    console.log(`[Sync] Global timeout reached (${SYNC_TIMEOUT_MS / 1000}s) — aborting`);
    syncAbortController?.abort();
  }, SYNC_TIMEOUT_MS);

  let activeRunId: string | null = null;

  try {
    console.log(`[Sync] Starting sync check (triggered by ${triggeredBy})`);

    if (abortSignal.aborted) throw new Error("Sync cancelled");
    await discoverAvailableTiers();

    if (abortSignal.aborted) throw new Error("Sync cancelled");
    const { data, simcCount, fallbackCount, dataHash } = await buildAddonData();
    console.log(`[Sync] Fetched data: ${simcCount} SimC specs, ${fallbackCount} fallback (hash: ${dataHash.slice(0, 12)}…)`);

    if (abortSignal.aborted) throw new Error("Sync cancelled");

    const previousHash = await storage.getLastDataHash();
    const forceSync = triggeredBy === "manual";

    if (!forceSync && previousHash === dataHash) {
      console.log(`[Sync] No changes detected — skipping build and upload`);
      return {
        id: randomUUID(),
        startedAt: new Date().toISOString(),
        completedAt: new Date().toISOString(),
        status: "skipped",
        simcSpecs: simcCount,
        fallbackSpecs: fallbackCount,
        addonVersion: state.currentVersion,
        curseforgeUploaded: false,
        error: null,
        triggeredBy,
      };
    }

    const newVersion = bumpVersion(state.currentVersion);
    const runId = randomUUID();
    activeRunId = runId;
    const run: SyncRun = {
      id: runId,
      startedAt: new Date().toISOString(),
      completedAt: null,
      status: "running",
      simcSpecs: 0,
      fallbackSpecs: 0,
      addonVersion: newVersion,
      curseforgeUploaded: false,
      error: null,
      triggeredBy,
    };
    await storage.addSyncRun(run);

    console.log(`[Sync] Changes detected — building v${newVersion}`);
    setAddonVersion(newVersion);
    await storage.setCurrentVersion(newVersion);

    if (abortSignal.aborted) throw new Error("Sync cancelled");
    const archive = generateAllSpecsAddonZip(data);
    const zipBuffer = await archiveToBuffer(archive);
    console.log(`[Sync] ZIP built: ${(zipBuffer.length / 1024).toFixed(1)}KB`);

    let uploaded = false;
    let uploadError: string | null = null;
    try {
      if (abortSignal.aborted) throw new Error("Sync cancelled");
      await uploadToCurseForge(zipBuffer, newVersion);
      uploaded = true;
      console.log(`[Sync] Uploaded to CurseForge successfully`);
    } catch (uploadErr: any) {
      uploadError = uploadErr.message;
      console.log(`[Sync] CurseForge upload failed: ${uploadErr.message}`);
    }

    const hasCfCredentials = !!(process.env.CF_API_TOKEN && process.env.CF_PROJECT_ID);
    const finalStatus = (!hasCfCredentials || uploaded) ? "success" as const : "error" as const;

    if (finalStatus === "success") {
      await storage.setLastDataHash(dataHash);
    }

    await storage.updateSyncRun(runId, {
      status: finalStatus,
      completedAt: new Date().toISOString(),
      simcSpecs: simcCount,
      fallbackSpecs: fallbackCount,
      curseforgeUploaded: uploaded,
      addonVersion: newVersion,
      error: uploadError,
    });

    const completedRun = { ...run, status: finalStatus, completedAt: new Date().toISOString(), simcSpecs: simcCount, fallbackSpecs: fallbackCount, curseforgeUploaded: uploaded, addonVersion: newVersion, error: uploadError };
    console.log(`[Sync] Complete: v${newVersion} (uploaded: ${uploaded})`);
    return completedRun;
  } catch (err: any) {
    const errMsg = abortSignal.aborted ? "Sync cancelled or timed out" : err.message;
    console.error(`[Sync] Failed:`, errMsg);
    if (activeRunId) {
      await storage.updateSyncRun(activeRunId, {
        status: "error",
        completedAt: new Date().toISOString(),
        error: errMsg,
      });
    }
    return {
      id: activeRunId || randomUUID(),
      startedAt: new Date().toISOString(),
      completedAt: new Date().toISOString(),
      status: "error",
      simcSpecs: 0,
      fallbackSpecs: 0,
      addonVersion: state.currentVersion,
      curseforgeUploaded: false,
      error: errMsg,
      triggeredBy,
    };
  } finally {
    clearTimeout(timeoutId);
    syncAbortController = null;
    await storage.setSyncRunning(false);
  }
}
