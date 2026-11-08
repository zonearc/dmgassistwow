/**
 * @module generators/transpiler
 * @description
 * **SimulationCraft APL Condition → Lua Transpiler**
 *
 * This is the core translation engine that converts SimC APL condition strings
 * into executable Lua code for the WoW addon runtime.
 *
 * ## How It Works
 *
 * SimC uses a domain-specific expression language for APL conditions:
 *   `"buff.avenging_wrath.up&cooldown.judgment.remains<gcd&holy_power>=3"`
 *
 * This function translates those expressions into valid Lua:
 *   `"CLF.BuffUp("avenging_wrath") and CLF.CooldownRemains("judgment")<CLF.GCDMax() and CLF.Power()>=3"`
 *
 * Translation is done via **ordered regex replacements**. ORDER MATTERS -- more
 * specific patterns (e.g. `buff.X.remains`) must match before generic ones
 * (e.g. `buff.X`), otherwise the generic pattern consumes the token first.
 *
 * ## Translation Categories (in order)
 *
 * 1. **SimC min/max operators** -- `>?` → math.min, `<?` → math.max
 * 2. **Target state** -- health, debuffs, casting, distance
 * 3. **Raid events** -- SimC-only simulation tokens → safe constants
 * 4. **Class-specific tokens** -- Eclipse, Death & Decay, Consecration, etc.
 * 5. **Pets & totems** -- PetAlive, TotemActive, etc.
 * 6. **Talents** -- talent.X.enabled → CLF.TalentEnabled("X")
 * 7. **Previous GCD** -- prev_gcd.1.X → CLF.PrevGCD("X")
 * 8. **Time & GCD** -- fight_remains, gcd.remains, gcd.max
 * 9. **Variables** -- Two-pass: numeric context → raw value, boolean → ~= 0 wrap
 * 10. **Action properties** -- cast_time, cost, charges, usable
 * 11. **Buffs & debuffs** -- up/down/remains/stack/duration
 * 12. **Trinkets** -- Must run before generic cooldown handlers
 * 13. **Cooldowns** -- remains/ready/charges/duration
 * 14. **Dots** -- Aliased to debuff equivalents
 * 15. **Resources** -- All power types → CLF.Power()
 * 16. **Time suffixes** -- 2m → 120, 500ms → 0.5
 * 17. **Operators** -- &→and, |→or, !→not, =→==
 *
 * @taint-solution The transpiler generates Lua code that calls CLF.* functions
 * which internally handle taint/secret values. The transpiled conditions never
 * directly call WoW APIs -- they always go through the CLF abstraction layer.
 *
 * @see {@link conditionToLua} -- Main entry point
 */

/**
 * Transpiles a SimulationCraft APL condition string into executable Lua code.
 *
 * The generated Lua calls CLF.* functions that read live WoW game state.
 * Unknown tokens are left as-is (they'll resolve to nil in Lua, which is falsy).
 *
 * @param cond - Raw SimC condition string (e.g. "buff.hot_streak.up&!prev_gcd.1.pyroblast")
 * @returns Valid Lua boolean expression string.
 *
 * @example
 * conditionToLua("buff.avenging_wrath.up&holy_power>=3")
 * // → 'CLF.BuffUp("avenging_wrath") and CLF.Power()>=3'
 *
 * conditionToLua("cooldown.combustion.remains>?30")
 * // → 'math.min(CLF.CooldownRemains("combustion"),30)'
 */
