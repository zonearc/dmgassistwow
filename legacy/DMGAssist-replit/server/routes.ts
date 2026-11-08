/**
 * @module server/routes
 *
 * Central API route registration for the DMGAssist backend.
 * All REST endpoints are registered here and wired to the storage layer.
 *
 * ## Authentication & Authorization
 *
 * Routes fall into three tiers:
 * 1. **Public** – No authentication required (specs, APL, HUD, alerts, profiles, version).
 * 2. **Authenticated** – Requires a valid Replit Auth session (`isAuthenticated` middleware).
 * 3. **Admin** – Requires authentication *and* the user's email to be in `ADMIN_EMAILS`
 *    (`isAdmin` middleware). Used for sync control and addon export.
 *
 * Auth is bootstrapped via {@link setupAuth} which registers Replit OAuth
 * routes and session middleware before any API routes are bound.
 *
 * ## Middleware Chain
 *
 * 1. `setupAuth(app)` – session + Replit OAuth (called first)
 * 2. Per-route: `isAdmin` (which internally calls `isAuthenticated` then checks email)
 *
 * ## API Route Table
 *
 * | Method   | Path                       | Auth   | Description                              |
 * |----------|----------------------------|--------|------------------------------------------|
 * | GET      | /api/version               | Public | Current addon version string              |
 * | GET      | /api/specs                 | Public | All supported WoW class/spec definitions  |
 * | GET      | /api/specs/:id             | Public | Single spec by ID                         |
 * | GET      | /api/apl/:specId           | Public | APL entries for a spec                    |
 * | POST     | /api/apl                   | Public | Create a new APL entry                    |
 * | PATCH    | /api/apl/:id               | Public | Partially update an APL entry             |
 * | DELETE   | /api/apl/:id               | Public | Delete an APL entry                       |
 * | POST     | /api/apl/:specId/reorder   | Public | Reorder APL entries by ID list            |
 * | GET      | /api/hud/:specId           | Public | HUD config for a spec (auto-creates default) |
 * | PUT      | /api/hud                   | Public | Create or update HUD config               |
 * | GET      | /api/alerts/:specId        | Public | Combat alerts for a spec                  |
 * | POST     | /api/alerts                | Public | Create a combat alert                     |
 * | PATCH    | /api/alerts/:id            | Public | Partially update a combat alert           |
 * | DELETE   | /api/alerts/:id            | Public | Delete a combat alert                     |
 * | GET      | /api/profiles/:specId      | Public | Saved profiles for a spec                 |
 * | POST     | /api/profiles              | Public | Save a new profile snapshot               |
 * | GET      | /api/profiles/load/:id     | Public | Load a full profile by ID                 |
 * | DELETE   | /api/profiles/:id          | Public | Delete a profile                          |
 * | GET      | /api/admin/status          | Admin  | Sync engine status + next scheduled run   |
 * | POST     | /api/admin/sync            | Admin  | Trigger a manual sync run                 |
 * | GET      | /api/admin/logs            | Admin  | Sync history log entries                  |
 * | GET      | /api/export/all            | Admin  | Download ZIP of the all-specs addon       |
 * | GET      | /api/export/:specId        | Admin  | Download ZIP of a single-spec addon       |
 */
import type { Express } from "express";
import { createServer, type Server } from "http";
import { storage, DEFAULT_HUD } from "./storage";
import { insertAplEntrySchema, insertHudConfigSchema, insertCombatAlertSchema, insertProfileSchema } from "@shared/schema";
import { z } from "zod";
import { generateAddonZip, generateAllSpecsAddonZip, setAddonVersion } from "./addon-generator";
import type { AllSpecsData } from "./addon-generator";
import { fetchSimcApl } from "./simc-parser";
import { getCommunityApl } from "./community-apls";
import { isAdmin, setupAuth } from "./auth";
import { runSync, cancelSync } from "./sync-engine";
import { startScheduler, getNextScheduledRun } from "./scheduler";

