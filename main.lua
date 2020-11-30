local addonName, ZT = ...;
_G[addonName] = ZT;

ZT.inspectLib = LibStub:GetLibrary("LibGroupInSpecT-1.1", true);

-- Local versions of commonly used functions
local ipairs = ipairs
local pairs = pairs
local print = print
local select = select
local tonumber = tonumber
local tinsert = tinsert

local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local UnitGUID = UnitGUID
local GetTime = GetTime

local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo

-- Turns on/off debugging messages
local DEBUG_EVENT = { isEnabled = false, color = "FF2281F4" }
local DEBUG_MESSAGE = { isEnabled = false, color = "FF11D825" }
local DEBUG_TIMER = { isEnabled = false, color = "FFF96D27" }
local DEBUG_TRACKING = { isEnabled = false, color = "FFA53BF7" }

-- Turns on/off testing of combatlog-based tracking for the player
-- (Note: This will disable sharing of player CD updates over addon messages)
local TEST_CLEU = false

local function prdebug(type, ...)
	if type.isEnabled then
		print("|c"..type.color.."[ZT-Debug]", ...)
	end
end

local function prerror(...)
	print("|cFFFF0000[ZT-Error]", ...)
end

-- Utility functions for creating tables/maps
local function DefaultTable_Create(genDefaultFunc)
	local metatable = {}
	metatable.__index = function(table, key)
		local value = genDefaultFunc()
		rawset(table, key, value)
		return value
	end

    return setmetatable({}, metatable)
end

local function Map_FromTable(table)
	local map = {}
	for _,value in ipairs(table) do
		map[value] = true
	end
	return map
end

local IterateGroupMembers = function(reversed, forceParty)
	local unit = (not forceParty and IsInRaid()) and 'raid' or 'party'
	local numGroupMembers = unit == 'party' and GetNumSubgroupMembers() or GetNumGroupMembers()
	local i = reversed and numGroupMembers or (unit == 'party' and 0 or 1)
	return function()
		local ret
		if i == 0 and unit == 'party' then
			ret = 'player'
		elseif i <= numGroupMembers and i > 0 then
			ret = unit .. i
		end
		i = i + (reversed and -1 or 1)
		return ret
	end
end

--##############################################################################
-- Class and Spec Information

local DH = {ID=12, name="DEMONHUNTER", Havoc=577, Veng=581}
local DK = {ID=6, name="DEATHKNIGHT", Blood=250, Frost=251, Unholy=252}
local Druid = {ID=11, name="DRUID", Balance=102, Feral=103, Guardian=104, Resto=105}
local Hunter = {ID=3, name="HUNTER", BM=253, MM=254, SV=255}
local Mage = {ID=8, name="MAGE", Arcane=62, Fire=63, Frost=64}
local Monk = {ID=10, name="MONK", BRM=268, WW=269, MW=270}
local Paladin = {ID=2, name="PALADIN", Holy=65, Prot=66, Ret=70}
local Priest = {ID=5, name="PRIEST", Disc=256, Holy=257, Shadow=258}
local Rogue = {ID=4, name="ROGUE", Sin=259, Outlaw=260, Sub=261}
local Shaman = {ID=7, name="SHAMAN", Ele=262, Enh=263, Resto=264}
local Warlock = {ID=9, name="WARLOCK", Affl=265, Demo=266, Destro=267}
local Warrior = {ID=1, name="WARRIOR", Arms=71, Fury=72, Prot=73}

local AllClasses = {
	[DH.name] = DH, [DK.name] = DK, [Druid.name] = Druid, [Hunter.name] = Hunter,
	[Mage.name] = Mage, [Monk.name] = Monk, [Paladin.name] = Paladin,
	[Priest.name] = Priest, [Rogue.name] = Rogue, [Shaman.name] = Shaman,
	[Warlock.name] = Warlock, [Warrior.name] = Warrior
}

local AllCovenants = {
    ["Kyrian"] = 1,
    ["Venthyr"] = 2,
    ["NightFae"] = 3,
    ["Necrolord"] = 4,
}

--##############################################################################
-- Spell Requirements

local function Requirement(type, check, indices)
    return { type = type, check = check, indices = indices }
end

local function LevelReq(minLevel)
    return Requirement("level", function(member)
        if type(member.level) == "string" then
            prerror("!!!", member.level)
        end
        return member.level >= minLevel end, {minLevel})
end

local function RaceReq(race)
    return Requirement("race", function(member) return member.race == race end, {race})
end

local function ClassReq(class)
    return Requirement("class", function(member) return member.classID == class.ID end, {class.ID})
end

local function SpecReq(ids)
    local idsMap = Map_FromTable(ids)
    return Requirement("spec", function(member) return idsMap[member.specID] ~= nil end, ids)
end

local function TalentReq(id)
    return Requirement("talent", function(member) return member.talents[id] ~= nil end, {id})
end

local function NoTalentReq(id)
    return Requirement("notalent", function(member) return member.talents[id] == nil end, {id})
end

-- local function ItemReq(id)
--     return Requirement("items", function(member) return false end)
-- end

local function CovenantReq(name)
    local covenantID = AllCovenants[name]
    return Requirement("covenant", function(member) return covenantID == member.covenantID end, {covenantID})
end

--##############################################################################
-- Spell Modifiers (Static and Dynamic)

local function StaticMod(func)
    return { type = "Static", func = func }
end

local function SubtractMod(amount)
    return StaticMod(function(watchInfo) watchInfo.duration = watchInfo.duration - amount end)
end

local function MultiplyMod(coeff)
    return StaticMod(function(watchInfo) watchInfo.duration = watchInfo.duration * coeff end)
end

local function ChargesMod(amount)
    return StaticMod(function(watchInfo)
        watchInfo.charges = amount
        watchInfo.maxCharges = amount
    end)
end


local function DynamicMod(handlers)
    if handlers.type then
		handlers = { handlers }
	end

	return { type = "Dynamic", handlers = handlers }
end

local function EventDeltaMod(type, spellID, delta)
	return DynamicMod({
		type = type,
		spellID = spellID,
		handler = function(watchInfo)
			watchInfo:updateCDDelta(delta)
		end
	})
end

local function CastDeltaMod(spellID, delta)
	return EventDeltaMod("SPELL_CAST_SUCCESS", spellID, delta)
end

local function EventRemainingMod(type, spellID, remaining)
	return DynamicMod({
		type = type,
		spellID = spellID,
		handler = function(watchInfo)
			watchInfo:updateCDRemaining(remaining)
		end
	})
end

local function CastRemainingMod(spellID, remaining)
	return EventRemainingMod("SPELL_CAST_SUCCESS", spellID, remaining)
end

-- If Shockwave 3+ targets hit then reduces cooldown by 15 seconds
local RumblingEarthMod = DynamicMod({
	{
		type = "SPELL_CAST_SUCCESS", spellID = 46968,
		handler = function(watchInfo)
			watchInfo.numHits = 0
		end
	},
	{
		type = "SPELL_AURA_APPLIED", spellID = 132168,
		handler = function(watchInfo)
			watchInfo.numHits = watchInfo.numHits + 1
			if watchInfo.numHits == 3 then
				watchInfo:updateCDDelta(-15)
			end
		end
	}
})

-- Each target hit by Capacitor Totem reduces cooldown by 5 seconds (up to 4 targets hit)
local function StaticChargeAuraHandler(watchInfo)
    watchInfo.numHits = watchInfo.numHits + 1
    if watchInfo.numHits <= 4 then
        watchInfo:updateCDDelta(-5)
    end
end

local StaticChargeMod = DynamicMod({
	type = "SPELL_SUMMON", spellID = 192058,
	handler = function(watchInfo)
		watchInfo.numHits = 0

		if watchInfo.totemGUID then
            ZT.eventHandlers:remove("SPELL_AURA_APPLIED", 118905, watchInfo.totemGUID, StaticChargeAuraHandler)
		end

		watchInfo.totemGUID = select(8, CombatLogGetCurrentEventInfo())
        ZT.eventHandlers:add("SPELL_AURA_APPLIED", 118905, watchInfo.totemGUID, StaticChargeAuraHandler, watchInfo)
	end
})


-- Guardian Spirit: If expires watchInfothout healing then reset to 60 seconds
local GuardianAngelMod = DynamicMod({
	{
		type = "SPELL_HEAL", spellID = 48153,
		handler = function(watchInfo)
			watchInfo.spiritHeal = true
		end
	},
	{
		type = "SPELL_AURA_REMOVED", spellID = 47788,
		handler = function(watchInfo)
			if not watchInfo.spiritHeal then
				watchInfo:updateCDRemaining(60)
			end
			watchInfo.spiritHeal = false
		end
	}
})

-- Dispels: Go on cooldown only if a debuff is dispelled
local function DispelMod(spellID)
	return DynamicMod({
		type = "SPELL_DISPEL",
		spellID = spellID,
		handler = function(watchInfo)
			watchInfo:updateCDRemaining(8)
		end
	})
end

-- Resource Spending: For every spender, reduce cooldown by (coefficient * cost) seconds
--   Note: By default, I try to use minimum cost values as to not over-estimate the cooldown reduction
local specIDToSpenderInfo = {
	[DK.Blood] = {
        [47541]  = 40, -- Death Coil
        [49998]  = 40, -- Death Strike (Assumes -5 due to Ossuary)
		[61999]  = 30, -- Raise Ally
        [327574]  = 20, -- Sacrificial Pact
	},
	[Warrior.Arms] = {
		[845]    = 20, -- Cleave
		[163201] = 20, -- Execute (Ignores Sudden Death)
		[1715]   = 10, -- Hamstring
		[202168] = 10, -- Impending Victory
		[12294]  = 30, -- Moral Strike
		[772]    = 30, -- Rend
		[1464]   = 20, -- Slam
		[1680]   = 30, -- Whirlwind
        [190456] = 40, -- Ignore Pain
	},
	[Warrior.Fury] = {
		[202168] = 10, -- Impending Victory
		[184367] = 75, -- Rampage (Assumes -10 from Carnage)
		[12323]  = 10, -- Piercing Howl
        [190456] = 40, -- Ignore Pain
	},
	[Warrior.Prot] = {
		[190456] = 40, -- Ignore Pain (Ignores Vengeance)
		[202168] = 10, -- Impending Victory
		[6572]   = 30, -- Revenge (Ignores Vengeance)
		[2565]   = 30, -- Shield Block
    },
    [Hunter.BM] = {
        [185358] = 40, -- Arcane Shot
        [195645] = 30, -- Wing Clip
        [982]    = 35, -- Revive Pet
        [34026]  = 30, -- Kill Command
        [193455] = 35, -- Cobra Shot
        [2643]   = 40, -- Multi-Shot
        [1513]   = 25, -- Scare Beast
        [53351]  = 10, -- Kill Shot
        [131894] = 30, -- A Murder of Crows
        [120360] = 60, -- Barrage
    },
    [Hunter.MM] = {
        [185358] = 20, -- Arcane Shot
        [195645] = 30, -- Wing Clip
        [982]    = 35, -- Revive Pet
        [19434]  = 35, -- Aimed Shot
        [186387] = 10, -- Bursting Shot
        [257620] = 20, -- Multi-Shot
        [53351]  = 10, -- Kill Shot
        [271788] = 60, -- Serpent Sting
        [131894] = 30, -- A Murder of Crows
        [120360] = 60, -- Barrage
        [212431] = 20, -- Explosive Shot
        [342049] = 20, -- Chimaera Shot
    },
    [Hunter.SV] = {
        [185358] = 40, -- Arcane Shot
        [195645] = 30, -- Wing Clip
        [982]    = 35, -- Revive Pet
        [186270] = 30, -- Raptor Strike
        [259491] = 20, -- Serpent Sting
        [187708] = 35, -- Carve
        [320976] = 10, -- Kill Shot
        [212436] = 30, -- Butchery
        [259387] = 30, -- Mongoose Bite
        [259391] = 15, -- Chakrams
    },
    [Paladin] = {
        [85673]  = 3, -- Word of Glory
        [85222]  = 3, -- Light of Dawn
        [152262] = 3, -- Seraphim
        [53600]  = 3, -- Shield of the Righteous
        [85256]  = 3, -- Templar's Verdict
        [53385]  = 3, -- Divine Storm
        [343527] = 3, -- Execution Sentence
    },
    [Paladin.Holy] = {
        [85673]  = 3, -- Word of Glory
        [85222]  = 3, -- Light of Dawn
        [152262] = 3, -- Seraphim
    },
    [Paladin.Prot] = {
        [85673]  = 3, -- Word of Glory
        [53600]  = 3, -- Shield of the Righteous
        [152262] = 3, -- Seraphim
    },
    [Paladin.Ret] = {
        [85673]  = 3, -- Word of Glory
        [85256]  = 3, -- Templar's Verdict
        [53385]  = 3, -- Divine Storm
        [343527] = 3, -- Execution Sentence
        [152262] = 3, -- Seraphim
    },
}

local function ResourceSpendingMods(specID, coefficient)
	local handlers = {}
	local spenderInfo = specIDToSpenderInfo[specID]

	for spellID,cost in pairs(spenderInfo) do
		local delta = -(coefficient * cost)

		handlers[#handlers+1] = {
			type = "SPELL_CAST_SUCCESS",
			spellID = spellID,
			handler = function(watchInfo)
				watchInfo:updateCDDelta(delta)
			end
		}
	end

	return DynamicMod(handlers)
end

-- Duration Modifier (For active buff durations)
local function DurationMod(spellID, refreshes)
    local handlers = {}
    handlers[1] = {
        type = "SPELL_AURA_REMOVED",
        force = true,
        spellID = spellID,
        handler = function(watchInfo)
            watchInfo.activeExpiration = GetTime()
            ZT:sendCDUpdate(watchInfo, true)
            watchInfo:sendTriggerEvent()
        end
    }

    if refreshes then
        for r in pairs(refreshes) do
            handlers[#handlers+1] = {
                type = "SPELL_CAST_SUCCESS",
                spellID = r,
                handler = function(watchInfo)
                end
            }
        end
    end

    return DynamicMod(handlers)
end

local function ActiveMod(spellID, duration, refreshes)
    return { spellID = spellID, duration = duration , refreshes = refreshes}
end

--##############################################################################
-- List of Tracked Spells
-- TODO: Denote which spells should be modified by UnitSpellHaste(...)

