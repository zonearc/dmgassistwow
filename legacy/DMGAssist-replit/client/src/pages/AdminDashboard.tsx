/**
 * @module AdminDashboard
 * @description Protected admin panel for managing the DMGAssist sync pipeline.
 * Requires Replit authentication; unauthenticated users are shown a login prompt.
 *
 * Features:
 * - Real-time sync status display (current version, last sync time, next scheduled run)
 * - Manual "Trigger Sync Now" button to kick off the SimC → CurseForge pipeline
 * - Download link for the latest generated addon ZIP
 * - Reverse-chronological sync history with per-run status, version, and error details
 *
 * Data endpoints:
 * - `GET  /api/admin/status` — Polled every 5 s for live sync state
 * - `POST /api/admin/sync`   — Triggers a new sync run
 * - `GET  /api/export/all`   — Downloads the latest addon archive
 */

import { useState } from "react";
import { useQuery, useMutation } from "@tanstack/react-query";
import { queryClient } from "@/lib/queryClient";
import { useAuth } from "@/hooks/use-auth";
import type { SyncState, SyncRun } from "@shared/schema";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Loader2, Play, CheckCircle2, XCircle, Clock,
  RefreshCw, ArrowLeft, Zap, Download, LogIn, LogOut, SkipForward,
  Variable, ChevronDown, ChevronRight, Code2, Hash, FileText
} from "lucide-react";

/**
 * Admin dashboard page component. Handles three visual states:
 * 1. **Loading** — Spinner while auth status is being determined.
 * 2. **Unauthenticated** — Login card with Replit OAuth link.
 * 3. **Authenticated** — Full dashboard with sync controls and history.
 */