export function conditionToLua(cond: string): string {
  if (!cond || cond.trim() === "") return "true";

  let lua = cond;

  // ── SimC min/max operators ──
  // SimC uses >? for "min of" and <? for "max of" (counterintuitive naming)
  // e.g. spell_targets>?3 → min(spell_targets, 3) -- "cap at 3"
  for (let pass = 0; pass < 10; pass++) {
    const prev = lua;
    lua = lua.replace(/([\w.]+)\s*>\?\s*([\w.]+)/g, "math.min($1,$2)");
    lua = lua.replace(/([\w.]+)\s*<\?\s*([\w.]+)/g, "math.max($1,$2)");
    if (lua === prev) break;
  }
  // Any remaining >?/<? with complex operands -- strip the ? operator entirely.
  lua = lua.replace(/>\?/g, ">");
  lua = lua.replace(/<\?/g, "<");

  // ── Target & environment state ──
  lua = lua.replace(/target\.is_casting_interruptible/g, "CLF.TargetIsCasting()");
  lua = lua.replace(/target\.health\.pct/g, "CLF.TargetHealthPct()");
  lua = lua.replace(/target\.time_to_die/g, "CLF.FightRemains()");
  lua = lua.replace(/target\.distance/g, "0");
  lua = lua.replace(/target\.debuff\.(\w+)\.remains\b/g, 'CLF.DebuffRemains("$1")');
  lua = lua.replace(/target\.debuff\.(\w+)\.stack\b/g, 'CLF.DebuffStacks("$1")');
  lua = lua.replace(/target\.debuff\.(\w+)\.down\b/g, '(not CLF.DebuffUp("$1"))');
  lua = lua.replace(/target\.debuff\.(\w+)\.up\b/g, 'CLF.DebuffUp("$1")');
  lua = lua.replace(/target\.debuff\.(\w+)\b/g, 'CLF.DebuffUp("$1")');
  lua = lua.replace(/target\.cooldown\.(\w+)\.remains\b/g, 'CLF.CooldownRemains("$1")');
  lua = lua.replace(/target\.cooldown\.(\w+)\.ready\b/g, 'CLF.CooldownReady("$1")');
  lua = lua.replace(/target\.cooldown\.(\w+)\b/g, "0");
  lua = lua.replace(/player\.health\.pct/g, "CLF.PlayerHealthPct()");
  lua = lua.replace(/\bhealth\.max\b/g, "CLF.HealthMax()");
  lua = lua.replace(/\bhealth\.pct\b/g, "CLF.PlayerHealthPct()");
  lua = lua.replace(/\btime_to_die\.remains\b/g, "CLF.FightRemains()");
  lua = lua.replace(/\bactive_enemies\b/g, "CLF.ActiveEnemies()");
  lua = lua.replace(/\bspell_targets\.(\w+)\b/g, "CLF.ActiveEnemies()");
  lua = lua.replace(/\bspell_targets\b/g, "CLF.ActiveEnemies()");
  lua = lua.replace(/\bmoving\b/g, "CLF.IsMoving()");
  lua = lua.replace(/\bmovement\.distance\b/g, "0");
  lua = lua.replace(/\bposition_back\b/g, "false");

  // Raid events (SimC simulation only -- always safe defaults in live WoW)
  lua = lua.replace(/\braid_event\.adds\.exists\b/g, "false");
  lua = lua.replace(/\braid_event\.adds\.up\b/g, "false");
  lua = lua.replace(/\braid_event\.adds\.in\b/g, "999");
  lua = lua.replace(/\braid_event\.adds\.remains\b/g, "0");
  lua = lua.replace(/\braid_event\.adds\.count\b/g, "0");
  lua = lua.replace(/\braid_event\.adds\.duration\b/g, "0");
  lua = lua.replace(/\braid_event\.movement\.in\b/g, "999");
  lua = lua.replace(/\braid_event\.movement\.remains\b/g, "0");
  lua = lua.replace(/\braid_event\.\w+\.\w+\b/g, "0");
  lua = lua.replace(/\braid_event\.\w+\b/g, "0");
  lua = lua.replace(/\braid_event\b/g, "0");

  // Fight style (SimC only -- default to false)
  lua = lua.replace(/\bfight_style\.\w+\b/g, "false");

  // Hero tree (talent subtree -- treated as talent check)
  lua = lua.replace(/\bhero_tree\.(\w+)\b/g, 'CLF.TalentEnabled("$1")');

  // Apex talent node (hero talent capstone)
  lua = lua.replace(/\bapex\.\d+\b/g, "false");
  lua = lua.replace(/\bapex\b/g, "false");

  // Class-specific SimC tokens (safe defaults)
  lua = lua.replace(/\bdeath_and_decay\.ticking\b/g, 'CLF.BuffUp("death_and_decay")');
  lua = lua.replace(/\bsoul_fragments\.total\b/g, "CLF.Power()");
  lua = lua.replace(/\bconsecration\.up\b/g, 'CLF.BuffUp("consecration")');
  lua = lua.replace(/\bconsecration\.remains\b/g, 'CLF.BuffRemains("consecration")');

  // Action property tokens (SimC action.X.Y)
  lua = lua.replace(/\baction\.(\w+)\.demonsurge_available\b/g, "false");
  lua = lua.replace(/\baction\.(\w+)\.pmultiplier\b/g, "1");

  // Multi-DoT refreshable count
  lua = lua.replace(/\bdot_refreshable_count\.(\w+)\b/g, "CLF.ActiveEnemies()");

  // Eclipse system (Balance Druid) -- must come before catch-all
  lua = lua.replace(/\beclipse\.in_solar\b/g, "CLF.InSolarEclipse()");
  lua = lua.replace(/\beclipse\.in_lunar\b/g, "CLF.InLunarEclipse()");
  lua = lua.replace(/\beclipse\.in_both\b/g, "(CLF.InSolarEclipse() and CLF.InLunarEclipse())");
  lua = lua.replace(/\beclipse\.in_any\b/g, "CLF.InAnyEclipse()");
  lua = lua.replace(/\beclipse\.in_eclipse\b/g, "CLF.InAnyEclipse()");
  lua = lua.replace(/\beclipse\.in_none\b/g, "(not CLF.InAnyEclipse())");
  lua = lua.replace(/\beclipse\.solar_next\b/g, 'CLF.EclipseNext("solar")');
  lua = lua.replace(/\beclipse\.lunar_next\b/g, 'CLF.EclipseNext("lunar")');
  lua = lua.replace(/\beclipse\.any_next\b/g, 'CLF.EclipseNext("any")');
  lua = lua.replace(/\beclipse\.wrath_counter\b/g, 'CLF.EclipseCounter("wrath")');
  lua = lua.replace(/\beclipse\.starfire_counter\b/g, 'CLF.EclipseCounter("starfire")');
  lua = lua.replace(/\beclipse\.\w+\b/g, "false");

  lua = lua.replace(/\bdrw\.bp_ticking\b/g, 'CLF.DebuffUp("blood_plague")');
  lua = lua.replace(/\bdeath_knight\.\w+\b/g, "false");
  lua = lua.replace(/\bpriest\.\w+\b/g, "false");
  lua = lua.replace(/\bboar_charge\.remains\b/g, "0");
  lua = lua.replace(/\bhowl_summon\.ready\b/g, "false");
  lua = lua.replace(/\bis\.\w+\b/g, "false");

  // Weapon tokens
  lua = lua.replace(/\bmain_hand\.2h\b/g, "true");
  lua = lua.replace(/\bmain_hand\.1h\b/g, "false");
  lua = lua.replace(/\boff_hand\.2h\b/g, "false");
  lua = lua.replace(/\boff_hand\.1h\b/g, "true");
  lua = lua.replace(/\bmain_hand\.\w+\b/g, "0");
  lua = lua.replace(/\boff_hand\.\w+\b/g, "0");

  // Pet
  lua = lua.replace(/\bpet\.alive\b/g, "CLF.PetAlive()");
  lua = lua.replace(/\bpet\.(\w+)\.active\b/g, 'CLF.PetActive("$1")');
  lua = lua.replace(/\bpet\.(\w+)\.remains\b/g, 'CLF.PetRemains("$1")');
  lua = lua.replace(/\bpet\.(\w+)\.stack\b/g, 'CLF.BuffStacks("pet_$1")');
  lua = lua.replace(/\bpet\.(\w+)\.up\b/g, 'CLF.BuffUp("pet_$1")');
  lua = lua.replace(/\bpet\.main\.buff\.(\w+)\.up\b/g, 'CLF.BuffUp("$1")');

  // Totem
  lua = lua.replace(/\btotem\.(\w+)\.active\b/g, 'CLF.TotemActive("$1")');
  lua = lua.replace(/\btotem\.(\w+)\.remains\b/g, 'CLF.TotemRemains("$1")');

  // Talent check
  lua = lua.replace(/\btalent\.(\w+)\.enabled\b/g, 'CLF.TalentEnabled("$1")');
  lua = lua.replace(/\btalent\.(\w+)\b/g, 'CLF.TalentEnabled("$1")');

  // Previous GCD
  lua = lua.replace(/\bprev_off_gcd\.(\w+)\b/g, 'CLF.PrevGCD("$1")');
  lua = lua.replace(/\bprev_gcd\.(\d+)\.(\w+)\b/g, 'CLF.PrevGCD("$2")');
  lua = lua.replace(/\bprev\.(\d+)\.(\w+)\b/g, 'CLF.PrevGCD("$2")');
  lua = lua.replace(/\bprev_gcd\b/g, 'CLF.PrevGCD("")');
  lua = lua.replace(/\bprev\b/g, 'CLF.PrevGCD("")');

  // Time & fight duration
  lua = lua.replace(/\bfight_remains\b/g, "CLF.FightRemains()");
  lua = lua.replace(/\btime\b(?!\.\w)/g, "CLF.CombatTime()");

  // GCD
  lua = lua.replace(/\bgcd\.remains\b/g, "CLF.GCDRemains()");
  lua = lua.replace(/\bgcd\.max\b/g, "CLF.GCDMax()");
  lua = lua.replace(/\bgcd\b(?!\.)/g, "CLF.GCDMax()");

  // Variable -- two-pass replacement:
  // @taint-solution Variables use CLF.GetVar() which reads from internal _varFns
  // table, never from WoW APIs directly. The ~= 0 wrap converts numeric
  // variable results to boolean context safely.
  lua = lua.replace(/\bvariable\.(\w+)(?=\s*[<>=!+\-*\/%])/g, 'CLF.GetVar("$1")');
  lua = lua.replace(/(?<=[<>=+\-*\/%])\s*variable\.(\w+)\b/g, ' CLF.GetVar("$1")');
  lua = lua.replace(/(?<=[(,])\s*variable\.(\w+)(?=\s*[),+\-*\/%<>=!])/g, 'CLF.GetVar("$1")');
  lua = lua.replace(/\bvariable\.(\w+)(?=\s*\)\s*[<>=!+\-*\/%])/g, 'CLF.GetVar("$1")');
  lua = lua.replace(/\bvariable\.(\w+)\b/g, '(CLF.GetVar("$1") ~= 0)');

  // Action properties
  lua = lua.replace(/\baction\.(\w+)\.execute_time\b/g, 'CLF.SpellCastTime("$1")');
  lua = lua.replace(/\baction\.(\w+)\.cast_time\b/g, 'CLF.SpellCastTime("$1")');
  lua = lua.replace(/\baction\.(\w+)\.execute_remains\b/g, "0");
  lua = lua.replace(/\baction\.(\w+)\.executing\b/g, "false");
  lua = lua.replace(/\baction\.(\w+)\.last_used\b/g, "0");
  lua = lua.replace(/\baction\.(\w+)\.cost\b/g, 'CLF.SpellCost("$1")');
  lua = lua.replace(/\baction\.(\w+)\.ready\b/g, 'CLF.CooldownReady("$1")');
  lua = lua.replace(/\baction\.(\w+)\.charges\b/g, 'CLF.CooldownCharges("$1")');
  lua = lua.replace(/\baction\.(\w+)\.in_flight_remains\b/g, "0");
  lua = lua.replace(/\baction\.(\w+)\.in_flight\b/g, "false");
  lua = lua.replace(/\baction\.(\w+)\.usable_in\b/g, 'CLF.CooldownRemains("$1")');
  lua = lua.replace(/\baction\.(\w+)\.usable\b/g, 'CLF.IsSpellUsable("$1")');
  lua = lua.replace(/\baction\.(\w+)\.enabled\b/g, 'CLF.IsSpellKnown("$1")');
  lua = lua.replace(/\baction\.(\w+)\.cooldown_react\b/g, 'CLF.CooldownReady("$1")');
  lua = lua.replace(/\baction\.(\w+)\.cooldown\b/g, 'CLF.CooldownRemains("$1")');
  lua = lua.replace(/\baction\.(\w+)\.energize_amount\b/g, "0");
  lua = lua.replace(/\baction\.(\w+)\.[\w.]+\b/g, "0");

  // Active dots
  lua = lua.replace(/\bactive_dot\.(\w+)\b/g, 'CLF.ActiveDot("$1")');

  // Eclipse buffs -- route to dedicated eclipse detection (must come before generic buff handlers)
  // WoW buff names are "Eclipse (Solar)" / "Eclipse (Lunar)" with parentheses,
  // but SimC uses buff.eclipse_solar / buff.eclipse_lunar (underscores).
  // Generic BuffUp("eclipse_solar") normalizes to "eclipse solar" which never matches
  // "Eclipse (Solar)", so these must use the CLF eclipse state tracker instead.
  lua = lua.replace(/\bbuff\.eclipse_solar\.remains\b/g, 'CLF.EclipseRemains("solar")');
  lua = lua.replace(/\bbuff\.eclipse_solar\.stack\b/g, '(CLF.InSolarEclipse() and 1 or 0)');
  lua = lua.replace(/\bbuff\.eclipse_solar\.down\b/g, "(not CLF.InSolarEclipse())");
  lua = lua.replace(/\bbuff\.eclipse_solar\.up\b/g, "CLF.InSolarEclipse()");
  lua = lua.replace(/\bbuff\.eclipse_lunar\.remains\b/g, 'CLF.EclipseRemains("lunar")');
  lua = lua.replace(/\bbuff\.eclipse_lunar\.stack\b/g, '(CLF.InLunarEclipse() and 1 or 0)');
  lua = lua.replace(/\bbuff\.eclipse_lunar\.down\b/g, "(not CLF.InLunarEclipse())");
  lua = lua.replace(/\bbuff\.eclipse_lunar\.up\b/g, "CLF.InLunarEclipse()");

  // SimC shorthand ca_inc = celestial_alignment/incarnation (must come before generic buff handlers)
  lua = lua.replace(/\bbuff\.ca_inc\.up\b/g, 'CLF.BuffUp("celestial alignment")');
  lua = lua.replace(/\bbuff\.ca_inc\.down\b/g, '(not CLF.BuffUp("celestial alignment"))');
  lua = lua.replace(/\bbuff\.ca_inc\.remains\b/g, 'CLF.BuffRemains("celestial alignment")');
  lua = lua.replace(/\bbuff\.ca_inc\.stack\b/g, 'CLF.BuffStacks("celestial alignment")');
  lua = lua.replace(/\bbuff\.ca_inc\.duration\b/g, 'CLF.BuffDuration("celestial alignment")');

  // Buffs -- process longer suffixes before shorter to avoid partial match
  lua = lua.replace(/\bbuff\.(\w+)\.tick_time_remains\b/g, "0");
  lua = lua.replace(/\bbuff\.(\w+)\.at_max_stacks\b/g, '(CLF.BuffStacks("$1") >= (CLF.BuffMaxStacks("$1")))');
  lua = lua.replace(/\bbuff\.(\w+)\.max_stack\b/g, 'CLF.BuffMaxStacks("$1")');
  lua = lua.replace(/\bbuff\.(\w+)\.value\b/g, "0");
  lua = lua.replace(/\bbuff\.(\w+)\.duration\b/g, 'CLF.BuffDuration("$1")');
  lua = lua.replace(/\bbuff\.(\w+)\.remains\b/g, 'CLF.BuffRemains("$1")');
  lua = lua.replace(/\bbuff\.(\w+)\.stack\b/g, 'CLF.BuffStacks("$1")');
  lua = lua.replace(/\bbuff\.(\w+)\.down\b/g, '(not CLF.BuffUp("$1"))');
  lua = lua.replace(/\bbuff\.(\w+)\.up\b/g, 'CLF.BuffUp("$1")');
  lua = lua.replace(/\bbuff\.(\w+)\.react\b/g, 'CLF.BuffUp("$1")');

  // Debuffs
  lua = lua.replace(/\bdebuff\.(\w+)\.pandemic\b/g, 'CLF.DebuffPandemic("$1")');
  lua = lua.replace(/\bdebuff\.(\w+)\.remains\b/g, 'CLF.DebuffRemains("$1")');
  lua = lua.replace(/\bdebuff\.(\w+)\.stack\b/g, 'CLF.DebuffStacks("$1")');
  lua = lua.replace(/\bdebuff\.(\w+)\.down\b/g, '(not CLF.DebuffUp("$1"))');
  lua = lua.replace(/\bdebuff\.(\w+)\.up\b/g, 'CLF.DebuffUp("$1")');
  lua = lua.replace(/\bdebuff\.(\w+)\.react\b/g, 'CLF.DebuffStacks("$1")');

  // Trinket tokens -- MUST run before generic cooldown handlers
  // @taint-solution Trinket cooldowns use CLF.GetTrinketCooldown() which
  // internally uses DurationObject:IsZero() (never reads secret CD values).
  lua = lua.replace(/\btrinket\.1\.cooldown\.remains\b/g, 'CLF.GetTrinketCooldown("trinket1")');
  lua = lua.replace(/\btrinket\.2\.cooldown\.remains\b/g, 'CLF.GetTrinketCooldown("trinket2")');
  lua = lua.replace(/\btrinket\.1\.cooldown\.ready\b/g, 'CLF.TrinketReady("trinket1")');
  lua = lua.replace(/\btrinket\.2\.cooldown\.ready\b/g, 'CLF.TrinketReady("trinket2")');
  lua = lua.replace(/\btrinket\.1\.has_use_buff\b/g, '(CLF.GetTrinketInfo("trinket1") and CLF.GetTrinketInfo("trinket1").hasUse or false)');
  lua = lua.replace(/\btrinket\.2\.has_use_buff\b/g, '(CLF.GetTrinketInfo("trinket2") and CLF.GetTrinketInfo("trinket2").hasUse or false)');
  lua = lua.replace(/\btrinket\.1\.has_cooldown\b/g, '(CLF.GetTrinketInfo("trinket1") and CLF.GetTrinketInfo("trinket1").hasUse or false)');
  lua = lua.replace(/\btrinket\.2\.has_cooldown\b/g, '(CLF.GetTrinketInfo("trinket2") and CLF.GetTrinketInfo("trinket2").hasUse or false)');
  lua = lua.replace(/\btrinket\.1\.ready\b/g, 'CLF.TrinketReady("trinket1")');
  lua = lua.replace(/\btrinket\.2\.ready\b/g, 'CLF.TrinketReady("trinket2")');
  lua = lua.replace(/\btrinket\.\d+\.\w+[\w.]*\b/g, "0");
  lua = lua.replace(/\btrinket\.\w+[\w.]*\b/g, "0");

  // SimC shorthand ca_inc = celestial_alignment/incarnation (must come before generic cooldown handlers)
  lua = lua.replace(/\bcooldown\.ca_inc\.full_recharge_time\b/g, 'CLF.CooldownRemains("celestial alignment")');
  lua = lua.replace(/\bcooldown\.ca_inc\.remains_expected\b/g, 'CLF.CooldownRemains("celestial alignment")');
  lua = lua.replace(/\bcooldown\.ca_inc\.charges_fractional\b/g, 'CLF.ChargesFractional("celestial alignment")');
  lua = lua.replace(/\bcooldown\.ca_inc\.charges\b/g, 'CLF.CooldownCharges("celestial alignment")');
  lua = lua.replace(/\bcooldown\.ca_inc\.remains\b/g, 'CLF.CooldownRemains("celestial alignment")');
  lua = lua.replace(/\bcooldown\.ca_inc\.ready\b/g, 'CLF.CooldownReady("celestial alignment")');
  lua = lua.replace(/\bcooldown\.ca_inc\.up\b/g, 'CLF.CooldownReady("celestial alignment")');
  lua = lua.replace(/\bcooldown\.ca_inc\.duration\b/g, 'CLF.CooldownDuration("celestial alignment")');
  lua = lua.replace(/\bcooldown\.ca_inc\b/g, 'CLF.CooldownRemains("celestial alignment")');

  // Cooldowns -- process longer suffixes first
  // @taint-solution All cooldown checks go through CLF.CooldownRemains/Ready
  // which use DurationObject:IsZero() + internal CD timers, never reading
  // secret GetSpellCooldown() values directly.
  lua = lua.replace(/\bcooldown\.(\w+)\.full_recharge_time\b/g, 'CLF.CooldownRemains("$1")');
  lua = lua.replace(/\bcooldown\.(\w+)\.remains_expected\b/g, 'CLF.CooldownRemains("$1")');
  lua = lua.replace(/\bcooldown\.(\w+)\.charges_fractional\b/g, 'CLF.ChargesFractional("$1")');
  lua = lua.replace(/\bcooldown\.(\w+)\.charges\b/g, 'CLF.CooldownCharges("$1")');
  lua = lua.replace(/\bcooldown\.(\w+)\.remains\b/g, 'CLF.CooldownRemains("$1")');
  lua = lua.replace(/\bcooldown\.(\w+)\.ready\b/g, 'CLF.CooldownReady("$1")');
  lua = lua.replace(/\bcooldown\.(\w+)\.up\b/g, 'CLF.CooldownReady("$1")');
  lua = lua.replace(/\bcooldown\.(\w+)\.duration\b/g, 'CLF.CooldownDuration("$1")');
  lua = lua.replace(/\bcooldown\.(\w+)\b/g, 'CLF.CooldownRemains("$1")');

  // Dots (aliases to debuff)
  lua = lua.replace(/\bdot\.(\w+)\.refreshable\b/g, 'CLF.DebuffPandemic("$1")');
  lua = lua.replace(/\bdot\.(\w+)\.pmultiplier\b/g, "1");
  lua = lua.replace(/\bdot\.(\w+)\.ticks_remain\b/g, "1");
  lua = lua.replace(/\bdot\.(\w+)\.duration\b/g, "0");
  lua = lua.replace(/\bdot\.(\w+)\.remains\b/g, 'CLF.DebuffRemains("$1")');
  lua = lua.replace(/\bdot\.(\w+)\.ticking\b/g, 'CLF.DebuffUp("$1")');
  lua = lua.replace(/\bdot\.(\w+)\.stack\b/g, 'CLF.DebuffStacks("$1")');
  lua = lua.replace(/\bdot\.(\w+)\.pandemic\b/g, 'CLF.DebuffPandemic("$1")');

  // Resources (raw value)
  // @taint-solution All resource reads go through CLF.Power() which uses
  // internal CLF._resTracker (fed by CLEU events), never reading secret
  // UnitPower() values directly in combat.
  lua = lua.replace(/\bfocus\b/g, "CLF.Power()");
  lua = lua.replace(/\brage\b/g, "CLF.Power()");
  lua = lua.replace(/\benergy\b/g, "CLF.Power()");
  lua = lua.replace(/\bmaelstrom\b/g, "CLF.Power()");
  lua = lua.replace(/\bfury\b/g, "CLF.Power()");
  lua = lua.replace(/\bpain\b/g, "CLF.Power()");
  lua = lua.replace(/\brunic_power\b/g, "CLF.Power()");
  lua = lua.replace(/\bholy_power\b/g, "CLF.Power()");
  lua = lua.replace(/\bchi\b/g, "CLF.Power()");
  lua = lua.replace(/\bsoul_shards\b/g, "CLF.Power()");
  lua = lua.replace(/\bastral_power\b/g, "CLF.Power()");
  lua = lua.replace(/\bessence\b/g, "CLF.Power()");
  lua = lua.replace(/\bcombo_points\b/g, "CLF.ComboPoints()");
  lua = lua.replace(/\binsanity\b/g, "CLF.Power()");
  lua = lua.replace(/\barcane_charges\b/g, "CLF.Power()");
  lua = lua.replace(/\bmana\b/g, "CLF.PowerPct()");
  lua = lua.replace(/\bpower\.deficit\b/g, "CLF.PowerDeficit()");
  lua = lua.replace(/\bpower\.max\b/g, "CLF.PowerMax()");
  lua = lua.replace(/\bpower\.pct\b/g, "CLF.PowerPct()");

  // DK runes
  lua = lua.replace(/\brune\b/g, "CLF.Runes()");

  // Charges
  lua = lua.replace(/\bcharges\b/g, "CLF.CurrentCharges()");
  lua = lua.replace(/\bmax_charges\b/g, "CLF.CurrentMaxCharges()");

  // Set bonus & equipment (SimC only -- always false in live)
  lua = lua.replace(/\bset_bonus\.\w+\b/g, "false");
  lua = lua.replace(/\bequipped\.\w+\b/g, "false");
  lua = lua.replace(/\brace\.\w+\b/g, "false");

  // Stat cooldowns (SimC only)
  lua = lua.replace(/\bstat\.any\.cooldown_remains\b/g, "0");
  lua = lua.replace(/\bstat\.\w+\.\w+\b/g, "0");

  // Form/stance checks
  lua = lua.replace(/\bform\.cat\b/g, 'CLF.IsForm("cat")');
  lua = lua.replace(/\bform\.bear\b/g, 'CLF.IsForm("bear")');
  lua = lua.replace(/\bform\.moonkin\b/g, 'CLF.IsForm("moonkin")');
  lua = lua.replace(/\bform\.travel\b/g, 'CLF.IsForm("travel")');
  lua = lua.replace(/\bform\.caster\b/g, 'CLF.IsForm("caster")');
  lua = lua.replace(/\bform\.shadowform\b/g, 'CLF.IsForm("shadowform")');
  lua = lua.replace(/\bform\.stealth\b/g, 'CLF.IsForm("stealth")');
  lua = lua.replace(/\bform\.(\w+)\b/g, 'CLF.IsForm("$1")');

  // Boolean helpers
  lua = lua.replace(/\bstealthed\.improved_garrote\b/g, "CLF.IsStealthed()");
  lua = lua.replace(/\bstealthed\.all\b/g, "CLF.IsStealthed()");
  lua = lua.replace(/\bstealthed\.rogue\b/g, "CLF.IsStealthed()");
  lua = lua.replace(/\bstealthed\.\w+\b/g, "CLF.IsStealthed()");

  // Catch-all for remaining unresolved dot-pattern tokens
  lua = lua.replace(/\bpet\.main\b/g, "CLF.PetAlive()");

  // Set bonus catch-all
  lua = lua.replace(/\bset_bonus\.[\w.]+\b/g, "false");

  // Legacy tokens (Shadowlands/earlier)
  lua = lua.replace(/\bcovenant\.[\w.]+\b/g, "false");
  lua = lua.replace(/\bconduit\.[\w.]+\b/g, "0");
  lua = lua.replace(/\bruneforge\.[\w.]+\b/g, "false");
  lua = lua.replace(/\blegendary\.[\w.]+\b/g, "false");
  lua = lua.replace(/\bsoulbind\.[\w.]+\b/g, "false");

  // Hero talent tree tokens
  lua = lua.replace(/\bhero_tree\.[\w.]+\b/g, "false");

  // Catch-all: any remaining word.number.word patterns
  lua = lua.replace(/\b(\w+)\.(\d+)\.(\w[\w.]*)\b/g, "0");

  // SimC time suffixes -- must come after all token replacements
  const toLuaNum = (v: number): string => {
    if (!isFinite(v) || isNaN(v)) return "0";
    if (Math.abs(v) > 1e15) return String(Math.round(v));
    let s = String(v);
    if (/e[+-]/i.test(s)) {
      const digits = Math.max(0, Math.min(20, -Math.floor(Math.log10(Math.abs(v))))) + 2;
      s = v.toFixed(Math.min(digits, 20)).replace(/\.?0+$/, "");
    }
    if (s.startsWith(".")) s = "0" + s;
    if (s.startsWith("-.")) s = "-0" + s.slice(1);
    return s || "0";
  };
  lua = lua.replace(/(?<!\w)(\d*\.?\d+)ms(?!\w)/g, (_, n) => toLuaNum(parseFloat(n) / 1000));
  lua = lua.replace(/(?<!\w)(\d*\.?\d+)h(?!\w)/g, (_, n) => toLuaNum(parseFloat(n) * 3600));
  lua = lua.replace(/(?<!\w)(\d*\.?\d+)m(?!\w)/g, (_, n) => toLuaNum(parseFloat(n) * 60));
  lua = lua.replace(/(?<!\w)(\d*\.?\d+)s(?!\w)/g, (_, n) => toLuaNum(parseFloat(n)));

  // Operators -- must come after all token replacements
  lua = lua.replace(/%%/g, "%");
  lua = lua.replace(/&&/g, "&");
  lua = lua.replace(/\|\|/g, "|");
  lua = lua.replace(/&/g, " and ");
  lua = lua.replace(/\|/g, " or ");
  lua = lua.replace(/>=/g, " >= ");
  lua = lua.replace(/<=/g, " <= ");
  lua = lua.replace(/!=/g, "~=");
  lua = lua.replace(/([^<>~])=([^=])/g, "$1==$2");
  lua = lua.replace(/!/g, "not ");

  // Fix bare leading-dot decimals (.7200 → 0.7200) -- Lua requires a leading zero
  lua = lua.replace(/(?<![0-9a-zA-Z_"])\.(\d+)/g, "0.$1");

  return lua;
}