ZT.spellListVersion = 103
ZT.spellList = {
    -- Racials
    {type="HARDCC", id=255654, cd=120, reqs={RaceReq("HighmountainTauren")}}, -- Bull Rush
    {type="HARDCC", id=20549, cd=90, reqs={RaceReq("Tauren")}}, -- War Stomp
    {type="STHARDCC", id=287712, cd=150, reqs={RaceReq("KulTiran")}}, -- Haymaker
    {type="STSOFTCC", id=107079, cd=120, reqs={RaceReq("Pandaren")}}, -- Quaking Palm
    {type="DISPEL", id=202719, cd=120, reqs={RaceReq("BloodElf"), ClassReq(DH)}}, -- Arcane Torrent
    {type="DISPEL", id=50613, cd=120, reqs={RaceReq("BloodElf"), ClassReq(DK)}}, -- Arcane Torrent
    {type="DISPEL", id=80483, cd=120, reqs={RaceReq("BloodElf"), ClassReq(Hunter)}}, -- Arcane Torrent
    {type="DISPEL", id=28730, cd=120, reqs={RaceReq("BloodElf"), ClassReq(Mage)}}, -- Arcane Torrent
    {type="DISPEL", id=129597, cd=120, reqs={RaceReq("BloodElf"), ClassReq(Monk)}}, -- Arcane Torrent
    {type="DISPEL", id=155145, cd=120, reqs={RaceReq("BloodElf"), ClassReq(Paladin)}}, -- Arcane Torrent
    {type="DISPEL", id=232633, cd=120, reqs={RaceReq("BloodElf"), ClassReq(Priest)}}, -- Arcane Torrent
    {type="DISPEL", id=25046, cd=120, reqs={RaceReq("BloodElf"), ClassReq(Rogue)}}, -- Arcane Torrent
    {type="DISPEL", id=28730, cd=120, reqs={RaceReq("BloodElf"), ClassReq(Warlock)}}, -- Arcane Torrent
    {type="DISPEL", id=69179, cd=120, reqs={RaceReq("BloodElf"), ClassReq(Warrior)}}, -- Arcane Torrent
    {type="DISPEL", id=20594, cd=120, reqs={RaceReq("Dwarf")}, mods={{mod=EventRemainingMod("SPELL_AURA_APPLIED",65116,120)}}}, -- Stoneform
    {type="DISPEL", id=265221, cd=120, reqs={RaceReq("DarkIronDwarf")}, mods={{mod=EventRemainingMod("SPELL_AURA_APPLIED",265226,120)}}}, -- Fireblood
    {type="UTILITY", id=58984, cd=120, reqs={RaceReq("NightElf")}}, -- Shadowmeld

    -- Covenants
    {type="COVENANT", id=324739, cd=300, reqs={CovenantReq("Kyrian")}, version=101},-- Summon Steward
    {type="COVENANT", id=323436, cd=180, reqs={CovenantReq("Kyrian")}, version=103},-- Purify Soul
    {type="COVENANT", id=300728, cd=60, reqs={CovenantReq("Venthyr")}, version=101},-- Door of Shadows
    {type="COVENANT", id=310143, cd=90, reqs={CovenantReq("NightFae")}, version=101},-- Soulshape
    {type="COVENANT", id=324631, cd=90, reqs={CovenantReq("Necrolord")}, version=101},-- Fleshcraft

    -- DH
    ---- Base
    {type="INTERRUPT", id=183752, cd=15, reqs={ClassReq(DH)}}, -- Disrupt
    {type="UTILITY", id=188501, cd=60, reqs={ClassReq(DH)}, mods={{reqs={ClassReq(DH), LevelReq(42)}, mod=SubtractMod(30)}}}, -- Spectral Sight
    {type="TANK", id=185245, cd=8, reqs={ClassReq(DH), LevelReq(9)}}, -- Torment
    {type="DISPEL", id=278326, cd=10, reqs={ClassReq(DH), LevelReq(17)}}, -- Consume Magic
    {type="STSOFTCC", id=217832, cd=45, reqs={ClassReq(DH), LevelReq(34)}}, -- Imprison
    ---- DH.Havoc
    {type="HARDCC", id=179057, cd=60, reqs={SpecReq({DH.Havoc})}, mods={{reqs={TalentReq(206477)}, mod=SubtractMod(20)}}}, -- Chaos Nova
    {type="PERSONAL", id=198589, cd=60, reqs={SpecReq({DH.Havoc}), LevelReq(21)}, active=ActiveMod(212800, 10)}, -- Blur
    {type="RAIDCD", id=196718, cd=300, reqs={SpecReq({DH.Havoc}), LevelReq(39)}, mods={{reqs={LevelReq(47)}, mod=SubtractMod(120)}}, active=ActiveMod(nil, 8)}, -- Darkness
    {type="DAMAGE", id=191427, cd=300, reqs={SpecReq({DH.Havoc})}, mods={{reqs={LevelReq(48)}, mod=SubtractMod(60)}}}, -- Metamorphosis
    ---- DH.Veng
    {type="TANK", id=204021, cd=60, reqs={SpecReq({DH.Veng})}}, -- Fiery Brand
    {type="TANK", id=212084, cd=45, reqs={SpecReq({DH.Veng}), LevelReq(11)}}, -- Fel Devastation
    {type="SOFTCC", id=207684, cd=180, reqs={SpecReq({DH.Veng}), LevelReq(21)}, mods={{reqs={LevelReq(33)}, mod=SubtractMod(90)}, {reqs={TalentReq(209281)}, mod=MultiplyMod(0.8)}}}, -- Sigil of Misery
    {type="SOFTCC", id=202137, cd=120, reqs={SpecReq({DH.Veng}), LevelReq(39)}, mods={{reqs={LevelReq(48)}, mod=SubtractMod(60)}, {reqs={TalentReq(209281)}, mod=MultiplyMod(0.8)}}}, -- Sigil of Silence
    {type="TANK", id=187827, cd=300, reqs={SpecReq({DH.Veng})}, mods={{reqs={LevelReq(20)}, mod=SubtractMod(60)}, {reqs={LevelReq(48)}, mod=SubtractMod(60)}}}, -- Metamorphosis
    ---- Talents
    {type="IMMUNITY", id=196555, cd=180, reqs={TalentReq(196555)}, active=ActiveMod(196555, 5)}, -- Netherwalk
    {type="SOFTCC", id=202138, cd=90, reqs={TalentReq(202138)}}, -- Sigil of Chains
    {type="STHARDCC", id=211881, cd=30, reqs={TalentReq(211881)}}, -- Fel Eruption
    {type="TANK", id=263648, cd=30, reqs={TalentReq(263648)}}, -- Soul Barrier
    {type="DAMAGE", id=258925, cd=60, reqs={TalentReq(258925)}}, -- Fel Barrage
    {type="TANK", id=320341, cd=90, reqs={TalentReq(320341)}}, -- Bulk Extraction
    ---- Covenants
    {type="COVENANT", id=312202, cd=60, reqs={ClassReq(DK), CovenantReq("Kyrian")}, version=103}, -- Shackle the Unworthy
    {type="COVENANT", id=311648, cd=60, reqs={ClassReq(DK), CovenantReq("Venthyr")}, version=103}, -- Swarming Mist
    {type="COVENANT", id=324128, cd=30, reqs={ClassReq(DK), CovenantReq("NightFae")}, version=103}, -- Death's Due
    {type="COVENANT", id=315443, cd=120, reqs={ClassReq(DK), CovenantReq("Necrolord")}, version=103}, -- Abomination Limb

    -- DK
    -- TODO: Raise Ally (Brez support)
    ---- Base
    {type="UTILITY", id=49576, cd=25, reqs={ClassReq(DK), LevelReq(5)}, version=103}, -- Death Grip
    {type="INTERRUPT", id=47528, cd=15, reqs={ClassReq(DK), LevelReq(7)}}, -- Mind Freeze
    {type="PERSONAL", id=48707, cd=60, reqs={ClassReq(DK), LevelReq(9)}, mods={{reqs={TalentReq(205727)}, mod=SubtractMod(20)}}}, -- Anti-Magic Shell
    {type="TANK", id=56222, cd=8, reqs={ClassReq(DK), LevelReq(14)}}, -- Dark Command
    {type="PERSONAL", id=49039, cd=120, reqs={ClassReq(DK), LevelReq(33)}, active=ActiveMod(49039, 10)}, -- Lichborne
    {type="PERSONAL", id=48792, cd=180, reqs={ClassReq(DK), LevelReq(38)}, active=ActiveMod(48792, 8)}, -- Icebound Fortitude
    {type="BREZ", id=61999, cd=600, reqs={ClassReq(DK), LevelReq(39)}}, -- Raise Ally
    {type="RAIDCD", id=51052, cd=120, reqs={ClassReq(DK), LevelReq(47)}, active=ActiveMod(nil, 10)}, -- Anti-Magic Zone
    {type="PERSONAL", id=327574, cd=120, reqs={ClassReq(DK), LevelReq(54)}}, -- Sacrificial Pact
    ---- DK.Blood
    {type="STHARDCC", id=221562, cd=45, reqs={SpecReq({DK.Blood}), LevelReq(13)}}, -- Asphyxiate
    {type="TANK", id=55233, cd=90, reqs={SpecReq({DK.Blood}), LevelReq(29)}, mods={{reqs={TalentReq(205723)}, mod=ResourceSpendingMods(DK.Blood, 0.15)}}, active=ActiveMod(55233, 10)}, -- Vampiric Blood
    {type="SOFTCC", id=108199, cd=120, reqs={SpecReq({DK.Blood}), LevelReq(44)}, mods={{reqs={TalentReq(206970)}, mod=SubtractMod(30)}}}, -- Gorefiend's Grasp
    {type="TANK", id=49028, cd=120, reqs={SpecReq({DK.Blood}), LevelReq(34)}, active=ActiveMod(81256, 8)}, -- Dancing Rune Weapon
    ---- DK.Frost
    {type="DAMAGE", id=51271, cd=45, reqs={SpecReq({DK.Frost}), LevelReq(29)}}, -- Pillar of Frost
    {type="DAMAGE", id=279302, cd=180, reqs={SpecReq({DK.Frost}), LevelReq(44)}}, -- Frostwyrm's Fury
    ---- DK.Unholy
    {type="DAMAGE", id=275699, cd=90, reqs={SpecReq({DK.Unholy}), LevelReq(19)}, mods={{reqs={LevelReq(49)}, mod=SubtractMod(15)}, {reqs={TalentReq(276837)}, mod=CastDeltaMod(47541,-1)}, {reqs={TalentReq(276837)}, mod=CastDeltaMod(207317,-1)}}}, -- Apocalypse
    {type="DAMAGE", id=63560, cd=60, reqs={SpecReq({DK.Unholy}), LevelReq(32)}, mods={{reqs={LevelReq(41)}, mod=CastDeltaMod(47541,-1)}}}, -- Dark Transformation
    {type="DAMAGE", id=42650, cd=480, reqs={SpecReq({DK.Unholy}), LevelReq(44)}, mods={{reqs={TalentReq(276837)}, mod=CastDeltaMod(47541,-5)}, {reqs={TalentReq(276837)}, mod=CastDeltaMod(207317,-5)}}}, -- Army of the Dead
    ---- Talents
    {type="TANK", id=219809, cd=60, reqs={TalentReq(219809)}}, -- Tombstone
    {type="DAMAGE", id=115989, cd=45, reqs={TalentReq(115989)}}, -- Unholy Blight
    {type="STHARDCC", id=108194, cd=45, reqs={TalentReq(108194)}}, -- Asphyxiate
    {type="SOFTCC", id=207167, cd=60, reqs={TalentReq(207167)}}, -- Blinding Sleet
    {type="PERSONAL", id=48743, cd=120, reqs={TalentReq(48743)}}, -- Death Pact
    {type="TANK", id=194844, cd=60, reqs={TalentReq(194844)}}, -- Bonestorm
    {type="DAMAGE", id=152279, cd=120, reqs={TalentReq(152279)}}, -- Breath of Sindragosa
    {type="DAMAGE", id=49206, cd=180, reqs={TalentReq(49206)}}, -- Summon Gargoyle
    {type="DAMAGE", id=207289, cd=75, reqs={TalentReq(207289)}}, -- Unholy Assault
    ---- Covenants
    {type="COVENANT", id=306830, cd=60, reqs={ClassReq(DH), CovenantReq("Kyrian")}, version=103}, -- Elysian Decree
    {type="COVENANT", id=317009, cd=60, reqs={ClassReq(DH), CovenantReq("Venthyr")}, version=103}, -- Sinful Brand
    {type="COVENANT", id=323639, cd=90, reqs={ClassReq(DH), CovenantReq("NightFae")}, version=103}, -- The Hunt
    {type="COVENANT", id=329554, cd=120, reqs={ClassReq(DH), CovenantReq("Necrolord")}, version=103}, -- Fodder to the Flame

    -- Druid
    -- TODO: Rebirth (Brez support)
    ---- Base
    {type="TANK", id=6795, cd=8, reqs={ClassReq(Druid), LevelReq(14)}}, -- Growl
    {type="PERSONAL", id=22812, cd=60, reqs={ClassReq(Druid), LevelReq(24)}, mods={{reqs={TalentReq(203965)}, mod=MultiplyMod(0.67)}}, active=ActiveMod(22812, 12)}, -- Barkskin
    {type="BREZ", id=20484, cd=600, reqs={ClassReq(Druid), LevelReq(29)}}, -- Rebirth
    {type="DISPEL", id=2908, cd=10, reqs={ClassReq(Druid), LevelReq(41)}}, -- Soothe
    {type="UTILITY", id=106898, cd=120, reqs={ClassReq(Druid), LevelReq(43)}, mods={{reqs={SpecReq({Druid.Guardian}), LevelReq(49)}, mod=SubtractMod(60)}}}, -- Stampeding Roar
    ---- Shared
    {type="DISPEL", id=2782, cd=8, reqs={SpecReq({Druid.Balance, Druid.Feral, Druid.Guardian}), LevelReq(19)}, mods={{mod=DispelMod(2782)}}, ignoreCast=true}, -- Remove Corruption
    {type="INTERRUPT", id=106839, cd=15, reqs={SpecReq({Druid.Feral, Druid.Guardian}), LevelReq(26)}}, -- Skull Bash
    {type="PERSONAL", id=61336, cd=180, reqs={SpecReq({Druid.Feral, Druid.Guardian}), LevelReq(32)}, mods={{reqs={SpecReq({Druid.Guardian}), LevelReq(47)}, mod=ChargesMod(2)}}, active=ActiveMod(61336, 6)}, -- Survival Instincts
    {type="UTILITY", id=29166, cd=180, reqs={SpecReq({Druid.Balance, Druid.Resto}), LevelReq(42)}}, -- Innervate
    ---- Druid.Balance
    {type="INTERRUPT", id=78675, cd=60, reqs={SpecReq({Druid.Balance}), LevelReq(26)}, active=ActiveMod(nil, 8)}, -- Solar Beam
    {type="SOFTCC", id=132469, cd=30, reqs={SpecReq({Druid.Balance}), LevelReq(28)}}, -- Typhoon
    {type="DAMAGE", id=194223, cd=180, reqs={SpecReq({Druid.Balance}), NoTalentReq(102560), LevelReq(39)}}, -- Celestial Alignment
    ---- Druid.Feral
    {type="STHARDCC", id=22570, cd=20, reqs={SpecReq({Druid.Feral}), LevelReq(28)}}, -- Maim
    {type="DAMAGE", id=106951, cd=180, reqs={SpecReq({Druid.Feral}), NoTalentReq(102543), LevelReq(34)}}, -- Berserk
    ---- Druid.Guardian
    {type="SOFTCC", id=99, cd=30, reqs={SpecReq({Druid.Guardian}), LevelReq(28)}}, -- Incapacitating Roar
    {type="TANK", id=50334, cd=180, reqs={SpecReq({Druid.Guardian}), NoTalentReq(102558), LevelReq(34)}}, -- Berserk
    ---- Druid.Resto
    {type="EXTERNAL", id=102342, cd=90, reqs={SpecReq({Druid.Resto}), LevelReq(12)}}, -- Ironbark
    {type="DISPEL", id=88423, cd=8, reqs={SpecReq({Druid.Resto}), LevelReq(19)}, mods={{mod=DispelMod(88423)}}, ignoreCast=true}, -- Remove Corruption
    {type="SOFTCC", id=102793, cd=60, reqs={SpecReq({Druid.Resto}), LevelReq(28)}}, -- Ursol's Vortex
    {type="HEALING", id=740, cd=180, reqs={SpecReq({Druid.Resto}), LevelReq(37)}, mods={{reqs={SpecReq({Druid.Resto}), TalentReq(197073)}, mod=SubtractMod(60)}}}, -- Tranquility
    {type="UTILITY", id=132158, cd=60, reqs={SpecReq({Druid.Resto}), LevelReq(58)}}, -- Nature's Swiftness
    ---- Talents
    {type="HEALING", id=102351, cd=30, reqs={TalentReq(102351)}}, -- Cenarion Ward
    {type="UTILITY", id=205636, cd=60, reqs={TalentReq(205636)}}, -- Force of Nature
    {type="PERSONAL", id=108238, cd=90, reqs={TalentReq(108238)}}, -- Renewal
    {type="STHARDCC", id=5211, cd=60, reqs={TalentReq(5211)}}, -- Mighty Bash
    {type="SOFTCC", id=102359, cd=30, reqs={TalentReq(102359)}}, -- Mass Entanglement
    {type="SOFTCC", id=132469, cd=30, reqs={TalentReq(197632)}}, -- Typhoon
    {type="SOFTCC", id=132469, cd=30, reqs={TalentReq(197488)}}, -- Typhoon
    {type="SOFTCC", id=102793, cd=60, reqs={TalentReq(197492)}}, -- Ursol's Vortex
    {type="SOFTCC", id=99, cd=30, reqs={TalentReq(197491)}}, -- Incapacitating Roar
    {type="SOFTCC", id=99, cd=30, reqs={TalentReq(217615)}}, -- Incapacitating Roar
    {type="DAMAGE", id=319454, cd=300, reqs={TalentReq(319454), TalentReq(202157)}}, -- Heart of the Wild
    {type="PERSONAL", id=319454, cd=300, reqs={TalentReq(319454), TalentReq(197491)}}, -- Heart of the Wild
    {type="HEALING", id=319454, cd=300, reqs={TalentReq(319454), TalentReq(197492)}}, -- Heart of the Wild
    {type="DAMAGE", id=319454, cd=300, reqs={TalentReq(319454), TalentReq(197488)}}, -- Heart of the Wild
    {type="PERSONAL", id=319454, cd=300, reqs={TalentReq(319454), TalentReq(217615)}}, -- Heart of the Wild
    {type="DAMAGE", id=319454, cd=300, reqs={TalentReq(319454), TalentReq(202155)}}, -- Heart of the Wild
    {type="DAMAGE", id=319454, cd=300, reqs={TalentReq(319454), TalentReq(197632)}}, -- Heart of the Wild
    {type="DAMAGE", id=319454, cd=300, reqs={TalentReq(319454), TalentReq(197490)}}, -- Heart of the Wild
    {type="DAMAGE", id=102543, cd=180, reqs={TalentReq(102543)}}, -- Incarnation: King of the Jungle
    {type="DAMAGE", id=102560, cd=180, reqs={TalentReq(102560)}}, -- Incarnation: Chosen of Elune
    {type="TANK", id=102558, cd=180, reqs={TalentReq(102558)}}, -- Incarnation: Guardian of Ursoc
    {type="HEALING", id=33891, cd=180, reqs={TalentReq(33891)}, mods={{mod=EventRemainingMod("SPELL_AURA_APPLIED",117679,180)}}, ignoreCast=true, active=ActiveMod(117679, 30)}, -- Incarnation: Tree of Life
    {type="HEALING", id=203651, cd=60, reqs={TalentReq(203651)}}, -- Overgrowth
    {type="DAMAGE", id=202770, cd=60, reqs={TalentReq(202770)}}, -- Fury of Elune
    {type="TANK", id=204066, cd=75, reqs={TalentReq(204066)}}, -- Lunar Beam
    {type="HEALING", id=197721, cd=90, reqs={TalentReq(197721)}}, -- Flourish
    {type="TANK", id=80313, cd=30, reqs={TalentReq(80313)}}, -- Pulverize
    ---- Covenants
    ---- TODO: Kindered Spirits
    {type="COVENANT", id=323546, cd=180, reqs={ClassReq(Druid), CovenantReq("Venthyr")}, version=103}, -- Ravenous Frenzy
    {type="COVENANT", id=323764, cd=120, reqs={ClassReq(Druid), CovenantReq("NightFae")}, version=103}, -- Channel the Spirits
    {type="COVENANT", id=325727, cd=25, reqs={ClassReq(Druid), CovenantReq("Necrolord")}, version=103}, -- Adaptive Swarm

    -- Hunter
    ---- Base
    {type="UTILITY", id=186257, cd=180, reqs={ClassReq(Hunter), LevelReq(5)}, mods={{reqs={ClassReq(Hunter), TalentReq(266921)}, mod=MultiplyMod(0.8)}}}, -- Aspect of the Cheetah
    {type="UTILITY", id=5384, cd=30, reqs={ClassReq(Hunter), LevelReq(6)}}, -- Feign Death
    {type="IMMUNITY", id=186265, cd=180, reqs={ClassReq(Hunter), LevelReq(8)}, mods={{reqs={ClassReq(Hunter), TalentReq(266921)}, mod=MultiplyMod(0.8)}}, active=ActiveMod(186265, 8)}, -- Aspect of the Turtle
    {type="PERSONAL", id=109304, cd=120, reqs={ClassReq(Hunter), LevelReq(9)}, mods={{reqs={SpecReq({Hunter.BM}), TalentReq(270581)}, mod=ResourceSpendingMods(Hunter.BM, 0.033)}, {reqs={SpecReq({Hunter.MM}), TalentReq(270581)}, mod=ResourceSpendingMods(Hunter.MM, 0.05)}, {reqs={SpecReq({Hunter.SV}), TalentReq(270581)}, mod=ResourceSpendingMods(Hunter.SV, 0.05)}}}, -- Exhilaration
    {type="STSOFTCC", id=187650, cd=30, reqs={ClassReq(Hunter), LevelReq(10)}, mods={{reqs={ClassReq(Hunter), LevelReq(56)}, mod=SubtractMod(5)}}}, -- Freezing Trap
    {type="UTILITY", id=34477, cd=30, reqs={ClassReq(Hunter), LevelReq(27)}}, -- Misdirection
    {type="DISPEL", id=19801, cd=10, reqs={ClassReq(Hunter), LevelReq(37)}}, -- Tranquilizing Shot
    {type="PERSONAL", id=264735, cd=180, reqs={ClassReq(Hunter)}, active=ActiveMod(264735, 10), version=103}, -- Survival of the Fittest
    ---- Shared
    {type="INTERRUPT", id=147362, cd=24, reqs={SpecReq({Hunter.BM, Hunter.MM}), LevelReq(18)}}, -- Counter Shot
    {type="STHARDCC", id=19577, cd=60, reqs={SpecReq({Hunter.BM, Hunter.SV}), LevelReq(33)}}, -- Intimidation
    ---- Hunter.BM
    {type="DAMAGE", id=19574, cd=90, reqs={SpecReq({Hunter.BM}), LevelReq(20)}}, -- Bestial Wrath
    {type="DAMAGE", id=193530, cd=120, reqs={SpecReq({Hunter.BM}), LevelReq(38)}}, -- Aspect of the Wild
    ---- Hunter.MM
    {type="STSOFTCC", id=186387, cd=30, reqs={SpecReq({Hunter.MM}), LevelReq(12)}}, -- Bursting Shot
    {type="HARDCC", id=109248, cd=45, reqs={SpecReq({Hunter.MM}), LevelReq(33)}}, -- Binding Shot
    {type="DAMAGE", id=288613, cd=120, reqs={SpecReq({Hunter.MM}), LevelReq(34)}}, -- Trueshot
    ---- Hunter.SV
    {type="INTERRUPT", id=187707, cd=15, reqs={SpecReq({Hunter.SV}), LevelReq(18)}}, -- Muzzle
    {type="DAMAGE", id=266779, cd=120, reqs={SpecReq({Hunter.SV}), LevelReq(34)}}, -- Coordinated Assault
    ---- Talents
    {type="UTILITY", id=199483, cd=60, reqs={TalentReq(199483)}}, -- Camouflage
    {type="SOFTCC", id=162488, cd=30, reqs={TalentReq(162488)}}, -- Steel Trap
    {type="HARDCC", id=109248, cd=45, reqs={SpecReq({Hunter.BM, Hunter.SV}), TalentReq(109248)}}, -- Binding Shot
    {type="DAMAGE", id=201430, cd=120, reqs={TalentReq(201430)}}, -- Stampede
    {type="DAMAGE", id=260402, cd=60, reqs={TalentReq(260402)}}, -- Double Tap
    {type="DAMAGE", id=321530, cd=60, reqs={TalentReq(321530)}}, -- Bloodshed
    ---- Covenants
    {type="COVENANT", id=308491, cd=60, reqs={ClassReq(Hunter), CovenantReq("Kyrian")}, version=103}, -- Resonating Arrow
    {type="COVENANT", id=324149, cd=30, reqs={ClassReq(Hunter), CovenantReq("Venthyr")}, version=103}, -- Flayed Shot
    {type="COVENANT", id=328231, cd=120, reqs={ClassReq(Hunter), CovenantReq("NightFae")}, version=103}, -- Wild Spirits
    {type="COVENANT", id=325028, cd=45, reqs={ClassReq(Hunter), CovenantReq("Necrolord")}, version=103}, -- Death Chakram

    -- Mage
    -- TODO: Arcane should have Invisibility from 34 to 46, then Greater Invisibility from 47 onward
    ---- Base
    {type="INTERRUPT", id=2139, cd=24, reqs={ClassReq(Mage), LevelReq(7)}}, -- Counterspell
    {type="DISPEL", id=475, cd=8, reqs={ClassReq(Mage), LevelReq(21)}, mods={{mod=DispelMod(475)}}, ignoreCast=true}, -- Remove Curse
    {type="IMMUNITY", id=45438, cd=240, reqs={ClassReq(Mage), LevelReq(22)}, mods={{mod=CastRemainingMod(235219, 0)}}, active=ActiveMod(45438, 10)}, -- Ice Block
    {type="PERSONAL", id=55342, cd=120, reqs={ClassReq(Mage), LevelReq(44)}}, -- Mirror Image
    ---- Shared
    {type="UTILITY", id=66, cd=300, reqs={SpecReq({Mage.Fire, Mage.Frost}), LevelReq(34)}}, -- Invisibility
    {type="PERSONAL", id=108978, cd=60, reqs={SpecReq({Mage.Fire, Mage.Frost}), LevelReq(58)}}, -- Alter Time
    ---- Mage.Arcane
    {type="PERSONAL", id=342245, cd=60, reqs={SpecReq({Mage.Arcane}), LevelReq(19)}, mods={{reqs={TalentReq(342249)}, mod=SubtractMod(30)}}}, -- Alter Time
    {type="PERSONAL", id=235450, cd=25, reqs={SpecReq({Mage.Arcane}), LevelReq(28)}}, -- Prismatic Barrier
    {type="DAMAGE", id=12042, cd=120, reqs={SpecReq({Mage.Arcane}), LevelReq(29)}}, -- Arcane Power
    {type="DAMAGE", id=321507, cd=45, reqs={SpecReq({Mage.Arcane}), LevelReq(33)}}, -- Touch of the Magi
    {type="UTILITY", id=205025, cd=60, reqs={SpecReq({Mage.Arcane}), LevelReq(42)}}, -- Presence of Mind
    {type="UTILITY", id=110959, cd=120, reqs={SpecReq({Mage.Arcane}), LevelReq(47)}}, -- Greater Invisibility
    ---- Mage.Fire
    {type="SOFTCC", id=31661, cd=20, reqs={SpecReq({Mage.Fire}), LevelReq(27)}, mods={{reqs={SpecReq({Mage.Fire}), LevelReq(38)}, mod=SubtractMod(2)}}}, -- Dragon's Breath
    {type="PERSONAL", id=235313, cd=25, reqs={SpecReq({Mage.Fire}), LevelReq(28)}}, -- Blazing Barrier
    {type="DAMAGE", id=190319, cd=120, reqs={SpecReq({Mage.Fire}), LevelReq(29)}}, -- Combustion
    ---- Mage.Frost
    {type="PERSONAL", id=11426, cd=25, reqs={SpecReq({Mage.Frost}), LevelReq(28)}}, -- Ice Barrier
    {type="DAMAGE", id=12472, cd=180, reqs={SpecReq({Mage.Frost}), LevelReq(29)}}, -- Icy Veins
    {type="DAMAGE", id=84714, cd=60, reqs={SpecReq({Mage.Frost}), LevelReq(38)}}, -- Frozen Orb
    {type="UTILITY", id=235219, cd=300, reqs={SpecReq({Mage.Frost}), LevelReq(42)}, mods={{reqs={SpecReq({Mage.Frost}), LevelReq(54)}, mod=SubtractMod(30)}}}, -- Cold Snap
    ---- Talents
    {type="SOFTCC", id=113724, cd=45, reqs={TalentReq(113724)}}, -- Ring of Frost
    ---- Covenants
    {type="COVENANT", id=307443, cd=30, reqs={ClassReq(Mage), CovenantReq("Kyrian")}, version=103}, -- Radiant Spark
    {type="COVENANT", id=314793, cd=90, reqs={ClassReq(Mage), CovenantReq("Venthyr")}, version=103}, -- Mirrors of Torment
    {type="COVENANT", id=314791, cd=45, reqs={ClassReq(Mage), CovenantReq("NightFae")}, version=103}, -- Shifting Power
    {type="COVENANT", id=324220, cd=180, reqs={ClassReq(Mage), CovenantReq("Necrolord")}, version=103}, -- Deathborne

    -- Monk
    -- TODO: Spiritual Focus (280197) as a ResourceSpendingMod
    -- TODO: Blackout Combo modifiers
    ---- Base
    {type="DAMAGE", id=322109, cd=180, reqs={ClassReq(Monk)}}, -- Touch of Death
    {type="TANK", id=115546, cd=8, reqs={ClassReq(Monk), LevelReq(14)}}, -- Provoke
    {type="STSOFTCC", id=115078, cd=45, reqs={ClassReq(Monk), LevelReq(22)}, mods={{reqs={ClassReq(Monk), LevelReq(56)}, mod=SubtractMod(15)}}}, -- Paralysis
    {type="HARDCC", id=119381, cd=60, reqs={ClassReq(Monk), LevelReq(6)}, mods={{reqs={ClassReq(Monk), TalentReq(264348)}, mod=SubtractMod(10)}}}, -- Leg Sweep
    ---- Shared
    {type="INTERRUPT", id=116705, cd=15, reqs={SpecReq({Monk.BRM, Monk.WW}), LevelReq(18)}}, -- Spear Hand Strike
    {type="DISPEL", id=218164, cd=8, reqs={SpecReq({Monk.BRM, Monk.WW}), LevelReq(24)}, mods={{mod=DispelMod(218164)}}, ignoreCast=true, version=103}, -- Detox
    {type="PERSONAL", id=243435, cd=420, reqs={SpecReq({Monk.MW, Monk.WW}), LevelReq(28)}, mods={{reqs={LevelReq(48)}, mod=SubtractMod(240)}}, active=ActiveMod(243435, 15)}, -- Fortifying Brew
    ---- Monk.BRM
    {type="TANK", id=322507, cd=30, reqs={SpecReq({Monk.BRM}), LevelReq(27)}, mods={{reqs={SpecReq({Monk.BRM}), TalentReq(325093)}, mod=MultiplyMod(0.8)}, {reqs={TalentReq(115399)}, mod=CastRemainingMod(115399, 0)}}}, -- Celestial Brew
    {type="PERSONAL", id=115203, cd=360, reqs={SpecReq({Monk.BRM}), LevelReq(28)}, active=ActiveMod(115203, 15)}, -- Fortifying Brew
    {type="TANK", id=115176, cd=300, reqs={SpecReq({Monk.BRM}), LevelReq(34)}}, -- Zen Meditation
    {type="SOFTCC", id=324312, cd=30, reqs={SpecReq({Monk.BRM}), LevelReq(54)}}, -- Clash
    {type="TANK", id=132578, cd=180, reqs={SpecReq({Monk.BRM}), LevelReq(42)}, active=ActiveMod(nil, 25)}, -- Invoke Niuzao, the Black Ox
    ---- Monk.MW
    {type="DISPEL", id=115450, cd=8, reqs={SpecReq({Monk.MW}), LevelReq(24)}, mods={{mod=DispelMod(115450)}}, ignoreCast=true, version=103}, -- Detox
    {type="HEALING", id=322118, cd=180, reqs={SpecReq({Monk.MW}), NoTalentReq(325197), LevelReq(42)}, active=ActiveMod(nil, 25)}, -- Invoke Yu'lon, the Jade Serpent
    {type="HEALING", id=115310, cd=180, reqs={SpecReq({Monk.MW}), LevelReq(46)}}, -- Revival
    {type="EXTERNAL", id=116849, cd=120, reqs={SpecReq({Monk.MW}), LevelReq(27)}}, -- Life Cocoon
    ---- Monk.WW
    {type="PERSONAL", id=122470, cd=90, reqs={SpecReq({Monk.WW}), LevelReq(29)}}, -- Touch of Karma
    {type="DAMAGE", id=137639, cd=90, reqs={SpecReq({Monk.WW}), LevelReq(27), NoTalentReq(152173)}, mods={{reqs={LevelReq(47)}, mod=ChargesMod(2)}}}, -- Storm, Earth, and Fire
    {type="DAMAGE", id=123904, cd=120, reqs={SpecReq({Monk.WW}), LevelReq(42)}}, -- Invoke Xuen, the White Tiger
    {type="DAMAGE", id=113656, cd=24, reqs={SpecReq({Monk.WW}), LevelReq(12)}}, -- Fists of Fury
    ---- Talents
    {type="UTILITY", id=116841, cd=30, reqs={TalentReq(116841)}}, -- Tiger's Lust
    {type="TANK", id=115399, cd=120, reqs={TalentReq(115399)}}, -- Black Ox Brew
    {type="SOFTCC", id=198898, cd=30, reqs={TalentReq(198898)}}, -- Song of Chi-Ji
    {type="SOFTCC", id=116844, cd=45, reqs={TalentReq(116844)}, active=ActiveMod(nil, 5)}, -- Ring of Peace
    {type="PERSONAL", id=122783, cd=90, reqs={TalentReq(122783)}}, -- Diffuse Magic
    {type="PERSONAL", id=122278, cd=120, reqs={TalentReq(122278)}, active=ActiveMod(122278, 10)}, -- Dampen Harm
    {type="TANK", id=325153, cd=60, reqs={TalentReq(325153)}}, -- Exploding Keg
    {type="HEALING", id=325197, cd=120, reqs={TalentReq(325197)}, active=ActiveMod(nil, 25)}, -- Invoke Chi-Ji, the Red Crane
    {type="DAMAGE", id=152173, cd=90, reqs={TalentReq(152173)}}, -- Serenity
    ---- Covenants
    {type="COVENANT", id=310454, cd=120, reqs={ClassReq(Monk), CovenantReq("Kyrian")}, version=103}, -- Weapons of Order
    {type="COVENANT", id=326860, cd=180, reqs={ClassReq(Monk), CovenantReq("Venthyr")}, version=103}, -- Fallen Order
    {type="COVENANT", id=327104, cd=30, reqs={ClassReq(Monk), CovenantReq("NightFae")}, version=103}, -- Faeline Stomp
    {type="COVENANT", id=325216, cd=60, reqs={ClassReq(Monk), CovenantReq("Necrolord")}, version=103}, -- Bonedust Brew

    -- Paladin
    -- TODO: Prot should have Divine Protection from 28 to 41, then Ardent Defender from 42 onward
    ---- Base
    {type="IMMUNITY", id=642, cd=300, reqs={ClassReq(Paladin)}, mods={{reqs={TalentReq(114154)}, mod=MultiplyMod(0.7)}}, active=ActiveMod(642, 8)}, -- Divine Shield
    {type="STHARDCC", id=853, cd=60, reqs={ClassReq(Paladin), LevelReq(5)}, mods={{reqs={TalentReq(234299)}, mod=ResourceSpendingMods(Paladin, 2)}}}, -- Hammer of Justice
    {type="EXTERNAL", id=633, cd=600, reqs={ClassReq(Paladin), LevelReq(9)}, mods={{reqs={TalentReq(114154)}, mod=MultiplyMod(0.3)}}}, -- Lay on Hands
    {type="UTILITY", id=1044, cd=25, reqs={ClassReq(Paladin), LevelReq(22)}, version=101}, -- Blessing of Freedom
    {type="EXTERNAL", id=6940, cd=120, reqs={ClassReq(Paladin), LevelReq(32)}}, -- Blessing of Sacrifice
    {type="EXTERNAL", id=1022, cd=300, reqs={ClassReq(Paladin), LevelReq(41), NoTalentReq(204018)}}, -- Blessing of Protection
    ---- Shared
    {type="DISPEL", id=213644, cd=8, reqs={SpecReq({Paladin.Prot, Paladin.Ret}), LevelReq(12)}}, -- Cleanse Toxins
    {type="INTERRUPT", id=96231, cd=15, reqs={SpecReq({Paladin.Prot, Paladin.Ret}), LevelReq(23)}}, -- Rebuke
    {type="DAMAGE", id=31884, cd=180, reqs={SpecReq({Paladin.Prot, Paladin.Ret}), LevelReq(37), NoTalentReq(231895)}, mods={{reqs={LevelReq(49)}, mod=SubtractMod(60)}}}, -- Avenging Wrath
    ---- Paladin.Holy
    {type="DISPEL", id=4987, cd=8, reqs={SpecReq({Paladin.Holy}), LevelReq(12)}, mods={{mod=DispelMod(4987)}}, ignoreCast=true}, -- Cleanse
    {type="PERSONAL", id=498, cd=60, reqs={SpecReq({Paladin.Holy}), LevelReq(26)}, mods={{reqs={TalentReq(114154)}, mod=MultiplyMod(0.7)}}, active=ActiveMod(498, 8)}, -- Divine Protection
    {type="HEALING", id=31884, cd=180, reqs={SpecReq({Paladin.Holy}), LevelReq(37), NoTalentReq(216331)}, mods={{reqs={LevelReq(49)}, mod=SubtractMod(60)}}, active=ActiveMod(31884, 20)}, -- Avenging Wrath
    {type="RAIDCD", id=31821, cd=180, reqs={SpecReq({Paladin.Holy}), LevelReq(39)}, active=ActiveMod(31821, 6)}, -- Aura Mastery
    ---- Paladin.Prot
    {type="INTERRUPT", id=31935, cd=15, reqs={SpecReq({Paladin.Prot}), LevelReq(10)}}, -- Avenger's Shield
    {type="TANK", id=62124, cd=8, reqs={SpecReq({Paladin.Prot}), LevelReq(14)}, version=102}, -- Hand of Reckoning
    {type="TANK", id=86659, cd=300, reqs={SpecReq({Paladin.Prot}), LevelReq(39)}, active=ActiveMod(86659, 8)}, -- Guardian of Ancient Kings
    {type="TANK", id=31850, cd=120, reqs={SpecReq({Paladin.Prot}), LevelReq(42)}, mods={{reqs={TalentReq(114154)}, mod=MultiplyMod(0.7)}}, active=ActiveMod(31850, 8)}, -- Ardent Defender
    ---- Paladin.Ret
    {type="PERSONAL", id=184662, cd=120, reqs={SpecReq({Paladin.Ret}), LevelReq(26)}, mods={{reqs={TalentReq(114154)}, mod=MultiplyMod(0.7)}}}, -- Shield of Vengeance
    ---- Talents
    {type="STSOFTCC", id=20066, cd=15, reqs={TalentReq(20066)}}, -- Repentance
    {type="SOFTCC", id=115750, cd=90, reqs={TalentReq(115750)}}, -- Blinding Light
    {type="PERSONAL", id=205191, cd=60, reqs={TalentReq(205191)}, active=ActiveMod(205191, 10)}, -- Eye for an Eye
    {type="EXTERNAL", id=204018, cd=180, reqs={TalentReq(204018)}}, -- Blessing of Spellwarding
    {type="HEALING", id=105809, cd=180, reqs={TalentReq(105809), SpecReq({Paladin.Holy})}, active=ActiveMod(105809, 20)}, -- Holy Avenger
    {type="TANK", id=105809, cd=180, reqs={TalentReq(105809), SpecReq({Paladin.Prot})}}, -- Holy Avenger
    {type="DAMAGE", id=105809, cd=180, reqs={TalentReq(105809), SpecReq({Paladin.Ret})}}, -- Holy Avenger
    {type="HEALING", id=216331, cd=120, reqs={TalentReq(216331)}, active=ActiveMod(216331, 20)}, -- Avenging Crusader
    {type="DAMAGE", id=231895, cd=20, reqs={TalentReq(231895)}}, -- Crusade
    {type="DAMAGE", id=343721, cd=60, reqs={TalentReq(343721)}}, -- Final Reckoning
    {type="HEALING", id=200025, cd=15, reqs={TalentReq(200025)}}, -- Beacon of Virtue
    ---- Covenants
    {type="COVENANT", id=304971, cd=60, reqs={ClassReq(Paladin), CovenantReq("Kyrian")}, version=103}, -- Divine Toll
    {type="COVENANT", id=316958, cd=240, reqs={ClassReq(Paladin), CovenantReq("Venthyr")}, version=103}, -- Ashen Hallow
    ---- TODO: Blessing of Summer
    {type="COVENANT", id=328204, cd=30, reqs={ClassReq(Paladin), CovenantReq("Necrolord")}, version=103}, -- Vanquisher's Hammer

    -- Priest
    ---- Base
    {type="SOFTCC", id=8122, cd=60, reqs={ClassReq(Priest), LevelReq(7)}, mods={{reqs={TalentReq(196704)}, mod=SubtractMod(30)}}}, -- Psychic Scream
    {type="PERSONAL", id=19236, cd=90, reqs={ClassReq(Priest), LevelReq(8)}, active=ActiveMod(19236, 10)}, -- Desperate Prayer
    {type="DISPEL", id=32375, cd=45, reqs={ClassReq(Priest), LevelReq(42)}}, -- Mass Dispel
    {type="UTILITY", id=73325, cd=90, reqs={ClassReq(Priest), LevelReq(49)}}, -- Leap of Faith
    ---- Shared
    {type="DISPEL", id=527, cd=8, reqs={SpecReq({Priest.Disc, Priest.Holy}), LevelReq(18)}, mods={{mod=DispelMod(4987)}}, ignoreCast=true}, -- Purify
    {type="HEALING", id=10060, cd=120, reqs={SpecReq({Priest.Disc, Priest.Holy}), LevelReq(58)}}, -- Power Infusion
    ---- Priest.Disc
    {type="EXTERNAL", id=33206, cd=180, reqs={SpecReq({Priest.Disc}), LevelReq(38)}}, -- Pain Suppression
    {type="HEALING", id=47536, cd=90, reqs={SpecReq({Priest.Disc}), LevelReq(41), NoTalentReq(109964)}, active=ActiveMod(47536, 8)}, -- Rapture
    {type="RAIDCD", id=62618, cd=180, reqs={SpecReq({Priest.Disc}), LevelReq(44)}, active=ActiveMod(nil, 10)}, -- Power Word: Barrier
    ---- Priest.Holy
    {type="STSOFTCC", id=88625, cd=60, reqs={SpecReq({Priest.Holy}), LevelReq(23), NoTalentReq(200199)}, mods={{mod=CastDeltaMod(585, -4)}, {reqs={TalentReq(196985)}, mod=CastDeltaMod(585, -1.3333)}}}, -- Holy Word: Chastise
    {type="STHARDCC", id=88625, cd=60, reqs={SpecReq({Priest.Holy}), LevelReq(23), TalentReq(200199)}, mods={{mod=CastDeltaMod(585, -4)}, {reqs={TalentReq(196985)}, mod=CastDeltaMod(585, -1.3333)}}}, -- Holy Word: Chastise
    {type="EXTERNAL", id=47788, cd=180, reqs={SpecReq({Priest.Holy}), LevelReq(38)}, mods={{reqs={TalentReq(200209)}, mod=GuardianAngelMod}}}, -- Guardian Spirit
    {type="HEALING", id=64843, cd=180, reqs={SpecReq({Priest.Holy}), LevelReq(44)}}, -- Divine Hymn
    {type="UTILITY", id=64901, cd=300, reqs={SpecReq({Priest.Holy}), LevelReq(47)}}, -- Symbol of Hope
    ---- Priest.Shadow
    {type="PERSONAL", id=47585, cd=120, reqs={SpecReq({Priest.Shadow}), LevelReq(16)}, mods={{reqs={TalentReq(288733)}, mod=SubtractMod(30)}}, active=ActiveMod(47585, 6)}, -- Dispersion
    {type="DISPEL", id=213634, cd=8, reqs={SpecReq({Priest.Shadow}), LevelReq(18)}}, -- Purify Disease
    {type="DAMAGE", id=228260, cd=90, reqs={SpecReq({Priest.Shadow}), LevelReq(23)}}, -- Void Eruption
    {type="HEALING", id=15286, cd=120, reqs={SpecReq({Priest.Shadow}), LevelReq(38)}, mods={{reqs={TalentReq(199855)}, mod=SubtractMod(45)}}, active=ActiveMod(15286, 15)}, -- Vampiric Embrace
    {type="INTERRUPT", id=15487, cd=45, reqs={SpecReq({Priest.Shadow}), LevelReq(41)}, mods={{reqs={TalentReq(263716)}, mod=SubtractMod(15)}}}, -- Silence
    {type="DAMAGE", id=10060, cd=120, reqs={SpecReq({Priest.Shadow}), LevelReq(58)}}, -- Power Infusion
    ---- Talents
    {type="HARDCC", id=205369, cd=30, reqs={TalentReq(205369)}}, -- Mind Bomb
    {type="SOFTCC", id=204263, cd=45, reqs={TalentReq(204263)}}, -- Shining Force
    {type="STHARDCC", id=64044, cd=45, reqs={TalentReq(64044)}}, -- Psychic Horror
    {type="HEALING", id=109964, cd=60, reqs={TalentReq(109964)}, active=ActiveMod(109964, 10)}, -- Spirit Shell
    {type="HEALING", id=200183, cd=120, reqs={TalentReq(200183)}, active=ActiveMod(200183, 20)}, -- Apotheosis
    {type="HEALING", id=246287, cd=90, reqs={TalentReq(246287)}}, -- Evangelism
    {type="HEALING", id=265202, cd=720, reqs={TalentReq(265202)}, mods={{mod=CastDeltaMod(34861,-30)}, {mod=CastDeltaMod(2050,-30)}}}, -- Holy Word: Salvation
    {type="DAMAGE", id=319952, cd=90, reqs={TalentReq(319952)}}, -- Surrender to Madness
    ---- Covenants
    {type="COVENANT", id=325013, cd=180, reqs={ClassReq(Priest), CovenantReq("Kyrian")}, version=103}, -- Boon of the Ascended
    {type="COVENANT", id=323673, cd=45, reqs={ClassReq(Priest), CovenantReq("Venthyr")}, version=103}, -- Mindgames
    {type="COVENANT", id=327661, cd=90, reqs={ClassReq(Priest), CovenantReq("NightFae")}, version=103}, -- Fae Guardians
    {type="COVENANT", id=324724, cd=60, reqs={ClassReq(Priest), CovenantReq("Necrolord")}, version=103}, -- Unholy Nova

    -- Rogue
    ---- Base
    {type="UTILITY", id=57934, cd=30, reqs={ClassReq(Rogue), LevelReq(44)}}, -- Tricks of the Trade
    {type="UTILITY", id=114018, cd=360, reqs={ClassReq(Rogue), LevelReq(47)}, active=ActiveMod(114018, 15)}, -- Shroud of Concealment
    {type="UTILITY", id=1856, cd=120, reqs={ClassReq(Rogue), LevelReq(31)}}, -- Vanish
    {type="IMMUNITY", id=31224, cd=120, reqs={ClassReq(Rogue), LevelReq(49)}, active=ActiveMod(31224, 5)}, -- Cloak of Shadows
    {type="STHARDCC", id=408, cd=20, reqs={ClassReq(Rogue), LevelReq(20)}}, -- Kidney Shot
    {type="UTILITY", id=1725, cd=30, reqs={ClassReq(Rogue), LevelReq(36)}}, -- Distract
    {type="STSOFTCC", id=2094, cd=120, reqs={ClassReq(Rogue), LevelReq(41)}, mods={{reqs={TalentReq(256165)}, mod=SubtractMod(30)}}}, -- Blind
    {type="PERSONAL", id=5277, cd=120, reqs={ClassReq(Rogue), LevelReq(23)}, active=ActiveMod(5277, 10)}, -- Evasion
    {type="INTERRUPT", id=1766, cd=15, reqs={ClassReq(Rogue), LevelReq(6)}}, -- Kick
    {type="PERSONAL", id=185311, cd=30, reqs={ClassReq(Rogue), LevelReq(8)}}, -- Crimson Vial
    ---- Rogue.Sin
    {type="DAMAGE", id=79140, cd=120, reqs={SpecReq({Rogue.Sin}), LevelReq(34)}}, -- Vendetta
    ---- Rogue.Outlaw
    {type="DAMAGE", id=13877, cd=30, reqs={SpecReq({Rogue.Outlaw}), LevelReq(33)}, mods={{reqs={SpecReq({Rogue.Outlaw}), TalentReq(272026)}, mod=SubtractMod(-3)}}}, -- Blade Flurry
    {type="DAMAGE", id=13750, cd=180, reqs={SpecReq({Rogue.Outlaw}), LevelReq(34)}}, -- Adrenaline Rush
    {type="STSOFTCC", id=1776, cd=15, reqs={SpecReq({Rogue.Outlaw}), LevelReq(46)}, version=101}, -- Gouge
    ---- Rogue.Sub
    {type="DAMAGE", id=121471, cd=180, reqs={SpecReq({Rogue.Sub}), LevelReq(34)}}, -- Shadow Blades
    ---- Talents
    {type="DAMAGE", id=343142, cd=90, reqs={TalentReq(343142)}}, -- Dreadblades
    {type="DAMAGE", id=271877, cd=45, reqs={TalentReq(271877)}}, -- Blade Rush
    {type="DAMAGE", id=51690, cd=120, reqs={TalentReq(51690)}}, -- Killing Spree
    {type="DAMAGE", id=277925, cd=60, reqs={TalentReq(277925)}}, -- Shuriken Tornado
    ---- Covenants
    {type="COVENANT", id=323547, cd=45, reqs={ClassReq(Rogue), CovenantReq("Kyrian")}, version=103}, -- Echoing Reprimand
    {type="COVENANT", id=323654, cd=90, reqs={ClassReq(Rogue), CovenantReq("Venthyr")}, version=103}, -- Flagellation
    {type="COVENANT", id=328305, cd=90, reqs={ClassReq(Rogue), CovenantReq("NightFae")}, version=103}, -- Sepsis
    {type="COVENANT", id=328547, cd=30, reqs={ClassReq(Rogue), CovenantReq("Necrolord")}, charges=3, version=103}, -- Serrated Bone Spike

    -- Shaman
    -- TODO: Add support for Reincarnation
    ---- Base
    {type="INTERRUPT", id=57994, cd=12, reqs={ClassReq(Shaman), LevelReq(12)}}, -- Wind Shear
    {type="HARDCC", id=192058, cd=60, reqs={ClassReq(Shaman), LevelReq(23)}, mods={{reqs={TalentReq(265046)}, mod=StaticChargeMod}}}, -- Capacitor Totem
    {type="UTILITY", id=198103, cd=300, reqs={ClassReq(Shaman), LevelReq(37)}}, -- Earth Elemental
    {type="STSOFTCC", id=51514, cd=30, reqs={ClassReq(Shaman), LevelReq(41)}, mods={{reqs={LevelReq(56)}, mod=SubtractMod(10)}}}, -- Hex
    {type="PERSONAL", id=108271, cd=90, reqs={ClassReq(Shaman), LevelReq(42)}, active=ActiveMod(108271, 8)}, -- Astral Shift
    {type="DISPEL", id=8143, cd=60, reqs={ClassReq(Shaman), LevelReq(47)}, active=ActiveMod(nil, 10)}, -- Tremor Totem
    ---- Shared
    {type="DISPEL", id=51886, cd=8, reqs={SpecReq({Shaman.Ele, Shaman.Enh}), LevelReq(18)}, mods={{mod=DispelMod(51886)}}, ignoreCast=true}, -- Cleanse Spirit
    {type="UTILITY", id=79206, cd=120, reqs={SpecReq({Shaman.Ele, Shaman.Resto}), LevelReq(44)}, mods={{reqs={TalentReq(192088)}, mod=SubtractMod(60)}}}, -- Spiritwalker's Grace
    ---- Shaman.Ele
    {type="DAMAGE", id=198067, cd=150, reqs={SpecReq({Shaman.Ele}), LevelReq(34), NoTalentReq(192249)}}, -- Fire Elemental
    ---- Shaman.Enh
    {type="DAMAGE", id=51533, cd=120, reqs={SpecReq({Shaman.Enh}), LevelReq(34)}, mods={{reqs={SpecReq({Shaman.Enh}), TalentReq(262624)}, mod=SubtractMod(30)}}}, -- Feral Spirit
    ---- Shaman.Resto
    {type="DISPEL", id=77130, cd=8, reqs={SpecReq({Shaman.Resto}), LevelReq(18)}, mods={{mod=DispelMod(77130)}}, ignoreCast=true}, -- Purify Spirit
    {type="UTILITY", id=16191, cd=180, reqs={SpecReq({Shaman.Resto}), LevelReq(38)}}, -- Mana Tide Totem
    {type="RAIDCD", id=98008, cd=180, reqs={SpecReq({Shaman.Resto}), LevelReq(43)}, active=ActiveMod(nil, 6), version=101}, -- Spirit Link Totem
    {type="HEALING", id=108280, cd=180, reqs={SpecReq({Shaman.Resto}), LevelReq(49)}}, -- Healing Tide Totem
    ---- Talents
    {type="SOFTCC", id=51485, cd=30, reqs={TalentReq(51485)}}, -- Earthgrab Totem
    {type="HEALING", id=198838, cd=60, reqs={TalentReq(198838)}}, -- Earthen Wall Totem
    {type="DAMAGE", id=192249, cd=150, reqs={TalentReq(192249)}}, -- Fire Elemental
    {type="EXTERNAL", id=207399, cd=300, reqs={TalentReq(207399)}}, -- Ancestral Protection Totem
    {type="HEALING", id=108281, cd=120, reqs={TalentReq(108281)}, active=ActiveMod(108281, 10)}, -- Ancestral Guidance
    {type="UTILITY", id=192077, cd=120, reqs={TalentReq(192077)}}, -- Wind Rush Totem
    {type="DAMAGE", id=191634, cd=60, reqs={TalentReq(191634)}}, -- Stormkeeper
    {type="HEALING", id=114052, cd=180, reqs={TalentReq(114052)}, active=ActiveMod(264735, 10)}, -- Ascendance
    {type="DAMAGE", id=114050, cd=180, reqs={TalentReq(114050)}}, -- Ascendance
    {type="DAMAGE", id=114051, cd=180, reqs={TalentReq(114051)}}, -- Ascendance
    ---- Covenants
    {type="COVENANT", id=324386, cd=60, reqs={ClassReq(Shaman), CovenantReq("Kyrian")}, version=103}, -- Vesper Totem
    {type="COVENANT", id=320674, cd=90, reqs={ClassReq(Shaman), CovenantReq("Venthyr")}, version=103}, -- Chain Harvest
    {type="COVENANT", id=328923, cd=120, reqs={ClassReq(Shaman), CovenantReq("NightFae")}, version=103}, -- Fae Transfusion
    {type="COVENANT", id=326059, cd=45, reqs={ClassReq(Shaman), CovenantReq("Necrolord")}, version=103}, -- Primordial Wave

    -- Warlock
    -- TODO: Soulstone (Brez Support)
    -- TODO: PetReq for Spell Lock and Axe Toss
    ---- Base
    {type="PERSONAL", id=104773, cd=180, reqs={ClassReq(Warlock), LevelReq(4)}, active=ActiveMod(104773, 8)}, -- Unending Resolve
    {type="UTILITY", id=333889, cd=180, reqs={ClassReq(Warlock), LevelReq(22)}}, -- Fel Domination
    {type="BREZ", id=20707, cd=600, reqs={ClassReq(Warlock), LevelReq(48)}}, -- Soulstone
    {type="HARDCC", id=30283, cd=60, reqs={ClassReq(Warlock), LevelReq(38)}, mods={{reqs={TalentReq(264874)}, mod=SubtractMod(15)}}}, -- Shadowfury
    ---- Shared
    {type="INTERRUPT", id=19647, cd=24, reqs={SpecReq({Warlock.Affl, Warlock.Destro}), LevelReq(29)}}, -- Spell Lock
    ---- Warlock.Affl
    {type="DAMAGE", id=205180, cd=180, reqs={SpecReq({Warlock.Affl}), LevelReq(42)}, mods={{reqs={TalentReq(334183)}, mod=SubtractMod(60)}}}, -- Summon Darkglare
    ---- Warlock.Demo
    {type="INTERRUPT", id=89766, cd=30, reqs={SpecReq({Warlock.Demo}), LevelReq(29)}}, -- Axe Toss
    {type="DAMAGE", id=265187, cd=90, reqs={SpecReq({Warlock.Demo}), LevelReq(42)}}, -- Summon Demonic Tyrant
    ---- Warlock.Destro
    {type="DAMAGE", id=1122, cd=180, reqs={SpecReq({Warlock.Destro}), LevelReq(42)}}, -- Summon Infernal
    ---- Talents
    {type="PERSONAL", id=108416, cd=60, reqs={TalentReq(108416)}}, -- Dark Pact
    {type="DAMAGE", id=152108, cd=30, reqs={TalentReq(152108)}}, -- Cataclysm
    {type="STHARDCC", id=6789, cd=45, reqs={TalentReq(6789)}}, -- Mortal Coil
    {type="SOFTCC", id=5484, cd=40, reqs={TalentReq(5484)}}, -- Howl of Terror
    {type="DAMAGE", id=111898, cd=120, reqs={TalentReq(111898)}}, -- Grimoire: Felguard
    {type="DAMAGE", id=113858, cd=120, reqs={TalentReq(113858)}}, -- Dark Soul: Instability
    {type="DAMAGE", id=267217, cd=180, reqs={TalentReq(267217)}}, -- Nether Portal
    {type="DAMAGE", id=113860, cd=120, reqs={TalentReq(113860)}}, -- Dark Soul: Misery
    ---- Covenants
    {type="COVENANT", id=312321, cd=40, reqs={ClassReq(Warlock), CovenantReq("Kyrian")}, version=103}, -- Scouring Tithe
    {type="COVENANT", id=321792, cd=60, reqs={ClassReq(Warlock), CovenantReq("Venthyr")}, version=103}, -- Impending Catastrophe
    {type="COVENANT", id=325640, cd=60, reqs={ClassReq(Warlock), CovenantReq("NightFae")}, version=103}, -- Soul Rot
    {type="COVENANT", id=325289, cd=45, reqs={ClassReq(Warlock), CovenantReq("Necrolord")}, version=103}, -- Decimating Bolt

    -- Warrior
    ---- Base
    {type="INTERRUPT", id=6552, cd=15, reqs={ClassReq(Warrior), LevelReq(7)}}, -- Pummel
    {type="TANK", id=355, cd=8, reqs={ClassReq(Warrior), LevelReq(14)}}, -- Taunt
    {type="SOFTCC", id=5246, cd=90, reqs={ClassReq(Warrior), LevelReq(34)}}, -- Intimidating Shout
    {type="UTILITY", id=64382, cd=180, reqs={ClassReq(Warrior), LevelReq(41)}}, -- Shattering Throw
    {type="EXTERNAL", id=3411, cd=30, reqs={ClassReq(Warrior), LevelReq(43)}}, -- Intervene
    {type="RAIDCD", id=97462, cd=180, reqs={ClassReq(Warrior), LevelReq(46)}, active=ActiveMod(97462, 10)}, -- Rallying Cry
    {type="TANK", id=1161, cd=240, reqs={ClassReq(Warrior), LevelReq(54)}}, -- Challenging Shout
    ---- Shared
    {type="PERSONAL", id=23920, cd=25, reqs={SpecReq({Warrior.Arms, Warrior.Fury}), LevelReq(47)}, active=ActiveMod(23920, 5)}, -- Spell Reflection
    ---- Warrior.Arms
    {type="PERSONAL", id=118038, cd=180, reqs={SpecReq({Warrior.Arms}), LevelReq(23)}, mods={{reqs={LevelReq(52)}, mod=SubtractMod(60)}}, active=ActiveMod(118038, 8)}, -- Die by the Sword
    {type="DAMAGE", id=227847, cd=90, reqs={SpecReq({Warrior.Arms}), LevelReq(38)}, mods={{reqs={TalentReq(152278)}, mod=ResourceSpendingMods(Warrior.Arms, 0.05)}}}, -- Bladestorm
    ---- Warrior.Fury
    {type="PERSONAL", id=184364, cd=180, reqs={SpecReq({Warrior.Fury}), LevelReq(23)}, mods={{reqs={LevelReq(32)}, mod=SubtractMod(60)}}, active=ActiveMod(184364, 8)}, -- Enraged Regeneration
    {type="DAMAGE", id=1719, cd=90, reqs={SpecReq({Warrior.Fury}), LevelReq(38)}, mods={{reqs={TalentReq(152278)}, mod=ResourceSpendingMods(Warrior.Fury, 0.05)}}}, -- Recklessness
    ---- Warrior.Prot
    {type="HARDCC", id=46968, cd=40, reqs={SpecReq({Warrior.Prot}), LevelReq(21)}, mods={{reqs={TalentReq(275339)}, mod=RumblingEarthMod}}}, -- Shockwave
    {type="TANK", id=871, cd=240, reqs={SpecReq({Warrior.Prot}), LevelReq(23)}, mods={{reqs={TalentReq(152278)}, mod=ResourceSpendingMods(Warrior.Arms, 0.1)}}, active=ActiveMod(871, 8)}, -- Shield Wall
    {type="TANK", id=1160, cd=45, reqs={SpecReq({Warrior.Prot}), LevelReq(27)}}, -- Demoralizing Shout
    {type="DAMAGE", id=107574, cd=90, reqs={SpecReq({Warrior.Prot}), LevelReq(32)}, mods={{reqs={TalentReq(152278)}, mod=ResourceSpendingMods(Warrior.Prot, 0.1)}}}, -- Avatar
    {type="TANK", id=12975, cd=180, reqs={SpecReq({Warrior.Prot}), LevelReq(38)}, mods={{reqs={TalentReq(280001)}, mod=SubtractMod(60)}}, active=ActiveMod(12975, 15)}, -- Last Stand
    {type="PERSONAL", id=23920, cd=25, reqs={SpecReq({Warrior.Prot}), LevelReq(47)}, active=ActiveMod(23920, 5)}, -- Spell Reflection
    ---- Talents
    {type="STHARDCC", id=107570, cd=30, reqs={TalentReq(107570)}}, -- Storm Bolt
    {type="DAMAGE", id=107574, cd=90, reqs={TalentReq(107574)}}, -- Avatar
    {type="DAMAGE", id=262228, cd=60, reqs={TalentReq(262228)}}, -- Deadly Calm
    {type="DAMAGE", id=228920, cd=45, reqs={TalentReq(228920)}}, -- Ravager
    {type="DAMAGE", id=46924, cd=60, reqs={TalentReq(46924)}}, -- Bladestorm
    {type="DAMAGE", id=152277, cd=45, reqs={TalentReq(152277)}}, -- Ravager
    {type="DAMAGE", id=280772, cd=30, reqs={TalentReq(280772)}}, -- Siegebreaker
    ---- Covenants
    {type="COVENANT", id=307865, cd=60, reqs={ClassReq(Warrior), CovenantReq("Kyrian")}, version=103}, -- Spear of Bastion
    {type="COVENANT", id=325886, cd=90, reqs={ClassReq(Warrior), CovenantReq("NightFae")}, version=103}, -- Ancient Aftershock
    {type="COVENANT", id=324143, cd=180, reqs={ClassReq(Warrior), CovenantReq("Necrolord")}, version=103}, -- Conqueror's Banner
}

