import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/use-auth";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { ArrowLeft, Copy, Check, LogIn, Loader2 } from "lucide-react";
import { useToast } from "@/hooks/use-toast";

function getCurseForgeDescription(version: string): string {
  return `DMGAssist: Enhanced Rotation HUD
DMGAssist is a modern, SimC-powered rotation assistant for World of Warcraft Midnight (12.0). It provides a real-time, Guitar Hero-style 2-3 spell priority queue HUD that combines Blizzard's Assisted Combat system with SimulationCraft APL data to show you exactly what to press next. Built with a zero-taint architecture designed from the ground up for 12.0's restricted API environment.

Current Version: ${version}


Key Features

SimC-Powered Intelligence: Every rotation is driven by the latest SimulationCraft Action Priority Lists (APL), ensuring you are always following the most mathematically optimal combat sequence. APL data is automatically synced weekly.
4-Tier Signal System: DMGAssist combines four signal sources to build its priority queue:
  - Assisted Combat (highest) -- Blizzard's C_AssistedCombat.GetNextCastSpell recommendation
  - Proc Glows -- Action bar overlay glows from C_SpellActivationOverlay
  - Assisted Highlights -- Action bar glow child detection
  - Spell Readiness -- C_Spell.IsSpellUsable + off cooldown
When multiple signals fire, SimC priority data ranks them so you always see the best spell to press next.
Comprehensive Class Coverage: All 38 specializations across 13 classes, with auto-detection that instantly adjusts your HUD when you swap specs in-game.
Zero-Taint Architecture: Built specifically for WoW 12.0's restricted API environment. All in-combat data comes from internal tracking tables (CLEU events, own aura/resource caches), never from tainted Blizzard APIs. No ADDON_ACTION_BLOCKED errors.
Tank Mode: Automatic tank spec detection with dedicated defensive spell scoring. Manual override available for off-tanking on DPS specs. Emergency cooldowns flow through Assisted Combat recommendations.
DBM/BigWigs Integration: Interrupt alerts from boss mods are promoted to the highest priority in the queue.


Installation & Use

Download: Get the latest build here on CurseForge (or through CurseForge App).
Install: Extract the folder into your World of Warcraft/_retail_/Interface/AddOns/ directory.
Play: Just log in! DMGAssist auto-detects your class and spec immediately.


Quick Start
1. Install from CurseForge (or your addon manager)
2. Log in -- addon auto-detects your spec
3. HUD appears center-screen -- drag to reposition, press the keybinds shown


Minimap Icon
Left-click -- Toggle HUD on/off
Right-click -- Options dropdown (mode, lock, OOC hide, reset)
Drag -- Move icon around minimap

HUD Controls
Drag tab (top of HUD) -- Left-drag to move, right-click to lock position
Gear icon (top-right) -- Open full Options panel


Options Panel (8 Tabs)

Open via: gear icon on HUD, right-click minimap > Open Options, or /dmga options

Setup -- Welcome, required setup steps, tips
Display -- Scale, opacity, icon layout, border style, keybind overlays, spell names, HUD elements, text appearance
Combat -- Target mode (AoE/ST), keybinds, auto-hide, form awareness, queue behavior, trinket tracking, combat role (Auto/Tank/DPS), interrupts
Consumables -- Flask, food, weapon enchant, augment rune tracking with alert categories and event sounds
Sounds -- Configurable sound alerts for combat events
SimC Data -- APL inspection, trinket configuration, spell priority viewer
Profiles -- Account-wide + per-character profile system with auto-create
Issues -- Diagnostics, debug logging, condition errors, issue log, quick fixes, common issues


Slash Commands

/dmga or /dmgassist -- show help

Core
/dmga options -- Open Options panel
/dmga show | hide | toggle -- HUD visibility
/dmga lock | unlock -- Lock/unlock HUD position
/dmga ooc -- Toggle auto-hide out of combat

Mode
/dmga mode -- Cycle AoE / ST
/dmga mode st | aoe -- Override mode

Diagnostics
/dmga status -- Current spec, mode, toggles
/dmga spells -- Which APL spells are known/talented
/dmga trinkets -- Equipped trinkets + cooldown status
/dmga consumables -- Check consumable buff status
/dmga spellbook -- View spell book (learned cast times, CDs, costs)
/dmga ac -- Assisted Combat diagnostic (API + internal state)
/dmga snapshot -- Last tick: queue, candidates, scores, signals, taint
/dmga selftest -- Full subsystem health check (API, aura, spells, taint)
/dmga glows -- Check glow/overlay CVar health
/dmga fixglows -- Auto-fix overlay CVars
/dmga testinterrupt -- Simulate boss mod interrupt alert
/dmga taintreset -- Reset taint hit counters
/dmga taintstats -- View per-API taint statistics
/dmga taintmap -- Full API permission scan (best in combat)
/dmga debug -- Toggle debug logging (verbose/off)
/dmga reset -- Factory reset (reloads UI)

Diagnostic Logging (Watchdog)
/dmgawd or /watchdog -- show watchdog help
/dmgawd enable | disable -- Toggle diagnostic logging
/dmgawd -- Open Event Viewer (when enabled)
/dmgawd snap -- Capture manual snapshot
/dmgawd scan -- Run full API scan
/dmgawd health -- Run subsystem health checks
/dmgawd status -- Show monitoring status
/dmgawd clear -- Clear all saved data


How It Works

DMGAssist uses a 10-tier scoring algorithm that blends SimC APL priorities with Blizzard's Assisted Combat signals. The engine evaluates every known rotation spell each combat tick and ranks them into a 2-3 spell queue displayed on the HUD.

Signal sources (in priority order):
1. Assisted Combat (C_AssistedCombat) -- Blizzard's own recommended next cast
2. Proc Glows (C_SpellActivationOverlay) -- Spell proc overlay detection
3. Action Bar Glow -- Assisted highlight glow child on action buttons
4. Spell Readiness -- Usable, off cooldown, affordable

Additional systems:
- Interrupt override from DBM/BigWigs (highest priority)
- Tank defensive boost scoring for tank specs
- Execute spell suppression until AC confirms target is in execute range
- Major CD priority override even when SimC conditions partially fail
- Action bar glow authoritative override (treats glows as ground truth)
- APL rotation spell fallback injection for spells not on action bars
- Anti-stuck penalty system to prevent queue stalling
- Staleness falloff after 12s without casting (resets dot timers/priorities)
- Channeled spell detection (3-tier: cast state, active channel tracker, API fallback)
- Primary slot lock during GCD/cast with fade-in animation


Features
All 38 DPS/Tank/Healer specs -- auto-detects on login
SimC APL data synced weekly from SimulationCraft
AoE/ST mode toggle
On-use trinket detection + cooldown tracking
Druid form / stance / shapeshift awareness
Your actual keybinds shown on each spell icon
DBM/BigWigs interrupt integration
Fully configurable HUD (size, opacity, position, fonts, colors, borders)
Real-time settings -- no /reload needed
Profile system (account-wide + per-character)
Built-in diagnostics, issue detection, and event logging
Consumable buff alerts (flask, food, weapon enchant, augment rune)
Configurable sound alerts
Secondary resource tracking (combo points, holy power, etc.)
Weapon enchant buff detection (Flametongue/Windfury)
Precombat state evaluation
Dynamic spell override discovery via C_Spell.GetOverrideSpell
Localization support (English + zhCN)
Boss mod integration for phase tracking


Known Issues

SimC is not updated for all classes yet. This means not all rotations may be fully optimized. When SimC is up to date for Midnight, DMGAssist will automatically pull in the updated data within a week. I have done what I can to work around gaps in SimC coverage.

Blizzard has restricted many APIs in 12.0 that previous rotation addons relied on. DMGAssist is built from scratch for this new environment, but it means some things work differently than pre-Midnight addons. You may see roughly 10% below theoretical peak DPS. If "close enough" works for you, this addon is built for that.

Defensive and heal recommendations for DPS specs have been removed due to API restrictions. Tank specs get defensive spells scored in the main queue. All players manage their own defensive cooldowns.

Interrupt/kick recommendations are built in via DBM/BigWigs integration. It works when boss mods identify an interruptible cast, but boss mod detection itself has limitations in 12.0.

DMGAssist is continuously being tuned. If you encounter issues, enable diagnostic logging (Options > Issues tab) and use /dmgawd to open the Event Viewer. Copy/paste the log with details about what happened through the CurseForge bug tracker -- I can use those logs to rapidly identify the cause.`;
}

