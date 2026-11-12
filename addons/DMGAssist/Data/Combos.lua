-- Written by tools/mine_combos.lua from long simulated fights: each spec's chains after a major
-- cooldown (spell IDs, the cooldown first). Combos.lua announces one when you finish it in Flow.
local _, ns = ...
ns.COMBO_DATA = {
  deathknight_blood = {
    { 46584, 43265 }, -- raise_dead > death_and_decay (22 of 30)
    { 439843, 205223, 206930 }, -- reapers_mark > consumption > heart_strike (18 of 21)
  },
  deathknight_frost = {
    { 51271, 152279 }, -- pillar_of_frost > breath_of_sindragosa (3 of 3)
    { 439843, 46584 }, -- reapers_mark_debuff > raise_dead (3 of 3)
  },
  demonhunter_havoc = {
    { 323639, 210152, 201427 }, -- the_hunt > death_sweep > annihilation (9 of 12)
  },
  druid_feral = {
    { 106951, 1079, 323764, 1079 }, -- bs_inc > rip > convoke_the_spirits > rip (4 of 6)
  },
  druid_guardian = {
    { 204066, 323764 }, -- lunar_beam > convoke_the_spirits (9 of 15)
    { 1252871, 33917, 213764 }, -- red_moon > mangle > swipe (7 of 10)
  },
  hunter_marksmanship = {
    { 212431, 53351, 56641 }, -- explosive_shot > kill_shot > steady_shot (9 of 15)
    { 288613, 19434 }, -- trueshot > aimed_shot (9 of 9)
  },
  mage_arcane = {
    { 365350, 5143, 321507, 5143 }, -- arcane_surge > arcane_missiles > touch_of_the_magi > arcane_missiles (11 of 12)
  },
  mage_fire = {
    { 190319, 153561, 2948 }, -- combustion > meteor > scorch (9 of 9)
  },
  monk_windwalker = {
    { 1249625, 443028 }, -- zenith > celestial_conduit (8 of 13)
  },
  paladin_holy = {
    { 304971, 20473 }, -- divine_toll > holy_shock (11 of 15)
  },
  paladin_protection = {
    { 31884, 24275, 20271 }, -- avenging_wrath > hammer_of_wrath > judgment (6 of 9)
  },
  priest_shadow = {
    { 10060, 120517, 194249, 1227280 }, -- power_infusion > halo > voidform > tentacle_slam (3 of 3)
  },
  rogue_subtlety = {
    { 426591, 53 }, -- goremaws_bite > backstab (3 of 3)
  },
  shaman_elemental = {
    { 378081, 191634 }, -- natures_swiftness > stormkeeper (15 of 15)
  },
  warrior_arms = {
    { 260708, 156287 }, -- sweeping_strikes > ravager (10 of 10)
  },
  warrior_protection = {
    { 107574, 228920, 1271985 }, -- avatar > ravager > champions_leap (8 of 12)
  },
}