ZT.linkedSpellIDs = {
	[19647]  = {119910, 132409, 115781}, -- Spell Lock
    [89766]  = {119914, 347008}, -- Axe Toss
    [51514]  = {211004, 211015, 277778, 309328, 210873, 211010, 269352, 277784}, -- Hex
	[132469] = {61391}, -- Typhoon
	[191427] = {200166}, -- Metamorphosis
	[106898] = {77761, 77764}, -- Stampeding Roar
	[86659] = {212641}, -- Guardian of the Ancient Kings (+Glyph)
    [281195] = {264735}, -- Survival of the Fittest (+Lone Wolf)
}

ZT.separateLinkedSpellIDs = {
	[86659] = {212641}, -- Guardian of the Ancient Kings (+Glyph)
}

--##############################################################################
-- Handling custom spells specified by the user in the configuration

local spellConfigPrefix = "return function(DH,DK,Druid,Hunter,Mage,Monk,Paladin,Priest,Rogue,Shaman,Warlock,Warrior,LevelReq,RaceReq,ClassReq,SpecReq,TalentReq,NoTalentReq,SubtractMod,MultiplyMod,ChargesMod,DynamicMod,EventDeltaMod,CastDeltaMod,EventRemainingMod,CastRemainingMod,DispelMod) return "
local spellConfigSuffix = "end"

