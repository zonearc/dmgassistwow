# Gap analysis: DMGAssist vs pre-Midnight rotation addons (2026-11-08)

Compared against Hekili (options in `.libraries/reference/Hekili/Options`), MaxDps (glows action buttons, hooks
the Cooldown Manager), ConRO-style defensive/interrupt side windows, and the requests players repeat on those
projects' trackers and forums (wording from memory of common themes — no specific threads quoted).

Legend: ✅ have · 🟡 partial · ❌ missing · ⛔ impossible in Midnight combat (secret values) · ➖ out of scope

## Recommendations
| Feature | Hekili / others | DMGAssist | Notes |
|---|---|---|---|
| SimC priority lists, auto-updated | Hekili (hand-maintained packs) | ✅ weekly import from SimC itself | Hekili lagged patches; ours follows SimC's own repo |
| Major cooldowns in their own display | Hekili Cooldowns display | ✅ cooldown icon + burst toggle | |
| Queue length | up to 10 | 🟡 3 | Past ~3 the look-ahead is mostly guesswork under secrets |
| Look-ahead / forecasting | ✅ | ✅ cooldowns, auras, costs, gains, current cast | Not modelled: passive regen, procs, charges, CDR |
| Pooling | ✅ pooling time | ✅ SimC `pool_resource` → "pool" pick | |
| Target count | nameplates, damage, pets, range radius | 🟡 nameplates + range of our spells | ⛔ damage-based counting (combat log) |
| ST / AoE / Auto / Dual displays + hotkey | ✅ | 🟡 ST/AoE/Auto + hotkey | ❌ Dual (ST and AoE side by side) |
| Movement awareness | ✅ | ✅ cast-time spells skipped while moving | from never-secret movement events |
| Hidden resources | n/a pre-Midnight | ✅ counting, bounds, oracle, **game-rendered branches** | unique to us |
| Spell queue window / press-now cue | 🟡 | ✅ | |
| Trinkets / potions | ✅ | ❌ | next: SimC `use_item`/`potion` lines → cooldown slot |
| Empower stages (Evoker) | ✅ | ❌ | `empower_to` is in our data, not used yet |
| Custom priorities / editor / import-export | ✅ | ❌ | deliberate for now: SimC is the source; maybe "overrides" later |
| Healer support | ❌ (Hekili none) | ❌ | SimC has no healer lists; Blizzard's assistant covers healers on Midnight |

## Help in combat
| Feature | Others | DMGAssist | Notes |
|---|---|---|---|
| Interrupts | Hekili Interrupts display | ✅ policy (smart/everywhere/instances/bossmods/off), slot 1, skip detection | important-only via Blizzard + boss mods |
| Defensives | Hekili Defensives display, ConRO | ✅ boss-mod timed + low-health (game-rendered) | ❌ spec-specific logic (e.g. Ironfur uptime) |
| Boss mod timing | none built in | ✅ DBM, BigWigs, LittleWigs, Blizzard timeline | |
| Tank maintenance (Ironfur, Shield Block, stagger) | Hekili via APL | 🟡 stacks tracked | ❌ dedicated "keep it up" helper |

## Display & UX
| Feature | Others | DMGAssist | Notes |
|---|---|---|---|
| Keybind text, overrides | ✅ | ✅ Blizzard, macros, Bartender/ElvUI/Dominos | ❌ manual override text |
| Glow the real action button | MaxDps, Hekili overlay | ✅ highlight | |
| Fonts, outline, sizes | ✅ | ✅ | |
| Masque skins | Hekili | ❌ | optional dependency, low cost — later |
| Show/hide rules (combat, target, mounted, vehicle, pet battle) | ✅ | ✅ | ❌ PvP alpha |
| Sound alerts | partial | ✅ per event | |
| Profiles / per-spec layouts | Hekili styles | ❌ | settings are per character |
| Edit Mode integration | some addons | ❌ | preview-while-panel-open covers placing |
| Explain the pick | Hekili snapshot | ✅ `/dmga why`, decision text, `/dmga snapshot` | |
| Issue reporting | Hekili snapshot → pastebin | ✅ `tools/send-logs.py` → GitHub | |

## Player wish-list themes we can answer
- "Works in Midnight" — the whole design (secrets handled, nothing protected called).
- "Tell me *why*" — sources on icons, decision text, snapshots.
- "Don't spam me with interrupts on trash that doesn't matter" — smart interrupt policy.
- "Keep me alive in M+" — boss-mod-timed defensives.
- "Keybinds must be right with my bar addon" — done.
- "Less clutter" — icons-only defaults.

## Next up (ordered by value / effort)
1. Trinkets and potions from SimC lines (cooldown slot), with a toggle.
2. Dual display (ST + AoE) for players who want both.
3. Tank helper: Ironfur / Shield Block / Demon Spikes uptime nudges.
4. Evoker empower stages.
5. Masque support; per-spec layouts.
