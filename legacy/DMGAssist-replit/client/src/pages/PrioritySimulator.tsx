import { useState, useCallback } from "react";
import { useQuery, useMutation } from "@tanstack/react-query";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { Badge } from "@/components/ui/badge";
import { Textarea } from "@/components/ui/textarea";
import { ArrowLeft, Play, Zap, Clock, Target, Shield, Swords, RotateCcw, CheckCircle2, XCircle, AlertTriangle, ChevronDown, ChevronRight, FlaskConical, FileText } from "lucide-react";
import { Link } from "wouter";
import { apiRequest } from "@/lib/queryClient";

interface SpellState {
  spellName: string;
  spellId: number;
  priority: number;
  mode: "ST" | "AoE" | "Both";
  isCooldown: boolean;
  isOffensive: boolean;
  isInterrupt: boolean;
  cdReady: boolean;
  cdRemaining: number;
  cdDuration: number;
  isUsable: boolean;
  isAcRecommended: boolean;
  isAnts: boolean;
  isProc: boolean;
  conditionMet: boolean;
}

interface SimResult {
  spellName: string;
  score: number;
  tier: string;
  reason: string;
  signal: string;
  mode: string;
  basePrio: number;
  isCD: boolean;
  modeMismatch: boolean;
}

interface Anomaly {
  severity: "error" | "warning" | "info";
  rule: string;
  message: string;
  spellName?: string;
  details?: string;
  time?: number;
}

interface ScenarioResult {
  scenarioName: string;
  description: string;
  combatMode: "ST" | "AoE";
  results: SimResult[];
  anomalies: Anomaly[];
  topQueue: string[];
  passed: boolean;
}

interface SpellStat {
  spellName: string;
  totalCasts: number;
  timesInSlot1: number;
  firstSlot1Time: number | null;
  avgGapBetweenCasts: number | null;
  longestDrought: number;
  isCD: boolean;
  cdDuration: number;
  mode: string;
  priority: number;
}

interface TimelineEntry {
  time: number;
  castSpell: string;
  slot1: string;
  slot2: string;
  slot3: string;
  acState?: string;
  resources?: { primary: number; secondary?: number; primaryType: string; secondaryType?: string };
  resourceBlocked?: string;
}

interface TimelineResult {
  scenarioName: string;
  description: string;
  combatMode: "ST" | "AoE";
  duration: number;
  timeline: TimelineEntry[];
  anomalies: Anomaly[];
  spellStats: SpellStat[];
  passed: boolean;
}

interface SpecValidation {
  specId: string;
  specLabel: string;
  spellCount: number;
  cdCount: number;
  scenarios: ScenarioResult[];
  timelineResults: TimelineResult[];
  totalAnomalies: number;
  errors: number;
  warnings: number;
  passed: boolean;
}

interface BatchResult {
  timestamp: string;
  duration: number;
  totalSpecs: number;
  passedSpecs: number;
  failedSpecs: number;
  totalAnomalies: number;
  totalErrors: number;
  specs: SpecValidation[];
}

const SPEC_LABELS: Record<string, string> = {
  "druid-balance": "Balance Druid",
  "rogue-ass": "Assassination Rogue",
  "evoker-aug": "Augmentation Evoker",
  "dk-blood": "Blood Death Knight",
  "dh-vengeance": "Vengeance Demon Hunter",
  "druid-guardian": "Guardian Druid",
  "monk-brew": "Brewmaster Monk",
  "paladin-prot": "Protection Paladin",
  "warrior-prot": "Protection Warrior",
  "druid-resto": "Restoration Druid",
  "evoker-pres": "Preservation Evoker",
  "monk-mw": "Mistweaver Monk",
  "paladin-holy": "Holy Paladin",
  "priest-disc": "Discipline Priest",
  "priest-holy": "Holy Priest",
  "shaman-resto": "Restoration Shaman",
};

function getTierColor(tier: string): string {
  if (tier.includes("T1")) return "bg-purple-500/20 text-purple-300 border-purple-500/50";
  if (tier.includes("T2b")) return "bg-orange-500/20 text-orange-300 border-orange-500/50";
  if (tier.includes("T2")) return "bg-red-500/20 text-red-300 border-red-500/50";
  if (tier.includes("T3")) return "bg-yellow-500/20 text-yellow-300 border-yellow-500/50";
  if (tier.includes("T4")) return "bg-amber-500/20 text-amber-300 border-amber-500/50";
  if (tier.includes("T5")) return "bg-green-500/20 text-green-300 border-green-500/50";
  if (tier.includes("T6")) return "bg-blue-500/20 text-blue-300 border-blue-500/50";
  if (tier.includes("T7")) return "bg-cyan-500/20 text-cyan-300 border-cyan-500/50";
  if (tier.includes("T9")) return "bg-zinc-700/40 text-zinc-400 border-zinc-600/50";
  if (tier.includes("T10")) return "bg-zinc-800/40 text-zinc-500 border-zinc-700/50";
  return "bg-zinc-600/20 text-zinc-400 border-zinc-500/50";
}

