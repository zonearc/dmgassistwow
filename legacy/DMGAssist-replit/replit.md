# DMGAssist — Enhanced Rotation HUD Companion

## Overview
DMGAssist is a World of Warcraft addon and web platform designed to provide an "Enhanced Highlight Assist Pro" HUD for WoW Midnight 12.0 players. It offers a Guitar Hero-style 2-3 spell queue based on Blizzard's Assisted Highlights, action bar proc glows, spell readiness, and SimC priority data. The web platform includes a public landing page and an admin dashboard. The system automates daily updates of new SimC data and uploads to CurseForge, ensuring continuous optimization of in-game rotation assistance for all 38 specializations.

## User Preferences
I prefer detailed explanations.
I want iterative development.
Ask before making major changes.
I prefer simple language.
I like functional programming.

## System Architecture
The project uses a Node.js + Express backend and a React + Vite frontend, both in TypeScript, with Tailwind CSS and shadcn/ui for styling. Core addon data is stored in-memory. Authentication is handled via Replit Auth with session and user data in PostgreSQL, managed by `drizzle-orm` and `pg`. The application is deployed to a VM target for a weekly cron scheduler and web server. The theme is a dark World of Warcraft aesthetic with gold (amber) as the primary color and class-specific accents.

### UI/UX Decisions
- **Theme:** Dark World of Warcraft aesthetic with gold (amber) and class-specific accents.
- **Font:** Oxanium font.

### Technical Implementations
- **Addon Generation:** A structured system orchestrates 13 modules to emit Lua source files for the WoW addon.
- **SimC Integration:** Fetches, processes, and compiles SimC APL data into Lua functions.
- **Community APL Priority:** All 16 supported specs use hand-crafted modern 12.0 community APLs from `server/community-apls.ts` as the primary data source for addon generation. These take precedence over SimC GitHub data and old database seeds. Specs without community APLs fall back to SimC GitHub → storage seed data.
- **Sync Engine:** A weekly scheduler automates data fetching, Lua file generation, ZIP packaging, and CurseForge uploads.
- **Addon Architecture (WoW 12.0 Compliant):**
    - **Signal Sources (12.0):** Utilizes a 4-tier signal system (SIGNAL_ANTS, SIGNAL_PROC, SIGNAL_ASSISTED, SIGNAL_READY) adapting to 12.0 API changes.
    - **C_AssistedCombat Integration:** Polls `GetNextCastSpell` and discovers rotation spells for range checks.
    - **Scoring System:** A 10-tier algorithm prioritizes spells. AC signals (ANTS/ASSISTED/PROC) are evaluated BEFORE mode mismatch, ensuring AC-recommended spells bypass mode penalties. CD+AC combinations score highest at -12000. Both-mode and mode-matched fillers share the same T5 tier (-7000 base). CDs auto-classify as major (15s+) or rotational (<15s). Neglect escalator boosts starved spells by -500/interval (cap -2000).
    - **Taint Safety (12.0 Zero-Taint Architecture):** Three-pillar combat architecture: (1) `C_Spell.IsSpellUsable` as single castability gate (tainted=accept, clean false=reject), (2) `C_AssistedCombat.GetNextCastSpell` as rotation authority, (3) event-based CD tracking chain (castLog/knownCDDur/cdMap+30s default). All `CheckResourceAffordable` calls removed from combat paths. Test harness includes taint simulation with `SecretValue` wrapper matching WoW 12.0 semantics.
    - **CLEU-Based Target Tracking:** Derives target GUID from CLEU data for accurate multi-target debuff tracking.
    - **Secondary Resource Tracking:** Manages secondary resources like combo points for relevant specs.
    - **Healing/Defensive Spell Suppression:** Blocks healing and defensive spells for non-healer/non-tank specs, while tanks receive TANK-BOOST scoring for defensives.
    - **Druid Form Gating:** Prevents recommendations for spells that would break current druid forms.
    - **Balance Druid Eclipse Filler Swap:** Wrath entries have `!buff.eclipse_lunar.up` condition; Starfire is mode "Both" unconditional. During Lunar Eclipse in ST, Wrath is skipped and Starfire becomes the filler. In AoE, Starfire always wins via mode match.
    - **Slot 2-3 APL Resource Pass:** APL spells with no cooldown bypass the `IsSpellUsable` check in slots 2-3 when specifically blocked by resource affordability (not other usability failures). This lets spells like Starsurge appear in the lookahead queue as "cast next when you have resources."
    - **AC Full Trust Architecture:** Prioritizes AC-recommended spells, bypassing internal resource checks and `IsSpellUsable` for higher accuracy.
    - **Precombat State Bar Gate:** Suppresses precombat spells not on action bars to prevent queue jamming.

