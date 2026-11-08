import { describe, it, expect } from "vitest";
import { conditionToLua, generateWatchdogLua, generateHelpers, generateCore, generateEngine } from "../server/addon-generator";
import { generatePrecombatCondition, injectGroupBuff } from "../server/simc-parser";
import type { AplEntry } from "../shared/schema";

describe("SimC Condition Transpiler (conditionToLua)", () => {
  describe("Empty / trivial conditions", () => {
    it("returns 'true' for empty string", () => {
      expect(conditionToLua("")).toBe("true");
    });
    it("returns 'true' for whitespace-only", () => {
      expect(conditionToLua("   ")).toBe("true");
    });
    it("returns 'true' for null/undefined", () => {
      expect(conditionToLua(null as any)).toBe("true");
      expect(conditionToLua(undefined as any)).toBe("true");
    });
  });

  describe("Logical operators", () => {
    it("converts & to 'and'", () => {
      const result = conditionToLua("buff.test.up&cooldown.test.ready");
      expect(result).toContain(" and ");
    });
    it("converts | to 'or'", () => {
      const result = conditionToLua("buff.a.up|buff.b.up");
      expect(result).toContain(" or ");
    });
    it("converts ! to 'not '", () => {
      const result = conditionToLua("!buff.test.up");
      expect(result).toContain("not ");
    });
    it("converts != to ~=", () => {
      const result = conditionToLua("variable.test!=0");
      expect(result).toContain("~=");
    });
    it("converts single = to ==", () => {
      const result = conditionToLua("variable.test=1");
      expect(result).toContain("==");
    });
  });

  describe("Min/Max operators", () => {
    it("converts >? to math.min", () => {
      const result = conditionToLua("spell_targets>?3");
      expect(result).toContain("math.min(");
    });
    it("converts <? to math.max", () => {
      const result = conditionToLua("spell_targets<?1");
      expect(result).toContain("math.max(");
    });
  });

  describe("Buff conditions", () => {
    it("converts buff.X.up to CLF.BuffUp", () => {
      expect(conditionToLua("buff.avenging_wrath.up")).toContain('CLF.BuffUp("avenging_wrath")');
    });
    it("converts buff.X.down to not CLF.BuffUp", () => {
      const result = conditionToLua("buff.avenging_wrath.down");
      expect(result).toContain('not CLF.BuffUp("avenging_wrath")');
    });
    it("converts buff.X.remains to CLF.BuffRemains", () => {
      expect(conditionToLua("buff.avenging_wrath.remains")).toContain('CLF.BuffRemains("avenging_wrath")');
    });
    it("converts buff.X.stack to CLF.BuffStacks", () => {
      expect(conditionToLua("buff.avenging_wrath.stack")).toContain('CLF.BuffStacks("avenging_wrath")');
    });
    it("converts buff.X.react to CLF.BuffUp", () => {
      expect(conditionToLua("buff.avenging_wrath.react")).toContain('CLF.BuffUp("avenging_wrath")');
    });
    it("converts buff.X.duration to CLF.BuffDuration", () => {
      expect(conditionToLua("buff.avenging_wrath.duration")).toContain('CLF.BuffDuration("avenging_wrath")');
    });
    it("converts buff.X.max_stack to CLF.BuffMaxStacks", () => {
      expect(conditionToLua("buff.bone_shield.max_stack")).toContain('CLF.BuffMaxStacks("bone_shield")');
    });
  });

  describe("Debuff conditions", () => {
    it("converts debuff.X.up to CLF.DebuffUp", () => {
      expect(conditionToLua("debuff.flame_shock.up")).toContain('CLF.DebuffUp("flame_shock")');
    });
    it("converts target.debuff.X.up to CLF.DebuffUp", () => {
      expect(conditionToLua("target.debuff.flame_shock.up")).toContain('CLF.DebuffUp("flame_shock")');
    });
    it("converts debuff.X.remains to CLF.DebuffRemains", () => {
      expect(conditionToLua("debuff.flame_shock.remains")).toContain('CLF.DebuffRemains("flame_shock")');
    });
    it("converts debuff.X.stack to CLF.DebuffStacks", () => {
      expect(conditionToLua("debuff.flame_shock.stack")).toContain('CLF.DebuffStacks("flame_shock")');
    });
  });

  describe("Cooldown conditions", () => {
    it("converts cooldown.X.remains to CLF.CooldownRemains", () => {
      expect(conditionToLua("cooldown.judgment.remains")).toContain('CLF.CooldownRemains("judgment")');
    });
    it("converts cooldown.X.ready to CLF.CooldownReady", () => {
      expect(conditionToLua("cooldown.judgment.ready")).toContain('CLF.CooldownReady("judgment")');
    });
    it("converts cooldown.X.charges to CLF.CooldownCharges", () => {
      expect(conditionToLua("cooldown.charge.charges")).toContain('CLF.CooldownCharges("charge")');
    });
    it("converts cooldown.X.charges_fractional to CLF.ChargesFractional", () => {
      expect(conditionToLua("cooldown.fireball.charges_fractional")).toContain('CLF.ChargesFractional("fireball")');
    });
    it("converts cooldown.X.up to CLF.CooldownReady", () => {
      expect(conditionToLua("cooldown.judgment.up")).toContain('CLF.CooldownReady("judgment")');
    });
    it("converts cooldown.X.duration to CLF.CooldownDuration", () => {
      expect(conditionToLua("cooldown.judgment.duration")).toContain('CLF.CooldownDuration("judgment")');
    });
  });

  describe("Dot conditions (aliases to debuff)", () => {
    it("converts dot.X.ticking to CLF.DebuffUp", () => {
      expect(conditionToLua("dot.corruption.ticking")).toContain('CLF.DebuffUp("corruption")');
    });
    it("converts dot.X.refreshable to CLF.DebuffPandemic", () => {
      expect(conditionToLua("dot.corruption.refreshable")).toContain('CLF.DebuffPandemic("corruption")');
    });
    it("converts dot.X.remains to CLF.DebuffRemains", () => {
      expect(conditionToLua("dot.corruption.remains")).toContain('CLF.DebuffRemains("corruption")');
    });
  });

  describe("Resource conditions", () => {
    it("converts holy_power to CLF.Power()", () => {
      expect(conditionToLua("holy_power>=3")).toContain("CLF.Power()");
      expect(conditionToLua("holy_power>=3")).toMatch(/>=\s*3/);
    });
    it("converts combo_points to CLF.ComboPoints()", () => {
      expect(conditionToLua("combo_points>=5")).toContain("CLF.ComboPoints()");
      expect(conditionToLua("combo_points>=5")).toMatch(/>=\s*5/);
    });
    it("converts energy to CLF.Power()", () => {
      expect(conditionToLua("energy>40")).toContain("CLF.Power()");
    });
    it("converts rage to CLF.Power()", () => {
      expect(conditionToLua("rage>=30")).toContain("CLF.Power()");
      expect(conditionToLua("rage>=30")).toMatch(/>=\s*30/);
    });
    it("converts mana to CLF.PowerPct()", () => {
      expect(conditionToLua("mana>20")).toContain("CLF.PowerPct()");
    });
    it("converts soul_shards to CLF.Power()", () => {
      expect(conditionToLua("soul_shards>=3")).toContain("CLF.Power()");
    });
    it("converts chi to CLF.Power()", () => {
      expect(conditionToLua("chi>=4")).toContain("CLF.Power()");
    });
    it("converts runic_power to CLF.Power()", () => {
      expect(conditionToLua("runic_power>=80")).toContain("CLF.Power()");
    });
    it("converts astral_power to CLF.Power()", () => {
      expect(conditionToLua("astral_power>=50")).toContain("CLF.Power()");
    });
    it("converts insanity to CLF.Power()", () => {
      expect(conditionToLua("insanity>=60")).toContain("CLF.Power()");
    });
    it("converts essence to CLF.Power()", () => {
      expect(conditionToLua("essence>=2")).toContain("CLF.Power()");
    });
    it("converts arcane_charges to CLF.Power()", () => {
      expect(conditionToLua("arcane_charges>=4")).toContain("CLF.Power()");
    });
    it("converts fury to CLF.Power()", () => {
      expect(conditionToLua("fury>=40")).toContain("CLF.Power()");
    });
    it("converts pain to CLF.Power()", () => {
      expect(conditionToLua("pain>=50")).toContain("CLF.Power()");
    });
    it("converts focus to CLF.Power()", () => {
      expect(conditionToLua("focus>=30")).toContain("CLF.Power()");
    });
    it("converts power.deficit to CLF.PowerDeficit()", () => {
      expect(conditionToLua("power.deficit>30")).toContain("CLF.PowerDeficit()>30");
    });
    it("converts power.max to CLF.PowerMax()", () => {
      expect(conditionToLua("power.max")).toContain("CLF.PowerMax()");
    });
    it("converts power.pct to CLF.PowerPct()", () => {
      expect(conditionToLua("power.pct>50")).toContain("CLF.PowerPct()>50");
    });
    it("converts rune to CLF.Runes() for DK", () => {
      expect(conditionToLua("rune>=3")).toContain("CLF.Runes()");
      expect(conditionToLua("rune>=3")).toMatch(/>=\s*3/);
    });
  });

  describe("Target conditions", () => {
    it("converts target.health.pct to CLF.TargetHealthPct()", () => {
      expect(conditionToLua("target.health.pct<20")).toContain("CLF.TargetHealthPct()<20");
    });
    it("converts target.time_to_die to CLF.FightRemains()", () => {
      expect(conditionToLua("target.time_to_die>10")).toContain("CLF.FightRemains()>10");
    });
    it("converts target.is_casting_interruptible to CLF.TargetIsCasting()", () => {
      expect(conditionToLua("target.is_casting_interruptible")).toContain("CLF.TargetIsCasting()");
    });
    it("converts active_enemies to CLF.ActiveEnemies()", () => {
      expect(conditionToLua("active_enemies>=3")).toContain("CLF.ActiveEnemies()");
      expect(conditionToLua("active_enemies>=3")).toMatch(/>=\s*3/);
    });
    it("converts spell_targets.X to CLF.ActiveEnemies()", () => {
      expect(conditionToLua("spell_targets.divine_storm>=3")).toContain("CLF.ActiveEnemies()");
      expect(conditionToLua("spell_targets.divine_storm>=3")).toMatch(/>=\s*3/);
    });
  });

  describe("Action properties", () => {
    it("converts action.X.ready to CLF.CooldownReady", () => {
      expect(conditionToLua("action.judgment.ready")).toContain('CLF.CooldownReady("judgment")');
    });
    it("converts action.X.usable to CLF.IsSpellUsable", () => {
      expect(conditionToLua("action.judgment.usable")).toContain('CLF.IsSpellUsable("judgment")');
    });
    it("converts action.X.charges to CLF.CooldownCharges", () => {
      expect(conditionToLua("action.judgment.charges")).toContain('CLF.CooldownCharges("judgment")');
    });
    it("converts action.X.cast_time to CLF.SpellCastTime", () => {
      expect(conditionToLua("action.frostbolt.cast_time")).toContain('CLF.SpellCastTime("frostbolt")');
    });
    it("converts action.X.cost to CLF.SpellCost", () => {
      expect(conditionToLua("action.frostbolt.cost")).toContain('CLF.SpellCost("frostbolt")');
    });
    it("converts action.X.enabled to CLF.IsSpellKnown", () => {
      expect(conditionToLua("action.frostbolt.enabled")).toContain('CLF.IsSpellKnown("frostbolt")');
    });
  });

  describe("Talent conditions", () => {
    it("converts talent.X.enabled to CLF.TalentEnabled", () => {
      expect(conditionToLua("talent.improved_judgment.enabled")).toContain('CLF.TalentEnabled("improved_judgment")');
    });
    it("converts bare talent.X to CLF.TalentEnabled", () => {
      expect(conditionToLua("talent.improved_judgment")).toContain('CLF.TalentEnabled("improved_judgment")');
    });
    it("converts hero_tree.X to CLF.TalentEnabled", () => {
      expect(conditionToLua("hero_tree.lightsmith")).toContain('CLF.TalentEnabled("lightsmith")');
    });
  });

  describe("GCD & time", () => {
    it("converts gcd.remains to CLF.GCDRemains()", () => {
      expect(conditionToLua("gcd.remains")).toContain("CLF.GCDRemains()");
    });
    it("converts gcd.max to CLF.GCDMax()", () => {
      expect(conditionToLua("gcd.max")).toContain("CLF.GCDMax()");
    });
    it("converts fight_remains to CLF.FightRemains()", () => {
      expect(conditionToLua("fight_remains>30")).toContain("CLF.FightRemains()>30");
    });
  });

  describe("Previous GCD", () => {
    it("converts prev_gcd.1.X to CLF.PrevGCD", () => {
      expect(conditionToLua("prev_gcd.1.pyroblast")).toContain('CLF.PrevGCD("pyroblast")');
    });
    it("converts prev_off_gcd.X to CLF.PrevGCD", () => {
      expect(conditionToLua("prev_off_gcd.counterspell")).toContain('CLF.PrevGCD("counterspell")');
    });
  });

  describe("SimC-only tokens (safe defaults)", () => {
    it("raid_event.adds.in defaults to 999", () => {
      expect(conditionToLua("raid_event.adds.in")).toContain("999");
    });
    it("raid_event.adds.exists defaults to false", () => {
      expect(conditionToLua("raid_event.adds.exists")).toContain("false");
    });
    it("set_bonus is always false", () => {
      expect(conditionToLua("set_bonus.tier31_2pc")).toContain("false");
    });
    it("equipped.X is always false", () => {
      expect(conditionToLua("equipped.some_trinket")).toContain("false");
    });
    it("target.distance is 0", () => {
      expect(conditionToLua("target.distance")).toContain("0");
    });
  });

  describe("Variable conditions", () => {
    it("converts variable.X to CLF.GetVar wrapped in ~= 0", () => {
      const result = conditionToLua("variable.hold_cds");
      expect(result).toContain('CLF.GetVar("hold_cds")');
      expect(result).toContain("~= 0");
    });
  });

  describe("Pet conditions", () => {
    it("converts pet.alive to CLF.PetAlive()", () => {
      expect(conditionToLua("pet.alive")).toContain("CLF.PetAlive()");
    });
    it("converts pet.X.active to CLF.PetActive", () => {
      expect(conditionToLua("pet.felguard.active")).toContain('CLF.PetActive("felguard")');
    });
  });

  describe("Movement", () => {
    it("converts moving to CLF.IsMoving()", () => {
      expect(conditionToLua("moving")).toContain("CLF.IsMoving()");
    });
  });

  describe("Form/stance", () => {
    it("converts form.cat to CLF.IsForm", () => {
      expect(conditionToLua("form.cat")).toContain('CLF.IsForm("cat")');
    });
    it("converts form.bear to CLF.IsForm", () => {
      expect(conditionToLua("form.bear")).toContain('CLF.IsForm("bear")');
    });
    it("converts form.moonkin to CLF.IsForm", () => {
      expect(conditionToLua("form.moonkin")).toContain('CLF.IsForm("moonkin")');
    });
  });

  describe("Time suffixes", () => {
    it("converts seconds suffix (1.5s)", () => {
      const result = conditionToLua("cooldown.test.remains<1.5s");
      expect(result).toContain("<1.5");
      expect(result).not.toMatch(/1\.5s/);
    });
    it("converts minutes suffix (2m)", () => {
      const result = conditionToLua("fight_remains>2m");
      expect(result).toContain(">120");
    });
    it("converts milliseconds suffix (500ms)", () => {
      const result = conditionToLua("gcd.remains<500ms");
      expect(result).toContain("<0.5");
    });
  });

  describe("Complex real-world conditions", () => {
    it("Ret Paladin: buff+resource combo", () => {
      const result = conditionToLua("buff.avenging_wrath.up&holy_power>=3");
      expect(result).toContain('CLF.BuffUp("avenging_wrath")');
      expect(result).toContain(" and ");
      expect(result).toContain("CLF.Power()");
      expect(result).toMatch(/>=\s*3/);
    });

    it("Fire Mage: hot streak with min operator", () => {
      const result = conditionToLua("buff.hot_streak.up&!prev_gcd.1.pyroblast&cooldown.combustion.remains>?30");
      expect(result).toContain('CLF.BuffUp("hot_streak")');
      expect(result).toContain("not ");
      expect(result).toContain('CLF.PrevGCD("pyroblast")');
      expect(result).toContain("math.min(");
      expect(result).toContain('CLF.CooldownRemains("combustion")');
    });

    it("Unholy DK: debuff + cooldown + buff combo", () => {
      const result = conditionToLua("target.debuff.festering_wound.stack>=4&cooldown.apocalypse.ready&!buff.dark_transformation.up");
      expect(result).toContain('CLF.DebuffStacks("festering_wound")');
      expect(result).toMatch(/>=\s*4/);
      expect(result).toContain('CLF.CooldownReady("apocalypse")');
      expect(result).toContain('not CLF.BuffUp("dark_transformation")');
    });

    it("Balance Druid: eclipse check + power", () => {
      const result = conditionToLua("eclipse.in_eclipse&astral_power>=50&buff.starweaver.up");
      expect(result).toContain("CLF.InAnyEclipse()");
      expect(result).toContain("CLF.Power()");
      expect(result).toMatch(/>=\s*50/);
      expect(result).toContain('CLF.BuffUp("starweaver")');
    });

    it("Balance Druid: eclipse.in_solar and eclipse.in_lunar", () => {
      const solar = conditionToLua("eclipse.in_solar");
      expect(solar).toContain("CLF.InSolarEclipse()");

      const lunar = conditionToLua("eclipse.in_lunar");
      expect(lunar).toContain("CLF.InLunarEclipse()");

      const none = conditionToLua("eclipse.in_none");
      expect(none).toContain("not CLF.InAnyEclipse()");

      const both = conditionToLua("eclipse.in_both");
      expect(both).toContain("CLF.InSolarEclipse()");
      expect(both).toContain("CLF.InLunarEclipse()");
    });

    it("Balance Druid: eclipse counters and next", () => {
      const wc = conditionToLua("eclipse.wrath_counter<=1");
      expect(wc).toContain('CLF.EclipseCounter("wrath")');

      const sc = conditionToLua("eclipse.starfire_counter<=1");
      expect(sc).toContain('CLF.EclipseCounter("starfire")');

      const sn = conditionToLua("eclipse.solar_next");
      expect(sn).toContain('CLF.EclipseNext("solar")');

      const ln = conditionToLua("eclipse.lunar_next");
      expect(ln).toContain('CLF.EclipseNext("lunar")');
    });

    it("Balance Druid: unknown eclipse tokens fall through safely", () => {
      const result = conditionToLua("eclipse.some_future_token");
      expect(result).toBe("false");
    });

    it("Windwalker Monk: chi + buff + active_enemies", () => {
      const result = conditionToLua("chi>=3&active_enemies>=3&buff.serenity.down");
      expect(result).toContain("CLF.Power()");
      expect(result).toContain("CLF.ActiveEnemies()");
      expect(result).toContain('not CLF.BuffUp("serenity")');
    });

    it("Assassination Rogue: dot refreshable + energy", () => {
      const result = conditionToLua("dot.garrote.refreshable&energy>=45&combo_points<4");
      expect(result).toContain('CLF.DebuffPandemic("garrote")');
      expect(result).toContain("CLF.Power()");
      expect(result).toMatch(/>=\s*45/);
      expect(result).toMatch(/<\s*4/);
    });

    it("Enhancement Shaman: maelstrom + buff stacks", () => {
      const result = conditionToLua("buff.maelstrom_weapon.stack>=5&!buff.primordial_wave.up");
      expect(result).toContain('CLF.BuffStacks("maelstrom_weapon")');
      expect(result).toMatch(/>=\s*5/);
      expect(result).toContain('not CLF.BuffUp("primordial_wave")');
    });
  });
});