export default function AdminDashboard() {
  const { user: authUser, isLoading: authLoading, isAuthenticated, logout } = useAuth();

  const { data: syncState, isLoading } = useQuery<SyncState & { nextScheduledRun: string | null }>({
    queryKey: ["/api/admin/status"],
    queryFn: async () => {
      const res = await fetch("/api/admin/status", { credentials: "include" });
      if (res.status === 401) {
        queryClient.setQueryData(["/api/auth/user"], null);
        throw new Error("Session expired");
      }
      if (!res.ok) throw new Error("Status fetch failed");
      return res.json();
    },
    refetchInterval: 5000,
    enabled: isAuthenticated,
    retry: false,
  });

  const triggerSync = useMutation({
    mutationFn: async () => {
      const res = await fetch("/api/admin/sync", { method: "POST", credentials: "include" });
      if (res.status === 401) {
        queryClient.setQueryData(["/api/auth/user"], null);
        throw new Error("Session expired");
      }
      if (!res.ok) throw new Error("Sync trigger failed");
      return res;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["/api/admin/status"] });
    },
  });

  const cancelSyncMutation = useMutation({
    mutationFn: async () => {
      const res = await fetch("/api/admin/sync/cancel", { method: "POST", credentials: "include" });
      if (!res.ok) throw new Error("Cancel failed");
      return res.json();
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["/api/admin/status"] });
    },
  });

  if (authLoading) {
    return (
      <div className="min-h-screen bg-background text-foreground flex items-center justify-center">
        <Loader2 className="w-6 h-6 animate-spin text-primary" />
      </div>
    );
  }

  if (!isAuthenticated) {
    return (
      <div className="min-h-screen bg-background text-foreground flex items-center justify-center">
        <Card className="w-full max-w-sm">
          <CardContent className="p-6 space-y-4">
            <div className="text-center">
              <LogIn className="w-8 h-8 text-primary mx-auto mb-2" />
              <p className="text-lg font-semibold mb-1">Admin Dashboard</p>
              <p className="text-sm text-muted-foreground">Sign in to access the admin panel.</p>
            </div>
            <Button
              className="w-full gap-2"
              asChild
              data-testid="button-login"
            >
              <a href="/api/login?returnTo=/admin">
                <LogIn className="w-4 h-4" />
                Sign in with Replit
              </a>
            </Button>
          </CardContent>
        </Card>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="min-h-screen bg-background text-foreground flex items-center justify-center">
        <Loader2 className="w-6 h-6 animate-spin text-primary" />
      </div>
    );
  }

  const displayName = authUser?.firstName
    ? `${authUser.firstName}${authUser.lastName ? ` ${authUser.lastName}` : ""}`
    : authUser?.email ?? "Admin";

  return (
    <div className="min-h-screen bg-background text-foreground">
      <div className="max-w-3xl mx-auto px-6 py-8">
        <div className="flex items-center justify-between mb-6">
          <div className="flex items-center gap-3">
            <Button variant="ghost" size="sm" asChild data-testid="link-back-home">
              <a href="/"><ArrowLeft className="w-4 h-4 mr-1" /> Home</a>
            </Button>
            <h1 className="font-display text-2xl font-bold" data-testid="text-admin-title">Admin Dashboard</h1>
          </div>
          <div className="flex items-center gap-2">
            {authUser?.profileImageUrl && (
              <img
                src={authUser.profileImageUrl}
                alt=""
                className="w-6 h-6 rounded-full"
                data-testid="img-admin-avatar"
              />
            )}
            <span className="text-xs text-muted-foreground" data-testid="text-admin-user">{displayName}</span>
            <Button variant="ghost" size="sm" onClick={() => logout()} data-testid="button-logout">
              <LogOut className="w-3.5 h-3.5" />
            </Button>
          </div>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 mb-6">
          <StatusCard
            label="Current Version"
            value={syncState?.currentVersion ?? "..."}
            testId="text-current-version"
          />
          <StatusCard
            label="Last Sync"
            value={syncState?.lastSyncTime ? formatRelative(syncState.lastSyncTime) : "Never"}
            testId="text-last-sync"
          />
          <StatusCard
            label="Next Scheduled"
            value={syncState?.nextScheduledRun ? formatRelative(syncState.nextScheduledRun) : "Not scheduled"}
            testId="text-next-sync"
          />
        </div>

        <Card className="mb-6">
          <CardHeader>
            <div className="flex items-center justify-between">
              <CardTitle className="text-sm font-display">Sync Control</CardTitle>
              {syncState?.isRunning && (
                <Badge variant="secondary" className="gap-1" data-testid="badge-sync-running">
                  <Loader2 className="w-3 h-3 animate-spin" />
                  Running
                </Badge>
              )}
            </div>
          </CardHeader>
          <CardContent className="space-y-3">
            {syncState?.lastError && syncState.lastSyncStatus === "error" && (
              <div className="p-3 rounded bg-red-500/10 border border-red-500/20 text-xs text-red-400" data-testid="text-last-error">
                Last error: {syncState.lastError}
              </div>
            )}
            <div className="flex gap-2">
              <Button
                onClick={() => triggerSync.mutate()}
                disabled={syncState?.isRunning || triggerSync.isPending}
                className="gap-2"
                data-testid="button-trigger-sync"
              >
                {triggerSync.isPending || syncState?.isRunning ? (
                  <Loader2 className="w-4 h-4 animate-spin" />
                ) : (
                  <Play className="w-4 h-4" />
                )}
                Trigger Sync Now
              </Button>
              {syncState?.isRunning && (
                <Button
                  variant="destructive"
                  onClick={() => cancelSyncMutation.mutate()}
                  disabled={cancelSyncMutation.isPending}
                  className="gap-2"
                  data-testid="button-cancel-sync"
                >
                  {cancelSyncMutation.isPending ? (
                    <Loader2 className="w-4 h-4 animate-spin" />
                  ) : (
                    <XCircle className="w-4 h-4" />
                  )}
                  Cancel Sync
                </Button>
              )}
              {!syncState?.isRunning && (
                <Button
                  variant="secondary"
                  className="gap-2"
                  asChild
                  data-testid="button-download-addon"
                >
                  <a href="/api/export/all" download>
                    <Download className="w-4 h-4" />
                    Download Latest
                  </a>
                </Button>
              )}
              <Button
                variant="outline"
                className="gap-2"
                asChild
                data-testid="link-curseforge-description"
              >
                <a href="/admin/curseforge">
                  <FileText className="w-4 h-4" />
                  CurseForge Page
                </a>
              </Button>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-display">Sync History</CardTitle>
          </CardHeader>
          <CardContent>
            {!syncState?.history?.length ? (
              <p className="text-xs text-muted-foreground" data-testid="text-no-history">No sync runs yet.</p>
            ) : (
              <div className="space-y-2">
                {[...syncState.history].reverse().map((run) => (
                  <SyncRunRow key={run.id} run={run} />
                ))}
              </div>
            )}
          </CardContent>
        </Card>

        <VariablesPanel isAuthenticated={isAuthenticated} />
      </div>
    </div>
  );
}

/**
 * Compact summary card displaying a single key-value metric (e.g. "Current Version: 1.2.3").
 *
 * @param props.label  - Uppercase label text.
 * @param props.value  - Display value string.
 * @param props.testId - `data-testid` attribute for automated testing.
 */