/**
 * Registers all HTTP routes on the Express application and starts the
 * background sync scheduler.
 *
 * Called once during server bootstrap (see `server/index.ts`).
 *
 * Initialization steps:
 * 1. Set up Replit Auth middleware.
 * 2. Restore the persisted addon version from sync state so generated
 *    addons use the correct version string.
 * 3. Register every API route (public, then admin-protected).
 * 4. Start the 24-hour sync scheduler.
 *
 * @param httpServer - The Node.js HTTP server instance (created upstream).
 * @param app - The Express application to attach routes to.
 * @returns The same `httpServer`, allowing chaining in the bootstrap flow.
 */
export async function registerRoutes(httpServer: Server, app: Express): Promise<Server> {
  await setupAuth(app);

  const initState = await storage.getSyncState();
  if (initState.currentVersion) {
    setAddonVersion(initState.currentVersion);
    console.log(`[Init] Addon version restored: v${initState.currentVersion}`);
  }

  let orphansCleaned = 0;
  for (const run of initState.history) {
    if (run.status === "running") {
      await storage.updateSyncRun(run.id, {
        status: "error",
        completedAt: run.startedAt || new Date().toISOString(),
        error: "Orphaned by server restart",
      });
      orphansCleaned++;
    }
  }
  if (orphansCleaned > 0) {
    console.log(`[Init] Cleaned ${orphansCleaned} orphaned sync run(s)`);
  }
  await storage.setSyncRunning(false);

  /**
   * GET /api/version
   * Returns the current addon version string from persisted sync state.
   * @returns {{ version: string }}
   */
  app.get("/api/version", async (_req, res) => {
    const state = await storage.getSyncState();
    res.json({ version: state.currentVersion });
  });

  /**
   * GET /api/specs
   * Returns the full list of supported WoW class/spec definitions.
   * @returns {Spec[]}
   */
  app.get("/api/specs", async (_req, res) => {
    const specs = await storage.getSpecs();
    res.json(specs);
  });

  /**
   * GET /api/specs/:id
   * Returns a single spec by its composite ID (e.g. "frost-death_knight").
   * @param id - Spec identifier
   * @returns {Spec} or 404
   */
  app.get("/api/specs/:id", async (req, res) => {
    const spec = await storage.getSpec(req.params.id);
    if (!spec) return res.status(404).json({ message: "Spec not found" });
    res.json(spec);
  });

  /**
   * GET /api/apl/:specId
   * Returns all APL (Action Priority List) entries for the given spec,
   * ordered by priority.
   * @param specId - Spec identifier
   * @returns {AplEntry[]}
   */
  app.get("/api/apl/:specId", async (req, res) => {
    const entries = await storage.getAplEntries(req.params.specId);
    res.json(entries);
  });

  /**
   * POST /api/apl
   * Creates a new APL entry. Request body is validated against
   * {@link insertAplEntrySchema}.
   * @body {InsertAplEntry}
   * @returns {AplEntry} The newly created entry (with generated `id`).
   */
  app.post("/api/apl", async (req, res) => {
    const result = insertAplEntrySchema.safeParse(req.body);
    if (!result.success) return res.status(400).json({ message: result.error.message });
    const entry = await storage.createAplEntry(result.data);
    res.json(entry);
  });

  /**
   * PATCH /api/apl/:id
   * Partially updates an existing APL entry. Only provided fields are
   * overwritten; the rest are preserved.
   * @param id - APL entry identifier
   * @body {Partial<InsertAplEntry>}
   * @returns {AplEntry} The updated entry, or 404 if not found.
   */
  app.patch("/api/apl/:id", async (req, res) => {
    const result = insertAplEntrySchema.partial().safeParse(req.body);
    if (!result.success) return res.status(400).json({ message: result.error.message });
    const entry = await storage.updateAplEntry(req.params.id, result.data);
    if (!entry) return res.status(404).json({ message: "APL entry not found" });
    res.json(entry);
  });

  /**
   * DELETE /api/apl/:id
   * Removes an APL entry by ID.
   * @param id - APL entry identifier
   * @returns {{ success: true }} or 404
   */
  app.delete("/api/apl/:id", async (req, res) => {
    const ok = await storage.deleteAplEntry(req.params.id);
    if (!ok) return res.status(404).json({ message: "APL entry not found" });
    res.json({ success: true });
  });

  /**
   * POST /api/apl/:specId/reorder
   * Reorders APL entries for a spec by reassigning priorities based on
   * the provided ordered array of entry IDs.
   * @param specId - Spec identifier
   * @body {{ orderedIds: string[] }}
   * @returns {AplEntry[]} The reordered entries with updated priorities.
   */
  app.post("/api/apl/:specId/reorder", async (req, res) => {
    const schema = z.object({ orderedIds: z.array(z.string()) });
    const result = schema.safeParse(req.body);
    if (!result.success) return res.status(400).json({ message: result.error.message });
    const entries = await storage.reorderAplEntries(req.params.specId, result.data.orderedIds);
    res.json(entries);
  });

  /**
   * GET /api/hud/:specId
   * Returns the HUD configuration for a spec. If none exists yet, a
   * default configuration is auto-created and returned.
   * @param specId - Spec identifier
   * @returns {HudConfig}
   */
  app.get("/api/hud/:specId", async (req, res) => {
    const config = await storage.getHudConfig(req.params.specId);
    if (!config) {
      const created = await storage.upsertHudConfig({ ...DEFAULT_HUD, specId: req.params.specId });
      return res.json(created);
    }
    res.json(config);
  });

  /**
   * PUT /api/hud
   * Creates or replaces the HUD configuration for a spec (upsert by specId).
   * Request body is validated against {@link insertHudConfigSchema}.
   * @body {InsertHudConfig}
   * @returns {HudConfig}
   */
  app.put("/api/hud", async (req, res) => {
    const result = insertHudConfigSchema.safeParse(req.body);
    if (!result.success) return res.status(400).json({ message: result.error.message });
    const config = await storage.upsertHudConfig(result.data);
    res.json(config);
  });

  /**
   * GET /api/alerts/:specId
   * Returns all combat alert rules for a spec.
   * @param specId - Spec identifier
   * @returns {CombatAlert[]}
   */
  app.get("/api/alerts/:specId", async (req, res) => {
    const alerts = await storage.getCombatAlerts(req.params.specId);
    res.json(alerts);
  });

  /**
   * POST /api/alerts
   * Creates a new combat alert. Validated against {@link insertCombatAlertSchema}.
   * @body {InsertCombatAlert}
   * @returns {CombatAlert}
   */
  app.post("/api/alerts", async (req, res) => {
    const result = insertCombatAlertSchema.safeParse(req.body);
    if (!result.success) return res.status(400).json({ message: result.error.message });
    const alert = await storage.createCombatAlert(result.data);
    res.json(alert);
  });

  /**
   * PATCH /api/alerts/:id
   * Partially updates a combat alert.
   * @param id - Combat alert identifier
   * @body {Partial<InsertCombatAlert>}
   * @returns {CombatAlert} or 404
   */
  app.patch("/api/alerts/:id", async (req, res) => {
    const result = insertCombatAlertSchema.partial().safeParse(req.body);
    if (!result.success) return res.status(400).json({ message: result.error.message });
    const alert = await storage.updateCombatAlert(req.params.id, result.data);
    if (!alert) return res.status(404).json({ message: "Alert not found" });
    res.json(alert);
  });

  /**
   * DELETE /api/alerts/:id
   * Removes a combat alert by ID.
   * @param id - Combat alert identifier
   * @returns {{ success: true }} or 404
   */
  app.delete("/api/alerts/:id", async (req, res) => {
    const ok = await storage.deleteCombatAlert(req.params.id);
    if (!ok) return res.status(404).json({ message: "Alert not found" });
    res.json({ success: true });
  });

  /**
   * GET /api/profiles/:specId
   * Returns all saved profiles for a spec.
   * @param specId - Spec identifier
   * @returns {Profile[]}
   */
  app.get("/api/profiles/:specId", async (req, res) => {
    const profiles = await storage.getProfiles(req.params.specId);
    res.json(profiles);
  });

  /**
   * POST /api/profiles
   * Saves a new profile snapshot. The current HUD config for the spec is
   * automatically captured and stored alongside the profile data. If no
   * HUD config exists yet, a default one is created first.
   * @body {InsertProfile}
   * @returns {Profile}
   */
  app.post("/api/profiles", async (req, res) => {
    const result = insertProfileSchema.safeParse(req.body);
    if (!result.success) return res.status(400).json({ message: result.error.message });
    let hudConfig = await storage.getHudConfig(result.data.specId);
    if (!hudConfig) {
      hudConfig = await storage.upsertHudConfig({ ...DEFAULT_HUD, specId: result.data.specId });
    }
    const profile = await storage.saveProfile(result.data, hudConfig);
    res.json(profile);
  });

  /**
   * GET /api/profiles/load/:id
   * Loads a full profile by its ID, including the embedded HUD config snapshot.
   * @param id - Profile identifier
   * @returns {Profile} or 404
   */
  app.get("/api/profiles/load/:id", async (req, res) => {
    const profile = await storage.loadProfile(req.params.id);
    if (!profile) return res.status(404).json({ message: "Profile not found" });
    res.json(profile);
  });

  /**
   * DELETE /api/profiles/:id
   * Removes a saved profile by ID.
   * @param id - Profile identifier
   * @returns {{ success: true }} or 404
   */
  app.delete("/api/profiles/:id", async (req, res) => {
    const ok = await storage.deleteProfile(req.params.id);
    if (!ok) return res.status(404).json({ message: "Profile not found" });
    res.json({ success: true });
  });

  /**
   * GET /api/admin/status
   * Returns the sync engine's current state: last run info, current version,
   * whether a sync is in progress, and the next scheduled run time.
   * Protected by `isAdmin` middleware.
   * @returns {SyncState & { nextScheduledRun: string | null }}
   */
  app.get("/api/admin/status", isAdmin, async (_req, res) => {
    const state = await storage.getSyncState();
    const nextRun = getNextScheduledRun();
    res.json({
      ...state,
      currentVersion: state.currentVersion,
      nextScheduledRun: nextRun?.toISOString() ?? null,
    });
  });

  /**
   * POST /api/admin/sync
   * Triggers a manual sync run. Returns immediately with a confirmation
   * message; the sync executes asynchronously in the background.
   * Returns 409 if a sync is already in progress.
   * Protected by `isAdmin` middleware.
   * @returns {{ message: string }} or 409/500
   */
  app.post("/api/admin/sync", isAdmin, async (_req, res) => {
    try {
      const state = await storage.getSyncState();
      if (state.isRunning) {
        return res.status(409).json({ message: "A sync is already running" });
      }

      res.json({ message: "Sync started" });

      runSync("manual").catch(err => {
        console.error("[Admin Sync] Error:", err.message);
      });
    } catch (err: any) {
      res.status(500).json({ message: err.message });
    }
  });

  app.post("/api/admin/sync/cancel", isAdmin, async (_req, res) => {
    try {
      const cancelled = cancelSync();
      await storage.setSyncRunning(false);
      const state = await storage.getSyncState();
      let orphansCleaned = 0;
      for (const run of state.history) {
        if (run.status === "running") {
          await storage.updateSyncRun(run.id, {
            status: "error",
            completedAt: new Date().toISOString(),
            error: "Cancelled by admin",
          });
          orphansCleaned++;
        }
      }
      if (cancelled) {
        res.json({ message: `Sync cancellation requested (${orphansCleaned} orphaned runs cleaned)` });
      } else if (orphansCleaned > 0) {
        res.json({ message: `No active sync process — cleaned ${orphansCleaned} orphaned run(s)` });
      } else {
        res.json({ message: "No sync is currently running" });
      }
    } catch (err: any) {
      res.status(500).json({ message: err.message });
    }
  });

  /**
   * GET /api/admin/logs
   * Returns the full sync run history array from persisted state.
   * Protected by `isAdmin` middleware.
   * @returns {SyncRun[]}
   */
  app.get("/api/admin/logs", isAdmin, async (_req, res) => {
    const state = await storage.getSyncState();
    res.json(state.history);
  });

  app.get("/api/admin/variables/:specId", isAdmin, async (req, res) => {
    try {
      const specId = req.params.specId;
      const simcResult = await fetchSimcApl(specId);
      if (!simcResult) return res.json({ variables: [], source: null });
      res.json({
        variables: simcResult.variables,
        source: simcResult.source,
      });
    } catch (_err) {
      res.status(500).json({ message: "Failed to fetch variables" });
    }
  });

  app.get("/api/sim/specs", async (_req, res) => {
    const { getAvailableSpecs } = await import("./priority-simulator");
    res.json(getAvailableSpecs());
  });

  app.get("/api/sim/spells/:specId", async (req, res) => {
    const { getSpecSpells } = await import("./priority-simulator");
    const spells = getSpecSpells(req.params.specId);
    if (!spells.length) return res.status(404).json({ message: "Spec not found" });
    res.json(spells);
  });

  app.post("/api/sim/run", async (req, res) => {
    const { simulatePriority } = await import("./priority-simulator");
    const { specId, combatMode, spells, aplBranch } = req.body;
    if (!specId || !combatMode || !spells) {
      return res.status(400).json({ message: "Missing specId, combatMode, or spells" });
    }
    const results = simulatePriority(specId, combatMode, spells, aplBranch || "community");
    res.json(results);
  });

  app.get("/api/sim/validate/all", async (_req, res) => {
    const { validateAllSpecs } = await import("./priority-sim-validator");
    res.json(validateAllSpecs());
  });

  app.get("/api/sim/validate/:specId", async (req, res) => {
    const { validateSpec } = await import("./priority-sim-validator");
    res.json(validateSpec(req.params.specId));
  });

  app.post("/api/sim/validate/log", async (req, res) => {
    const { parseLogForScenarios, simulateFromLogScenario } = await import("./priority-sim-validator");
    const { logText } = req.body;
    if (!logText) return res.status(400).json({ message: "Missing logText" });
    const scenarios = parseLogForScenarios(logText);
    const results = scenarios.map(s => simulateFromLogScenario(s));
    res.json({ scenarios: scenarios.length, results });
  });

  app.post("/api/sim/replay", async (req, res) => {
    const { replayLogVsSim } = await import("./priority-sim-validator");
    const { logText, specId } = req.body;
    if (!logText) return res.status(400).json({ message: "Missing logText" });
    res.json(replayLogVsSim(logText, specId));
  });

  app.post("/api/sim/validate/scenario", async (req, res) => {
    const { simulateFromLogScenario } = await import("./priority-sim-validator");
    res.json(simulateFromLogScenario(req.body));
  });

  app.get("/api/admin/variables-summary", isAdmin, async (_req, res) => {
    try {
      const specs = await storage.getSpecs();
      const summary: { specId: string; specName: string; className: string; varCount: number; source: string | null }[] = [];
      for (const spec of specs) {
        const simcResult = await fetchSimcApl(spec.id);
        summary.push({
          specId: spec.id,
          specName: spec.specName,
          className: spec.className,
          varCount: simcResult?.variables?.length ?? 0,
          source: simcResult?.source ?? null,
        });
      }
      res.json(summary);
    } catch (_err) {
      res.status(500).json({ message: "Failed to fetch variables summary" });
    }
  });

  /**
   * GET /api/export/all
   * Generates and streams a ZIP archive containing the all-specs addon
   * package. Fetches fresh SimC APL data for each spec (falling back to
   * stored entries), bundles with HUD configs and combat alerts.
   * Protected by `isAdmin` middleware.
   * @returns Binary ZIP stream (Content-Type: application/zip)
   */
  app.get("/api/export/all", isAdmin, async (_req, res) => {
    try {
      const state = await storage.getSyncState();
      setAddonVersion(state.currentVersion);
      const allSpecsData = await buildAllSpecsData();
      const archive = generateAllSpecsAddonZip(allSpecsData);

      res.setHeader("Content-Type", "application/zip");
      res.setHeader("Content-Disposition", `attachment; filename="DMGAssist_${Date.now()}.zip"`);
      res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
      res.setHeader("Pragma", "no-cache");
      res.setHeader("Expires", "0");

      archive.on("error", (_err: Error) => {
        if (!res.headersSent) {
          res.status(500).json({ message: "Failed to generate addon package" });
        }
      });

      archive.pipe(res);
      archive.finalize();
    } catch (_err) {
      if (!res.headersSent) {
        res.status(500).json({ message: "Failed to generate addon package" });
      }
    }
  });

  /**
   * GET /api/export/:specId
   * Generates and streams a ZIP archive for a single spec's addon.
   * Attempts to fetch fresh SimC APL data; falls back to stored entries.
   * Auto-creates a default HUD config if none exists for the spec.
   * Protected by `isAdmin` middleware.
   * @param specId - Spec identifier
   * @returns Binary ZIP stream (Content-Type: application/zip) or 404/500
   */
  app.get("/api/export/:specId", isAdmin, async (req, res) => {
    const specId = req.params.specId;
    const spec = await storage.getSpec(specId);
    if (!spec) return res.status(404).json({ message: "Spec not found" });

    const communityApl = getCommunityApl(specId);
    let aplEntries;
    let variables: any[] = [];
    if (communityApl && communityApl.length > 0) {
      aplEntries = communityApl;
    } else {
      const simcResult = await fetchSimcApl(specId);
      aplEntries = simcResult ? simcResult.entries : await storage.getAplEntries(specId);
      variables = simcResult ? simcResult.variables : [];
    }
    let hudConfig = await storage.getHudConfig(specId);
    if (!hudConfig) {
      hudConfig = await storage.upsertHudConfig({ ...DEFAULT_HUD, specId });
    }
    const alerts = await storage.getCombatAlerts(specId);

    const syncState = await storage.getSyncState();
    setAddonVersion(syncState.currentVersion);
    const archive = generateAddonZip({ spec, aplEntries, hudConfig, alerts, variables, aplBranch: communityApl ? "community" : undefined });

    const fileName = `DMGAssist_${spec.specName.replace(/\s/g, "")}_${spec.className.replace(/\s/g, "")}_${Date.now()}.zip`;
    res.setHeader("Content-Type", "application/zip");
    res.setHeader("Content-Disposition", `attachment; filename="${fileName}"`);
    res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
    res.setHeader("Pragma", "no-cache");
    res.setHeader("Expires", "0");

    archive.on("error", (_err: Error) => {
      if (!res.headersSent) {
        res.status(500).json({ message: "Failed to generate addon package" });
      }
    });

    archive.pipe(res);
    archive.finalize();
  });

  startScheduler();

  return httpServer;
}