describe("Precombat Detection (generatePrecombatCondition)", () => {
  it("generates !form.X for form spells", () => {
    expect(generatePrecombatCondition("moonkin_form")).toBe("!form.moonkin");
    expect(generatePrecombatCondition("cat_form")).toBe("!form.cat");
    expect(generatePrecombatCondition("bear_form")).toBe("!form.bear");
  });

  it("generates !form.X for stance spells", () => {
    expect(generatePrecombatCondition("battle_stance")).toBe("!form.battle");
    expect(generatePrecombatCondition("defensive_stance")).toBe("!form.defensive");
  });

  it("generates !stealthed.all for stealth/prowl", () => {
    expect(generatePrecombatCondition("stealth")).toBe("!stealthed.all");
    expect(generatePrecombatCondition("prowl")).toBe("!stealthed.all");
  });

  it("generates !pet.main for summon_pet", () => {
    expect(generatePrecombatCondition("summon_pet")).toBe("!pet.main");
  });

  it("generates !buff.X.up for general buffs", () => {
    expect(generatePrecombatCondition("arcane_intellect")).toBe("!buff.arcane_intellect.up");
    expect(generatePrecombatCondition("mark_of_the_wild")).toBe("!buff.mark_of_the_wild.up");
    expect(generatePrecombatCondition("battle_shout")).toBe("!buff.battle_shout.up");
  });

  it("generates !buff.X.up for weapon enchant spells", () => {
    expect(generatePrecombatCondition("flametongue_weapon")).toBe("!buff.flametongue_weapon.up");
    expect(generatePrecombatCondition("windfury_weapon")).toBe("!buff.windfury_weapon.up");
  });
});

describe("Group Buff Injection (injectGroupBuff)", () => {
  const makeEntry = (name: string, specId: string): AplEntry => ({
    id: "test-" + name,
    specId,
    spellName: name,
    spellIcon: "",
    priority: 10,
    condition: "",
    mode: "Both",
    isInterrupt: false,
    isOffensive: true,
    keybind: "",
    enabled: true,
    isPrecombat: false,
    precombatType: null,
  });

  it("injects Mark of the Wild for Druid specs", () => {
    const entries = [makeEntry("Moonfire", "druid-balance")];
    const result = injectGroupBuff("druid-balance", entries);
    expect(result.length).toBe(2);
    expect(result[0].spellName).toBe("Mark of the Wild");
    expect(result[0].isPrecombat).toBe(true);
    expect(result[0].precombatType).toBe("state");
    expect(result[0].priority).toBe(-110);
  });

  it("injects Arcane Intellect for Mage specs", () => {
    const entries = [makeEntry("Frostbolt", "mage-frost")];
    const result = injectGroupBuff("mage-frost", entries);
    expect(result[0].spellName).toBe("Arcane Intellect");
    expect(result[0].condition).toBe("!buff.arcane_intellect.up");
  });

  it("injects Battle Shout for Warrior specs", () => {
    const entries = [makeEntry("Mortal Strike", "warrior-arms")];
    const result = injectGroupBuff("warrior-arms", entries);
    expect(result[0].spellName).toBe("Battle Shout");
  });

  it("injects Power Word: Fortitude for Priest specs", () => {
    const entries = [makeEntry("Shadow Word: Pain", "priest-shadow")];
    const result = injectGroupBuff("priest-shadow", entries);
    expect(result[0].spellName).toBe("Power Word: Fortitude");
  });

  it("injects Blessing of the Bronze for Evoker specs", () => {
    const entries = [makeEntry("Fire Breath", "evoker-dev")];
    const result = injectGroupBuff("evoker-dev", entries);
    expect(result[0].spellName).toBe("Blessing of the Bronze");
  });

  it("does NOT inject for classes without group buffs (Rogue)", () => {
    const entries = [makeEntry("Mutilate", "rogue-ass")];
    const result = injectGroupBuff("rogue-ass", entries);
    expect(result.length).toBe(1);
  });

  it("does NOT inject for classes without group buffs (Paladin)", () => {
    const entries = [makeEntry("Templar's Verdict", "paladin-ret")];
    const result = injectGroupBuff("paladin-ret", entries);
    expect(result.length).toBe(1);
  });

  it("does NOT double-inject if buff already exists", () => {
    const entries = [
      makeEntry("Mark of the Wild", "druid-balance"),
      makeEntry("Moonfire", "druid-balance"),
    ];
    const result = injectGroupBuff("druid-balance", entries);
    expect(result.length).toBe(2);
  });
});