function StatusCard({ label, value, testId }: { label: string; value: string; testId: string }) {
  return (
    <Card className="border-border/20 bg-card/40">
      <CardContent className="p-4">
        <p className="text-[11px] text-muted-foreground/60 uppercase tracking-wider mb-1">{label}</p>
        <p className="text-sm font-semibold text-foreground/80" data-testid={testId}>{value}</p>
      </CardContent>
    </Card>
  );
}

/**
 * Single row in the sync history list. Displays run status icon, addon version,
 * trigger source badge, optional CurseForge upload badge, spec counts, errors,
 * and a relative timestamp.
 *
 * @param props.run - A {@link SyncRun} record from the sync history array.
 */
function SyncRunRow({ run }: { run: SyncRun }) {
  return (
    <div className="flex items-center gap-3 p-2 rounded bg-muted/10" data-testid={`row-sync-${run.id}`}>
      <div className="flex-shrink-0">
        {run.status === "success" && <CheckCircle2 className="w-4 h-4 text-green-400" />}
        {run.status === "error" && <XCircle className="w-4 h-4 text-red-400" />}
        {run.status === "running" && <Loader2 className="w-4 h-4 animate-spin text-primary" />}
        {run.status === "skipped" && <SkipForward className="w-4 h-4 text-yellow-400" />}
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-xs font-semibold text-foreground/80">v{run.addonVersion}</span>
          <Badge variant="outline" className="text-[10px] py-0 h-4">
            {run.triggeredBy}
          </Badge>
          {run.curseforgeUploaded && (
            <Badge variant="secondary" className="text-[10px] py-0 h-4 gap-0.5">
              <RefreshCw className="w-2.5 h-2.5" />
              CF
            </Badge>
          )}
        </div>
        {run.status === "success" && (
          <p className="text-[10px] text-muted-foreground mt-0.5">
            {run.simcSpecs} SimC specs, {run.fallbackSpecs} fallback
          </p>
        )}
        {run.status === "skipped" && (
          <p className="text-[10px] text-yellow-400/70 mt-0.5">No changes detected</p>
        )}
        {run.status === "error" && run.error && (
          <p className="text-[10px] text-red-400/70 mt-0.5 truncate">{run.error}</p>
        )}
      </div>
      <div className="flex-shrink-0 text-right">
        <p className="text-[10px] text-muted-foreground/50">
          <Clock className="w-3 h-3 inline mr-0.5" />
          {run.startedAt ? formatRelative(run.startedAt) : "..."}
        </p>
      </div>
    </div>
  );
}

interface SimcVar {
  name: string;
  value: string;
  op: string;
  condition?: string;
  valueElse?: string;
  default?: string;
}

interface VarSummaryItem {
  specId: string;
  specName: string;
  className: string;
  varCount: number;
  source: string | null;
}