local function trim(s) -- From PiL2 20.4
    if s ~= nil then
        return s:gsub("^%s*(.-)%s*$", "%1")
    end
    return ""
end

local function addCustomSpell(spellConfig, i)
	if not spellConfig or type(spellConfig) ~= "table" then
		prerror("Custom Spell", i, "is not represented as a valid table")
		return
	end

	if type(spellConfig.type) ~= "string" then
		prerror("Custom Spell", i, "does not have a valid 'type' entry")
		return
	end

    if type(spellConfig.id) ~= "number" then
        prerror("Custom Spell", i, "does not have a valid 'id' entry")
		return
	end

    if type(spellConfig.cd) ~= "number" then
        prerror("Custom Spell", i, "does not have a valid 'cd' entry")
		return
	end

	spellConfig.version = 10000
	spellConfig.isCustom = true

    ZT.spellList[#ZT.spellList + 1] = spellConfig
end
--[[
for i = 1,16 do
    local spellConfig = trim(ZT.config["custom"..i])
		if spellConfig ~= "" then
        local spellConfigFunc = WeakAuras.LoadFunction(spellConfigPrefix..spellConfig..spellConfigSuffix, "ZenTracker Custom Spell "..i)
			if spellConfigFunc then
            local spell = spellConfigFunc(DH,DK,Druid,Hunter,Mage,Monk,Paladin,Priest,Rogue,Shaman,Warlock,Warrior,LevelReq,RaceReq,ClassReq,SpecReq,TalentReq,NoTalentReq,SubtractMod,MultiplyMod,ChargesMod,DynamicMod,EventDeltaMod,CastDeltaMod,EventRemainingMod,CastRemainingMod,DispelMod)
            addCustomSpell(spell, i)
			end
		end
	end
--]]

--##############################################################################
-- Compiling the complete indexed tables of spells

ZT.spells = DefaultTable_Create(function() return DefaultTable_Create(function() return {} end) end)

-- Building a complete list of tracked spells
function ZT:BuildSpellList()
	for _,spellInfo in ipairs(ZT.spellList) do
		spellInfo.version = spellInfo.version or 100
		spellInfo.isRegistered = false
		spellInfo.frontends = {}

		-- Indexing for faster lookups based on the info/requirements
		if spellInfo.reqs and (#spellInfo.reqs > 0) then
			for _,req in ipairs(spellInfo.reqs) do
				if req.indices then
					for _,index in ipairs(req.indices) do
						tinsert(ZT.spells[req.type][index], spellInfo)
					end
				end
			end
		else
			tinsert(ZT.spells["generic"], spellInfo)
		end

		if spellInfo.mods then
			for _,mod in ipairs(spellInfo.mods) do
				if mod.reqs then
					for _,req in ipairs(mod.reqs) do
						for _,index in ipairs(req.indices) do
							tinsert(ZT.spells[req.type][index], spellInfo)
						end
					end
				end
			end
		end

		tinsert(ZT.spells["type"][spellInfo.type], spellInfo)
		tinsert(ZT.spells["id"][spellInfo.id], spellInfo)

		-- Handling more convenient way of specifying active durations
		if spellInfo.active then
			local spellID = spellInfo.active.spellID
			local duration = spellInfo.active.duration

			spellInfo.duration = duration
			if spellID then
				if not spellInfo.mods then
					spellInfo.mods = {}
				end
				tinsert(spellInfo.mods, {mod=DurationMod(spellID)})
			end
		end
	end
end

--##############################################################################
-- Handling combatlog and WeakAura events by invoking specified callbacks

ZT.eventHandlers = { handlers = {} }

function ZT.eventHandlers:add(type, spellID, sourceGUID, func, data)
	local types = self.handlers[spellID]
	if not types then
		types = {}
		self.handlers[spellID] = types
	end

	local sources = types[type]
	if not sources then
		sources = {}
		types[type] = sources
	end

	local handlers = sources[sourceGUID]
	if not handlers then
		handlers = {}
		sources[sourceGUID] = handlers
	end

	handlers[func] = data
end

function ZT.eventHandlers:remove(type, spellID, sourceGUID, func)
	local types = self.handlers[spellID]
	if types then
		local sources = types[type]
		if sources then
			local handlers = sources[sourceGUID]
			if handlers then
				handlers[func] = nil
			end
		end
	end
end

function ZT.eventHandlers:removeAll(sourceGUID)
	for _,spells in pairs(self.eventHandlers) do
		for _,sources in pairs(spells) do
			for GUID,handlers in pairs(sources) do
				if GUID == sourceGUID then
					wipe(handlers)
				end
			end
		end
	end
end

local function fixSourceGUID(sourceGUID) -- Based on https://wago.io/p/Nnogga
	local type = strsplit("-",sourceGUID)
	if type == "Pet" then
		for unit in IterateGroupMembers() do
			if UnitGUID(unit.."pet") == sourceGUID then
				sourceGUID = UnitGUID(unit)
				break
			end
		end
	end

	return sourceGUID
end

function ZT.eventHandlers:handle(type, spellID, sourceGUID)
	local types = self.handlers[spellID]
	if not types then
		return
	end

	local sources = types[type]
	if not sources then
		return
	end

	local handlers = sources[sourceGUID]
	if not handlers then
		sourceGUID = fixSourceGUID(sourceGUID)
		handlers = sources[sourceGUID]
		if not handlers then
			return
		end
	end

	for func,data in pairs(handlers) do
		func(data, spellID)
	end
end

--##############################################################################
-- Managing timer callbacks in a way that allows for updates/removals

ZT.timers = { heap={}, callbackTimes={} }

function ZT.timers:fixHeapUpwards(index)
	local heap = self.heap
	local timer = heap[index]

	local parentIndex, parentTimer
	while index > 1 do
		parentIndex = floor(index / 2)
		parentTimer = heap[parentIndex]
		if timer.time >= parentTimer.time then
			break
		end

		parentTimer.index = index
		heap[index] = parentTimer
		index = parentIndex
	end

	if timer.index ~= index then
		timer.index = index
		heap[index] = timer
	end
end

function ZT.timers:fixHeapDownwards(index)
	local heap = self.heap
	local timer = heap[index]

	local childIndex, minChildTimer, leftChildTimer, rightChildTimer
	while true do
		childIndex = 2 * index

		leftChildTimer = heap[childIndex]
		if leftChildTimer then
			rightChildTimer = heap[childIndex + 1]
			if rightChildTimer and (rightChildTimer.time < leftChildTimer.time) then
				minChildTimer = rightChildTimer
			else
				minChildTimer = leftChildTimer
			end
		else
			break
		end

		if timer.time <= minChildTimer.time then
			break
		end

		childIndex = minChildTimer.index
		minChildTimer.index = index
		heap[index] = minChildTimer
		index = childIndex
	end

	if timer.index ~= index then
		timer.index = index
		heap[index] = timer
	end
end

function ZT.timers:setupCallback()
	local minTimer = self.heap[1]
	if minTimer then
		local timeNow = GetTime()
		local remaining = minTimer.time - timeNow
		if remaining <= 0 then
			self:handle()
		elseif not self.callbackTimes[minTimer.time] then
			for time,_ in pairs(self.callbackTimes) do
				if time < timeNow then
					self.callbackTimes[time] = nil
				end
			end
			self.callbackTimes[minTimer.time] = true

			-- Note: This 0.001 avoids early callbacks that I ran into
			remaining = remaining + 0.001
			prdebug(DEBUG_TIMER, "Setting callback for handling timers after", remaining, "seconds")
			C_Timer.After(remaining, function() self:handle() end)
		end
	end
end

function ZT.timers:handle()
	local timeNow = GetTime()
	local heap = self.heap
	local minTimer = heap[1]

	prdebug(DEBUG_TIMER, "Handling timers at time", timeNow, "( Min @", minTimer and minTimer.time or "NONE", ")")
	while minTimer and minTimer.time <= timeNow do
		local heapSize = #heap
		if heapSize > 1 then
			heap[1] = heap[heapSize]
			heap[1].index = 1
			heap[heapSize] = nil
			self:fixHeapDownwards(1)
		else
			heap[1] = nil
		end

		minTimer.index = -1
		minTimer.callback()

		minTimer = heap[1]
	end

	self:setupCallback()
end

function ZT.timers:add(time, callback)
	local heap = self.heap

	local index = #heap + 1
	local timer = {time=time, callback=callback, index=index}
	heap[index] = timer

	self:fixHeapUpwards(index)
	self:setupCallback()

	return timer
end

function ZT.timers:cancel(timer)
	local index = timer.index
	if index == -1 then
		return
	end

	timer.index = -1

	local heap = self.heap
	local heapSize = #heap
	if heapSize ~= index then
		heap[index] = heap[heapSize]
		heap[index].index = index
		heap[heapSize] = nil
		self:fixHeapDownwards(index)
		self:setupCallback()
	else
		heap[index] = nil
	end
end

function ZT.timers:update(timer, time)
	local fixHeapFunc = (time <= timer.time) and self.fixHeapUpwards or self.fixHeapDownwards
	timer.time = time

	fixHeapFunc(self, timer.index)
	self:setupCallback()
end

--##############################################################################
-- Managing the set of spells that are being watched

local WatchInfo = { nextID = 1 }
local WatchInfoMT = { __index = WatchInfo }

ZT.watching = {}

function WatchInfo:create(member, spellInfo, isHidden)
    local time = GetTime()
	local watchInfo = {
        id = self.nextID,
		member = member,
		spellInfo = spellInfo,
        duration = spellInfo.cd,
        expiration = time,
        activeDuration = spellInfo.active and spellInfo.active.duration or nil,
        activeExpiration = time,
		charges = spellInfo.charges,
        maxCharges = spellInfo.charges,
		isHidden = isHidden,
		isLazy = spellInfo.isLazy,
		ignoreSharing = false,
	}
	self.nextID = self.nextID + 1

	watchInfo = setmetatable(watchInfo, WatchInfoMT)
    watchInfo:updateModifiers()

	return watchInfo
end

function WatchInfo:updateModifiers()
    if not self.spellInfo.mods then
        return
    end

    self.duration = self.spellInfo.cd
    self.charges = self.spellInfo.charges
    self.maxCharges = self.spellInfo.charges

    for _,modifier in ipairs(self.spellInfo.mods) do
        if modifier.mod.type == "Static" then
            if self.member:checkRequirements(modifier.reqs) then
                modifier.mod.func(self)
            end
        end
    end
end

function WatchInfo:sendAddEvent()
	if not self.isLazy and not self.isHidden then
		local spellInfo = self.spellInfo
        prdebug(DEBUG_EVENT, "Sending ZT_ADD", spellInfo.type, self.id, self.member.name, spellInfo.id, self.duration, self.charges)
        WeakAuras.ScanEvents("ZT_ADD", spellInfo.type, self.id, self.member, spellInfo.id, self.duration, self.charges)

		if self.expiration > GetTime() then
			self:sendTriggerEvent()
		end
	end
end

function WatchInfo:sendTriggerEvent()
	if self.isLazy then
		self.isLazy = false
		self:sendAddEvent()
	end

	if not self.isHidden then
        prdebug(DEBUG_EVENT, "Sending ZT_TRIGGER", self.spellInfo.type, self.id, self.duration, self.expiration, self.charges, self.activeDuration, self.activeExpiration)
        WeakAuras.ScanEvents("ZT_TRIGGER", self.spellInfo.type, self.id, self.duration, self.expiration, self.charges, self.activeDuration, self.activeExpiration)
	end
end

function WatchInfo:sendRemoveEvent()
	if not self.isLazy and not self.isHidden then
        prdebug(DEBUG_EVENT, "Sending ZT_REMOVE", self.spellInfo.type, self.id)
        WeakAuras.ScanEvents("ZT_REMOVE", self.spellInfo.type, self.id)
	end
end

function WatchInfo:hide()
	if not self.isHidden then
		self:sendRemoveEvent()
		self.isHidden = true
	end
end

function WatchInfo:unhide(suppressAddEvent)
	if self.isHidden then
		self.isHidden = false
		if not suppressAddEvent then
			self:sendAddEvent()
		end
	end
end

function WatchInfo:toggleHidden(toggle, suppressAddEvent)
	if toggle then
		self:hide()
	else
		self:unhide(suppressAddEvent)
	end
end

function WatchInfo:handleReadyTimer()
	if self.charges then
		self.charges = self.charges + 1

		-- If we are not at max charges, update expiration and start a ready timer
        if self.charges < self.maxCharges then
			self.expiration = self.expiration + self.duration
            prdebug(DEBUG_TIMER, "Adding ready timer of", self.expiration, "for spellID", self.spellInfo.id)
			self.readyTimer = ZT.timers:add(self.expiration, function() self:handleReadyTimer() end)
		else
			self.readyTimer = nil
		end
	else
		self.readyTimer = nil
	end

	self:sendTriggerEvent()
end

function WatchInfo:updateReadyTimer() -- Returns true if a timer was set, false if handled immediately
	if self.expiration > GetTime() then
		if self.readyTimer then
            prdebug(DEBUG_TIMER, "Updating ready timer from", self.readyTimer.time, "to", self.expiration, "for spellID", self.spellInfo.id)
			ZT.timers:update(self.readyTimer, self.expiration)
		else
            prdebug(DEBUG_TIMER, "Adding ready timer of", self.expiration, "for spellID", self.spellInfo.id)
			self.readyTimer = ZT.timers:add(self.expiration, function() self:handleReadyTimer() end)
		end

		return true
	else
		if self.readyTimer then
            prdebug(DEBUG_TIMER, "Canceling ready timer for spellID", self.spellInfo.id)
			ZT.timers:cancel(self.readyTimer)
			self.readyTimer = nil
		end

		self:handleReadyTimer(self.expiration)
		return false
	end
end

function WatchInfo:handleActiveTimer()
    self.activeTimer = nil
    self:sendTriggerEvent()
    if self.member.isPlayer then
        ZT:sendCDUpdate(self, true)
    end
end

function WatchInfo:updateActiveTimer() -- Returns true if a timer was set, false if handled immediately
    if self.activeExpiration > GetTime() then
        if self.activeTimer then
            prdebug(DEBUG_TIMER, "Updating active timer from", self.activeTimer.time, "to", self.activeExpiration, "for spellID", self.spellInfo.id)
            ZT.timers:update(self.activeTimer, self.activeExpiration)
        else
            prdebug(DEBUG_TIMER, "Adding active timer of", self.expiration, "for spellID", self.spellInfo.id)
            self.activeTimer = ZT.timers:add(self.activeExpiration, function() self:handleActiveTimer() end)
        end

        return true
    else
        if self.activeTimer then
            prdebug(DEBUG_TIMER, "Canceling active timer for spellID", self.spellInfo.id)
            ZT.timers:cancel(self.activeTimer)
            self.activeTimer = nil
        end

        self:handleActiveTimer()
        return false
    end
end

local function GetActiveInfo(member, activeSpellID)
    for a=1,40 do
        local name,_,_,_,duration,expirationTime,_,_,_,spellID = UnitAura(member.unit, a)
        if spellID == activeSpellID then
            return duration, expirationTime
        elseif not name then
            return
        end
    end
end

function WatchInfo:updateActive(time)
    local active = self.spellInfo.active
    if not active then
        return
    end

    if not time then
        time = GetTime()
    end

    local activeSpellID = active.spellID
    local activeDefaultDuration = active.duration

    if activeSpellID then
        self.activeDuration, self.activeExpiration = GetActiveInfo(self.member, activeSpellID)
    else
        self.activeDuration = activeDefaultDuration
        self.activeExpiration = time + activeDefaultDuration
        self:updateActiveTimer()
    end
end

function WatchInfo:startCD()
    local time = GetTime()

	if self.charges then
        if self.charges == 0 or self.charges == self.maxCharges then
            self.expiration = time + self.duration
			self:updateReadyTimer()
		end

		if self.charges > 0 then
			self.charges = self.charges - 1
		end
	else
        self.expiration = time + self.duration
		self:updateReadyTimer()
	end

    self:updateActive(time)
	self:sendTriggerEvent()
end

function WatchInfo:updateCDDelta(delta)
	self.expiration = self.expiration + delta

	local time = GetTime()
	local remaining = self.expiration - time

	if self.charges and remaining <= 0 then
		local chargesGained = 1 - floor(remaining / self.duration)
        self.charges = max(self.charges + chargesGained, self.maxCharges)
        if self.charges == self.maxCharges then
			self.expiration = time
		else
			self.expiration = self.expiration + (chargesGained * self.duration)
		end
	end

	if self:updateReadyTimer() then
		self:sendTriggerEvent()
	end
end

function WatchInfo:updateCDRemaining(remaining)
	-- Note: This assumes that when remaining is 0 and the spell uses charges then it gains a charge
	if self.charges and remaining == 0 then
        if self.charges < self.maxCharges then
			self.charges = self.charges + 1
		end

		-- Below maximum charges the expiration time doesn't change
        if self.charges < self.maxCharges then
			self:sendTriggerEvent()
		else
			self.expiration = GetTime()
			self:updateReadyTimer()
		end
	else
		self.expiration = GetTime() + remaining
		if self:updateReadyTimer() then
			self:sendTriggerEvent()
		end
	end
end

function WatchInfo:updatePlayerCharges()
    local charges, maxCharges = GetSpellCharges(self.spellInfo.id)
	if charges then
		self.charges = charges
        self.maxCharges = maxCharges
	end
end

function WatchInfo:updatePlayerCD(spellID, ignoreIfReady)
    local startTime, duration, enabled, charges, chargesUsed
	if self.charges then
        charges, self.maxCharges, startTime, duration = GetSpellCharges(spellID)
        if charges == self.maxCharges then
			startTime = 0
		end
        chargesUsed = self.charges > charges
        self.charges = charges
		enabled = 1
	else
		startTime, duration, enabled = GetSpellCooldown(spellID)
        chargesUsed = false
	end

	if enabled ~= 0 then
        local time = GetTime()
		local ignoreRateLimit
		if startTime ~= 0 then
            if (self.expiration <= time) or chargesUsed then
                ignoreRateLimit = true
                self:updateActive(time)
            end

			self.duration = duration
			self.expiration = startTime + duration
		else
			ignoreRateLimit = true
            self.expiration = time
		end

		if (not ignoreIfReady) or (startTime ~= 0) then
			ZT:sendCDUpdate(self, ignoreRateLimit)
			self:sendTriggerEvent()
		end
	end
end

function ZT:togglePlayerHandlers(watchInfo, enable)
    local spellInfo = watchInfo.spellInfo
    local spellID = spellInfo.id
    local member = watchInfo.member
	local toggleHandlerFunc = enable and self.eventHandlers.add or self.eventHandlers.remove

	if enable then
		WeakAuras.WatchSpellCooldown(spellID)
	end
	toggleHandlerFunc(self.eventHandlers, "SPELL_COOLDOWN_CHANGED", spellID, 0, watchInfo.updatePlayerCD, watchInfo)

	local links = self.separateLinkedSpellIDs[spellID]
	if links then
		for _,linkedSpellID in ipairs(links) do
			if enable then
				WeakAuras.WatchSpellCooldown(linkedSpellID)
			end
			toggleHandlerFunc(self.eventHandlers, "SPELL_COOLDOWN_CHANGED", linkedSpellID, 0, watchInfo.updatePlayerCD, watchInfo)
		end
	end

    -- Handling any dynamic modifiers that are always required (with the 'force' tag)
    if spellInfo.mods then
        for _,modifier in ipairs(spellInfo.mods) do
            if modifier.mod.type == "Dynamic" then
                if not enable or member:checkRequirements(modifier.reqs) then
                    for _,handlerInfo in ipairs(modifier.mod.handlers) do
                        if handlerInfo.force then
                            toggleHandlerFunc(self.eventHandlers, handlerInfo.type, handlerInfo.spellID, member.GUID, handlerInfo.handler, watchInfo)
                        end
                    end
                end
            end
        end
    end
end

function ZT:toggleCombatLogHandlers(watchInfo, enable)
	local spellInfo = watchInfo.spellInfo
    local spellID = spellInfo.id
	local member = watchInfo.member
	local toggleHandlerFunc = enable and self.eventHandlers.add or self.eventHandlers.remove

	if not spellInfo.ignoreCast then
		toggleHandlerFunc(self.eventHandlers, "SPELL_CAST_SUCCESS", spellID, member.GUID, watchInfo.startCD, watchInfo)

		local links = self.linkedSpellIDs[spellID]
		if links then
			for _,linkedSpellID in ipairs(links) do
				toggleHandlerFunc(self.eventHandlers, "SPELL_CAST_SUCCESS", linkedSpellID, member.GUID, watchInfo.startCD, watchInfo)
			end
		end
	end

    if spellInfo.mods then
        for _,modifier in ipairs(spellInfo.mods) do
            if modifier.mod.type == "Dynamic" then
                if not enable or member:checkRequirements(modifier.reqs) then
                    for _,handlerInfo in ipairs(modifier.mod.handlers) do
							toggleHandlerFunc(self.eventHandlers, handlerInfo.type, handlerInfo.spellID, member.GUID, handlerInfo.handler, watchInfo)
						end
					end
				end
			end
		end
	end

function ZT:watch(spellInfo, member)
	-- Only handle registered spells (or those for the player)
	if not spellInfo.isRegistered and not member.isPlayer then
		return
	end

    -- Only handle spells that meet all the requirements for the member
    if not member:checkRequirements(spellInfo.reqs) then
        return
    end

    local spellID = spellInfo.id
	local spells = self.watching[spellID]
	if not spells then
		spells = {}
		self.watching[spellID] = spells
	end

	local isHidden = (member.isPlayer and not spellInfo.isRegistered) or member.isHidden

	local watchInfo = spells[member.GUID]
	local isNew = (watchInfo == nil)
	if not watchInfo then
        watchInfo = WatchInfo:create(member, spellInfo, isHidden)
		spells[member.GUID] = watchInfo
		member.watching[spellID] = watchInfo
	else
        -- If the type changed, send a remove event
        if not isHidden and spellInfo.type ~= watchInfo.spellInfo.type then
            watchInfo:sendRemoveEvent()
        end
		watchInfo.spellInfo = spellInfo
        watchInfo:updateModifiers()
		watchInfo:toggleHidden(isHidden, true) -- We will send the ZT_ADD event later
	end

	if member.isPlayer then
		watchInfo:updatePlayerCharges()
		watchInfo:sendAddEvent()

		watchInfo:updatePlayerCD(spellID, true)

		local links = self.separateLinkedSpellIDs[spellID]
		if links then
			for _,linkedSpellID in ipairs(links) do
				watchInfo:updatePlayerCD(linkedSpellID, true)
			end
		end
	else
		watchInfo:sendAddEvent()
	end

	if member.isPlayer and not TEST_CLEU then
		if isNew then
			self:togglePlayerHandlers(watchInfo, true)
		end
	elseif member.tracking == "CombatLog" or (member.tracking == "Sharing" and member.spellsVersion < spellInfo.version) then
		watchInfo.ignoreSharing = true
		if not isNew then
            self:toggleCombatLogHandlers(watchInfo, false)
		end
        self:toggleCombatLogHandlers(watchInfo, true)
	else
		watchInfo.ignoreSharing = false
	end
end

function ZT:unwatch(spellInfo, member)
	-- Only handle registered spells (or those for the player)
	if not spellInfo.isRegistered and not member.isPlayer then
		return
	end

    local spellID = spellInfo.id
	local sources = self.watching[spellID]
	if not sources then
		return
	end

	local watchInfo = sources[member.GUID]
	if not watchInfo then
		return
	end

	-- Ignoring unwatch requests if the spellInfo doesn't match (yet spellID does)
	-- (Note: This serves to ease updating after spec/talent changes)
	if watchInfo.spellInfo ~= spellInfo then
		return
	end

	if member.isPlayer and not TEST_CLEU then
		-- If called due to front-end unregistration, only hide it to allow continued sharing of updates
		-- Otherwise, called due to a spec/talent change, so actually unwatch it
		if not spellInfo.isRegistered then
			watchInfo:hide()
			return
		end

		self:togglePlayerHandlers(watchInfo, false)
	elseif member.tracking == "CombatLog"  or (member.tracking == "Sharing" and member.spellsVersion < spellInfo.version) then
        self:toggleCombatLogHandlers(watchInfo, false)
	end

	if watchInfo.readyTimer then
		self.timers:cancel(watchInfo.readyTimer)
	end

	sources[member.GUID] = nil
	member.watching[spellID] = nil

	watchInfo:sendRemoveEvent()
end

--##############################################################################
-- Tracking types registered by front-end WAs

function ZT:registerSpells(frontendID, spells)
	for _,spellInfo in ipairs(spells) do
		local frontends = spellInfo.frontends
		if next(frontends, nil) ~= nil then
			-- Some front-end already registered for this spell, so just send ADD events
            local watched = self.watching[spellInfo.id]
			if watched then
				for _,watchInfo in pairs(watched) do
					if watchInfo.spellInfo == spellInfo then
						watchInfo:sendAddEvent()
					end
				end
			end
		else
			-- No front-end was registered for this spell, so watch as needed
			spellInfo.isRegistered = true
			for _,member in pairs(self.members) do
                if not member.isIgnored then
					self:watch(spellInfo, member)
				end
			end
		end

		frontends[frontendID] = true
	end
end

function ZT:unregisterSpells(frontendID, spells)
	for _,spellInfo in ipairs(spells) do
		local frontends = spellInfo.frontends
		frontends[frontendID] = nil

		if next(frontends, nil) == nil then
            local watched = self.watching[spellInfo.id]
			if watched then
				for _,watchInfo in pairs(watched) do
					if watchInfo.spellInfo == spellInfo then
						self:unwatch(spellInfo, watchInfo.member)
					end
				end
			end
			spellInfo.isRegistered = false
		end
	end
end

function ZT:toggleFrontEndRegistration(frontendID, info, toggle)
	local infoType = type(info)
	local registerFunc = toggle and self.registerSpells or self.unregisterSpells

	if infoType == "string" then -- Registration info is a type
		prdebug(DEBUG_EVENT, "Received", toggle and "ZT_REGISTER" or "ZT_UNREGISTER", "from", frontendID, "for type", info)
        registerFunc(self, frontendID, self.spells["type"][info])
	elseif infoType == "number" then -- Registration info is a spellID
		prdebug(DEBUG_EVENT, "Received", toggle and "ZT_REGISTER" or "ZT_UNREGISTER", "from", frontendID, "for spellID", info)
        registerFunc(self, frontendID, self.spells["id"][info])
	elseif infoType == "table" then -- Registration info is a table of types or spellIDs
		infoType = type(info[1])

		if infoType == "string" then
			prdebug(DEBUG_EVENT, "Received", toggle and "ZT_REGISTER" or "ZT_UNREGISTER", "from", frontendID, "for multiple types")
			for _,type in ipairs(info) do
                registerFunc(self, frontendID, self.spells["type"][type])
			end
		elseif infoType == "number" then
			prdebug(DEBUG_EVENT, "Received", toggle and "ZT_REGISTER" or "ZT_UNREGISTER", "from", frontendID, "for multiple spells")
			for _,spellID in ipairs(info) do
                registerFunc(self, frontendID, self.spells["id"][spellID])
			end
		end
	end
end

function ZT:registerFrontEnd(frontendID, info)
	self:toggleFrontEndRegistration(frontendID, info, true)
end

function ZT:unregisterFrontEnd(frontendID, info)
	self:toggleFrontEndRegistration(frontendID, info, false)
end


--##############################################################################
-- Managing member information (e.g., spec, talents) for all group members

local Member = { }
local MemberMT = { __index = Member }

ZT.members = {}
ZT.inEncounter = false

local membersToIgnore = {}
--if ZT.config["ignoreList"] then
--	local ignoreListStr = trim(ZT.config["ignoreList"])
--
--	if ignoreListStr ~= "" then
--		ignoreListStr = "return "..ignoreListStr
--		local ignoreList = WeakAuras.LoadFunction(ignoreListStr, "ZenTracker Ignore List")
--
--		if ignoreList and (type(ignoreList) == "table") then
--			for i,name in ipairs(ignoreList) do
--				if type(name) == "string" then
--					membersToIgnore[strlower(name)] = true
--				else
--					prerror("Ignore list entry", i, "is not a string. Skipping...")
--				end
--			end
--		else
--			prerror("Ignore list is not in the form of a table. For example: {\"Zenlia\", \"Cistara\"}")
--		end
--	end
--end

function Member:create(memberInfo)
	local member = memberInfo
	member.watching = {}
	member.tracking = member.tracking and member.tracking or "CombatLog"
	member.isPlayer = (member.GUID == UnitGUID("player"))
	member.isHidden = false
	member.isReady = false

	return setmetatable(member, MemberMT)
end

function Member:update(memberInfo)
    self.level = memberInfo.level or self.level
    self.specID = memberInfo.specID or self.specID
    self.talents = memberInfo.talents or self.talents
    self.talentsStr = memberInfo.talentsStr or self.talentsStr
    self.covenantID = memberInfo.covenantID or self.covenantID
    self.unit = memberInfo.unit or self.unit
    if memberInfo.tracking then
        self.tracking = memberInfo.tracking
        self.spellsVersion = memberInfo.spellsVersion
        self.protocolVersion = memberInfo.protocolVersion
    end
end

function Member:gatherInfo()
	local _,className,_,race,_,name = GetPlayerInfoByGUID(self.GUID)
	self.name = name and gsub(name, "%-[^|]+", "") or nil
	self.class = className and AllClasses[className] or nil
	self.classID = className and AllClasses[className].ID or nil
	self.classColor = className and RAID_CLASS_COLORS[className] or nil
	self.race = race
    self.level = self.unit and UnitLevel(self.unit) or -1

	if (self.tracking == "Sharing") and self.name then
        prdebug(DEBUG_TRACKING, self.name, "is using ZenTracker with spell list version", self.spellsVersion)
	end

	if self.name and membersToIgnore[strlower(self.name)] then
		self.isIgnored = true
		return false
	end

    if self.isPlayer then
        self.covenantID = ZT:updateCovenantInfo()
    end

    self.isReady = (self.name ~= nil) and (self.classID ~= nil) and (self.race ~= nil) and (self.level >= 1)
	return self.isReady
end

function Member:checkRequirements(reqs)
    if not reqs then
		return true
	end

    for _,req in ipairs(reqs) do
        if not req.check(self) then
            return false
        end
    end
			return true
		end

function Member:hide()
	if not self.isHidden and not self.isPlayer then
		self.isHidden = true
		for _,watchInfo in pairs(self.watching) do
			watchInfo:hide()
		end
	end
end

function Member:unhide()
	if self.isHidden and not self.isPlayer then
		self.isHidden = false
		for _,watchInfo in pairs(self.watching) do
			watchInfo:unhide()
		end
	end
end

-- TODO: Fix rare issue where somehow only talented spells are being shown?
function ZT:addOrUpdateMember(memberInfo)
	local member = self.members[memberInfo.GUID]
	if not member then
		member = Member:create(memberInfo)
		self.members[member.GUID] = member
	end

	if member.isIgnored then
		return
	end

    -- Determining which properties of the member have updated
    local isInitialUpdate = not member.isReady and member:gatherInfo()
    local isLevelUpdate = memberInfo.level and (memberInfo.level ~= member.level)
    local isSpecUpdate = memberInfo.specID and (memberInfo.specID ~= member.specID)
    local isTalentUpdate = false
    if memberInfo.talents then
        for talent,_ in pairs(memberInfo.talents) do
            if member.talents[talent] == nil then
                isTalentUpdate = true
                break
            end
        end
    end
    local isCovenantUpdate = memberInfo.covenantID and (memberInfo.covenantID ~= member.covenantID)

    if member.isReady and (isInitialUpdate or isLevelUpdate or isSpecUpdate or isTalentUpdate or isCovenantUpdate) then
        local prevSpecID = member.specID
        local prevTalents = member.talents or {}
        local prevCovenantID = member.covenantID
        member:update(memberInfo)

        -- This handshake should come before any cooldown updates for newly watched spells
		if member.isPlayer then
            self:sendHandshake()
		end

		-- If we are in an encounter, hide the member if they are outside the player's instance
		-- (Note: Previously did this on member creation, which seemed to introduce false positives)
        if isInitialUpdate and self.inEncounter and (not member.isPlayer) then
			local _,_,_,instanceID = UnitPosition("player")
            local _,_,_,mInstanceID = UnitPosition(member.unit)
			if instanceID ~= mInstanceID then
				member:hide()
			end
		end

        -- Generic Spells + Class Spells + Race Spells
		-- Note: These are set once and never change
        if isInitialUpdate then
            for _,spellInfo in ipairs(self.spells["generic"]) do
                self:watch(spellInfo, member)
            end
            for _,spellInfo in ipairs(self.spells["race"][member.race]) do
                self:watch(spellInfo, member)
			end
            for _,spellInfo in ipairs(self.spells["class"][member.classID]) do
                self:watch(spellInfo, member)
            end
        end

        -- Leveling (No need to handle on initial update)
        if isLevelUpdate then
            for _,spellInfo in ipairs(self.spells["level"][member.level]) do
                self:watch(spellInfo, member)
            end
        end

        -- Specialization Spells
        if (isInitialUpdate or isSpecUpdate) and member.specID then
            for _,spellInfo in ipairs(self.spells["spec"][member.specID]) do
                self:watch(spellInfo, member)
            end

            if isSpecUpdate and prevSpecID then
                for _,spellInfo in ipairs(self.spells["spec"][prevSpecID]) do
                    if not member:checkRequirements(spellInfo.reqs) then
								self:unwatch(spellInfo, member)
					end
				end
			end
		end

        -- Talented Spells
        if (isInitialUpdate or isTalentUpdate) and member.talents then
            -- Handling talents that were just selected
            for talent,_ in pairs(member.talents) do
                if isInitialUpdate or not prevTalents[talent] then
                    for _,spellInfo in ipairs(self.spells["talent"][talent]) do
                        self:watch(spellInfo, member)
			end
                    for _,spellInfo in ipairs(self.spells["notalent"][talent]) do
                        if not member:checkRequirements(spellInfo.reqs) then
							self:unwatch(spellInfo, member)
                        end
                    end
                end
            end

            -- Handling talents that were just unselected
            if not isInitialUpdate then
                for talent,_ in pairs(prevTalents) do
                    if not member.talents[talent] then
                        for _,spellInfo in ipairs(self.spells["talent"][talent]) do
                            if not member:checkRequirements(spellInfo.reqs) then
                                self:unwatch(spellInfo, member) -- Talent was required
						else
                                self:watch(spellInfo, member) -- Talent was a modifier
                            end
                        end
                        for _,spellInfo in ipairs(self.spells["notalent"][talent]) do
                            self:watch(spellInfo, member)
                        end
                    end
						end
					end
				end

        -- Covenant Spells
        if (isInitialUpdate or isCovenantUpdate) and member.covenantID then
            for _,spellInfo in ipairs(self.spells["covenant"][member.covenantID]) do
                self:watch(spellInfo, member)
            end

            if isCovenantUpdate and prevCovenantID then
                for _,spellInfo in ipairs(self.spells["covenant"][prevCovenantID]) do
                    if not member:checkRequirements(spellInfo.reqs) then
								self:unwatch(spellInfo, member)
						end
					end
				end
			end
		end

	-- If tracking changed from "CombatLog" to "Sharing", remove unnecessary event handlers and send a handshake/updates
	if (member.tracking == "CombatLog") and (memberInfo.tracking == "Sharing") then
		member.tracking = "Sharing"
		member.spellsVersion = memberInfo.spellsVersion

		if member.name then
			prdebug(DEBUG_TRACKING, member.name, "is using ZenTracker with spell list version", member.spellsVersion)
		end

		for _,watchInfo in pairs(member.watching) do
			if watchInfo.spellInfo.version <= member.spellsVersion then
				watchInfo.ignoreSharing = false
                self:toggleCombatLogHandlers(watchInfo, false)
			end
		end

		self:sendHandshake()
		local time = GetTime()
		for _,watchInfo in pairs(self.members[UnitGUID("player")].watching) do
			if watchInfo.expiration > time then
				self:sendCDUpdate(watchInfo)
			end
		end
	end
end

--##############################################################################
-- Handling raid and M+ encounters

function ZT:resetEncounterCDs()
	for _,member in pairs(self.members) do
		local resetMemberCDs = not member.isPlayer and member.tracking ~= "Sharing"

		for _,watchInfo in pairs(member.watching) do
			if resetMemberCDs and watchInfo.duration >= 180 then
                watchInfo.charges = watchInfo.maxCharges
				watchInfo:updateCDRemaining(0)
			end

			-- If spell uses lazy tracking and it was triggered, reset lazy tracking at this point
			if watchInfo.spellInfo.isLazy and not watchInfo.isLazy then
				watchInfo:sendRemoveEvent()
				watchInfo.isLazy = true
			end
		end
	end
end

function ZT:startEncounter(event)
	self.inEncounter = true

	local _,_,_,instanceID = UnitPosition("player")
	for _,member in pairs(self.members) do
		local _,_,_,mInstanceID = UnitPosition(self.inspectLib:GuidToUnit(member.GUID))
		if mInstanceID ~= instanceID then
			member:hide()
		else
			member:unhide() -- Note: Shouldn't be hidden, but just in case...
		end
	end

	if event == "CHALLENGE_MODE_START" then
		self:resetEncounterCDs()
	end
end

function ZT:endEncounter(event)
	if self.inEncounter then
		self.inEncounter = false
		for _,member in pairs(self.members) do
			member:unhide()
		end
	end

	if event == "ENCOUNTER_END" then
		self:resetEncounterCDs()
	end
end

--##############################################################################
-- Public functions for other addons/auras to query ZenTracker information
-- Note: This API is subject to change at any time (for now)

-- Parameters:
--   type (string) -> Filter by a specific spell type (e.g., "IMMUNITY")
--   spellIDs (map<number, bool>) -> Filter by a specific set of spell IDs (e.g., {[642]=true, [1022]=true})
--   unitOrGUID (string) -> Filter by a specific member, as specified by a GUID or current unit (e.g., "player")
--   available (bool) -> Filters by whether a spell is available for use or not (e.g., true)
--   (Note: Set parameters to nil if they should be ignored)
-- Return Value:
--   Array containing tables with the following keys: spellID, member, expiration, charges, activeExpiration
local function Public_Query(type, spellIDs, unitOrGUID, available)
    local results = {}

    local members
    if unitOrGUID then
        local GUID = UnitGUID(unitOrGUID) or unitOrGUID
        if GUID and ZT.members[GUID] then
            members = {[GUID]=ZT.members[GUID]}
        else
            return results
        end
    else
        members = ZT.members
    end

    local time = GetTime()
    for _,member in pairs(members) do
        for _,watchInfo in pairs(member.watching) do
            local spellInfo = watchInfo.spellInfo
            if (not type or spellInfo.type == type) and (not spellIDs or spellIDs[spellInfo.id]) and (available == nil or (watchInfo.expiration <= time or (watchInfo.charges and watchInfo.charges > 0)) == available) then
                tinsert(results, {spellID = spellInfo.id, member = member, expiration = watchInfo.expiration, charges = watchInfo.charges, activeExpiration = watchInfo.activeExpiration})
            end
        end
    end

    return results
end

setglobal("ZenTracker_PublicFunctions", { query = Public_Query })

--##############################################################################
-- Handling the exchange of addon messages with other ZT clients
--
-- Message Format = <Protocol Version (%d)>:<Message Type (%s)>:<Member GUID (%s)>...
--   Type = "H" (Handshake)
--     ...:<Spec ID (%d)>:<Talents (%s)>:<IsInitial? (%d)>:<Spells Version (%d)>:<Covenant ID (%d)>
--   Type = "U" (CD Update)
--     ...:<Spell ID (%d)>:<Duration (%f)>:<Remaining (%f)>:<#Charges (%d)>:<Active Duration (%f)>:<Active Remaining (%f)>

ZT.protocolVersion = 4

ZT.timeBetweenHandshakes = 5 --seconds
ZT.timeOfNextHandshake = 0
ZT.handshakeTimer = nil

ZT.timeBetweenCDUpdates = 5 --seconds (per spellID)
ZT.timeOfNextCDUpdate = {}
ZT.updateTimers = {}

local function sendMessage(message)
	prdebug(DEBUG_MESSAGE, "Sending message '"..message.."'")

	if not IsInGroup() and not IsInRaid() then
		return
	end

	local channel = IsInGroup(2) and "INSTANCE_CHAT" or "RAID"
	C_ChatInfo.SendAddonMessage("ZenTracker", message, channel)
end

ZT.hasSentHandshake = false
function ZT:sendHandshake()
	local time = GetTime()
	if time < self.timeOfNextHandshake then
		if not self.handshakeTimer then
			self.handshakeTimer = self.timers:add(self.timeOfNextHandshake, function() self:sendHandshake() end)
		end
		return
	end

	local GUID = UnitGUID("player")
	if not self.members[GUID] then
		return -- This may happen when rejoining a group after login, so ignore this attempt to send a handshake
	end

    local member = self.members[GUID]
    local specID = member.specID or 0
    local talents = member.talentsStr or ""
	local isInitial = self.hasSentHandshake and 0 or 1
    local covenantID = member.covenantID or 0
    local message = string.format("%d:H:%s:%d:%s:%d:%d:%d", self.protocolVersion, GUID, specID, talents, isInitial, self.spellListVersion, covenantID)
	sendMessage(message)

	self.hasSentHandshake = true
	self.timeOfNextHandshake = time + self.timeBetweenHandshakes
	if self.handshakeTimer then
		self.timers:cancel(self.handshakeTimer)
		self.handshakeTimer = nil
	end
end

function ZT:sendCDUpdate(watchInfo, ignoreRateLimit)
    local spellID = watchInfo.spellInfo.id
	local time = GetTime()

	local timer = self.updateTimers[spellID]
	if ignoreRateLimit then
		if timer then
			self.timers:cancel(timer)
			self.updateTimers[spellID] = nil
		end
	elseif timer then
		return
	else
		local timeOfNextCDUpdate = self.timeOfNextCDUpdate[spellID]
		if timeOfNextCDUpdate and (time < timeOfNextCDUpdate) then
			self.updateTimers[spellID] = self.timers:add(timeOfNextCDUpdate, function() self:sendCDUpdate(watchInfo, true) end)
			return
		end
	end

    local message
	local GUID = watchInfo.member.GUID
	local duration = watchInfo.duration
	local remaining = watchInfo.expiration - time
	if remaining < 0 then
		remaining = 0
	end
	local charges = watchInfo.charges and tostring(watchInfo.charges) or "-"
    local activeDuration = watchInfo.activeDuration
    if activeDuration then
        local activeRemaining = watchInfo.activeExpiration - time
        if activeRemaining < 0 then
            activeRemaining = 0
        end
        message = string.format("%d:U:%s:%d:%0.2f:%0.2f:%s:%0.2f:%0.2f", self.protocolVersion, GUID, spellID, duration, remaining, charges, activeDuration, activeRemaining)
    else
        message = string.format("%d:U:%s:%d:%0.2f:%0.2f:%s", self.protocolVersion, GUID, spellID, duration, remaining, charges)
    end
	sendMessage(message)

	self.timeOfNextCDUpdate[spellID] = time + self.timeBetweenCDUpdates
end

function ZT:handleHandshake(version, mGUID, specID, talentsStr, isInitial, spellsVersion, covenantID)
    -- Protocol V4: Ignore any earlier versions due to substantial changes (talents)
    if version < 4 then
        return
    end

	specID = tonumber(specID)
	if specID == 0 then
		specID = nil
	end

    local talents = {}
	if talents ~= "" then
        for index in talentsStr:gmatch("%d+") do
			index = tonumber(index)
            talents[index] = true
		end
	end

	-- Protocol V2: Assume false if not present
	if isInitial == "1" then
		isInitial = true
	else
		isInitial = false
	end

	-- Protocol V2: Assume spellsVersion is 1 if not present
	if spellsVersion then
		spellsVersion = tonumber(spellsVersion)
		if not spellsVersion then
			spellsVersion = 1
		end
	else
		spellsVersion = 1
	end

    -- Protocol V4: Assume covenantID is nil if not present
    covenantID = tonumber(covenantID)
    if covenantID == 0 then
        covenantID = nil
    end

	local memberInfo = {
		GUID = mGUID,
			specID = specID,
			talents = talents,
        talentsStr = talentsStr,
        covenantID = covenantID,
		tracking = "Sharing",
        protocolVersion = version,
		spellsVersion = spellsVersion,
	}

	self:addOrUpdateMember(memberInfo)
	if isInitial then
		self:sendHandshake()
	end
end

function ZT:handleCDUpdate(version, mGUID, spellID, duration, remaining, charges, activeDuration, activeRemaining)
	local member = self.members[mGUID]
	if not member or not member.isReady then
		return
	end

	spellID = tonumber(spellID)
	duration = tonumber(duration)
	remaining = tonumber(remaining)
	if not spellID or not duration or not remaining then
		return
	end

	local sources = self.watching[spellID]
	if sources then
		local watchInfo = sources[member.GUID]
		if not watchInfo or watchInfo.ignoreSharing then
			return
		end

        local time = GetTime()

        -- Protocol V3: Charges (Ignore if not present)
			charges = tonumber(charges)
			if charges then
				watchInfo.charges = charges
			end

        -- Protocol V4: Active Duration/ Expiration (Assume default or inspect buff if not present)
        activeDuration = tonumber(activeDuration)
        activeRemaining = tonumber(activeRemaining)
        if activeDuration and activeRemaining then
            watchInfo.activeDuration = activeDuration
            watchInfo.activeExpiration = time + activeRemaining
        elseif watchInfo.spellInfo.active then
            watchInfo:updateActive(time)
		end

		watchInfo.duration = duration
        watchInfo.expiration = time + remaining
		watchInfo:sendTriggerEvent()
	end
end

function ZT:handleMessage(message)
    local version, type, mGUID, arg1, arg2, arg3, arg4, arg5, arg6 = strsplit(":", message)
    version = tonumber(version)

	-- Ignore any messages sent by the player
	if mGUID == UnitGUID("player") then
		return
	end

	prdebug(DEBUG_MESSAGE, "Received message '"..message.."'")

	if type == "H" then     -- Handshake
        self:handleHandshake(version, mGUID, arg1, arg2, arg3, arg4, arg5, arg6)
	elseif type == "U" then -- CD Update
        self:handleCDUpdate(version, mGUID, arg1, arg2, arg3, arg4, arg5, arg6)
	else
		return
	end
end

--##############################################################################
-- Callback functions for libGroupInspecT for updating/removing members

ZT.delayedUpdates = {}

function ZT:updateCovenantInfo()
    local covenantID = C_Covenants.GetActiveCovenantID()
    if covenantID == 0 then
        return
    end

    -- local soulbindID = C_Soulbinds.GetActiveSoulbindID()
    -- local soulbindData = C_Soulbinds.GetSoulbindData(soulbindID)
    -- if soulbindData and soulbindData.tree and soulbindData.tree.nodes then
    --     for _,node in pairs(soulbindData.tree.nodes) do
    --         if node.state == 3 then
    --             if node.conduitID ~= 0 then
    --             -- Process node.conduitID, node.conduitRank
    --             else
    --             -- Process node.spellID
    --             end
    --         end
    --     end
    -- end

    return covenantID
end

function ZT:libInspectUpdate(_, GUID, _, info)
	local specID = info.global_spec_id
	if specID == 0 then
		specID = nil
	end

    local talents = {}
    local talentsStr = ""
	if info.talents then
        for _,talent in pairs(info.talents) do
            if talent.spell_id then -- This is rarely nil, not sure why...
                talents[talent.spell_id] = true
                talentsStr = talentsStr..talent.spell_id..","
			end
		end
	end

	local memberInfo = {
		GUID = GUID,
        unit = info.lku,
			specID = specID,
			talents = talents,
        talentsStr = strsub(talentsStr, 0, -2),
	}

	if not self.delayedUpdates then
		self:addOrUpdateMember(memberInfo)
	else
        self.delayedUpdates[GUID] = memberInfo
	end
end

function ZT:libInspectRemove(_, GUID)
	local member = self.members[GUID]
	if not member then
		return
	end

	for _,watchInfo in pairs(member.watching) do
		self:unwatch(watchInfo.spellInfo, member)
	end
	self.members[GUID] = nil
end

function ZT:handleDelayedUpdates()
	if self.delayedUpdates then
        for _,memberInfo in pairs(self.delayedUpdates) do
			self:addOrUpdateMember(memberInfo)
		end
		self.delayedUpdates = nil
	end
end

function ZT:Init()
	self:BuildSpellList();

	if not C_ChatInfo.RegisterAddonMessagePrefix("ZenTracker") then
		prerror("Could not register addon message prefix. Defaulting to local-only cooldown tracking.")
	end

	-- If prevZT exists, we know it wasn't a login or reload. If it doesn't exist,
	-- it still might not be a login or reload if the user is installing ZenTracker
	-- for the first time. IsLoginFinished() takes care of the second case.
	--if prevZT or WeakAuras.IsLoginFinished() then
	--	ZT.delayedUpdates = nil
	--end

	ZT.inspectLib.RegisterCallback(ZT, "GroupInSpecT_Update", "libInspectUpdate")
	ZT.inspectLib.RegisterCallback(ZT, "GroupInSpecT_Remove", "libInspectRemove")

	for unit in IterateGroupMembers() do
		local GUID = UnitGUID(unit)
		if GUID then
			local info = self.inspectLib:GetCachedInfo(GUID)
			if info then
				self:libInspectUpdate("Init", GUID, unit, info)
			else
				self.inspectLib:Rescan(GUID)
			end
		end
	end
end