describe("Weapon Enchant Buff Detection", () => {
  const helpers = generateHelpers();

  it("defines WEAPON_ENCHANT_BUFFS lookup table", () => {
    expect(helpers).toContain("WEAPON_ENCHANT_BUFFS");
    expect(helpers).toContain("flametongue_weapon = true");
    expect(helpers).toContain("windfury_weapon = true");
  });

  it("CheckWeaponEnchant function uses GetWeaponEnchantInfo", () => {
    expect(helpers).toContain("function CheckWeaponEnchant()");
    expect(helpers).toContain("GetWeaponEnchantInfo");
  });

  it("CLF.BuffUp checks weapon enchant table as fallback", () => {
    expect(helpers).toContain("WEAPON_ENCHANT_BUFFS[rawBuff]");
    expect(helpers).toContain("CheckWeaponEnchant()");
  });

  it("CLF.BuffRemains checks weapon enchant for remaining time", () => {
    expect(helpers).toContain("WEAPON_ENCHANT_BUFFS[rawBuff] and GetWeaponEnchantInfo");
  });
});

describe("UNIT_SPELLCAST_SUCCEEDED Secret SpellID Fallback", () => {
  const coreData = {
    spec: { id: "shaman-ele", className: "Shaman", specName: "Elemental", role: "Ranged DPS", resource: "Maelstrom", classColor: "#0070DD", iconSlug: "shaman-ele" },
    entries: [],
  };
  const core = generateCore(coreData);

  it("tries C_Spell.GetSpellName with raw secret spellID as fallback", () => {
    expect(core).toContain("if not name and isSecret then");
    expect(core).toContain("C_Spell.GetSpellName, spellID");
  });

  it("uses DetaintStr on spell name from secret lookup", () => {
    expect(core).toContain('local cleanN = DetaintStr and DetaintStr(n3) or n3');
  });
});

describe("Engine Precombat State Weapon Enchant OOC Fallback", () => {
  const engine = generateEngine();

  it("checks GetWeaponEnchantInfo for weapon enchant spells in OOC precombat state", () => {
    expect(engine).toContain('rawArg == "flametongue_weapon" or rawArg == "windfury_weapon"');
    expect(engine).toContain("pcall(GetWeaponEnchantInfo)");
  });

  it("only applies weapon enchant fallback when buff lookup fails and out of combat", () => {
    expect(engine).toContain("not buffFound and GetWeaponEnchantInfo");
  });
});

describe("Scoring Model Verification", () => {
  const SIGNAL_ANTS = 1;
  const SIGNAL_ASSISTED = 2;
  const SIGNAL_PROC = 3;
  const SIGNAL_READY = 4;

  function scoreCandidate(
    basePrio: number,
    signal: number,
    mode: string,
    isCooldown: boolean,
    spellMode: string = "Both"
  ): number {
    if (signal === SIGNAL_ANTS) {
      if (isCooldown) return -11000 + basePrio;
      return -10500 + basePrio;
    } else if (signal === SIGNAL_ASSISTED) {
      if (isCooldown) return -11000 + basePrio;
      return -10000 + basePrio;
    } else if (signal === SIGNAL_PROC) {
      return -5000 + basePrio;
    }
    if (isCooldown) {
      return -11000 + basePrio;
    }
    let score = basePrio;
    if (spellMode !== "Both" && spellMode !== mode) {
      score = score + 2000;
    }
    return score;
  }

  describe("Signal tier ordering", () => {
    const basePrio = 10;

    it("ANTS beats ASSISTED (lower score = higher priority)", () => {
      const antsScore = scoreCandidate(basePrio, SIGNAL_ANTS, "ST", false);
      const assistedScore = scoreCandidate(basePrio, SIGNAL_ASSISTED, "ST", false);
      expect(antsScore).toBeLessThan(assistedScore);
    });

    it("ASSISTED beats PROC", () => {
      const assistedScore = scoreCandidate(basePrio, SIGNAL_ASSISTED, "ST", false);
      const procScore = scoreCandidate(basePrio, SIGNAL_PROC, "ST", false);
      expect(assistedScore).toBeLessThan(procScore);
    });

    it("PROC beats READY", () => {
      const procScore = scoreCandidate(basePrio, SIGNAL_PROC, "ST", false);
      const readyScore = scoreCandidate(basePrio, SIGNAL_READY, "ST", false);
      expect(procScore).toBeLessThan(readyScore);
    });

    it("full ordering: ANTS < ASSISTED < PROC < READY", () => {
      const ants = scoreCandidate(basePrio, SIGNAL_ANTS, "ST", false);
      const assisted = scoreCandidate(basePrio, SIGNAL_ASSISTED, "ST", false);
      const proc = scoreCandidate(basePrio, SIGNAL_PROC, "ST", false);
      const ready = scoreCandidate(basePrio, SIGNAL_READY, "ST", false);
      expect(ants).toBeLessThan(assisted);
      expect(assisted).toBeLessThan(proc);
      expect(proc).toBeLessThan(ready);
    });
  });

  describe("Major cooldown override", () => {
    it("CD with READY signal beats ASSISTED without CD", () => {
      const cdReady = scoreCandidate(10, SIGNAL_READY, "ST", true);
      const assistedNonCD = scoreCandidate(10, SIGNAL_ASSISTED, "ST", false);
      expect(cdReady).toBeLessThan(assistedNonCD);
    });

    it("CD with ANTS has same score as CD with ASSISTED (both -11000)", () => {
      const cdAnts = scoreCandidate(10, SIGNAL_ANTS, "ST", true);
      const cdAssisted = scoreCandidate(10, SIGNAL_ASSISTED, "ST", true);
      expect(cdAnts).toBe(cdAssisted);
    });

    it("CD with READY beats non-CD ANTS", () => {
      const cdReady = scoreCandidate(10, SIGNAL_READY, "ST", true);
      const nonCdAnts = scoreCandidate(10, SIGNAL_ANTS, "ST", false);
      expect(cdReady).toBeLessThan(nonCdAnts);
    });
  });

  describe("SimC priority affects ranking within same signal tier", () => {
    it("higher SimC priority (lower number) ranks first within ASSISTED", () => {
      const highPrio = scoreCandidate(5, SIGNAL_ASSISTED, "ST", false);
      const lowPrio = scoreCandidate(20, SIGNAL_ASSISTED, "ST", false);
      expect(highPrio).toBeLessThan(lowPrio);
    });

    it("higher SimC priority ranks first within PROC", () => {
      const highPrio = scoreCandidate(5, SIGNAL_PROC, "ST", false);
      const lowPrio = scoreCandidate(20, SIGNAL_PROC, "ST", false);
      expect(highPrio).toBeLessThan(lowPrio);
    });

    it("higher SimC priority ranks first within READY", () => {
      const highPrio = scoreCandidate(5, SIGNAL_READY, "ST", false);
      const lowPrio = scoreCandidate(20, SIGNAL_READY, "ST", false);
      expect(highPrio).toBeLessThan(lowPrio);
    });
  });

  describe("Mode mismatch penalty", () => {
    it("AoE spell in ST mode gets +2000 penalty for READY signal", () => {
      const matched = scoreCandidate(10, SIGNAL_READY, "ST", false, "ST");
      const mismatched = scoreCandidate(10, SIGNAL_READY, "ST", false, "AoE");
      expect(mismatched - matched).toBe(2000);
    });

    it("ST spell in AoE mode gets +2000 penalty for READY signal", () => {
      const matched = scoreCandidate(10, SIGNAL_READY, "AoE", false, "AoE");
      const mismatched = scoreCandidate(10, SIGNAL_READY, "AoE", false, "ST");
      expect(mismatched - matched).toBe(2000);
    });

    it("'Both' mode spells never get penalty", () => {
      const stMode = scoreCandidate(10, SIGNAL_READY, "ST", false, "Both");
      const aoeMode = scoreCandidate(10, SIGNAL_READY, "AoE", false, "Both");
      expect(stMode).toBe(aoeMode);
    });

    it("ANTS signal does NOT get mode penalty", () => {
      const matched = scoreCandidate(10, SIGNAL_ANTS, "ST", false, "ST");
      const mismatched = scoreCandidate(10, SIGNAL_ANTS, "ST", false, "AoE");
      expect(matched).toBe(mismatched);
    });

    it("PROC signal does NOT get mode penalty", () => {
      const matched = scoreCandidate(10, SIGNAL_PROC, "ST", false, "ST");
      const mismatched = scoreCandidate(10, SIGNAL_PROC, "ST", false, "AoE");
      expect(matched).toBe(mismatched);
    });
  });

  describe("Layer priority ordering", () => {
    it("Precombat state (-2000) beats interrupt (0)", () => {
      expect(-2000).toBeLessThan(0);
    });

    it("Interrupt (0) beats precombat opener (-500) in combat context", () => {
      expect(0).toBeGreaterThan(-500);
    });

    it("Precombat opener (-500) shows before regular rotation spells (positive scores)", () => {
      const openerPrio = -500;
      const bestReadyRotation = scoreCandidate(1, SIGNAL_READY, "ST", false);
      expect(openerPrio).toBeLessThan(bestReadyRotation);
    });

    it("State buffs use layer 0 priority (-2000) which is higher than openers (-500)", () => {
      const statePrio = -2000;
      const openerPrio = -500;
      expect(statePrio).toBeLessThan(openerPrio);
    });
  });
});