function VariablesPanel({ isAuthenticated }: { isAuthenticated: boolean }) {
  const [expanded, setExpanded] = useState(false);
  const [selectedSpec, setSelectedSpec] = useState<string | null>(null);

  const { data: summary = [] } = useQuery<VarSummaryItem[]>({
    queryKey: ["/api/admin/variables-summary"],
    queryFn: async () => {
      const res = await fetch("/api/admin/variables-summary", { credentials: "include" });
      if (!res.ok) return [];
      return res.json();
    },
    enabled: isAuthenticated && expanded,
    staleTime: 60000,
  });

  const { data: varData, isLoading: varsLoading } = useQuery<{ variables: SimcVar[]; source: string | null }>({
    queryKey: ["/api/admin/variables", selectedSpec],
    queryFn: async () => {
      const res = await fetch(`/api/admin/variables/${selectedSpec}`, { credentials: "include" });
      if (!res.ok) return { variables: [], source: null };
      return res.json();
    },
    enabled: isAuthenticated && !!selectedSpec,
    staleTime: 60000,
  });

  const totalVars = summary.reduce((sum, s) => sum + s.varCount, 0);
  const specsWithVars = summary.filter(s => s.varCount > 0);

  const opColors: Record<string, string> = {
    set: "text-blue-400",
    setif: "text-cyan-400",
    add: "text-green-400",
    sub: "text-orange-400",
    min: "text-yellow-400",
    max: "text-yellow-400",
    reset: "text-red-400",
  };

  return (
    <Card className="mt-6" data-testid="card-variables">
      <CardHeader
        className="cursor-pointer select-none"
        onClick={() => setExpanded(!expanded)}
      >
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Variable className="w-4 h-4 text-amber-400" />
            <CardTitle className="text-sm font-display">SimC Variables</CardTitle>
          </div>
          <div className="flex items-center gap-2">
            {expanded && totalVars > 0 && (
              <Badge variant="secondary" className="text-[10px] py-0 h-4 gap-0.5" data-testid="badge-total-vars">
                <Hash className="w-2.5 h-2.5" />
                {totalVars} vars across {specsWithVars.length} specs
              </Badge>
            )}
            {expanded ? <ChevronDown className="w-4 h-4 text-muted-foreground" /> : <ChevronRight className="w-4 h-4 text-muted-foreground" />}
          </div>
        </div>
      </CardHeader>
      {expanded && (
        <CardContent className="space-y-4">
          <div className="flex items-center gap-3">
            <Select
              value={selectedSpec ?? ""}
              onValueChange={(val) => setSelectedSpec(val || null)}
            >
              <SelectTrigger className="w-64 h-8 text-xs" data-testid="select-spec-vars">
                <SelectValue placeholder="Select a spec to inspect..." />
              </SelectTrigger>
              <SelectContent>
                {specsWithVars.map((s) => (
                  <SelectItem key={s.specId} value={s.specId} data-testid={`option-spec-${s.specId}`}>
                    {s.className} - {s.specName} ({s.varCount} vars)
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {varData?.source && (
              <Badge variant="outline" className="text-[10px] py-0 h-4" data-testid="badge-var-source">
                {varData.source}
              </Badge>
            )}
          </div>

          {varsLoading && selectedSpec && (
            <div className="flex items-center gap-2 py-4 justify-center">
              <Loader2 className="w-4 h-4 animate-spin text-primary" />
              <span className="text-xs text-muted-foreground">Loading variables...</span>
            </div>
          )}

          {!selectedSpec && (
            <p className="text-xs text-muted-foreground py-2" data-testid="text-select-prompt">
              Select a spec to view its SimC variable definitions and compiled Lua expressions.
            </p>
          )}

          {selectedSpec && varData && !varsLoading && (
            <div className="space-y-1.5" data-testid="list-variables">
              {varData.variables.length === 0 ? (
                <p className="text-xs text-muted-foreground py-2">No variables defined for this spec.</p>
              ) : (
                varData.variables.map((v, i) => (
                  <div
                    key={`${v.name}-${i}`}
                    className="p-2.5 rounded bg-muted/10 border border-border/10 space-y-1"
                    data-testid={`row-var-${v.name}-${i}`}
                  >
                    <div className="flex items-center gap-2">
                      <Code2 className="w-3 h-3 text-amber-400/70 flex-shrink-0" />
                      <span className="text-xs font-mono font-semibold text-foreground/90">{v.name}</span>
                      <Badge
                        variant="outline"
                        className={`text-[10px] py-0 h-4 ${opColors[v.op] || "text-muted-foreground"}`}
                      >
                        {v.op}
                      </Badge>
                    </div>
                    <div className="pl-5">
                      <p className="text-[11px] font-mono text-muted-foreground/80 break-all leading-relaxed">{v.value}</p>
                      {v.condition && (
                        <p className="text-[10px] text-cyan-400/60 mt-0.5">
                          <span className="text-muted-foreground/40">if: </span>{v.condition}
                        </p>
                      )}
                      {v.valueElse && (
                        <p className="text-[10px] text-orange-400/60 mt-0.5">
                          <span className="text-muted-foreground/40">else: </span>{v.valueElse}
                        </p>
                      )}
                    </div>
                  </div>
                ))
              )}
            </div>
          )}
        </CardContent>
      )}
    </Card>
  );
}

/**
 * Formats an ISO 8601 date string as a human-friendly relative time label.
 * Handles both past ("5m ago") and future ("in 2h") timestamps.
 * Falls back to `toLocaleDateString()` for dates older than 24 hours.
 *
 * @param isoString - ISO 8601 timestamp string.
 * @returns A short relative time string (e.g. "30s ago", "in 15m").
 */
function formatRelative(isoString: string): string {
  const date = new Date(isoString);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffSec = Math.floor(diffMs / 1000);

  if (diffSec < 0) {
    const absSec = Math.abs(diffSec);
    if (absSec < 60) return `in ${absSec}s`;
    if (absSec < 3600) return `in ${Math.floor(absSec / 60)}m`;
    return `in ${Math.floor(absSec / 3600)}h`;
  }

  if (diffSec < 60) return `${diffSec}s ago`;
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m ago`;
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h ago`;
  return date.toLocaleDateString();
}
