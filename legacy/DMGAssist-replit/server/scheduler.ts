import { runSync } from "./sync-engine";

let intervalId: ReturnType<typeof setInterval> | null = null;
let nextScheduledRun: Date | null = null;
let initialSyncTimeout: ReturnType<typeof setTimeout> | null = null;
const SYNC_INTERVAL_MS = 7 * 24 * 60 * 60 * 1000;
const INITIAL_SYNC_DELAY_MS = 15_000;

export function startScheduler() {
  if (intervalId) return;

  console.log(`[Scheduler] Starting. Initial sync in ${INITIAL_SYNC_DELAY_MS / 1000}s, then every 7 days.`);

  initialSyncTimeout = setTimeout(async () => {
    console.log(`[Scheduler] Running initial sync...`);
    try {
      await runSync("schedule");
      console.log(`[Scheduler] Initial sync complete.`);
    } catch (err: any) {
      console.error(`[Scheduler] Initial sync failed:`, err.message);
    }
    initialSyncTimeout = null;
  }, INITIAL_SYNC_DELAY_MS);

  nextScheduledRun = new Date(Date.now() + SYNC_INTERVAL_MS);
  console.log(`[Scheduler] Weekly sync scheduled. Next at ${nextScheduledRun.toISOString()}`);

  intervalId = setInterval(async () => {
    console.log(`[Scheduler] Running weekly sync check...`);
    try {
      await runSync("schedule");
    } catch (err: any) {
      console.error(`[Scheduler] Sync failed:`, err.message);
    }
    nextScheduledRun = new Date(Date.now() + SYNC_INTERVAL_MS);
    console.log(`[Scheduler] Next sync check at ${nextScheduledRun.toISOString()}`);
  }, SYNC_INTERVAL_MS);
}

export function stopScheduler() {
  if (intervalId) {
    clearInterval(intervalId);
    intervalId = null;
    nextScheduledRun = null;
  }
  if (initialSyncTimeout) {
    clearTimeout(initialSyncTimeout);
    initialSyncTimeout = null;
  }
}

export function getNextScheduledRun(): Date | null {
  return nextScheduledRun;
}