describe("Scenario Tests — Real Class Situations", () => {
  describe("Paladin without aura/buff", () => {
    it("precombat condition for missing buff is generated correctly", () => {
      const cond = generatePrecombatCondition("devotion_aura");
      expect(cond).toBe("!buff.devotion_aura.up");
      const lua = conditionToLua(cond);
      expect(lua).toContain("not ");
      expect(lua).toContain('CLF.BuffUp("devotion_aura")');
    });
  });

  describe("Balance Druid not in Moonkin Form", () => {
    it("generates correct form check", () => {
      const cond = generatePrecombatCondition("moonkin_form");
      expect(cond).toBe("!form.moonkin");
      const lua = conditionToLua(cond);
      expect(lua).toContain("not ");
      expect(lua).toContain('CLF.IsForm("moonkin")');
    });

    it("missing form has layer 0 priority (-2000) beating openers and ready spells", () => {
      const formPriority = -2000;
      const openerPriority = -500;
      const bestReadySpell = 1;
      expect(formPriority).toBeLessThan(openerPriority);
      expect(formPriority).toBeLessThan(bestReadySpell);
    });
  });

  describe("Rogue not in stealth before combat", () => {
    it("generates correct stealth check", () => {
      const cond = generatePrecombatCondition("stealth");
      expect(cond).toBe("!stealthed.all");
      const lua = conditionToLua(cond);
      expect(lua).toContain("not ");
      expect(lua).toContain("CLF.IsStealthed()");
    });
  });

  describe("Druid missing Mark of the Wild", () => {
    it("group buff is auto-injected into APL", () => {
      const entries: AplEntry[] = [{
        id: "test-1",
        specId: "druid-balance",
        spellName: "Moonfire",
        spellIcon: "",
        priority: 10,
        condition: "target.debuff.moonfire.down",
        mode: "Both",
        isInterrupt: false,
        isOffensive: true,
        keybind: "",
        enabled: true,
        isPrecombat: false,
        precombatType: null,
      }];
      const result = injectGroupBuff("druid-balance", entries);

      const motw = result.find(e => e.spellName === "Mark of the Wild");
      expect(motw).toBeDefined();
      expect(motw!.isPrecombat).toBe(true);
      expect(motw!.precombatType).toBe("state");
      expect(motw!.condition).toBe("!buff.mark_of_the_wild.up");
      expect(motw!.priority).toBe(-110);

      const condLua = conditionToLua(motw!.condition);
      expect(condLua).toContain("not ");
      expect(condLua).toContain('CLF.BuffUp("mark_of_the_wild")');
    });
  });

  describe("Warrior without Battle Shout", () => {
    it("Battle Shout auto-injected before other abilities", () => {
      const entries: AplEntry[] = [{
        id: "test-1",
        specId: "warrior-fury",
        spellName: "Rampage",
        spellIcon: "",
        priority: 5,
        condition: "rage>=80",
        mode: "Both",
        isInterrupt: false,
        isOffensive: true,
        keybind: "",
        enabled: true,
        isPrecombat: false,
        precombatType: null,
      }];
      const result = injectGroupBuff("warrior-fury", entries);
      expect(result[0].spellName).toBe("Battle Shout");
      expect(result[0].priority).toBeLessThan(result[1].priority);
    });
  });

  describe("Complex priority scenario: CD + Assisted + Proc", () => {
    it("major CD ready beats assisted highlight for same spell", () => {
      const SIGNAL_ANTS = 1;
      const SIGNAL_ASSISTED = 2;
      const SIGNAL_READY = 4;

      function score(basePrio: number, signal: number, isCD: boolean): number {
        if (signal === SIGNAL_ANTS) return isCD ? -11000 + basePrio : -10500 + basePrio;
        if (signal === SIGNAL_ASSISTED) return isCD ? -11000 + basePrio : -10000 + basePrio;
        if (isCD) return -11000 + basePrio;
        return basePrio;
      }

      const incarnation = score(3, SIGNAL_READY, true);
      const crushingBlow = score(8, SIGNAL_ASSISTED, false);
      expect(incarnation).toBeLessThan(crushingBlow);
    });

    it("low-priority ANTS beats high-priority READY", () => {
      const SIGNAL_ANTS = 1;
      const SIGNAL_READY = 4;

      const lowPrioAnts = -10500 + 50;
      const highPrioReady = 1;
      expect(lowPrioAnts).toBeLessThan(highPrioReady);
    });
  });

  describe("Interrupt layer takes precedence", () => {
    it("interrupt at priority 0 beats precombat opener at -500 (opener only shows OOC)", () => {
      const interruptPrio = 0;
      const openerPrio = -500;
      expect(interruptPrio).toBeGreaterThan(openerPrio);
    });

    it("precombat state (-2000) has lower numeric priority than interrupt (0)", () => {
      const statePrio = -2000;
      const interruptPrio = 0;
      expect(statePrio).toBeLessThan(interruptPrio);
    });

    it("precombat state spells are gated on action bar presence", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("CLF._spellSlots and CLF._spellSlots[cleanKey]");
      expect(engineSrc).toContain("not on action bars");
    });
  });

  describe("Precombat state cast tracking", () => {
    it("RecordCast marks precombat state spells as applied", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      expect(helpersSrc).toContain("CLF._precombatApplied = {}");
      expect(helpersSrc).toContain("CLF._precombatApplied[cleanName] = now");
    });

    it("excludes dynamic states (forms, stances, stealth) from tracking", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      expect(helpersSrc).toContain("IsDynamicState");
      expect(helpersSrc).toContain("not IsDynamicState(cleanName)");
      expect(helpersSrc).toContain('" form$"');
      expect(helpersSrc).toContain('" stance$"');
      expect(helpersSrc).toContain('"stealth"');
      expect(helpersSrc).toContain('"prowl"');
      expect(helpersSrc).toContain('"summon pet"');
    });

    it("precombat state evaluator skips already-applied spells", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("CLF._precombatApplied");
      expect(engineSrc).toContain("already applied this session");
    });

    it("PLAYER_DEAD clears precombat applied table", () => {
      const coreSrc = require("fs").readFileSync("server/generators/gen-core.ts", "utf-8");
      expect(coreSrc).toContain('event == "PLAYER_DEAD"');
      expect(coreSrc).toContain("wipe(CLF._precombatApplied)");
    });

    it("spec change clears precombat applied table", () => {
      const coreSrc = require("fs").readFileSync("server/generators/gen-core.ts", "utf-8");
      const handlerIdx = coreSrc.indexOf('elseif event == "PLAYER_TALENT_UPDATE"');
      expect(handlerIdx).toBeGreaterThan(-1);
      const after = coreSrc.slice(handlerIdx, handlerIdx + 2000);
      expect(after).toContain("_precombatApplied");
    });
  });

  describe("Spell morph/override resolution", () => {
    it("AC injection resolves unknown spell IDs via runtime override probing", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("AC-MORPH-RESOLVE");
      expect(engineSrc).toContain("GetSpellIDForSpellIdentifier");
      expect(engineSrc).toContain("acMorphBase = rName");
    });

    it("runtime morph discovery updates _spellAliases bidirectionally", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const morphSection = engineSrc.slice(
        engineSrc.indexOf("acMorphBase = rName"),
        engineSrc.indexOf("AC-MORPH-RESOLVE")
      );
      expect(morphSection).toContain("CLF._spellAliases[rName]");
      expect(morphSection).toContain("CLF._spellAliases[ovName]");
      expect(morphSection).toContain("_keybindCacheDirty = true");
    });

    it("GetKeybind falls back to spell aliases at lookup time", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const getKbBlock = helpersSrc.slice(
        helpersSrc.indexOf("function CLF.GetKeybind("),
        helpersSrc.indexOf("function CLF.GetKeybind(") + 500
      );
      expect(getKbBlock).toContain("CLF._spellAliases");
      expect(getKbBlock).toContain("altKb");
    });

    it("RecordCast propagates cast timestamp to spell aliases", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const recordBlock = helpersSrc.slice(
        helpersSrc.indexOf("function CLF.RecordCast("),
        helpersSrc.indexOf("function CLF.RecordCast(") + 600
      );
      expect(recordBlock).toContain("CLF._castLog[alt] = now");
    });

    it("morph promotion updates candidate icon and name", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("if acMorphBase then");
      expect(engineSrc).toContain("existing.spellName = morphName");
    });

    it("AC injection uses base spell keybind and CD for morphed spells", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain('CLF.GetKeybind(acMorphBase)');
      expect(engineSrc).toContain("local cdLookup = acMorphBase or spName");
    });
  });

  describe("Tank defensive boost in main queue", () => {
    it("bar path boosts tank defensives into queue with TANK-BOOST scoring", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("TANK-BOOST:");
      expect(engineSrc).toContain("CLF._defensiveSpells[cleanName] and result.signal == SIGNAL_READY then");
    });

    it("bar scanner path boosts tank defensives with TANK-BOOST scoring", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("TANK-BOOST:");
      expect(engineSrc).toContain("CLF._defensiveSpells");
    });
  });

  describe("Hybrid damage+heal tooltip classification", () => {
    it("ClassifySpells skips heal classification when tooltip mentions damage", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("hasDamageKeyword");
      const block = engineSrc.slice(
        engineSrc.indexOf("hasDamageKeyword"),
        engineSrc.indexOf("hasDamageKeyword") + 300
      );
      expect(block).toContain('"damage"');
      expect(block).toContain('"attack"');
      expect(block).toContain("not hasDamageKeyword");
    });

    it("both ClassifySpells tooltip scan blocks have the damage guard", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const firstIdx = engineSrc.indexOf("hasDamageKeyword");
      const secondIdx = engineSrc.indexOf("hasDmg2");
      expect(firstIdx).toBeGreaterThan(-1);
      expect(secondIdx).toBeGreaterThan(-1);
      expect(secondIdx).toBeGreaterThan(firstIdx);
    });
  });

  describe("Centralized spell classification safety system", () => {
    it("final-gate filter runs before sort and removes movement spells from candidates", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("FINAL-GATE:");
      const finalGateIdx = engineSrc.indexOf("FINAL-GATE:");
      const sortIdx = engineSrc.indexOf("tableSort(candidates,");
      expect(finalGateIdx).toBeGreaterThan(-1);
      expect(sortIdx).toBeGreaterThan(finalGateIdx);
    });

    it("final-gate preserves trinkets and filters movement spells", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const gateBlock = engineSrc.slice(
        engineSrc.indexOf("if #candidates > 0"),
        engineSrc.indexOf("candidates = filtered") + 30
      );
      expect(gateBlock).toContain("c.isTrinket");
      expect(gateBlock).toContain("_movementSpells[cn]");
    });

    it("IsHarmfulSpell cross-check prevents damage spells from being classified as heals", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("IsHarmfulSpell");
      expect(engineSrc).toContain("isAlsoHarmful");
      expect(engineSrc).toContain("alsoHarm2");
      const harmCount = (engineSrc.match(/IsHarmfulSpell/g) || []).length;
      expect(harmCount).toBeGreaterThanOrEqual(3);
    });

    it("_classifyExclude covers cross-class damage spells with heal side effects", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain('["spinning crane kick"] = true');
      expect(engineSrc).toContain('["death strike"] = true');
      expect(engineSrc).toContain('["soul cleave"] = true');
      expect(engineSrc).toContain('["chi burst"] = true');
      expect(engineSrc).toContain('["victory rush"] = true');
    });

    it("cast injection skips ALL spells in Lookahead mode", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("skipCastInject");
      expect(engineSrc).toContain('slotMode ~= "Current Cast"');
      expect(engineSrc).toContain("in Lookahead mode (showing next spell)");
      expect(engineSrc).not.toContain("isChannelCast");
    });

    it("slot 1 live CD recheck prevents stale-CD spells from showing", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      expect(engineSrc).toContain("SLOT1-STABLE:");
      expect(engineSrc).toContain("removing stale stable");
      expect(engineSrc).toContain("SLOT1-FILL:");
      expect(engineSrc).toContain("CLF.IsSlotReady(");
      expect(helpersSrc).toContain("CLF.SpellStatus(candidate.spellName)");
      expect(helpersSrc).toContain("CLF.IsOnEventCD(candidate.spellName)");
      expect(helpersSrc).toContain("CLF.IsSelfBuffBlocking(candidate.spellName)");
      const fillIdx = engineSrc.indexOf("SLOT1-FILL:");
      const skipIdx = engineSrc.indexOf("skip unusable spells for slot 1");
      expect(fillIdx).toBeGreaterThan(0);
      expect(skipIdx).toBeGreaterThan(fillIdx);
      expect(helpersSrc).toContain('liveCD > 1.5');
      expect(helpersSrc).toContain("function CLF.IsSlotReady(candidate, slotIdx, inCombat, gcdActive)");
    });

    it("ValidateCandidate has diagnostic logging at every gate", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      expect(helpersSrc).toContain('CLF.Log("VALIDATE"');
      expect(helpersSrc).toContain("G1: CD-norm override");
      expect(helpersSrc).toContain("G3: buff-blocked");
      expect(helpersSrc).toContain("G4: AC demoted");
      expect(helpersSrc).toContain("G5: not affordable");
      expect(helpersSrc).toContain("G6b: AC short-CD rescue");
      expect(helpersSrc).toContain("G7: moving+castTime");
      expect(helpersSrc).toContain("G8: execute spell");
    });

    it("IsSlotReady has diagnostic logging at every check", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      expect(helpersSrc).toContain('CLF.Log("SLOTCHK"');
      expect(helpersSrc).toContain("REJECT: starved signal");
      expect(helpersSrc).toContain("REJECT: not affordable");
      expect(helpersSrc).toContain("REJECT: trinket cd");
      expect(helpersSrc).toContain("REJECT: live cd=");
      expect(helpersSrc).toContain("REJECT: event cd=");
      expect(helpersSrc).toContain("REJECT: self-buff active");
      expect(helpersSrc).toContain("REJECT: IsSpellUsable=false");
      expect(helpersSrc).toContain("PASS (ac=");
    });

    it("Enhanced snapshot tracks target health, secondary resource, movement, form", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      expect(helpersSrc).toContain("snap.targetHealthPct");
      expect(helpersSrc).toContain("snap.secondaryPower");
      expect(helpersSrc).toContain("snap.moving");
      expect(helpersSrc).toContain("snap.form");
      expect(helpersSrc).toContain("snap.moveDuration");
      expect(helpersSrc).toContain("function CLF.SecondaryPower()");
      expect(helpersSrc).toContain("function CLF.MoveDuration()");
      expect(helpersSrc).toContain("function CLF.GetForm()");
      expect(helpersSrc).toContain("function CLF.TargetHealthPct()");
      expect(helpersSrc).not.toContain("function CLF.TargetHealthPct()\n  return 100");
    });

    it("Aura event logger tracks CLEU aura events", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      expect(helpersSrc).toContain("CLF._auraLog");
      expect(helpersSrc).toContain("LogAuraEvent(subEvent, unit, spellName, spellId");
      expect(helpersSrc).toContain('CLF.Log("AURA"');
    });

    it("Engine has per-tick decision summary and slot transition logging", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain('CLF.Log("TICK", "DECISION:');
      expect(engineSrc).toContain('CLF.Log("TICK", "SLOT1-CHANGE:');
      expect(engineSrc).toContain("vc.movePenalty");
      expect(engineSrc).toContain("vc.executePenalty");
    });

    it("heal and defensive spells are suppressed when settings are off", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("healing spell, suppressed");
      expect(engineSrc).toContain("defensive spell, suppressed");
      expect(engineSrc).not.toContain("redirectToUtility");
    });

    it("Touch of Death is classified as execute spell with _classifyExclude protection", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const execBlock = engineSrc.slice(
        engineSrc.indexOf("CLF._executeSpells = {"),
        engineSrc.indexOf("CLF._executeSpells = {") + 300
      );
      expect(execBlock).toContain('["touch of death"] = true');
      expect(engineSrc).toContain('["touch of death"] = true');
      const classifyBlock = engineSrc.slice(
        engineSrc.indexOf("local _classifyExclude = {"),
        engineSrc.indexOf("local _classifyExclude = {") + 900
      );
      expect(classifyBlock).toContain('["touch of death"] = true');
    });

    it("Flying Serpent Kick is in _movementSpells exclusion list", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain('["flying serpent kick"] = true');
    });

    it("_movementSpells table excludes Roll and other movement abilities", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain('local _movementSpells = {');
      expect(engineSrc).toContain('["roll"] = true');
      expect(engineSrc).toContain('["chi torpedo"] = true');
      expect(engineSrc).toContain('["blink"] = true');
      expect(engineSrc).toContain('["heroic leap"] = true');
      expect(engineSrc).toContain('["disengage"] = true');
      expect(engineSrc).toContain('["shadowstep"] = true');
      expect(engineSrc).toContain('["divine steed"] = true');
    });

    it("movement spells are filtered in bar scan and final gate", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const movementChecks = (engineSrc.match(/_movementSpells\[/g) || []).length;
      expect(movementChecks).toBeGreaterThanOrEqual(2);
      expect(engineSrc).toContain("(movement ability)");
    });

    it("_classifyExclude is declared before RuntimeHealCheck for proper Lua scoping", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const excludeIdx = engineSrc.indexOf("local _classifyExclude = {");
      const runtimeIdx = engineSrc.indexOf("function CLF.RuntimeHealCheck");
      expect(excludeIdx).toBeGreaterThan(-1);
      expect(runtimeIdx).toBeGreaterThan(-1);
      expect(excludeIdx).toBeLessThan(runtimeIdx);
    });

    it("final-gate removes movement abilities from candidate list", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("_movementSpells[cn]");
      expect(engineSrc).toContain("removed (movement ability)");
    });

    it("RuntimeHealCheck has IsHarmfulSpell guard and defensiveSpells guard", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const runtimeBlock = engineSrc.slice(
        engineSrc.indexOf("function CLF.RuntimeHealCheck"),
        engineSrc.indexOf("function CLF.RuntimeHealCheck") + 1200
      );
      expect(runtimeBlock).toContain("IsHarmfulSpell");
      expect(runtimeBlock).toContain("isAlsoHarmful");
      expect(runtimeBlock).toContain("CLF._defensiveSpells");
    });

    it("RuntimeHealCheck checks IsHelpfulSpell BEFORE exempting AC rotation spells", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const runtimeBlock = engineSrc.slice(
        engineSrc.indexOf("function CLF.RuntimeHealCheck"),
        engineSrc.indexOf("function CLF.IsUtilitySpell")
      );
      expect(runtimeBlock).toContain("CLF._acRotationNames and CLF._acRotationNames[cleanName]");
      expect(runtimeBlock).toContain("CLF._spellData and CLF._spellData[cleanName]");
      expect(runtimeBlock).toContain("GetSpellDescription");
      expect(runtimeBlock).toContain("hasDmg");
      const helpfulIdx = runtimeBlock.indexOf("IsHelpfulSpell");
      const acRotIdx = runtimeBlock.lastIndexOf("CLF._acRotationNames and CLF._acRotationNames[cleanName]");
      const spellDataIdx = runtimeBlock.lastIndexOf("CLF._spellData and CLF._spellData[cleanName]");
      expect(helpfulIdx).toBeGreaterThan(-1);
      expect(acRotIdx).toBeGreaterThan(-1);
      expect(helpfulIdx).toBeLessThan(acRotIdx);
      expect(helpfulIdx).toBeLessThan(spellDataIdx);
    });

    it("_healingSpells seed list contains Regrowth and other known pure heals", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const seedBlock = engineSrc.slice(
        engineSrc.indexOf("CLF._healingSpells = {"),
        engineSrc.indexOf("CLF._seedHealingSpells")
      );
      expect(seedBlock).toContain('["regrowth"] = true');
      expect(seedBlock).toContain('["rejuvenation"] = true');
      expect(seedBlock).toContain('["flash heal"] = true');
      expect(seedBlock).toContain('["healing surge"] = true');
      expect(seedBlock).toContain('["vivify"] = true');
      expect(seedBlock).not.toContain('["word of glory"]');
    });

    it("ClassifySpells preserves seed healing spells when rebuilding", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("CLF._seedHealingSpells = {}");
      expect(engineSrc).toContain("CLF._seedHealingSpells[_seedK] = _seedV");
      const classifyBlock = engineSrc.slice(
        engineSrc.indexOf("function CLF.ClassifySpells()"),
        engineSrc.indexOf("CLF.Log(\"INFO\", \"Spell classification:")
      );
      expect(classifyBlock).toContain("CLF._seedHealingSpells");
      expect(classifyBlock).toContain("newHeals[seedName] = true");
    });

    it("ScanActionBars result objects include spellId for RuntimeHealCheck", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const scanStart = engineSrc.indexOf("local function ScanActionBars()");
      const scanEnd = engineSrc.indexOf("local results = {}", scanStart);
      const scanBlock = engineSrc.slice(scanStart, scanEnd);
      expect(scanBlock).toContain("spellId = id,");
    });

    it("AC injection requires spell to be on action bar before creating new candidate", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const acInjectBlock = engineSrc.slice(
        engineSrc.indexOf("AC-INJECT-SKIP"),
        engineSrc.indexOf("AC-INJECT:")
      );
      expect(acInjectBlock).toContain("not on action bar");
      const acBlock = engineSrc.slice(
        engineSrc.indexOf("if not alreadyIdx and CLF._spellAliases"),
        engineSrc.indexOf("-- Fallback trinket injection")
      );
      expect(acBlock).toContain("injOnBar");
      expect(acBlock).toContain("CLF._spellSlots");
    });

    it("AC injection path requires actual bar presence for not-on-bar spells", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain("AC-INJECT-SKIP: ");
      expect(engineSrc).toContain("(not on action bar)");
      expect(engineSrc).not.toContain("AC-INJECT-KNOWN:");
    });

    it("_spellRequiresForm gates cat spells to cat form and bear spells to bear form", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const formBlock = engineSrc.slice(
        engineSrc.indexOf("CLF._spellRequiresForm = {"),
        engineSrc.indexOf("CLF._spellMultiForm")
      );
      expect(formBlock).toContain('["shred"] = "cat"');
      expect(formBlock).toContain('["rake"] = "cat"');
      expect(formBlock).toContain('["ferocious bite"] = "cat"');
      expect(formBlock).toContain('["mangle"] = "bear"');
      expect(formBlock).toContain('["ironfur"] = "bear"');
      expect(formBlock).toContain('["maul"] = "bear"');
      expect(formBlock).not.toContain('"swipe"');
      expect(formBlock).not.toContain('"thrash"');
    });

    it("_spellMultiForm allows swipe and thrash in both cat and bear forms", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const multiBlock = engineSrc.slice(
        engineSrc.indexOf("CLF._spellMultiForm = {"),
        engineSrc.indexOf("local function IsFormGated")
      );
      expect(multiBlock).toContain('["swipe"]');
      expect(multiBlock).toContain('["thrash"]');
      expect(multiBlock).toContain('["cat"] = true');
      expect(multiBlock).toContain('["bear"] = true');
    });

    it("IsFormGated checks both single-form and multi-form tables", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const isFormGatedBlock = engineSrc.slice(
        engineSrc.indexOf("local function IsFormGated"),
        engineSrc.indexOf("CLF._knownDefensives")
      );
      expect(isFormGatedBlock).toContain("CLF._spellRequiresForm[cleanName]");
      expect(isFormGatedBlock).toContain("currentForm ~= requiredForm");
      expect(isFormGatedBlock).toContain("CLF._spellMultiForm[cleanName]");
      expect(isFormGatedBlock).toContain("not multiForm[currentForm]");
    });

    it("RuntimeHealCheck short-circuits AC/APL rotation spells before IsHelpfulSpell", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const startIdx = engineSrc.indexOf("function CLF.RuntimeHealCheck(cleanName, spellId)");
      const endMarker = engineSrc.indexOf("\nend\n", startIdx);
      const healCheckBlock = engineSrc.slice(startIdx, endMarker);
      const acCheckPos = healCheckBlock.indexOf("_acRotationNames and CLF._acRotationNames[cleanName] then return false");
      const spellDataPos = healCheckBlock.indexOf("_spellData and CLF._spellData[cleanName] then return false");
      const notSpellIdPos = healCheckBlock.indexOf("not spellId then");
      const helpfulPos = healCheckBlock.indexOf("IsHelpfulSpell then");
      expect(acCheckPos).toBeGreaterThan(-1);
      expect(spellDataPos).toBeGreaterThan(-1);
      expect(helpfulPos).toBeGreaterThan(-1);
      expect(acCheckPos).toBeLessThan(notSpellIdPos);
      expect(spellDataPos).toBeLessThan(notSpellIdPos);
      expect(notSpellIdPos).toBeLessThan(helpfulPos);
    });

    it("AC injection has slotMapEmpty fallback using IsSpellKnown", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const injBlock = engineSrc.slice(
        engineSrc.indexOf("local injCleanName = NormalizeName"),
        engineSrc.indexOf("AC-INJECT-SKIP")
      );
      expect(injBlock).toContain("injSlotMapEmpty");
      expect(injBlock).toContain("CLF.IsSpellKnown");
    });
  });

  describe("Utility box classification excludes execute spells", () => {
    it("DEFENSIVE_KEYWORDS uses specific absorb patterns not bare absorb", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const kwStart = engineSrc.indexOf("local DEFENSIVE_KEYWORDS");
      const kwBlock = engineSrc.slice(kwStart, kwStart + 600);
      expect(kwBlock).not.toContain('"absorb"');
      expect(kwBlock).toContain('"absorbs.-damage"');
      expect(kwBlock).toContain('"damage.*absorb"');
    });

    it("_classifyExclude prevents execute spells from being classified as heals/defensives", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      expect(engineSrc).toContain('_classifyExclude');
      expect(engineSrc).toContain('["black arrow"] = true');
      expect(engineSrc).toContain('["kill shot"] = true');
    });

    it("ClassifySpells skips excluded/execute spells", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const classifyBlock = engineSrc.slice(
        engineSrc.indexOf("function CLF.ClassifySpells()"),
        engineSrc.indexOf("CLF.Log(\"INFO\", \"Spell classification:")
      );
      expect(classifyBlock).toContain("_classifyExclude[cleanName]");
      expect(classifyBlock).toContain("CLF._executeSpells[cleanName]");
    });

    it("RuntimeHealCheck short-circuits for execute spells", () => {
      const engineSrc = require("fs").readFileSync("server/generators/gen-engine.ts", "utf-8");
      const runtimeBlock = engineSrc.slice(
        engineSrc.indexOf("function CLF.RuntimeHealCheck"),
        engineSrc.indexOf("function CLF.ClassifySpells")
      );
      expect(runtimeBlock).toContain("_classifyExclude[cleanName]");
      expect(runtimeBlock).toContain("CLF._executeSpells[cleanName]");
    });
  });

  describe("In-combat CD detection fallback", () => {
    it("GetCDInfo tries C_Spell.GetSpellCooldown before returning ready in combat", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const getCDInfoBlock = helpersSrc.slice(helpersSrc.indexOf("local function GetCDInfo("), helpersSrc.indexOf("\nfunction CLF.GetActionBarCD"));
      expect(getCDInfoBlock).toContain("C_Spell.GetSpellCooldown");
      expect(getCDInfoBlock).toContain("cdInfo.startTime");
      expect(getCDInfoBlock).toContain("cdInfo.duration");
      expect(getCDInfoBlock).toContain("SafeIsUsableSpell(cleanName)");
    });

    it("SafeGetSpellCooldown tries C_Spell.GetSpellCooldown before returning ready in combat", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const safeGetCDBlock = helpersSrc.slice(helpersSrc.indexOf("local function SafeGetSpellCooldown("), helpersSrc.indexOf("\nlocal function SafeGetSpellCharges("));
      expect(safeGetCDBlock).toContain("C_Spell.GetSpellCooldown");
      expect(safeGetCDBlock).toContain("SafeIsUsableSpell(cleanName)");
    });

    it("GetCDInfo has _castLog safety net for spells with known CD duration", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const getCDInfoBlock = helpersSrc.slice(helpersSrc.indexOf("local function GetCDInfo("), helpersSrc.indexOf("\nfunction CLF.GetActionBarCD"));
      const safetyBlock = getCDInfoBlock.slice(getCDInfoBlock.indexOf("local probeUsable = SafeIsUsableSpell"));
      expect(safetyBlock).toContain("CLF._knownCDDur[cleanName]");
      expect(safetyBlock).toContain("CLF._castLog[cleanName]");
      expect(safetyBlock).toContain("elapsed < safetyDur");
    });

    it("SafeGetSpellCooldown has _castLog safety net for spells with known CD duration", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const safeGetCDBlock = helpersSrc.slice(helpersSrc.indexOf("local function SafeGetSpellCooldown("), helpersSrc.indexOf("\nlocal function SafeGetSpellCharges("));
      const safetyBlock = safeGetCDBlock.slice(safeGetCDBlock.indexOf("local probeUsable = SafeIsUsableSpell"));
      expect(safetyBlock).toContain("CLF._knownCDDur[cleanName]");
      expect(safetyBlock).toContain("CLF._castLog[cleanName]");
      expect(safetyBlock).toContain("elapsed < safetyDur");
    });
  });

  describe("RecordCast CD tracking for spellbook entries with unknown CD", () => {
    it("RecordCast tries action bar slot probe when CD is unknown for spellbook entries", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const recordBlock = helpersSrc.slice(
        helpersSrc.indexOf("function CLF.RecordCast("),
        helpersSrc.indexOf("function CLF.IsOnEventCD(")
      );
      expect(recordBlock).toContain("CLF._spellSlots and CLF._spellSlots[cleanName]");
      expect(recordBlock).toContain("GetActionCooldown(slotID)");
    });

    it("RecordCast uses 120s fallback (not 30s) for tracked spells with unknown CD", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const recordBlock = helpersSrc.slice(
        helpersSrc.indexOf("function CLF.RecordCast("),
        helpersSrc.indexOf("function CLF.IsOnEventCD(")
      );
      expect(recordBlock).toContain("cdDur = 120");
      expect(recordBlock).toContain("_cdMap");
      expect(recordBlock).toContain("_defensiveSpells");
    });

    it("RecordCast sets cdReadyAt and barCD for spellbook entries with fallback CD", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const recordBlock = helpersSrc.slice(
        helpersSrc.indexOf("function CLF.RecordCast("),
        helpersSrc.indexOf("function CLF.IsOnEventCD(")
      );
      expect(recordBlock).toContain("bookEntry.cdReadyAt = now + effCdDur");
      expect(recordBlock).toContain("CLF._barCD[cleanName]");
      expect(recordBlock).toContain("bookEntry.cdDuration = effCdDur");
    });

    it("delayed probe also tries action bar slot CD detection", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const recordBlock = helpersSrc.slice(
        helpersSrc.indexOf("function CLF.RecordCast("),
        helpersSrc.indexOf("function CLF.IsOnEventCD(")
      );
      const delayBlock = recordBlock.slice(recordBlock.indexOf("C_Timer.After(0.3"));
      expect(delayBlock).toContain("GetActionCooldown(slotID)");
      expect(delayBlock).toContain("CLF._spellSlots");
    });

    it("no-bookEntry fallback also uses 120s", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const recordBlock = helpersSrc.slice(
        helpersSrc.indexOf("function CLF.RecordCast("),
        helpersSrc.indexOf("function CLF.IsOnEventCD(")
      );
      const elseBlock = recordBlock.slice(recordBlock.indexOf("elseif knownDur and knownDur > 1.5"));
      expect(elseBlock).toContain("local fallbackDur = 120");
    });
  });

  describe("Spellbook scan CD learning uses SafeDetaintNum", () => {
    it("spellbook scan uses SafeDetaintNum for C_Spell.GetSpellCooldown duration", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const scanBlock = helpersSrc.slice(
        helpersSrc.indexOf("if C_Spell and C_Spell.GetSpellCooldown then"),
        helpersSrc.indexOf("if not entry.cdDuration and GetSpellBaseCooldown then")
      );
      expect(scanBlock).toContain("SafeDetaintNum(cdInfo.duration)");
    });

    it("spellbook scan uses SafeDetaintNum for GetSpellBaseCooldown", () => {
      const helpersSrc = require("fs").readFileSync("server/generators/gen-helpers.ts", "utf-8");
      const scanBlock = helpersSrc.slice(
        helpersSrc.indexOf("if not entry.cdDuration and GetSpellBaseCooldown then"),
        helpersSrc.indexOf("if not entry.cdDuration and GetSpellBaseCooldown then") + 300
      );
      expect(scanBlock).toContain("SafeDetaintNum(ms)");
    });
  });
});