### Critical Design Principles
- **SimC as Truth Source:** SimC APL is the sole source for spell behavior, avoiding hardcoded class specifics.
- **12.0 WoW Knowledge:** Relies on SimC APL for current spell behavior, not pre-12.0 game knowledge.
- **In-Combat Data:** Uses internal tables and CLEU events for in-combat aura, resource, and cooldown tracking.
- **Generic Infrastructure:** Infrastructure is generic across all 38 specs, with only SimC APL entries and spell icons as per-spec inputs.

### System Design Choices
- **Storage:** In-memory for application data; PostgreSQL for authentication and sync persistence.
- **Auth:** Replit Auth for user authentication with admin access control.
- **Deployment:** VM target for continuous operation and cron support.
- **API Endpoints:** Structured public, authenticated, and admin endpoints.
- **Priority Simulator** (`/admin/sim`): Offline scoring engine verification tool:
  - **Combat Simulation**: 5min (300s) time-stepping combat sim across all 16 specs with resource modeling. Each GCD picks top-scored spell, tracks CDs and resources (energy, mana, rage, combo points, holy power, runes, essence, fury, astral power). Spells blocked by insufficient resources fall through to the next affordable candidate. 15 detection rules: `SPELL_NEVER_CAST`, `SPELL_NEVER_SLOT1`, `CD_IN_QUEUE_WHILE_ON_CD`, `WRONG_MODE_CAST`, `DELAYED_CD_PROMOTION`, `MONOTONIC_ROTATION`, `LONG_DROUGHT`, `PRIORITY_INVERSION`, `MAINTENANCE_SPELL_STARVED`, `QUEUE_STAGNATION`, `AC_RECOMMENDATION_IGNORED`, `FILLER_DOMINANCE`, `CD_WASTED`, `RESOURCE_STARVED`, `BUILDER_SPENDER_IMBALANCE`. GCD timeline shows resource state and blocked spells per tick.
  - **Resource Tables**: `SPEC_RESOURCES` (per-spec resource configs) and `SPELL_COSTS` (per-spell primary/secondary costs and generation) in `server/priority-sim-validator.ts`.
  - **Snapshot Scenarios**: Mixed CDs on/off, all CDs down — single-frame priority snapshots.
  - **Interactive**: Manual spell state toggling for single-spec deep investigation.
  - **Log Replay**: Paste debug log output to replay AC highlight states through the simulator.
  - **Maintenance Buff Tracking**: `MAINTENANCE_BUFF_DURATIONS` table models DoT/HoT/buff uptime windows with pandemic refresh logic. Prevents premature re-casting of maintenance spells.
  - Known CD durations in `KNOWN_CD_DURATIONS`, resource configs in `SPEC_RESOURCES`, spell costs in `SPELL_COSTS`, maintenance durations in `MAINTENANCE_BUFF_DURATIONS` (all in `server/priority-sim-validator.ts`).
  - API: `GET /api/sim/validate/all`, `GET /api/sim/validate/:specId`, `POST /api/sim/validate/log`, `POST /api/sim/run`.

## External Dependencies
- **CurseForge:** Publishing platform for the WoW addon.
- **Replit Auth:** OpenID Connect provider for user authentication.
- **PostgreSQL:** Relational database.
- **Node.js, Express, React, Vite, TypeScript, Tailwind CSS, shadcn/ui:** Core technology stack.
- **drizzle-orm, pg:** ORM and PostgreSQL client.