function getSignalIcon(signal: string) {
  switch (signal) {
    case "ANTS": return <Zap className="w-3 h-3 text-yellow-400" />;
    case "PROC": return <Zap className="w-3 h-3 text-blue-400" />;
    case "ASSISTED": return <Target className="w-3 h-3 text-amber-400" />;
    case "READY": return <Shield className="w-3 h-3 text-green-400" />;
    default: return <Clock className="w-3 h-3 text-zinc-500" />;
  }
}

function ResultsTable({ results, specId, combatMode }: { results: SimResult[]; specId: string; combatMode: string }) {
  return (
    <div className="space-y-1">
      <div className="grid grid-cols-12 gap-2 px-3 py-1 text-[10px] text-zinc-500 uppercase tracking-wider border-b border-zinc-800">
        <div className="col-span-1">#</div>
        <div className="col-span-3">Spell</div>
        <div className="col-span-1">Score</div>
        <div className="col-span-2">Tier</div>
        <div className="col-span-1">Signal</div>
        <div className="col-span-1">Mode</div>
        <div className="col-span-3">Reason</div>
      </div>
      {results.map((r, i) => (
        <div
          key={r.spellName}
          className={`grid grid-cols-12 gap-2 px-3 py-2 rounded text-sm items-center ${
            i < 3 ? "bg-zinc-800/70 border border-zinc-700/50" : ""
          } ${r.modeMismatch ? "opacity-40" : ""}`}
          data-testid={`result-row-${i}`}
        >
          <div className="col-span-1">
            {i < 3 ? (
              <span className={`inline-flex items-center justify-center w-5 h-5 rounded-full text-xs font-bold ${
                i === 0 ? "bg-amber-600 text-white" : i === 1 ? "bg-zinc-600 text-zinc-200" : "bg-zinc-700 text-zinc-300"
              }`}>
                {i + 1}
              </span>
            ) : (
              <span className="text-zinc-600 text-xs">{i + 1}</span>
            )}
          </div>
          <div className="col-span-3 font-medium text-zinc-200 flex items-center gap-1">
            {r.isCD && <Clock className="w-3 h-3 text-purple-400 shrink-0" />}
            <span className="truncate">{r.spellName}</span>
          </div>
          <div className="col-span-1">
            <span className={`font-mono text-xs ${r.score < 0 ? "text-green-400" : "text-red-400"}`}>
              {r.score}
            </span>
          </div>
          <div className="col-span-2">
            <Badge variant="outline" className={`text-[10px] ${getTierColor(r.tier)}`}>
              {r.tier.split(":")[0]}
            </Badge>
          </div>
          <div className="col-span-1 flex items-center gap-1">
            {getSignalIcon(r.signal)}
            <span className="text-[10px] text-zinc-500">{r.signal}</span>
          </div>
          <div className="col-span-1">
            <span className={`text-[10px] ${
              r.mode === "AoE" ? "text-orange-400" : r.mode === "ST" ? "text-blue-400" : "text-zinc-400"
            }`}>
              {r.mode}
            </span>
          </div>
          <div className="col-span-3 text-[11px] text-zinc-500 truncate" title={r.reason}>
            {r.reason}
          </div>
        </div>
      ))}
    </div>
  );
}