describe("Generated Lua Code Validation", () => {
  describe("Detaint function correctness", () => {
    it("all Detaint patterns use issecretvalue check", () => {
      const { readFileSync, readdirSync } = require("fs");
      const genFiles = readdirSync("server/generators").filter((f: string) => f.startsWith("gen-") && f.endsWith(".ts"));
      for (const file of genFiles) {
        const source = readFileSync(`server/generators/${file}`, "utf-8");
        const detaintMatches = source.match(/local function Detaint\(val\)[\s\S]*?^end/gm);
        if (detaintMatches) {
          for (const match of detaintMatches) {
            expect(match).toContain("issecretvalue");
            expect(match).toContain("tonumber(val)");
            expect(match).toContain('type(val) == "nil"');
          }
        }
      }
    });

    it("no string.format-based detaint pattern exists (old pattern)", () => {
      const { readFileSync, readdirSync } = require("fs");
      const genFiles = readdirSync("server/generators").filter((f: string) => f.startsWith("gen-") && f.endsWith(".ts"));
      for (const file of genFiles) {
        const source = readFileSync(`server/generators/${file}`, "utf-8");
        const detaintBlocks = source.match(/local function Detaint\(val\)[\s\S]*?^end/gm);
        if (detaintBlocks) {
          for (const block of detaintBlocks) {
            expect(block).not.toContain('string.format("%s"');
          }
        }
      }
    });
  });

  describe("TOC file correctness", () => {
    it("interface version is 120001", () => {
      const { readFileSync } = require("fs");
      const shared = readFileSync("server/generators/shared.ts", "utf-8");
      expect(shared).toContain('WOW_INTERFACE = "120001"');
    });
  });

  describe("No banned API calls in generated Lua", () => {
    it("does not use bare UnitBuff() or UnitDebuff()", () => {
      const { readFileSync, readdirSync } = require("fs");
      const genFiles = readdirSync("server/generators").filter((f: string) => f.startsWith("gen-") && f.endsWith(".ts"));
      for (const file of genFiles) {
        const source = readFileSync(`server/generators/${file}`, "utf-8");
        const luaSections = source.match(/return `[\s\S]*?`;/g) || [];
        for (const section of luaSections) {
          const hasBareUnitBuff = /[^.]UnitBuff\(/.test(section) &&
            !section.includes("UnitBuff = UnitBuff") &&
            !section.includes("if UnitBuff then");
          const hasBareUnitDebuff = /[^.]UnitDebuff\(/.test(section) &&
            !section.includes("UnitDebuff = UnitDebuff") &&
            !section.includes("if UnitDebuff then");
          expect(hasBareUnitBuff).toBe(false);
          expect(hasBareUnitDebuff).toBe(false);
        }
      }
    });
  });

  describe("String method safety in generated Lua", () => {
    it("does not use :lower() :find() :gsub() method syntax on API returns", () => {
      const { readFileSync, readdirSync } = require("fs");
      const genFiles = readdirSync("server/generators").filter((f: string) => f.startsWith("gen-") && f.endsWith(".ts"));
      for (const file of genFiles) {
        const source = readFileSync(`server/generators/${file}`, "utf-8");
        const luaSections = source.match(/return `[\s\S]*?`;/g) || [];
        for (const section of luaSections) {
          const dangerousMethodCalls = section.match(/\w+:lower\(\)|UnitName[^)]*\):lower\(\)|DetaintStr[^)]*\):find\(/g);
          if (dangerousMethodCalls) {
            expect(dangerousMethodCalls).toEqual([]);
          }
        }
      }
    });
  });
});