export default function CurseForgeDescription() {
  const { user: authUser, isLoading: authLoading, isAuthenticated } = useAuth();
  const { toast } = useToast();
  const [copied, setCopied] = useState(false);

  const { data: versionData } = useQuery<{ version: string }>({
    queryKey: ["/api/version"],
    enabled: isAuthenticated,
  });

  const version = versionData?.version ?? "...";
  const description = getCurseForgeDescription(version);

  if (authLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <Loader2 className="w-6 h-6 animate-spin text-primary" />
      </div>
    );
  }

  if (!isAuthenticated) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <Card className="w-full max-w-sm">
          <CardHeader>
            <CardTitle className="text-center font-display">Admin Access Required</CardTitle>
          </CardHeader>
          <CardContent className="flex justify-center">
            <Button asChild data-testid="button-login">
              <a href="/api/login?returnTo=/admin/curseforge"><LogIn className="w-4 h-4 mr-2" /> Sign in with Replit</a>
            </Button>
          </CardContent>
        </Card>
      </div>
    );
  }

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(description);
      setCopied(true);
      toast({ title: "Copied!", description: "CurseForge description copied to clipboard." });
      setTimeout(() => setCopied(false), 2000);
    } catch {
      const textarea = document.createElement("textarea");
      textarea.value = description;
      document.body.appendChild(textarea);
      textarea.select();
      document.execCommand("copy");
      document.body.removeChild(textarea);
      setCopied(true);
      toast({ title: "Copied!", description: "CurseForge description copied to clipboard." });
      setTimeout(() => setCopied(false), 2000);
    }
  };

  return (
    <div className="min-h-screen bg-background text-foreground">
      <div className="max-w-4xl mx-auto px-6 py-8">
        <div className="flex items-center justify-between mb-6">
          <div className="flex items-center gap-3">
            <Button variant="ghost" size="sm" asChild data-testid="link-back-admin">
              <a href="/admin"><ArrowLeft className="w-4 h-4 mr-1" /> Admin</a>
            </Button>
            <h1 className="font-display text-2xl font-bold" data-testid="text-cf-title">CurseForge Description</h1>
          </div>
          <div className="flex items-center gap-2">
            <Badge variant="secondary" data-testid="text-cf-version">{version}</Badge>
            <Button
              onClick={handleCopy}
              className="gap-2"
              data-testid="button-copy-description"
            >
              {copied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
              {copied ? "Copied!" : "Copy to Clipboard"}
            </Button>
          </div>
        </div>

        <Card>
          <CardContent className="p-0">
            <pre
              className="p-6 text-sm leading-relaxed whitespace-pre-wrap font-mono text-muted-foreground overflow-auto max-h-[80vh] select-all"
              data-testid="text-cf-description"
            >
              {description}
            </pre>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