function QueuePreview({ results }: { results: SimResult[] }) {
  const ready = results.filter(r => !r.modeMismatch && r.score < 9000).slice(0, 3);
  if (!ready.length) return null;
  return (
    <div className="mt-4 p-3 bg-zinc-800/50 rounded-lg border border-zinc-700/30">
      <h3 className="text-xs text-zinc-400 uppercase tracking-wider mb-2">Queue Output (Top 3)</h3>
      <div className="flex gap-3">
        {ready.map((r, i) => (
          <div key={r.spellName} className="flex-1 text-center p-2 bg-zinc-900 rounded border border-zinc-700">
            <div className="text-[10px] text-zinc-500 mb-1">Slot {i + 1}</div>
            <div className="text-sm font-bold text-amber-400">{r.spellName}</div>
            <div className="text-[10px] text-zinc-500 mt-1">{r.tier.split(":")[1]?.trim()}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

function AnomalyBadge({ anomaly }: { anomaly: Anomaly }) {
  const colors = {
    error: "bg-red-500/20 text-red-300 border-red-500/50",
    warning: "bg-yellow-500/20 text-yellow-300 border-yellow-500/50",
    info: "bg-blue-500/20 text-blue-300 border-blue-500/50",
  };
  const icons = {
    error: <XCircle className="w-3 h-3 text-red-400 shrink-0" />,
    warning: <AlertTriangle className="w-3 h-3 text-yellow-400 shrink-0" />,
    info: <CheckCircle2 className="w-3 h-3 text-blue-400 shrink-0" />,
  };
  return (
    <div className={`flex items-start gap-2 p-2 rounded border text-xs ${colors[anomaly.severity]}`}>
      {icons[anomaly.severity]}
      <div>
        <span className="font-mono text-[10px] opacity-70">[{anomaly.rule}]</span>{" "}
        {anomaly.message}
      </div>
    </div>
  );
}

function BatchValidationTab() {
  const [batchResult, setBatchResult] = useState<BatchResult | null>(null);
  const [expandedSpec, setExpandedSpec] = useState<string | null>(null);
  const [expandedScenario, setExpandedScenario] = useState<string | null>(null);
  const [logText, setLogText] = useState("");
  const [logResults, setLogResults] = useState<{ scenarios: number; results: ScenarioResult[] } | null>(null);

  const { mutate: runBatch, isPending: batchRunning } = useMutation({
    mutationFn: async () => {
      const res = await apiRequest("GET", "/api/sim/validate/all");
      return res.json() as Promise<BatchResult>;
    },
    onSuccess: (data) => setBatchResult(data),
  });

  const { mutate: runLogReplay, isPending: logRunning } = useMutation({
    mutationFn: async () => {
      const res = await apiRequest("POST", "/api/sim/validate/log", { logText });
      return res.json() as Promise<{ scenarios: number; results: ScenarioResult[] }>;
    },
    onSuccess: (data) => setLogResults(data),
  });

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <Card className="bg-zinc-900 border-zinc-800">
          <CardHeader className="pb-3">
            <CardTitle className="text-sm text-zinc-400 uppercase tracking-wider flex items-center gap-2">
              <FlaskConical className="w-4 h-4" /> Batch Validation
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <p className="text-xs text-zinc-500">
              Runs 60s time-stepping combat simulations across all 16 specs. Catches spells that never get cast,
              CDs stuck in queue while on cooldown, wrong-mode spells appearing, and delayed CD promotion.
            </p>
            <Button
              onClick={() => runBatch()}
              disabled={batchRunning}
              className="w-full bg-amber-600 hover:bg-amber-700 text-white"
              data-testid="button-run-batch"
            >
              <Play className="w-4 h-4 mr-2" />
              {batchRunning ? "Running all specs..." : "Run All Specs"}
            </Button>
          </CardContent>
        </Card>

        <Card className="bg-zinc-900 border-zinc-800">
          <CardHeader className="pb-3">
            <CardTitle className="text-sm text-zinc-400 uppercase tracking-wider flex items-center gap-2">
              <FileText className="w-4 h-4" /> Log Replay
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <p className="text-xs text-zinc-500">
              Paste debug log output to extract AC highlight states and replay them through the simulator.
              Parses spec, combat mode, and AC signal data from log lines.
            </p>
            <Textarea
              value={logText}
              onChange={e => setLogText(e.target.value)}
              placeholder="Paste debug log lines here... (AC-NEXT, ANTS, ASSISTED lines)"
              className="bg-zinc-800 border-zinc-700 text-xs font-mono h-24 resize-none"
              data-testid="textarea-log"
            />
            <Button
              onClick={() => runLogReplay()}
              disabled={logRunning || !logText.trim()}
              size="sm"
              className="bg-zinc-700 hover:bg-zinc-600 text-white"
              data-testid="button-run-log"
            >
              <Play className="w-3 h-3 mr-1" />
              {logRunning ? "Parsing..." : "Replay Log Scenarios"}
            </Button>
          </CardContent>
        </Card>
      </div>

      {batchResult && (
        <Card className="bg-zinc-900 border-zinc-800">
          <CardHeader className="pb-3">
            <div className="flex items-center justify-between">
              <CardTitle className="text-sm text-zinc-400 uppercase tracking-wider">
                Batch Results
              </CardTitle>
              <div className="flex items-center gap-3 text-xs">
                <span className="text-zinc-500">{batchResult.duration}ms</span>
                <Badge variant="outline" className="border-green-600 text-green-400">
                  {batchResult.passedSpecs} passed
                </Badge>
                {batchResult.failedSpecs > 0 && (
                  <Badge variant="outline" className="border-red-600 text-red-400">
                    {batchResult.failedSpecs} failed
                  </Badge>
                )}
                <Badge variant="outline" className="border-yellow-600 text-yellow-400">
                  {batchResult.totalAnomalies} anomalies
                </Badge>
              </div>
            </div>
          </CardHeader>
          <CardContent className="space-y-2">
            {batchResult.specs.map(spec => (
              <div key={spec.specId} className="border border-zinc-800 rounded-lg overflow-hidden">
                <button
                  onClick={() => setExpandedSpec(expandedSpec === spec.specId ? null : spec.specId)}
                  className="w-full flex items-center justify-between px-4 py-3 bg-zinc-800/30 hover:bg-zinc-800/50 transition-colors"
                  data-testid={`spec-row-${spec.specId}`}
                >
                  <div className="flex items-center gap-3">
                    {spec.passed ? (
                      <CheckCircle2 className="w-4 h-4 text-green-400" />
                    ) : (
                      <XCircle className="w-4 h-4 text-red-400" />
                    )}
                    <span className="text-sm font-medium text-zinc-200">{spec.specLabel}</span>
                    <span className="text-[10px] text-zinc-500">
                      {spec.spellCount} spells, {spec.cdCount} CDs
                    </span>
                  </div>
                  <div className="flex items-center gap-2">
                    {spec.errors > 0 && (
                      <Badge variant="outline" className="text-[10px] border-red-600 text-red-400">
                        {spec.errors} errors
                      </Badge>
                    )}
                    {spec.warnings > 0 && (
                      <Badge variant="outline" className="text-[10px] border-yellow-600 text-yellow-400">
                        {spec.warnings} warnings
                      </Badge>
                    )}
                    {spec.passed && spec.warnings === 0 && (
                      <Badge variant="outline" className="text-[10px] border-green-600 text-green-400">
                        clean
                      </Badge>
                    )}
                    {expandedSpec === spec.specId ? (
                      <ChevronDown className="w-4 h-4 text-zinc-500" />
                    ) : (
                      <ChevronRight className="w-4 h-4 text-zinc-500" />
                    )}
                  </div>
                </button>

                {expandedSpec === spec.specId && (
                  <div className="p-4 space-y-4 border-t border-zinc-800">
                    {(spec.timelineResults || []).length > 0 && (
                      <div className="space-y-3">
                        <h4 className="text-xs text-amber-400 uppercase tracking-wider font-semibold flex items-center gap-2">
                          <Swords className="w-3 h-3" /> Combat Simulations (5min)
                        </h4>
                        {(spec.timelineResults || []).map(tr => {
                          const trKey = `${spec.specId}-tl-${tr.scenarioName}`;
                          const trErrors = tr.anomalies.filter(a => a.severity === "error").length;
                          const trWarnings = tr.anomalies.filter(a => a.severity === "warning").length;
                          return (
                            <div key={tr.scenarioName} className="border border-zinc-700/50 rounded-lg overflow-hidden">
                              <button
                                onClick={() => setExpandedScenario(expandedScenario === trKey ? null : trKey)}
                                className="w-full flex items-center justify-between px-3 py-2 bg-zinc-800/20 hover:bg-zinc-800/40 transition-colors"
                                data-testid={`timeline-${tr.scenarioName}`}
                              >
                                <div className="flex items-center gap-2">
                                  {tr.passed ? (
                                    <CheckCircle2 className="w-3 h-3 text-green-400" />
                                  ) : (
                                    <XCircle className="w-3 h-3 text-red-400" />
                                  )}
                                  <span className="text-xs font-medium text-zinc-300">{tr.description}</span>
                                  <Badge variant="outline" className="text-[10px] border-zinc-600">
                                    {tr.combatMode}
                                  </Badge>
                                </div>
                                <div className="flex items-center gap-2">
                                  {trErrors > 0 && (
                                    <Badge variant="outline" className="text-[10px] border-red-600 text-red-400">
                                      {trErrors} errors
                                    </Badge>
                                  )}
                                  {trWarnings > 0 && (
                                    <Badge variant="outline" className="text-[10px] border-yellow-600 text-yellow-400">
                                      {trWarnings} warns
                                    </Badge>
                                  )}
                                  {expandedScenario === trKey ? (
                                    <ChevronDown className="w-3 h-3 text-zinc-500" />
                                  ) : (
                                    <ChevronRight className="w-3 h-3 text-zinc-500" />
                                  )}
                                </div>
                              </button>
                              {expandedScenario === trKey && (
                                <div className="p-3 space-y-4 border-t border-zinc-800/50">
                                  {tr.anomalies.length > 0 && (
                                    <div className="space-y-1">
                                      {tr.anomalies.map((a, i) => (
                                        <AnomalyBadge key={i} anomaly={a} />
                                      ))}
                                    </div>
                                  )}
                                  <div>
                                    <h5 className="text-[10px] text-zinc-500 uppercase tracking-wider mb-2">Spell Statistics</h5>
                                    <div className="overflow-x-auto">
                                      <table className="w-full text-xs">
                                        <thead>
                                          <tr className="text-[10px] text-zinc-500 uppercase border-b border-zinc-800">
                                            <th className="text-left py-1 px-2">Spell</th>
                                            <th className="text-center py-1 px-1">P</th>
                                            <th className="text-center py-1 px-1">Mode</th>
                                            <th className="text-center py-1 px-1">CD</th>
                                            <th className="text-center py-1 px-1">Casts</th>
                                            <th className="text-center py-1 px-1">#1 Hits</th>
                                            <th className="text-center py-1 px-1">First #1</th>
                                            <th className="text-center py-1 px-1">Avg Gap</th>
                                            <th className="text-center py-1 px-1">Drought</th>
                                          </tr>
                                        </thead>
                                        <tbody>
                                          {tr.spellStats.sort((a, b) => a.priority - b.priority).map(ss => {
                                            const neverCast = ss.totalCasts === 0 && ss.mode !== "AoE" && tr.combatMode === "ST" && ss.mode !== "AoE";
                                            const neverSlot1 = ss.timesInSlot1 === 0 && !ss.isCD;
                                            const isStarved = neverCast && !ss.isCD && (ss.mode === tr.combatMode || ss.mode === "Both");
                                            return (
                                              <tr
                                                key={ss.spellName}
                                                className={`border-b border-zinc-800/30 ${
                                                  isStarved ? "bg-red-900/20" : neverSlot1 ? "bg-yellow-900/10" : ""
                                                }`}
                                              >
                                                <td className="py-1.5 px-2 font-medium text-zinc-200">
                                                  {ss.isCD && <Clock className="w-3 h-3 text-purple-400 inline mr-1" />}
                                                  {ss.spellName}
                                                </td>
                                                <td className="text-center text-zinc-400">{ss.priority}</td>
                                                <td className="text-center">
                                                  <span className={`${
                                                    ss.mode === "ST" ? "text-blue-400" : ss.mode === "AoE" ? "text-orange-400" : "text-zinc-400"
                                                  }`}>{ss.mode}</span>
                                                </td>
                                                <td className="text-center text-zinc-500">
                                                  {ss.cdDuration > 0 ? `${ss.cdDuration}s` : "-"}
                                                </td>
                                                <td className={`text-center font-mono ${ss.totalCasts === 0 ? "text-red-400 font-bold" : "text-zinc-300"}`}>
                                                  {ss.totalCasts}
                                                </td>
                                                <td className={`text-center font-mono ${ss.timesInSlot1 === 0 ? "text-red-400" : "text-zinc-300"}`}>
                                                  {ss.timesInSlot1}
                                                </td>
                                                <td className="text-center text-zinc-500 font-mono">
                                                  {ss.firstSlot1Time !== null ? `${ss.firstSlot1Time}s` : "never"}
                                                </td>
                                                <td className="text-center text-zinc-500 font-mono">
                                                  {ss.avgGapBetweenCasts !== null ? `${ss.avgGapBetweenCasts}s` : "-"}
                                                </td>
                                                <td className={`text-center font-mono ${ss.longestDrought > 20 ? "text-yellow-400" : "text-zinc-500"}`}>
                                                  {ss.longestDrought > 0 ? `${ss.longestDrought}s` : "-"}
                                                </td>
                                              </tr>
                                            );
                                          })}
                                        </tbody>
                                      </table>
                                    </div>
                                  </div>
                                  <div>
                                    <h5 className="text-[10px] text-zinc-500 uppercase tracking-wider mb-2">GCD Timeline (first 40)</h5>
                                    <div className="space-y-0.5 font-mono text-[11px]">
                                      {tr.timeline.slice(0, 40).map((e, i) => (
                                        <div key={i} className={`flex items-center gap-2 px-2 py-0.5 rounded hover:bg-zinc-800/30 ${e.resourceBlocked ? 'bg-red-950/20' : ''}`}>
                                          <span className="text-zinc-600 w-10 text-right">{e.time}s</span>
                                          <span className={`w-32 truncate font-semibold ${e.castSpell === '(none)' ? 'text-red-400' : 'text-amber-400'}`}>{e.castSpell}</span>
                                          <span className="text-zinc-600 text-[10px]">
                                            [{e.slot1} &gt; {e.slot2} &gt; {e.slot3}]
                                          </span>
                                          {e.resources && (
                                            <span className="text-[9px] text-blue-400">
                                              {e.resources.primaryType}={e.resources.primary}
                                              {e.resources.secondary !== undefined && ` ${e.resources.secondaryType}=${e.resources.secondary}`}
                                            </span>
                                          )}
                                          {e.resourceBlocked && (
                                            <Badge variant="outline" className="text-[9px] border-red-600 text-red-400 py-0" data-testid={`badge-resource-blocked-${i}`}>
                                              {e.resourceBlocked}
                                            </Badge>
                                          )}
                                          {e.acState && (
                                            <Badge variant="outline" className="text-[9px] border-purple-600 text-purple-400 py-0">
                                              {e.acState}
                                            </Badge>
                                          )}
                                        </div>
                                      ))}
                                    </div>
                                  </div>
                                </div>
                              )}
                            </div>
                          );
                        })}
                      </div>
                    )}

                    {spec.scenarios.length > 0 && (
                      <div className="space-y-3">
                        <h4 className="text-xs text-zinc-500 uppercase tracking-wider font-semibold flex items-center gap-2">
                          <FlaskConical className="w-3 h-3" /> Snapshot Scenarios
                        </h4>
                        {spec.scenarios.map(scenario => {
                          const scenarioKey = `${spec.specId}-${scenario.scenarioName}`;
                          return (
                            <div key={scenario.scenarioName} className="border border-zinc-700/50 rounded-lg overflow-hidden">
                              <button
                                onClick={() => setExpandedScenario(expandedScenario === scenarioKey ? null : scenarioKey)}
                                className="w-full flex items-center justify-between px-3 py-2 bg-zinc-800/20 hover:bg-zinc-800/40 transition-colors"
                                data-testid={`scenario-${scenario.scenarioName}`}
                              >
                                <div className="flex items-center gap-2">
                                  {scenario.passed ? (
                                    <CheckCircle2 className="w-3 h-3 text-green-400" />
                                  ) : (
                                    <XCircle className="w-3 h-3 text-red-400" />
                                  )}
                                  <span className="text-xs font-medium text-zinc-300">{scenario.description}</span>
                                  <Badge variant="outline" className="text-[10px] border-zinc-600">
                                    {scenario.combatMode}
                                  </Badge>
                                </div>
                                <div className="flex items-center gap-2">
                                  <span className="text-[10px] text-zinc-500">
                                    Queue: {scenario.topQueue.join(" > ") || "empty"}
                                  </span>
                                  {scenario.anomalies.length > 0 && (
                                    <Badge variant="outline" className="text-[10px] border-yellow-600 text-yellow-400">
                                      {scenario.anomalies.length}
                                    </Badge>
                                  )}
                                  {expandedScenario === scenarioKey ? (
                                    <ChevronDown className="w-3 h-3 text-zinc-500" />
                                  ) : (
                                    <ChevronRight className="w-3 h-3 text-zinc-500" />
                                  )}
                                </div>
                              </button>
                              {expandedScenario === scenarioKey && (
                                <div className="p-3 space-y-3 border-t border-zinc-800/50">
                                  {scenario.anomalies.length > 0 && (
                                    <div className="space-y-1">
                                      {scenario.anomalies.map((a, i) => (
                                        <AnomalyBadge key={i} anomaly={a} />
                                      ))}
                                    </div>
                                  )}
                                  <ResultsTable results={scenario.results} specId={spec.specId} combatMode={scenario.combatMode} />
                                  <QueuePreview results={scenario.results} />
                                </div>
                              )}
                            </div>
                          );
                        })}
                      </div>
                    )}
                  </div>
                )}
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      {logResults && (
        <Card className="bg-zinc-900 border-zinc-800">
          <CardHeader className="pb-3">
            <CardTitle className="text-sm text-zinc-400 uppercase tracking-wider">
              Log Replay Results ({logResults.scenarios} scenarios parsed)
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {logResults.scenarios === 0 && (
              <p className="text-xs text-zinc-500">No AC signal lines found in the log. Look for lines containing ANTS, ASSISTED, or AC-NEXT.</p>
            )}
            {logResults.results.map((scenario, i) => (
              <div key={i} className="border border-zinc-700/50 rounded-lg overflow-hidden">
                <div className="flex items-center justify-between px-3 py-2 bg-zinc-800/20">
                  <div className="flex items-center gap-2">
                    {scenario.passed ? (
                      <CheckCircle2 className="w-3 h-3 text-green-400" />
                    ) : (
                      <XCircle className="w-3 h-3 text-red-400" />
                    )}
                    <span className="text-xs font-medium text-zinc-300">{scenario.description}</span>
                  </div>
                  <span className="text-[10px] text-zinc-500">
                    Queue: {scenario.topQueue.join(" > ")}
                  </span>
                </div>
                {scenario.anomalies.length > 0 && (
                  <div className="p-2 space-y-1 border-t border-zinc-800/50">
                    {scenario.anomalies.map((a, j) => (
                      <AnomalyBadge key={j} anomaly={a} />
                    ))}
                  </div>
                )}
              </div>
            ))}
          </CardContent>
        </Card>
      )}
    </div>
  );
}

function InteractiveTab() {
  const [specId, setSpecId] = useState<string>("");
  const [combatMode, setCombatMode] = useState<"ST" | "AoE">("ST");
  const [spells, setSpells] = useState<SpellState[]>([]);
  const [results, setResults] = useState<SimResult[] | null>(null);

  const { data: specs } = useQuery<string[]>({
    queryKey: ["/api/sim/specs"],
  });

  const { mutate: loadSpells } = useMutation({
    mutationFn: async (sid: string) => {
      const res = await apiRequest("GET", `/api/sim/spells/${sid}`);
      return res.json() as Promise<SpellState[]>;
    },
    onSuccess: (data) => {
      setSpells(data);
      setResults(null);
    },
  });

  const { mutate: runSim, isPending: running } = useMutation({
    mutationFn: async () => {
      const res = await apiRequest("POST", "/api/sim/run", { specId, combatMode, spells });
      return res.json() as Promise<SimResult[]>;
    },
    onSuccess: (data) => setResults(data),
  });

  const handleSpecChange = useCallback((val: string) => {
    setSpecId(val);
    setResults(null);
    loadSpells(val);
  }, [loadSpells]);

  const updateSpell = useCallback((index: number, field: keyof SpellState, value: any) => {
    setSpells(prev => {
      const next = [...prev];
      next[index] = { ...next[index], [field]: value };
      return next;
    });
    setResults(null);
  }, []);

  return (
    <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
      <div className="lg:col-span-1 space-y-4">
        <Card className="bg-zinc-900 border-zinc-800">
          <CardHeader className="pb-3">
            <CardTitle className="text-sm text-zinc-400 uppercase tracking-wider">Configuration</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div>
              <label className="text-xs text-zinc-500 mb-1 block">Specialization</label>
              <Select value={specId} onValueChange={handleSpecChange}>
                <SelectTrigger className="bg-zinc-800 border-zinc-700" data-testid="select-spec">
                  <SelectValue placeholder="Pick a spec..." />
                </SelectTrigger>
                <SelectContent>
                  {specs?.map(s => (
                    <SelectItem key={s} value={s} data-testid={`option-spec-${s}`}>
                      {SPEC_LABELS[s] || s}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div>
              <label className="text-xs text-zinc-500 mb-1 block">Combat Mode</label>
              <div className="flex gap-2">
                <Button
                  variant={combatMode === "ST" ? "default" : "outline"}
                  size="sm"
                  onClick={() => { setCombatMode("ST"); setResults(null); }}
                  className={combatMode === "ST" ? "bg-amber-600 hover:bg-amber-700" : "border-zinc-700"}
                  data-testid="button-mode-st"
                >
                  <Swords className="w-3 h-3 mr-1" /> Single Target
                </Button>
                <Button
                  variant={combatMode === "AoE" ? "default" : "outline"}
                  size="sm"
                  onClick={() => { setCombatMode("AoE"); setResults(null); }}
                  className={combatMode === "AoE" ? "bg-amber-600 hover:bg-amber-700" : "border-zinc-700"}
                  data-testid="button-mode-aoe"
                >
                  <Target className="w-3 h-3 mr-1" /> AoE
                </Button>
              </div>
            </div>

            <div className="flex gap-2 flex-wrap">
              <Button size="sm" variant="outline" onClick={() => setSpells(prev => prev.map(s => ({ ...s, cdReady: true, isUsable: true, conditionMet: true })))} className="border-zinc-700 text-xs" data-testid="button-all-ready">
                All Ready
              </Button>
              <Button size="sm" variant="outline" onClick={() => { setSpells(prev => prev.map(s => ({ ...s, isAcRecommended: false, isAnts: false, isProc: false }))); setResults(null); }} className="border-zinc-700 text-xs" data-testid="button-clear-ac">
                Clear AC
              </Button>
              <Button size="sm" variant="outline" onClick={() => { if (specId) loadSpells(specId); }} className="border-zinc-700 text-xs" data-testid="button-reset">
                <RotateCcw className="w-3 h-3 mr-1" /> Reset
              </Button>
            </div>

            <Button
              onClick={() => runSim()}
              disabled={!specId || !spells.length || running}
              className="w-full bg-amber-600 hover:bg-amber-700 text-white"
              data-testid="button-simulate"
            >
              <Play className="w-4 h-4 mr-2" />
              {running ? "Simulating..." : "Simulate Priority"}
            </Button>
          </CardContent>
        </Card>

        {spells.length > 0 && (
          <Card className="bg-zinc-900 border-zinc-800">
            <CardHeader className="pb-3">
              <CardTitle className="text-sm text-zinc-400 uppercase tracking-wider">
                Spell States ({spells.length})
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 max-h-[60vh] overflow-y-auto">
              {spells.map((spell, i) => (
                <div key={`${spell.spellName}-${i}`} className="p-3 bg-zinc-800/50 rounded-lg border border-zinc-700/50 space-y-2">
                  <div className="flex items-center justify-between">
                    <span className="text-sm font-medium text-zinc-200">{spell.spellName}</span>
                    <div className="flex gap-1">
                      <Badge variant="outline" className="text-[10px] border-zinc-600">P{spell.priority}</Badge>
                      <Badge variant="outline" className={`text-[10px] ${spell.mode === "AoE" ? "border-orange-600 text-orange-400" : spell.mode === "ST" ? "border-blue-600 text-blue-400" : "border-zinc-600 text-zinc-400"}`}>
                        {spell.mode}
                      </Badge>
                      {spell.isCooldown && (
                        <Badge variant="outline" className="text-[10px] border-purple-600 text-purple-400">CD</Badge>
                      )}
                    </div>
                  </div>
                  <div className="grid grid-cols-2 gap-x-4 gap-y-1">
                    {(["cdReady", "isUsable", "isAcRecommended", "isAnts", "isProc", "conditionMet"] as const).map((field, fi) => {
                      const labels: Record<string, string> = { cdReady: "Off CD", isUsable: "Usable", isAcRecommended: "AC Rec", isAnts: "AC Ants", isProc: "Proc", conditionMet: "Cond OK" };
                      return (
                        <label key={field} className="flex items-center gap-2 text-xs text-zinc-400">
                          <Switch
                            checked={spell[field] as boolean}
                            onCheckedChange={v => updateSpell(i, field, v)}
                            className="scale-75"
                            data-testid={`switch-${field.replace(/([A-Z])/g, '-$1').toLowerCase()}-${i}`}
                          />
                          {labels[field]}
                        </label>
                      );
                    })}
                  </div>
                </div>
              ))}
            </CardContent>
          </Card>
        )}
      </div>

      <div className="lg:col-span-2">
        {results ? (
          <Card className="bg-zinc-900 border-zinc-800">
            <CardHeader className="pb-3">
              <CardTitle className="text-sm text-zinc-400 uppercase tracking-wider">
                Priority Queue ({SPEC_LABELS[specId] || specId} - {combatMode} mode)
              </CardTitle>
            </CardHeader>
            <CardContent>
              <ResultsTable results={results} specId={specId} combatMode={combatMode} />
              <QueuePreview results={results} />
            </CardContent>
          </Card>
        ) : (
          <Card className="bg-zinc-900 border-zinc-800">
            <CardContent className="py-20 text-center">
              <Swords className="w-12 h-12 text-zinc-700 mx-auto mb-4" />
              <p className="text-zinc-500 text-lg mb-2">Select a spec and click Simulate</p>
              <p className="text-zinc-600 text-sm max-w-md mx-auto">
                Toggle spell states (on CD, AC recommended, proc active, etc.) to see exactly how the scoring engine ranks your abilities.
              </p>
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  );
}

export default function PrioritySimulator() {
  const [tab, setTab] = useState<"interactive" | "batch">("batch");

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100">
      <div className="max-w-6xl mx-auto px-4 py-6">
        <div className="flex items-center gap-4 mb-6">
          <Link href="/admin">
            <Button variant="ghost" size="sm" data-testid="link-back-admin">
              <ArrowLeft className="w-4 h-4 mr-1" /> Admin
            </Button>
          </Link>
          <h1 className="text-2xl font-bold text-amber-400">Priority Simulator</h1>
          <Badge variant="outline" className="text-zinc-400 border-zinc-700">Offline Engine Testing</Badge>
        </div>

        <div className="flex gap-2 mb-6">
          <Button
            variant={tab === "batch" ? "default" : "outline"}
            size="sm"
            onClick={() => setTab("batch")}
            className={tab === "batch" ? "bg-amber-600 hover:bg-amber-700" : "border-zinc-700"}
            data-testid="tab-batch"
          >
            <FlaskConical className="w-3 h-3 mr-1" /> Batch Validation
          </Button>
          <Button
            variant={tab === "interactive" ? "default" : "outline"}
            size="sm"
            onClick={() => setTab("interactive")}
            className={tab === "interactive" ? "bg-amber-600 hover:bg-amber-700" : "border-zinc-700"}
            data-testid="tab-interactive"
          >
            <Swords className="w-3 h-3 mr-1" /> Interactive
          </Button>
        </div>

        {tab === "batch" ? <BatchValidationTab /> : <InteractiveTab />}
      </div>
    </div>
  );
}