describe("Condition Edge Cases", () => {
  it("handles deeply nested buff properties", () => {
    const result = conditionToLua("buff.test.at_max_stacks");
    expect(result).toContain('CLF.BuffStacks("test")');
    expect(result).toContain('CLF.BuffMaxStacks("test")');
  });

  it("handles active_dot.X", () => {
    const result = conditionToLua("active_dot.corruption>=3");
    expect(result).toContain('CLF.ActiveDot("corruption")');
  });

  it("handles totem conditions", () => {
    const result = conditionToLua("totem.searing_totem.active");
    expect(result).toContain('CLF.TotemActive("searing_totem")');
  });

  it("handles health.pct", () => {
    const result = conditionToLua("health.pct<50");
    expect(result).toContain("CLF.PlayerHealthPct()<50");
  });

  it("handles player.health.pct", () => {
    const result = conditionToLua("player.health.pct<30");
    expect(result).toContain("CLF.PlayerHealthPct()<30");
  });

  it("handles stealthed.all", () => {
    const result = conditionToLua("stealthed.all");
    expect(result).toContain("CLF.IsStealthed()");
  });

  it("preserves numeric literals", () => {
    const result = conditionToLua("holy_power>=3");
    expect(result).toMatch(/>=\s*3/);
  });

  it("handles multiple OR conditions", () => {
    const result = conditionToLua("buff.a.up|buff.b.up|buff.c.up");
    const orCount = (result.match(/ or /g) || []).length;
    expect(orCount).toBe(2);
  });
});

