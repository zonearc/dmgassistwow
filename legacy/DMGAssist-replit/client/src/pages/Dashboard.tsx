import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import type { Spec } from "@shared/schema";
import { Button } from "@/components/ui/button";
import {
  ExternalLink, Download, Heart, HelpCircle,
  Swords, ChevronRight, Shield, Zap, Users,
  Brain, Lock, RefreshCw,
  Code, CheckCircle, AlertTriangle,
} from "lucide-react";
import dmgassistIcon from "@assets/dmgassist-icon.png";

const CURSEFORGE_URL = "https://www.curseforge.com/wow/addons/dmgassist";
const PAYPAL_URL = "https://www.paypal.com/paypalme/theegli";

type TabId = "about" | "how" | "help";

export default function Dashboard() {
  const [activeTab, setActiveTab] = useState<TabId>("about");

  const { data: specs = [] } = useQuery<Spec[]>({
    queryKey: ["/api/specs"],
  });

  const { data: versionData } = useQuery<{ version: string }>({
    queryKey: ["/api/version"],
  });

  const classCount = new Set(specs.map(s => s.className)).size;

  return (
    <div className="h-screen bg-[#1a1d24] text-foreground flex flex-col overflow-hidden" data-testid="page-dashboard">
      <header className="flex-shrink-0 border-b border-white/5 bg-[#14161b]">
        <div className="max-w-5xl mx-auto px-4 sm:px-6">
          <div className="flex items-center justify-between h-14 sm:h-16 gap-4">
            <div className="flex items-center gap-3 flex-shrink-0">
              <img
                src={dmgassistIcon}
                alt="DMGAssist"
                className="w-9 h-9 sm:w-10 sm:h-10 object-contain"
                data-testid="img-logo"
              />
              <div className="leading-none">
                <span className="font-display text-base sm:text-lg font-bold tracking-wide">
                  <span className="text-amber-400">DMG</span><span className="text-white/90">Assist</span>
                </span>
                <span className="hidden sm:block text-[10px] text-white/30 font-medium tracking-widest uppercase mt-0.5">
                  Advanced Rotation HUD
                </span>
              </div>
            </div>

            <nav className="flex items-center gap-0.5" role="tablist" aria-label="Page sections">
              <TabButton id="about" icon={<Swords className="w-3.5 h-3.5" />} label="Addon" active={activeTab} onClick={setActiveTab} />
              <TabButton id="how" icon={<Brain className="w-3.5 h-3.5" />} label="How It Works" active={activeTab} onClick={setActiveTab} />
              <TabButton id="help" icon={<HelpCircle className="w-3.5 h-3.5" />} label="Help" active={activeTab} onClick={setActiveTab} />
            </nav>

            <div className="hidden md:flex items-center gap-2 flex-shrink-0">
              <Button
                size="sm"
                data-testid="button-curseforge-header"
                className="h-8 text-xs font-display font-bold gap-1.5 bg-amber-500 hover:bg-amber-400 text-black border-0"
                asChild
              >
                <a href={CURSEFORGE_URL} target="_blank" rel="noopener noreferrer">
                  <Download className="w-3.5 h-3.5" />
                  Download
                </a>
              </Button>
            </div>
          </div>
        </div>
      </header>

      <main className="flex-1 min-h-0 overflow-y-auto">
        <div className="max-w-5xl mx-auto px-4 sm:px-6 py-6" role="tabpanel" id={`tabpanel-${activeTab}`}>
          {activeTab === "about" && <AboutTab specs={specs} classCount={classCount} version={versionData?.version} />}
          {activeTab === "how" && <HowItWorksTab />}
          {activeTab === "help" && <HelpTab />}
        </div>
      </main>

      <footer className="flex-shrink-0 border-t border-white/5 bg-[#14161b]">
        <div className="max-w-5xl mx-auto px-4 sm:px-6 py-2.5 flex flex-wrap items-center justify-between gap-2">
          <div className="flex items-center gap-4">
            <a
              href={CURSEFORGE_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="text-[11px] text-white/30 hover:text-white/60 transition-colors"
              data-testid="link-curseforge-footer"
            >
              CurseForge
            </a>
            {versionData?.version && (
              <span className="text-[11px] font-mono text-white/20" data-testid="text-version-footer">
                v{versionData.version}
              </span>
            )}
          </div>
          <a
            href={PAYPAL_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-1.5 text-[11px] text-white/30 hover:text-amber-400/70 transition-colors"
            data-testid="link-donate-footer"
          >
            <Heart className="w-3 h-3" />
            Support Development
          </a>
        </div>
      </footer>
    </div>
  );
}

function TabButton({ id, icon, label, active, onClick }: {
  id: TabId;
  icon: React.ReactNode;
  label: string;
  active: TabId;
  onClick: (id: TabId) => void;
}) {
  const isActive = active === id;
  return (
    <button
      role="tab"
      aria-selected={isActive}
      aria-controls={`tabpanel-${id}`}
      onClick={() => onClick(id)}
      data-testid={`tab-${id}`}
      className={`
        flex items-center gap-1.5 py-1.5 px-3 sm:px-4 rounded-md text-xs font-semibold
        transition-all duration-150 cursor-pointer
        ${isActive
          ? "bg-amber-500/15 text-amber-400 border border-amber-500/20"
          : "text-white/40 hover:text-white/60 hover:bg-white/5 border border-transparent"
        }
      `}
    >
      {icon}
      <span className="font-display tracking-wide">{label}</span>
    </button>
  );
}

function AboutTab({ specs, classCount, version }: { specs: Spec[]; classCount: number; version?: string }) {
  return (
    <div className="space-y-8">
      <div className="flex flex-col lg:flex-row gap-8 items-start">
        <div className="flex-1 space-y-5">
          <div className="space-y-3">
            <h1 className="font-display text-2xl sm:text-3xl font-bold text-white leading-tight" data-testid="text-headline">
              Stop staring at your bars.{" "}
              <span className="text-amber-400">Start playing the game.</span>
            </h1>
            <p className="text-sm text-white/45 leading-relaxed max-w-xl">
              DMGAssist shows you exactly what spell to press next so you can focus on what
              actually matters: dodging mechanics, handling pulls, and staying alive. No
              more alt-tabbing to Icy Veins mid-dungeon or memorizing 15-step priority lists.
              Just a clean 2-3 spell queue, updated in real time, using the same SimulationCraft
              data the top players rely on. Built for Midnight 12.0 from the ground up, it
              works with Blizzard's own rotation engine to give you optimized spell priority
              across every class and spec.
            </p>
          </div>

          <div className="flex flex-wrap gap-3">
            <Button
              size="lg"
              data-testid="button-curseforge"
              className="h-11 text-sm font-display font-bold gap-2 bg-amber-500 hover:bg-amber-400 text-black border-0 shadow-lg shadow-amber-500/15"
              asChild
            >
              <a href={CURSEFORGE_URL} target="_blank" rel="noopener noreferrer">
                <Download className="w-4 h-4" />
                Get it on CurseForge
                <ExternalLink className="w-3 h-3 opacity-50" />
              </a>
            </Button>
            <Button
              size="lg"
              variant="outline"
              data-testid="button-donate"
              className="h-11 text-sm font-display font-semibold gap-2 border-white/10 text-white/60 hover:text-amber-400 hover:border-amber-500/20 hover:bg-amber-500/5"
              asChild
            >
              <a href={PAYPAL_URL} target="_blank" rel="noopener noreferrer">
                <Heart className="w-4 h-4" />
                Donate
              </a>
            </Button>
          </div>

          {version && (
            <p className="text-[11px] font-mono text-white/20" data-testid="text-addon-version">
              v{version} &middot; {specs.length} specs &middot; {classCount} classes &middot; auto-updated weekly
            </p>
          )}
        </div>

        <div className="w-full lg:w-72 flex-shrink-0 space-y-3">
          <div className="grid grid-cols-3 lg:grid-cols-1 gap-2">
            <StatCard value={`${specs.length}`} label="Every Spec" icon={<Swords className="w-4 h-4 text-amber-400/50" />} testId="stat-specs" />
            <StatCard value="Always Current" label="SimC Auto-Sync" icon={<RefreshCw className="w-4 h-4 text-amber-400/50" />} testId="stat-sync" />
            <StatCard value="Zero Config" label="Install & Play" icon={<CheckCircle className="w-4 h-4 text-amber-400/50" />} testId="stat-setup" />
          </div>
        </div>
      </div>

      <div className="rounded-xl border border-white/6 bg-white/[0.02] p-5">
        <div className="flex items-center gap-2 mb-4">
          <Shield className="w-4 h-4 text-amber-400/50" />
          <span className="text-xs font-display font-semibold text-white/50 uppercase tracking-wider">How it works</span>
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <MiniStep num="1" title="Install" desc="Grab it from CurseForge or your preferred addon manager. That's it." />
          <MiniStep num="2" title="Play" desc="Auto-detects your class and spec on login. No setup, no configuration needed." />
          <MiniStep num="3" title="Forget it" desc="Rotation data updates weekly behind the scenes. Always current, zero maintenance." />
        </div>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
        <FeatureCard
          title="See What to Press Next"
          desc="A clean 2-3 spell queue shows your next cast, what's coming after, and what to prepare for. No guesswork, just press the buttons in order."
          accent="amber"
        />
        <FeatureCard
          title="Focus on Mechanics, Not Bars"
          desc="Stop tunneling your action bars during boss fights. With your rotation handled, you can watch for swirlies, plan interrupts, and react to mechanics instead of memorizing spell priorities."
          accent="blue"
        />
        <FeatureCard
          title="No Guides Required"
          desc="DMGAssist uses the same SimulationCraft data that top theorycrafters build their guides from. You get near-optimal rotation priority without reading a single guide or forum post."
          accent="red"
        />
        <FeatureCard
          title="Your Keybinds, Your Spells"
          desc="Reads your actual action bar bindings and displays them right on the HUD. You see exactly which button to press, not just which spell."
          accent="cyan"
        />
        <FeatureCard
          title="AoE & Single Target Modes"
          desc="One keybind swaps between AoE and single-target priorities. Pull a big pack? Toggle AoE. Boss time? Switch to ST. You control the context."
          accent="green"
        />
        <FeatureCard
          title="Built for Accessibility"
          desc="Whether you have a disability that makes tracking 30+ spells difficult, you're returning after a long break, or you just want to enjoy the game without the homework, DMGAssist makes every spec approachable."
          accent="purple"
        />
        <FeatureCard
          title="Works with Boss Mods"
          desc="DBM and BigWigs interrupt alerts get promoted to top priority in the queue. When your raid leader calls for a kick, it's right there on the HUD."
          accent="orange"
        />
      </div>

      <div className="rounded-xl border border-white/6 bg-white/[0.02] p-5">
        <div className="flex items-center gap-2 mb-4">
          <Users className="w-4 h-4 text-amber-400/50" />
          <span className="text-xs font-display font-semibold text-white/50 uppercase tracking-wider">Who This Is For</span>
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <AudienceCard
            title="New & Returning Players"
            desc="Learning a new spec or coming back after a break? The visual queue shows you the optimal rotation without memorizing priority lists."
          />
          <AudienceCard
            title="Alt Players"
            desc="Juggling multiple characters and specs? DMGAssist auto-configures for each one. Switch to your alt, and the addon already knows the rotation."
          />
          <AudienceCard
            title="Min-Max Players"
            desc="Appreciate SimC-backed optimization but want to focus on mechanics rather than fumbling through 20+ abilities? The queue keeps your rotation tight while you handle the real gameplay."
          />
        </div>
      </div>

      <SpecsBar specs={specs} />
    </div>
  );
}

function AudienceCard({ title, desc }: { title: string; desc: string }) {
  return (
    <div className="space-y-1.5">
      <span className="text-sm font-semibold text-amber-400/70">{title}</span>
      <p className="text-xs text-white/35 leading-relaxed">{desc}</p>
    </div>
  );
}

function HowItWorksTab() {
  return (
    <div className="space-y-8">
      <div className="space-y-3">
        <h2 className="font-display text-xl sm:text-2xl font-bold text-white" data-testid="text-how-title">
          How It <span className="text-amber-400">Works</span>
        </h2>
        <p className="text-sm text-white/40 leading-relaxed max-w-2xl">
          A quick look at what powers DMGAssist, what it can't do, and why it's safe to use.
        </p>
      </div>

      <ArchSection
        icon={<Brain className="w-4 h-4" />}
        title="The Short Version"
        color="amber"
      >
        <p>
          WoW 12.0 (Midnight) changed everything for rotation addons. Blizzard locked down most of the
          APIs that older addons relied on — but they also added a built-in rotation engine called the
          Cooldown Manager that highlights the next spell you should cast. It works, but it only
          shows <em>one</em> spell at a time.
        </p>
        <p>
          DMGAssist takes that recommendation and extends it into a 2-3 spell queue. It combines three things:
          Blizzard's Cooldown Manager recommendation (always top priority), community-maintained{" "}
          <a href="https://www.simulationcraft.org/" target="_blank" rel="noopener noreferrer" className="text-blue-400 hover:underline">SimulationCraft</a>{" "}
          spell priority data (the same data behind the class guides you'd read on Icy Veins or Wowhead),
          and action bar glow detection for procs and resets. The result is a ranked spell queue that
          shows you what to press now, what's next, and what's coming after that.
        </p>
        <p>
          SimC data syncs weekly. When theorycrafters update priorities after balance patches or hotfixes,
          DMGAssist picks up those changes and pushes an update to CurseForge automatically.
        </p>
      </ArchSection>

      <ArchSection
        icon={<AlertTriangle className="w-4 h-4" />}
        title="Honest Limitations"
        color="red"
      >
        <p>
          DMGAssist is not foolproof. Blizzard's 12.0 restrictions mean certain things are genuinely impossible for any addon:
        </p>
        <ul className="list-none space-y-1.5 my-3">
          <li className="flex items-start gap-2">
            <AlertTriangle className="w-3 h-3 text-amber-400/40 flex-shrink-0 mt-0.5" />
            <span className="text-[11px] text-white/35 leading-relaxed"><strong className="text-white/50">No health tracking.</strong> HP percentages are hidden from addons in combat. We can't recommend defensives or execute-phase abilities based on health.</span>
          </li>
          <li className="flex items-start gap-2">
            <AlertTriangle className="w-3 h-3 text-amber-400/40 flex-shrink-0 mt-0.5" />
            <span className="text-[11px] text-white/35 leading-relaxed"><strong className="text-white/50">No automatic enemy counting.</strong> You toggle AoE/ST mode manually. AoE is the default.</span>
          </li>
          <li className="flex items-start gap-2">
            <AlertTriangle className="w-3 h-3 text-amber-400/40 flex-shrink-0 mt-0.5" />
            <span className="text-[11px] text-white/35 leading-relaxed"><strong className="text-white/50">Cooldown tracking can drift briefly.</strong> Action bar glows correct it, but there may be short windows of inaccuracy.</span>
          </li>
          <li className="flex items-start gap-2">
            <AlertTriangle className="w-3 h-3 text-amber-400/40 flex-shrink-0 mt-0.5" />
            <span className="text-[11px] text-white/35 leading-relaxed"><strong className="text-white/50">Reduced accuracy in instances.</strong> The Combat Log is restricted in M+, raids, and PvP, so the addon relies more on Blizzard's built-in recommendations and glow signals.</span>
          </li>
        </ul>
        <p>
          Priority suggestions represent what is <em>usually</em> the best choice — not a guarantee for every situation.
          You'll get close to optimal, but not pixel-perfect. If "close enough" works for you, this addon is built for that.
        </p>
      </ArchSection>

      <ArchSection
        icon={<Lock className="w-4 h-4" />}
        title="Blizzard Policy Compliance"
        color="green"
      >
        <p>
          DMGAssist works entirely within Blizzard's addon rules:
        </p>
        <ul className="list-none space-y-2 my-3">
          <ComplianceItem
            check={true}
            text="Visual overlay only — it displays information on screen. It never presses keys, casts spells, or automates any action."
          />
          <ComplianceItem
            check={true}
            text="Uses only official, documented WoW addon APIs. No memory reading, no packet manipulation, no client modification."
          />
          <ComplianceItem
            check={true}
            text="Fully respects Blizzard's taint and secret value system. When the game restricts data, the addon gracefully works around it or degrades rather than trying to extract it."
          />
          <ComplianceItem
            check={true}
            text="Built as an overlay on Blizzard's own Cooldown Manager. It enhances what WoW already provides — it does not replace or bypass it."
          />
        </ul>
        <p>
          DMGAssist is fundamentally the same kind of addon as WeakAuras or any other combat display.
          It reads your action bars, checks what's highlighted or glowing, and shows you spell icons.
          What you do with that information is entirely your decision as a player.
        </p>
      </ArchSection>
    </div>
  );
}

function HelpTab() {
  return (
    <div className="space-y-6">
      <div className="space-y-2">
        <h2 className="font-display text-xl sm:text-2xl font-bold text-white" data-testid="text-help-title">
          Getting Started & <span className="text-amber-400">Commands</span>
        </h2>
      </div>

      <div className="rounded-xl border border-amber-500/15 bg-amber-500/[0.04] p-5 space-y-3">
        <SectionLabel text="Required: Enable Assisted Combat Highlights" />
        <p className="text-xs text-white/55 leading-relaxed">
          DMGAssist depends on Blizzard's Cooldown Manager (C_AssistedCombat) as its primary authority for spell
          recommendations. If Assisted Combat Highlights are disabled, the Cooldown Manager cannot surface its
          recommendations and the addon will show a warning popup in-game.
        </p>
        <p className="text-xs text-white/55 leading-relaxed">
          To enable: press <Cmd>Esc</Cmd> {">"} <strong className="text-amber-400/70">Options</strong> {">"} <strong className="text-amber-400/70">Gameplay</strong> {">"} <strong className="text-amber-400/70">Combat</strong> {">"} set <strong className="text-amber-400/70">Assisted Combat Highlight Spells</strong> to <strong className="text-amber-400/70">Always</strong> or <strong className="text-amber-400/70">In Combat</strong>.
        </p>
      </div>

      <div className="rounded-xl border border-blue-500/15 bg-blue-500/[0.04] p-5 space-y-3">
        <SectionLabel text="Setup: Place Your Rotation Spells on Action Bars" />
        <p className="text-xs text-white/55 leading-relaxed">
          DMGAssist can only suggest spells that are on your action bars. Place all your rotation spells on any bar
          (including hidden bars like MultiBar 5/6/7). Macros containing spells work too &mdash; the addon reads the spell inside the macro.
        </p>
        <p className="text-xs text-white/55 leading-relaxed">
          Spells not on any action bar will not appear in the HUD, even if the SimC rotation includes them.
          If a spell shows up that you don't recognize, it may be from a talent you haven't selected &mdash; those are automatically filtered out.
        </p>
        <p className="text-xs text-white/45 leading-relaxed italic">
          Tip: Use <Cmd>/dmga spells</Cmd> in-game to see which spells the addon has detected on your bars.
        </p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div className="rounded-xl border border-white/6 bg-white/[0.02] p-5 space-y-3">
          <SectionLabel text="Options Panel" />
          <p className="text-xs text-white/50 leading-relaxed">
            Type <Cmd>/dmga options</Cmd> in chat, click the gear icon on the HUD, or right-click the
            minimap icon to open the full options panel.
          </p>
          <p className="text-xs text-white/50 leading-relaxed">
            Tabs: General, Display, Combat, Data, Profiles, and Issues/Debug.
            Changes apply instantly. If something feels off, check the Issues tab for live diagnostics.
          </p>
        </div>

        <div className="rounded-xl border border-white/6 bg-white/[0.02] p-5 space-y-3">
          <SectionLabel text="Troubleshooting" />
          <p className="text-[11px] text-white/45 leading-relaxed">
            <strong className="text-white/65">Warning popup about Assisted Highlights?</strong> Follow the steps above to enable it in WoW's Combat settings. The Cooldown Manager requires this setting to surface its recommendations.
          </p>
          <p className="text-[11px] text-white/45 leading-relaxed">
            <strong className="text-white/65">No glows showing?</strong> Type <Cmd>/dmga fixglows</Cmd> to auto-enable
            the required WoW CVars.
          </p>
          <p className="text-[11px] text-white/45 leading-relaxed">
            <strong className="text-white/65">HUD not appearing?</strong> Make sure you're targeting something and try <Cmd>/dmga show</Cmd>.
          </p>
          <p className="text-[11px] text-white/45 leading-relaxed">
            <strong className="text-white/65">Runtime errors?</strong> Use <Cmd>/dmga fixerrors</Cmd> to reset the error counter.
          </p>
          <p className="text-[11px] text-white/45 leading-relaxed">
            <strong className="text-white/65">Healer and want DPS suggestions?</strong> Just shapeshift. The addon auto-loads the correct DPS rotation for your current form (Cat, Bear, Moonkin, etc.) filtered to spells you know.
          </p>
        </div>
      </div>

      <div className="rounded-xl border border-white/6 bg-white/[0.02] p-5 space-y-4">
        <SectionLabel text="Slash Commands" />
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-1.5">
          <CmdRow cmd="/dmga" desc="Show all commands" />
          <CmdRow cmd="/dmga options" desc="Open options panel" />
          <CmdRow cmd="/dmga show" desc="Show the HUD" />
          <CmdRow cmd="/dmga hide" desc="Hide the HUD" />
          <CmdRow cmd="/dmga toggle" desc="Toggle HUD on/off" />
          <CmdRow cmd="/dmga lock" desc="Lock HUD position" />
          <CmdRow cmd="/dmga unlock" desc="Unlock HUD position" />
          <CmdRow cmd="/dmga mode st" desc="Single-target priority" />
          <CmdRow cmd="/dmga mode aoe" desc="AoE priority (default)" />
          <CmdRow cmd="/dmga ooc" desc="Toggle OOC display" />
          <CmdRow cmd="/dmga spells" desc="Show known spells" />
          <CmdRow cmd="/dmga trinkets" desc="Show detected trinkets" />
          <CmdRow cmd="/dmga status" desc="Config summary" />
          <CmdRow cmd="/dmga glows" desc="Check glow settings" />
          <CmdRow cmd="/dmga fixglows" desc="Auto-fix glow CVars" />
          <CmdRow cmd="/dmga debug" desc="Toggle debug logging" />
          <CmdRow cmd="/dmga snapshot" desc="Show engine state snapshot" />
          <CmdRow cmd="/dmga selftest" desc="Run internal diagnostics" />
          <CmdRow cmd="/dmga fixerrors" desc="Reset error counter" />
          <CmdRow cmd="/dmga reset" desc="Reset all to defaults" />
        </div>
        <div className="pt-3 border-t border-white/5">
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-1.5">
            <CmdRow cmd="Hold Alt" desc="Temp single-target override" />
            <CmdRow cmd="Right-click minimap" desc="Open options menu" />
            <CmdRow cmd="Drag HUD tab" desc="Move HUD (unlocked)" />
          </div>
        </div>
      </div>
    </div>
  );
}

function ArchSection({ icon, title, color, children }: { icon: React.ReactNode; title: string; color: string; children: React.ReactNode }) {
  const borderColors: Record<string, string> = {
    amber: "border-l-amber-500/30",
    blue: "border-l-blue-500/30",
    purple: "border-l-purple-500/30",
    green: "border-l-green-500/30",
    red: "border-l-red-500/30",
    cyan: "border-l-cyan-500/30",
  };
  const iconColors: Record<string, string> = {
    amber: "text-amber-400/60",
    blue: "text-blue-400/60",
    purple: "text-purple-400/60",
    green: "text-green-400/60",
    red: "text-red-400/60",
    cyan: "text-cyan-400/60",
  };
  return (
    <div className={`rounded-xl border border-white/6 border-l-2 ${borderColors[color] || borderColors.amber} bg-white/[0.02] p-5 sm:p-6`}>
      <div className="flex items-center gap-2.5 mb-4">
        <span className={iconColors[color] || iconColors.amber}>{icon}</span>
        <h3 className="font-display text-base font-bold text-white/85">{title}</h3>
      </div>
      <div className="space-y-3 text-[13px] text-white/45 leading-relaxed">
        {children}
      </div>
    </div>
  );
}


function ComplianceItem({ check, text }: { check: boolean; text: string }) {
  return (
    <li className="flex items-start gap-2.5">
      <CheckCircle className={`w-4 h-4 flex-shrink-0 mt-0.5 ${check ? "text-cyan-400/50" : "text-red-400/50"}`} />
      <span className="text-[12px] text-white/45 leading-relaxed">{text}</span>
    </li>
  );
}


function StatCard({ value, label, icon, testId }: { value: string; label: string; icon: React.ReactNode; testId: string }) {
  return (
    <div
      className="rounded-lg border border-white/6 bg-white/[0.02] p-3 flex items-center gap-3 lg:gap-3"
      data-testid={testId}
    >
      {icon}
      <div className="leading-tight">
        <span className="font-display text-lg font-bold text-amber-400">{value}</span>
        <span className="block text-[10px] text-white/30 uppercase tracking-wider font-medium">{label}</span>
      </div>
    </div>
  );
}

function MiniStep({ num, title, desc }: { num: string; title: string; desc: string }) {
  return (
    <div className="flex items-start gap-3">
      <span className="flex-shrink-0 w-7 h-7 rounded-full bg-amber-500/10 text-amber-400 text-xs font-bold flex items-center justify-center border border-amber-500/15">
        {num}
      </span>
      <div>
        <p className="text-sm font-semibold text-white/75">{title}</p>
        <p className="text-xs text-white/35 leading-relaxed mt-0.5">{desc}</p>
      </div>
    </div>
  );
}

function FeatureCard({ title, desc, accent }: { title: string; desc: string; accent: string }) {
  const borderColors: Record<string, string> = {
    amber: "border-l-amber-500/40",
    blue: "border-l-blue-500/40",
    purple: "border-l-purple-500/40",
    green: "border-l-green-500/40",
    orange: "border-l-orange-500/40",
    cyan: "border-l-cyan-500/40",
    red: "border-l-red-500/40",
  };
  return (
    <div className={`rounded-lg border border-white/6 border-l-2 ${borderColors[accent] || borderColors.amber} bg-white/[0.02] p-4`}>
      <span className="text-sm font-semibold text-white/80 block mb-1.5">{title}</span>
      <p className="text-xs text-white/35 leading-relaxed">{desc}</p>
    </div>
  );
}

function SpecsBar({ specs }: { specs: Spec[] }) {
  const grouped = specs.reduce<Record<string, Spec[]>>((acc, s) => {
    if (!acc[s.className]) acc[s.className] = [];
    acc[s.className].push(s);
    return acc;
  }, {});
  const classes = Object.keys(grouped).sort();

  if (classes.length === 0) return null;

  return (
    <div className="rounded-xl border border-white/6 bg-white/[0.02] p-4">
      <div className="flex items-center gap-2 mb-3">
        <ChevronRight className="w-3.5 h-3.5 text-amber-400/40" />
        <span className="text-xs text-white/40 uppercase tracking-wider font-semibold font-display">
          All {specs.length} Specs Supported
        </span>
      </div>
      <div className="flex flex-wrap gap-1.5">
        {classes.map(cls => (
          <span
            key={cls}
            className="text-[11px] px-2 py-1 rounded-md bg-white/[0.04] border border-white/5 font-medium"
            style={{ color: grouped[cls][0].classColor + "88" }}
            data-testid={`badge-class-${cls.toLowerCase().replace(/\s+/g, '-')}`}
          >
            {cls}
          </span>
        ))}
      </div>
    </div>
  );
}

function SectionLabel({ text }: { text: string }) {
  return (
    <div className="flex items-center gap-2">
      <span className="w-1 h-4 rounded-full bg-amber-500/30" />
      <span className="text-xs font-display font-semibold text-white/50 uppercase tracking-wider">{text}</span>
    </div>
  );
}

function Cmd({ children }: { children: React.ReactNode }) {
  return (
    <code className="font-mono text-[10px] bg-white/5 text-amber-300/70 px-1.5 py-0.5 rounded border border-white/8">
      {children}
    </code>
  );
}

function CmdRow({ cmd, desc }: { cmd: string; desc: string }) {
  return (
    <div className="flex items-baseline gap-2 py-0.5" data-testid={`cmd-${cmd.replace(/[\s\/]/g, '-').replace(/^-+/, '')}`}>
      <code className="font-mono text-[10px] bg-white/5 text-amber-300/60 px-1.5 py-0.5 rounded border border-white/6 whitespace-nowrap flex-shrink-0">
        {cmd}
      </code>
      <span className="text-[11px] text-white/30">{desc}</span>
    </div>
  );
}