/**
 * Aggregates data for every supported spec into a single payload used by
 * {@link generateAllSpecsAddonZip} to produce the all-in-one addon archive.
 *
 * For each spec:
 * 1. Attempts to fetch fresh APL data from SimC GitHub; falls back to stored entries.
 * 2. Loads (or auto-creates) the HUD config.
 * 3. Loads combat alerts.
 *
 * @returns A complete {@link AllSpecsData} object ready for archive generation.
 */
async function buildAllSpecsData(): Promise<AllSpecsData> {
  const specs = await storage.getSpecs();
  const allSpecsData: AllSpecsData = { specs: [] };

  for (const spec of specs) {
    const communityApl = getCommunityApl(spec.id);
    let aplEntries;
    let variables: any[] = [];
    let aplBranch: string | undefined;
    if (communityApl && communityApl.length > 0) {
      aplEntries = communityApl;
      aplBranch = "community";
    } else {
      const simcResult = await fetchSimcApl(spec.id);
      aplEntries = simcResult ? simcResult.entries : await storage.getAplEntries(spec.id);
      variables = simcResult ? simcResult.variables : [];
    }
    let hudConfig = await storage.getHudConfig(spec.id);
    if (!hudConfig) {
      hudConfig = await storage.upsertHudConfig({ ...DEFAULT_HUD, specId: spec.id });
    }
    const alerts = await storage.getCombatAlerts(spec.id);
    allSpecsData.specs.push({ spec, aplEntries, hudConfig, alerts, variables, aplBranch });
  }

  return allSpecsData;
}