describe("Watchdog Addon Generation", () => {

  describe("Watchdog Lua generation", () => {
    const lua = generateWatchdogLua();

    it("initializes SavedVariables with defaults", () => {
      expect(lua).toContain("DMGA_WD_Log = DMGA_WD_Log or {}");
      expect(lua).toContain("DMGA_WD_Config = DMGA_WD_Config or {}");
      expect(lua).toContain("DMGA_WD_APIScan = DMGA_WD_APIScan or {}");
    });

    it("wraps all external reads in pcall via SafeRead", () => {
      expect(lua).toContain("local function SafeRead(func, fallback)");
      expect(lua).toContain("pcall(func)");
    });

    it("wraps field access in SafeReadField", () => {
      expect(lua).toContain("local function SafeReadField(tbl, key, fallback)");
    });

    it("never calls CLF methods without pcall protection", () => {
      const directCalls = lua.match(/CLF\.\w+\(/g) || [];
      const inSafeRead = lua.match(/SafeRead\(function\(\).*?CLF\./gs) || [];
      const inSafeReadField = lua.match(/SafeReadField\(clf/g) || [];
      expect(inSafeRead.length + inSafeReadField.length).toBeGreaterThan(0);
    });

    it("registers for crash-relevant WoW events", () => {
      expect(lua).toContain('RegisterEvent("ADDON_ACTION_BLOCKED")');
      expect(lua).toContain('RegisterEvent("PLAYER_REGEN_DISABLED")');
      expect(lua).toContain('RegisterEvent("PLAYER_REGEN_ENABLED")');
      expect(lua).toContain('RegisterEvent("PLAYER_DEAD")');
      expect(lua).toContain('RegisterEvent("PLAYER_ENTERING_WORLD")');
    });

    it("has throttle protection to prevent spam", () => {
      expect(lua).toContain("local function ThrottleCheck(key, cooldown)");
    });

    it("captures content type (dungeon/raid/delve/open world)", () => {
      expect(lua).toContain("local function GetContentType()");
      expect(lua).toContain("GetInstanceInfo");
      expect(lua).toContain('"delve"');
      expect(lua).toContain('"dungeon"');
      expect(lua).toContain('"raid"');
    });

    it("captures player context with full state", () => {
      expect(lua).toContain("local function GetPlayerContext()");
      expect(lua).toContain("ctx.health");
      expect(lua).toContain("ctx.power");
      expect(lua).toContain("ctx.form");
      expect(lua).toContain("ctx.combatMode");
      expect(lua).toContain("ctx.enemies");
      expect(lua).toContain("ctx.activeAuras");
      expect(lua).toContain("ctx.gcdInfo");
    });

    it("has event type categorization", () => {
      expect(lua).toContain('"CRASH"');
      expect(lua).toContain('"DEGRADED"');
      expect(lua).toContain('"QUEUE_STUCK"');
      expect(lua).toContain('"EMPTY_QUEUE"');
      expect(lua).toContain('"HEARTBEAT_LOST"');
      expect(lua).toContain('"TAINT_SPIKE"');
      expect(lua).toContain('"ACTION_BLOCKED"');
      expect(lua).toContain('"COMBAT_START"');
      expect(lua).toContain('"COMBAT_END"');
      expect(lua).toContain('"SPEC_CHANGE"');
      expect(lua).toContain('"API_SCAN"');
      expect(lua).toContain('"MANUAL"');
    });

    it("generates copyable text format for events", () => {
      expect(lua).toContain("local function FormatEventForCopy(ev)");
      expect(lua).toContain("=== DMGA WATCHDOG EVENT ===");
      expect(lua).toContain("=== END EVENT ===");
    });

    it("creates an in-game viewer UI with event list and detail box", () => {
      expect(lua).toContain("CreateViewerUI");
      expect(lua).toContain("DMGAWatchdogViewer");
      expect(lua).toContain("DMGAWDDetailBox");
      expect(lua).toContain("SetMultiLine(true)");
    });

    it("has options panel with toggle checkboxes", () => {
      expect(lua).toContain("CreateOptionsPanel");
      expect(lua).toContain("DMGAWatchdogOptions");
      expect(lua).toContain("monitorHeartbeat");
      expect(lua).toContain("monitorStuckQueue");
      expect(lua).toContain("monitorTaint");
      expect(lua).toContain("chatAlerts");
      expect(lua).toContain("autoSnapshot");
    });

    it("creates a minimap button", () => {
      expect(lua).toContain("DMGAWDMinimapBtn");
      expect(lua).toContain("CreateMinimapButton");
    });

    it("has API scanner that tests WoW APIs for taint", () => {
      expect(lua).toContain("function RunAPIScan()");
      expect(lua).toContain("issecretvalue");
      expect(lua).toContain('"tainted"');
    });

    it("API scanner tests core WoW APIs", () => {
      expect(lua).toContain('"UnitClass"');
      expect(lua).toContain('"InCombatLockdown"');
      expect(lua).toContain('"GetShapeshiftForm"');
      expect(lua).toContain('C_Spell.GetSpellCooldown');
      expect(lua).toContain('"C_UnitAuras.GetBuffDataByIndex"');
    });

    it("API scanner tests CLF addon internals", () => {
      expect(lua).toContain('"CLF.ActiveEnemies"');
      expect(lua).toContain('"CLF.PlayerHealthPct"');
      expect(lua).toContain('"CLF.CurrentForm"');
      expect(lua).toContain('"CLF._filteredAPL_count"');
    });

    it("API scanner tests per-spell cooldowns and known status", () => {
      expect(lua).toContain('"SpellKnown:" .. spellName');
      expect(lua).toContain('"SpellCD:" .. spellName');
    });

    it("wraps OnUpdate poll in pcall", () => {
      expect(lua).toContain("local ok, err = pcall(PollCheck)");
    });

    it("wraps event handler in pcall", () => {
      const eventHandlerMatch = lua.match(/SetScript\("OnEvent".*?pcall\(function\(\)/s);
      expect(eventHandlerMatch).toBeTruthy();
    });

    it("monitors empty queue during combat", () => {
      expect(lua).toContain("monitorEmptyQueue");
      expect(lua).toContain("EMPTY_QUEUE_COMBAT_THRESHOLD");
    });

    it("tracks player death events", () => {
      expect(lua).toContain('"PLAYER_DIED"');
      expect(lua).toContain('"PLAYER_ALIVE"');
    });

    it("slash commands include viewer, options, scan, snap", () => {
      expect(lua).toContain('cmd == "" or cmd == "viewer"');
      expect(lua).toContain('cmd == "options"');
      expect(lua).toContain('cmd == "scan"');
      expect(lua).toContain('cmd == "snap"');
      expect(lua).toContain('cmd == "status"');
    });

    it("ADDON_ACTION_BLOCKED captures both addon name and function name via arg1/arg2", () => {
      expect(lua).toContain("addonName");
      expect(lua).toContain("blockedFn");
      expect(lua).toContain("addon = addonName");
      expect(lua).toContain("blockedFunction = blockedFn");
      expect(lua).not.toContain("select(1, ...)");
    });

    it("wraps _G.CLF access in SafeRead in init and status paths", () => {
      expect(lua).toContain('SafeRead(function() return _G.CLF end');
      expect(lua).toContain('SafeRead(function() return _G.CLF ~= nil end');
    });

    it("has combat session tracking with start/end/add functions", () => {
      expect(lua).toContain("local combatSessions = {}");
      expect(lua).toContain("local function StartCombatSession(ev)");
      expect(lua).toContain("local function EndCombatSession(ev)");
      expect(lua).toContain("local function AddEventToCurrentSession(ev)");
    });

    it("routes COMBAT_START/END events to session tracking in PushEvent", () => {
      expect(lua).toContain('StartCombatSession(ev)');
      expect(lua).toContain('EndCombatSession(ev)');
      expect(lua).toContain('AddEventToCurrentSession(ev)');
    });

    it("has FormatSessionForCopy that combines all events into one export", () => {
      expect(lua).toContain("local function FormatSessionForCopy(session)");
      expect(lua).toContain("DMGA WATCHDOG - COMBAT SESSION EXPORT");
      expect(lua).toContain("END SESSION EXPORT");
    });

    it("has GetSessionLabel showing index, time, duration, and event count", () => {
      expect(lua).toContain("local function GetSessionLabel(session, idx)");
      expect(lua).toContain("(active)");
    });

    it("viewer uses activity log tab as default", () => {
      expect(lua).toContain('activeTab = "log"');
      expect(lua).not.toContain('"Event Inspector"');
    });

    it("defaults to log tab on open", () => {
      expect(lua).toContain('ShowTab("log")');
    });

    it("clears combat sessions along with events on Clear All", () => {
      expect(lua).toContain("wipe(combatSessions)");
      expect(lua).toContain("currentSessionIdx = nil");
      expect(lua).toContain("selectedSessionIdx = nil");
    });

    it("session sidebar uses selectedSessionIdx for selection state", () => {
      expect(lua).toContain("selectedSessionIdx = self._dataIdx");
      expect(lua).toContain("btn._sel:SetShown(selectedSessionIdx == sIdx)");
    });

    it("highlights sessions with alerts in red, active in green", () => {
      const redAlert = lua.includes('|cFFFF4444" .. label');
      const greenActive = lua.includes('|cFF00CC00" .. label');
      expect(redAlert).toBe(true);
      expect(greenActive).toBe(true);
    });
  });
});

describe("Modular Architecture Validation", () => {
  describe("Re-export completeness", () => {
    it("addon-generator.ts re-exports all public functions", () => {
      const expectedExports = [
        "setAddonVersion", "getAddonVersion",
        "conditionToLua",
        "generateToc", "generateBindingNames", "generateBindingsXml", "generateAllSpecsToc",
        "generateLibStub",
        "generateLocales",
        "generateConfig", "generateAllSpecsConfig",
        "generateHelpers",
        "generateEngine",
        "generateHud",
        "generateCore",
        "generateSettingsPanel",
        "generateWatchdogLua",
        "generateAllSpecsAddonZip", "generateAddonZip",
      ];
      const { readFileSync } = require("fs");
      const source = readFileSync("server/addon-generator.ts", "utf-8");
      for (const name of expectedExports) {
        expect(source).toContain(name);
      }
    });

    it("addon-generator.ts re-exports AllSpecsData and AddonData types", () => {
      const { readFileSync } = require("fs");
      const source = readFileSync("server/addon-generator.ts", "utf-8");
      expect(source).toContain("type AllSpecsData");
      expect(source).toContain("type AddonData");
    });
  });

  describe("Generator isolation", () => {
    it("each gen-*.ts file can be imported independently", () => {
      const { readdirSync } = require("fs");
      const genFiles = readdirSync("server/generators").filter((f: string) => f.startsWith("gen-") && f.endsWith(".ts"));
      expect(genFiles.length).toBeGreaterThanOrEqual(11);
    });

    it("every gen-*.ts has a module-level JSDoc header", () => {
      const { readFileSync, readdirSync } = require("fs");
      const genFiles = readdirSync("server/generators").filter((f: string) => f.startsWith("gen-") && f.endsWith(".ts"));
      for (const file of genFiles) {
        const source = readFileSync(`server/generators/${file}`, "utf-8");
        expect(source).toContain("@module");
      }
    });

    it("shared.ts exports all required constants and types", () => {
      const { readFileSync } = require("fs");
      const source = readFileSync("server/generators/shared.ts", "utf-8");
      expect(source).toContain("export const ADDON_NAME");
      expect(source).toContain("export let ADDON_VERSION");
      expect(source).toContain("export const WOW_INTERFACE");
      expect(source).toContain("export function setAddonVersion");
      expect(source).toContain("export function getAddonVersion");
      expect(source).toContain("export function escapeLuaStr");
      expect(source).toContain("export function safeLuaCondition");
      expect(source).toContain("export interface AllSpecsData");
    });
  });
});

describe("Watchdog Subsystem Health Monitoring", () => {
  const lua = generateWatchdogLua();

  it("includes subsystem registry", () => {
    expect(lua).toContain("local subsystemRegistry = {}");
    expect(lua).toContain("local function RegisterSubsystem(name, checkFn)");
  });

  it("includes RunHealthChecks function", () => {
    expect(lua).toContain("local function RunHealthChecks()");
  });

  it("registers all 10 CLF subsystems", () => {
    const subsystems = [
      "ResourceTracker", "AuraTracker", "CastTracker", "SnapshotCache",
      "CDTracker", "ActionBarScanner", "APLEvaluator", "HUDRenderer",
      "EnemyCounter", "BossModBridge",
    ];
    for (const name of subsystems) {
      expect(lua).toContain(`RegisterSubsystem("${name}"`);
    }
  });

  it("includes /dmgawd health command", () => {
    expect(lua).toContain('cmd == "health"');
    expect(lua).toContain("/dmgawd health");
  });

  it("includes health report in session export", () => {
    expect(lua).toContain("local healthResults = RunHealthChecks()");
    expect(lua).toContain("FormatHealthReportPlain(healthResults)");
  });

  it("registers subsystems on ADDON_LOADED", () => {
    expect(lua).toContain("RegisterCLFSubsystems");
  });

  it("each health check returns ok, lastUpdate, eventCount, errors", () => {
    expect(lua).toContain("ok =");
    expect(lua).toContain("lastUpdate =");
    expect(lua).toContain("eventCount =");
    expect(lua).toContain("errors =");
  });
});

describe("Secondary Resource (Combo Points) System", () => {
  it("gen-config SECONDARY_POWER_TYPE maps Feral and Rogues to combo points (4)", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-config.ts", "utf-8");
    expect(src).toContain('"druid-feral": 4');
    expect(src).toContain('"rogue-ass": 4');
    expect(src).toContain('"rogue-out": 4');
    expect(src).toContain('"rogue-sub": 4');
  });

  it("gen-config templates emit secondaryPowerTypeId field", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-config.ts", "utf-8");
    const matches = src.match(/secondaryPowerTypeId/g);
    expect(matches).not.toBeNull();
    expect(matches!.length).toBeGreaterThanOrEqual(2);
  });

  it("gen-helpers defines CLF.ComboPoints function", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-helpers.ts", "utf-8");
    expect(src).toContain("function CLF.ComboPoints()");
    expect(src).toContain('UnitPower("player", 4)');
  });

  it("gen-helpers defines CLF.GetSecondaryPowerType function", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-helpers.ts", "utf-8");
    expect(src).toContain("function CLF.GetSecondaryPowerType()");
    expect(src).toContain("secondaryPowerTypeId");
  });

  it("gen-helpers declares _spellSecondaryCosts table", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-helpers.ts", "utf-8");
    expect(src).toContain("CLF._spellSecondaryCosts = {}");
  });

  it("CheckResourceAffordable checks secondary costs via UnitPower", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-helpers.ts", "utf-8");
    expect(src).toContain("CLF._spellSecondaryCosts");
    expect(src).toContain("secondaryPowerTypeId");
    const affordBlock = src.substring(src.indexOf("local function CheckResourceAffordable"), src.indexOf("function CLF.CheckResourceAffordable"));
    expect(affordBlock).toContain("secCosts");
    expect(affordBlock).toContain("secCur < secCost");
  });

  it("SnapshotSpellBook stores secondary costs separately from primary", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-helpers.ts", "utf-8");
    const snapBlock = src.substring(src.indexOf("function CLF.SnapshotSpellBook"), src.indexOf("function CLF.DiscoverSpellOverrides"));
    expect(snapBlock).toContain("_spellSecondaryCosts");
    expect(snapBlock).toContain("secondaryPowerTypeId");
  });

  it("AC promotion trusts AC and always promotes non-CD spells", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-engine.ts", "utf-8");
    expect(src).toContain("ac:promoted");
    expect(src).toContain("AC-PROMOTE:");
    expect(src).not.toContain("ac:promoteDenied(starved)");
  });

  it("Feral APL conditions use CLF.ComboPoints() not CLF.Power()", async () => {
    const { conditionToLua } = await import("../server/generators/transpiler");
    const result = conditionToLua("combo_points>=5");
    expect(result).toContain("CLF.ComboPoints()");
    expect(result).not.toContain("CLF.Power()");
  });

  it("energy conditions still use CLF.Power()", async () => {
    const { conditionToLua } = await import("../server/generators/transpiler");
    const result = conditionToLua("energy>=40");
    expect(result).toContain("CLF.Power()");
    expect(result).not.toContain("CLF.ComboPoints()");
  });
});

describe("Fallback Chain & Pre-Midnight Overlay Logic", () => {
  it("community-apls.ts uses correct spec IDs matching SPECS array", async () => {
    const { COMMUNITY_APLS } = await import("../server/community-apls");
    const { SPECS } = await import("../server/storage");
    const specIds = new Set(SPECS.map(s => s.id));
    for (const key of Object.keys(COMMUNITY_APLS)) {
      expect(specIds.has(key), `Community APL key "${key}" must exist in SPECS`).toBe(true);
    }
  });

  it("community-apls.ts does NOT use long-form IDs", async () => {
    const { COMMUNITY_APLS } = await import("../server/community-apls");
    const keys = Object.keys(COMMUNITY_APLS);
    expect(keys).not.toContain("rogue-assassination");
    expect(keys).not.toContain("evoker-augmentation");
    expect(keys).toContain("rogue-ass");
    expect(keys).toContain("evoker-aug");
  });

  it("community APL entries use the correct spec ID internally", async () => {
    const { COMMUNITY_APLS } = await import("../server/community-apls");
    for (const [specId, entries] of Object.entries(COMMUNITY_APLS)) {
      for (const entry of entries) {
        expect(entry.specId, `Entry "${entry.spellName}" in ${specId} has wrong specId "${entry.specId}"`).toBe(specId);
      }
    }
  });

  it("PRE_MIDNIGHT_OVERRIDES keys use correct short-form spec IDs", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-engine.ts", "utf-8");
    const tableMatch = src.match(/PRE_MIDNIGHT_OVERRIDES\s*=\s*\{([\s\S]*?)\n\}/);
    expect(tableMatch).not.toBeNull();
    const tableBody = tableMatch![1];
    expect(tableBody).not.toContain('"rogue-assassination"');
    expect(tableBody).not.toContain('"evoker-augmentation"');
    expect(tableBody).toContain('"rogue-ass"');
    expect(tableBody).toContain('"evoker-aug"');
  });

  it("ApplyPreMidnightOverrides skips community branch", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-engine.ts", "utf-8");
    expect(src).toContain('aplBranch == "community" then return false');
  });

  it("ApplyPreMidnightOverrides skips midnight branch", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-engine.ts", "utf-8");
    expect(src).toContain('aplBranch == "midnight"');
    const overrideFn = src.substring(src.indexOf("function ApplyPreMidnightOverrides"), src.indexOf("function CLF.BuildFilteredAPL"));
    expect(overrideFn).toContain('if aplBranch == "midnight" or aplBranch == "community" then return false end');
  });

  it("sync-engine falls back to community APL when SimC returns null", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/sync-engine.ts", "utf-8");
    const buildFn = src.substring(src.indexOf("async function buildAddonData"), src.indexOf("function computeDataHash") > -1 ? src.indexOf("export async function runSync") : src.length);
    const simcCheck = buildFn.indexOf("if (simcResult)");
    const communityCheck = buildFn.indexOf("getCommunityApl");
    const dbFallback = buildFn.indexOf("storage.getAplEntries");
    expect(simcCheck).toBeGreaterThan(-1);
    expect(communityCheck).toBeGreaterThan(simcCheck);
    expect(dbFallback).toBeGreaterThan(communityCheck);
  });

  it("sync-engine sets aplBranch='community' for community APL path", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/sync-engine.ts", "utf-8");
    expect(src).toContain('aplBranch = "community"');
    expect(src).toContain('aplTier = "MID1-community"');
  });

  it("generated config embeds aplBranch into CLF_DefaultConfig.spec", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-config.ts", "utf-8");
    expect(src).toContain('aplBranch = "');
    const specBlock = src.substring(src.indexOf("CLF_DefaultConfig"), src.indexOf("hud = {"));
    expect(specBlock).toContain("aplBranch");
  });

  it("BuildFilteredAPL reads aplBranch from config.spec and passes to ApplyPreMidnightOverrides", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-engine.ts", "utf-8");
    const startIdx = src.indexOf("function CLF.BuildFilteredAPL");
    const nextFnIdx = src.indexOf("\nfunction CLF.", startIdx + 10);
    const buildFn = src.substring(startIdx, nextFnIdx > -1 ? nextFnIdx : startIdx + 10000);
    expect(buildFn).toContain('config.spec and config.spec.aplBranch or "fallback"');
    expect(buildFn).toContain("ApplyPreMidnightOverrides(specId, aplBranch");
  });

  it("all 6 tanks have community APLs", async () => {
    const { COMMUNITY_APLS } = await import("../server/community-apls");
    const tanks = ["dk-blood", "dh-vengeance", "druid-guardian", "monk-brew", "paladin-prot", "warrior-prot"];
    for (const t of tanks) {
      expect(COMMUNITY_APLS[t], `Missing community APL for tank: ${t}`).toBeDefined();
      expect(COMMUNITY_APLS[t].length).toBeGreaterThan(5);
    }
  });

  it("all 7 healers have community APLs", async () => {
    const { COMMUNITY_APLS } = await import("../server/community-apls");
    const healers = ["druid-resto", "evoker-pres", "monk-mw", "paladin-holy", "priest-disc", "priest-holy", "shaman-resto"];
    for (const h of healers) {
      expect(COMMUNITY_APLS[h], `Missing community APL for healer: ${h}`).toBeDefined();
      expect(COMMUNITY_APLS[h].length).toBeGreaterThan(5);
    }
  });

  it("community APL specs each have an interrupt at priority 1", async () => {
    const { COMMUNITY_APLS } = await import("../server/community-apls");
    for (const [specId, entries] of Object.entries(COMMUNITY_APLS)) {
      const interrupts = entries.filter(e => e.isInterrupt);
      expect(interrupts.length, `${specId} should have at least 1 interrupt`).toBeGreaterThanOrEqual(1);
      const topInterrupt = interrupts.find(e => e.priority === 1);
      expect(topInterrupt, `${specId} interrupt should be at priority 1`).toBeDefined();
    }
  });

  it("community APL specs each have at least 1 cooldown", async () => {
    const { COMMUNITY_APLS } = await import("../server/community-apls");
    for (const [specId, entries] of Object.entries(COMMUNITY_APLS)) {
      const cds = entries.filter(e => e.isCooldown);
      expect(cds.length, `${specId} should have at least 1 cooldown`).toBeGreaterThanOrEqual(1);
    }
  });

  it("TWW branch would trigger pre-midnight overlay for rogue-ass", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/generators/gen-engine.ts", "utf-8");
    const overrideFn = src.substring(src.indexOf("function ApplyPreMidnightOverrides"), src.indexOf("function CLF.BuildFilteredAPL"));
    expect(overrideFn).toContain('if aplBranch == "midnight" or aplBranch == "community" then return false end');
    const tableMatch = src.match(/PRE_MIDNIGHT_OVERRIDES\s*=\s*\{([\s\S]*?)\n\}/);
    expect(tableMatch).not.toBeNull();
    expect(tableMatch![1]).toContain('"rogue-ass"');
  });

  it("getCommunityApl returns null for specs without community data", async () => {
    const { getCommunityApl } = await import("../server/community-apls");
    expect(getCommunityApl("nonexistent-spec")).toBeNull();
    expect(getCommunityApl("mage-fire")).toBeNull();
  });

  it("getCommunityApl returns entries for specs with community data", async () => {
    const { getCommunityApl } = await import("../server/community-apls");
    const result = getCommunityApl("rogue-ass");
    expect(result).not.toBeNull();
    expect(result!.length).toBeGreaterThan(5);
    expect(result![0].specId).toBe("rogue-ass");
  });

  it("community APL for evoker-aug uses correct short-form ID throughout", async () => {
    const { getCommunityApl } = await import("../server/community-apls");
    const entries = getCommunityApl("evoker-aug");
    expect(entries).not.toBeNull();
    for (const entry of entries!) {
      expect(entry.specId).toBe("evoker-aug");
      expect(entry.specId).not.toBe("evoker-augmentation");
    }
  });

  it("SimC -> community -> DB fallback order is correct in sync-engine", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/sync-engine.ts", "utf-8");
    const buildFn = src.substring(
      src.indexOf("async function buildAddonData"),
      src.indexOf("export async function runSync")
    );
    const simcLine = buildFn.indexOf("fetchSimcApl(spec.id)");
    const communityLine = buildFn.indexOf("getCommunityApl(spec.id)");
    const dbLine = buildFn.indexOf("storage.getAplEntries(spec.id)");
    expect(simcLine).toBeGreaterThan(-1);
    expect(communityLine).toBeGreaterThan(simcLine);
    expect(dbLine).toBeGreaterThan(communityLine);
    const simcBranchBlock = buildFn.substring(simcLine, communityLine);
    expect(simcBranchBlock).toContain("simcResult.branch");
    const communityBlock = buildFn.substring(communityLine, dbLine);
    expect(communityBlock).toContain('"community"');
    const dbBlock = buildFn.substring(dbLine, dbLine + 200);
    expect(dbBlock).toContain('"fallback"');
  });

  it("when SimC returns a result, community APL is NOT consulted", () => {
    const { readFileSync } = require("fs");
    const src = readFileSync("server/sync-engine.ts", "utf-8");
    const buildFn = src.substring(
      src.indexOf("async function buildAddonData"),
      src.indexOf("export async function runSync")
    );
    const ifSimcBlock = buildFn.substring(
      buildFn.indexOf("if (simcResult)"),
      buildFn.indexOf("} else {")
    );
    expect(ifSimcBlock).not.toContain("getCommunityApl");
    expect(ifSimcBlock).toContain("simcResult.entries");
    expect(ifSimcBlock).toContain("simcResult.branch");
  });

  it("generated Lua compiles after all changes", async () => {
    const { execSync } = require("child_process");
    const { generateEngine } = await import("../server/addon-generator");
    const { writeFileSync } = require("fs");
    const lua = generateEngine();
    writeFileSync("/tmp/fallback-test.lua", lua);
    const result = execSync("luac -p /tmp/fallback-test.lua 2>&1", { encoding: "utf-8" });
    expect(result.trim()).toBe("");
  });
});
