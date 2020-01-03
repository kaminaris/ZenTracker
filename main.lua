local addonName, ZT = ...;
_G[addonName] = ZT;

ZT.inspectLib = LibStub:GetLibrary("LibGroupInSpecT-1.1", true);

-- Local versions of commonly used functions
local ipairs = ipairs
local pairs = pairs
local print = print
local select = select
local tonumber = tonumber

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

local function Table_Create(values)
	if not values then
		return {}
	elseif not values[1] then
		return { values }
	end
	return values
end

local function DefaultTable_Create(genDefaultFunc)
	local table = {}
	local metatable = {}
	metatable.__index = function(table, key)
		local value = genDefaultFunc()
		rawset(table, key, value)
		return value
	end

	return setmetatable(table, metatable)
end

local function Map_FromTable(table)
	local map = {}
	for _,value in ipairs(table) do
		map[value] = true
	end
	return map
end

-- TODOs
--
-- 1) Fix the registration to allow for spellIDs or types
-- 2) Track front-end registration at the level of spellIDs
-- 3) Change spell list to allow for multiple types per spell (introduce RAIDCD)

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
-- Spell Cooldown Modifiers

local function StaticMod(type, value)
	return { type = "Static", [type] = value }
end

local function DynamicMod(handlers)
	if not handlers[1] then
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

-- Shockwave: If 3+ targets hit then reduces by 15 seconds
local modShockwave = DynamicMod({
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

-- Capacitor Totem: Each target hit reduces by 5 seconds (up to 4 targets hit)
local modCapTotem = DynamicMod({
	type = "SPELL_SUMMON", spellID = 192058,
	handler = function(watchInfo)
		watchInfo.numHits = 0

		if not watchInfo.totemHandler then
			watchInfo.totemHandler = function(watchInfo)
				watchInfo.numHits = watchInfo.numHits + 1
				if watchInfo.numHits <= 4 then
					watchInfo:updateCDDelta(-5)
				end
			end
		end

		if watchInfo.totemGUID then
			ZT.eventHandlers:remove("SPELL_AURA_APPLIED", 118905, watchInfo.totemGUID, watchInfo.totemHandler)
		end

		watchInfo.totemGUID = select(8, CombatLogGetCurrentEventInfo())
		ZT.eventHandlers:add("SPELL_AURA_APPLIED", 118905, watchInfo.totemGUID, watchInfo.totemHandler, watchInfo)
	end
})


-- Guardian Spirit: If expires watchInfothout healing then reset to 60 seconds
local modGuardianSpirit = DynamicMod({
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
		[49998]  = 40, -- Death Strike (Assumes -5 from Ossuary)
		[61999]  = 30, -- Raise Ally
		[206940] = 30, -- Mark of Blood
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
	},
	[Warrior.Fury] = {
		[202168] = 10, -- Impending Victory
		[184367] = 75, -- Rampage (Assumes -10 from Carnage)
		[12323]  = 10, -- Piercing Howl
	},
	[Warrior.Prot] = {
		[190456] = 40, -- Ignore Pain (Ignores Vengeance)
		[202168] = 10, -- Impending Victory
		[6572]   = 30, -- Revenge (Ignores Vengeance)
		[2565]   = 30, -- Shield Block
	}
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

--##############################################################################
-- List of Tracked Spells

ZT.spellsVersion = 8
ZT.spells = {
	-- Interrupts
	{type="INTERRUPT", spellID=183752, class=DH, baseCD=15}, -- Disrupt
	{type="INTERRUPT", spellID=47528, class=DK, baseCD=15}, -- Mind Freeze
	{type="INTERRUPT", spellID=91802, specs={DK.Unholy}, baseCD=30}, -- Shambling Rush
	{type="INTERRUPT", spellID=78675, specs={Druid.Balance}, baseCD=60}, -- Solar Beam
	{type="INTERRUPT", spellID=106839, specs={Druid.Feral, Druid.Guardian}, baseCD=15}, -- Skull Bash
	{type="INTERRUPT", spellID=147362, specs={Hunter.BM, Hunter.MM}, baseCD=24}, -- Counter Shot
	{type="INTERRUPT", spellID=187707, specs={Hunter.SV}, baseCD=15}, -- Muzzle
	{type="INTERRUPT", spellID=2139, class=Mage, baseCD=24}, -- Counter Spell
	{type="INTERRUPT", spellID=116705, specs={Monk.WW, Monk.BRM}, baseCD=15}, -- Spear Hand Strike
	{type="INTERRUPT", spellID=96231, specs={Paladin.Prot, Paladin.Ret}, baseCD=15}, -- Rebuke
	{type="INTERRUPT", spellID=15487, specs={Priest.Shadow}, baseCD=45, modTalents={[41]=StaticMod("sub", 15)}}, -- Silence
	{type="INTERRUPT", spellID=1766, class=Rogue, baseCD=15}, -- Kick
	{type="INTERRUPT", spellID=57994, class=Shaman, baseCD=12}, -- Wind Shear
	{type="INTERRUPT", spellID=19647, class=Warlock, baseCD=24}, -- Spell Lock
	{type="INTERRUPT", spellID=6552, class=Warrior, baseCD=15}, -- Pummel
	-- Hard Crowd Control (AOE)
	{type="HARDCC", spellID=179057, specs={DH.Havoc}, baseCD=60, modTalents={[61]=StaticMod("mul", 0.666667)}}, -- Chaos Nova
	{type="HARDCC", spellID=119381, class=Monk, baseCD=60, modTalents={[41]=StaticMod("sub", 10)}}, -- Leg Sweep
	{type="HARDCC", spellID=192058, class=Shaman, baseCD=60, modTalents={[33]=modCapTotem}}, -- Capacitor Totem
	{type="HARDCC", spellID=30283, class=Warlock, baseCD=60, modTalents={[51]=StaticMod("sub", 15)}}, -- Shadowfury
	{type="HARDCC", spellID=46968, specs={Warrior.Prot}, baseCD=40, modTalents={[52]=modShockwave}}, -- Shockwave
	{type="HARDCC", spellID=255654, race="HighmountainTauren", baseCD=120}, -- Bull Rush
	{type="HARDCC", spellID=20549, race="Tauren", baseCD=90}, -- War Stomp
	-- Soft Crowd Control (AOE)
	{type="SOFTCC", spellID=202138, specs={DH.Veng}, baseCD=90, reqTalents={53}}, -- Sigil of Chains
	{type="SOFTCC", spellID=207684, specs={DH.Veng}, baseCD=90, modTalents={[52]=StaticMod("mul", 0.8)}}, -- Sigil of Misery
	{type="SOFTCC", spellID=202137, specs={DH.Veng}, baseCD=60, modTalents={[52]=StaticMod("mul", 0.8)}}, -- Sigil of Silence
	{type="SOFTCC", spellID=108199, specs={DK.Blood}, baseCD=120, modTalents={[52]=StaticMod("sub", 30)}}, -- Gorefiend's Grasp
	{type="SOFTCC", spellID=207167, specs={DK.Frost}, baseCD=60, reqTalents={33}}, -- Blinding Sleet
	{type="SOFTCC", spellID=132469, class=Druid, baseCD=30, reqTalents={43}}, -- Typhoon
	{type="SOFTCC", spellID=102359, class=Druid, baseCD=30, reqTalents={42}}, -- Mass Entanglement
	{type="SOFTCC", spellID=99, specs={Druid.Guardian}, baseCD=30}, -- Incapacitating Roar
	{type="SOFTCC", spellID=102793, specs={Druid.Guardian}, baseCD=60, reqTalents={22}}, -- Ursol's Vortex
	{type="SOFTCC", spellID=102793, specs={Druid.Resto}, baseCD=60}, -- Ursol's Vortex
	{type="SOFTCC", spellID=109248, class=Hunter, baseCD=45, reqTalents={53}}, -- Binding Shot
	{type="SOFTCC", spellID=122, class=Mage, baseCD=30, reqTalents={51,53}, mods=CastRemainingMod(235219,0), version=6}, -- Frost Nova
	{type="SOFTCC", spellID=122, class=Mage, baseCD=30, charges=2, reqTalents={52}, mods=CastRemainingMod(235219,0), version=6}, -- Frost Nova
	{type="SOFTCC", spellID=113724, class=Mage, baseCD=30, reqTalents={53}, version=6}, -- Ring of Frost
	{type="SOFTCC", spellID=31661, specs={Mage.Fire}, baseCD=20, version=2}, -- Dragon's Breath
	{type="SOFTCC", spellID=33395, specs={Mage.Frost}, baseCD=25, reqTalents={11,13}, version=6}, -- Freeze (Pet)
	{type="SOFTCC", spellID=116844, class=Monk, baseCD=45, reqTalents={43}}, -- Ring of Peace
	{type="SOFTCC", spellID=115750, class=Paladin, baseCD=90, reqTalents={33}, version=3}, -- Blinding Light
	{type="SOFTCC", spellID=8122, specs={Priest.Disc, Priest.Holy}, baseCD=60, modTalents={[41]=StaticMod("sub", 30)}}, -- Psychic Scream
	{type="SOFTCC", spellID=204263, specs={Priest.Disc, Priest.Holy}, baseCD=45, reqTalents={43}}, -- Shining Force
	{type="SOFTCC", spellID=8122, specs={Priest.Shadow}, baseCD=60}, -- Psychic Scream
	{type="SOFTCC", spellID=51490, specs={Shaman.Ele}, baseCD=45}, -- Thunderstorm
	-- Hard Crowd Control (Single Target)
	{type="STHARDCC", spellID=211881, specs={DH.Havoc}, baseCD=30, reqTalents={63}}, -- Fel Eruption
	{type="STHARDCC", spellID=221562, specs={DK.Blood}, baseCD=45}, -- Asphyxiate
	{type="STHARDCC", spellID=108194, specs={DK.FrostDK}, baseCD=45, reqTalents={32}}, -- Asphyxiate
	{type="STHARDCC", spellID=108194, specs={DK.Unholy}, baseCD=45, reqTalents={33}}, -- Asphyxiate
	{type="STHARDCC", spellID=5211, class=Druid, baseCD=50, reqTalents={41}}, -- Mighty Bash
	{type="STHARDCC", spellID=19577, specs={Hunter.BM, Hunter.Surv}, baseCD=60}, -- Intimidation
	{type="STHARDCC", spellID=853, specs={Paladin.Holy}, baseCD=60, modTalents={[31]=CastDeltaMod(275773, -10)}}, -- Hammer of Justice
	{type="STHARDCC", spellID=853, specs={Paladin.Prot}, baseCD=60, modTalents={[31]=CastDeltaMod(275779, -6)}}, -- Hammer of Justice
	{type="STHARDCC", spellID=853, specs={Paladin.Ret}, baseCD=60}, -- Hammer of Justice
	{type="STHARDCC", spellID=88625, specs={Priest.Holy}, baseCD=60, reqTalents={42}, mods=CastDeltaMod(585, -4), modTalents={[71]=CastDeltaMod(585, -1.333333)}}, -- Holy Word: Chastise
	{type="STHARDCC", spellID=64044, specs={Priest.Shadow}, baseCD=45, reqTalents={43}}, -- Psychic Horror
	{type="STHARDCC", spellID=6789, class=Warlock, baseCD=45, reqTalents={52}}, -- Mortal Coil
	{type="STHARDCC", spellID=107570, specs={Warrior.Arms,Warrior.Fury}, baseCD=30, reqTalents={23}}, -- Storm Bolt
	{type="STHARDCC", spellID=107570, specs={Warrior.Prot}, baseCD=30, reqTalents={53}}, -- Storm Bolt
	-- Soft Crowd Control (Single Target)
	{type="STSOFTCC", spellID=217832, class=DH, baseCD=45}, -- Imprison
	{type="STSOFTCC", spellID=49576, specs={DK.Blood}, baseCD=15, version=2}, -- Death Grip
	{type="STSOFTCC", spellID=49576, specs={DK.Frost, DK.Unholy}, baseCD=25, version=2}, -- Death Grip
	{type="STSOFTCC", spellID=2094, specs={Rogue.Outlaw}, baseCD=120, modTalents={[52]=StaticMod("sub", 30)}}, -- Blind
	{type="STSOFTCC", spellID=2094, specs={Rogue.Sin, Rogue.Sub}, baseCD=120}, -- Blind
	{type="STSOFTCC", spellID=115078, class=Monk, baseCD=45}, -- Paralysis
	{type="STSOFTCC", spellID=187650, class=Hunter, baseCD=30}, -- Freezing Trap
	{type="STSOFTCC", spellID=107079, race="Pandaren", baseCD=120, version=4}, -- Quaking Palm
	-- Dispel (Offensive)
	{type="DISPEL", spellID=278326, class=DH, baseCD=10, version=6}, -- Disrupt
	{type="DISPEL", spellID=2908, class=Druid, baseCD=10, version=6}, -- Soothe
	{type="DISPEL", spellID=32375, class=Priest, baseCD=45}, -- Mass Dispel
	{type="DISPEL", spellID=202719, race="BloodElf", class=DH, baseCD=120}, -- Arcane Torrent
	{type="DISPEL", spellID=50613, race="BloodElf", class=DK, baseCD=120}, -- Arcane Torrent
	{type="DISPEL", spellID=80483, race="BloodElf", class=Hunter, baseCD=120}, -- Arcane Torrent
	{type="DISPEL", spellID=28730, race="BloodElf", class=Mage, baseCD=120}, -- Arcane Torrent
	{type="DISPEL", spellID=129597, race="BloodElf", class=Monk, baseCD=120}, -- Arcane Torrent
	{type="DISPEL", spellID=155145, race="BloodElf", class=Paladin, baseCD=120}, -- Arcane Torrent
	{type="DISPEL", spellID=232633, race="BloodElf", class=Priest, baseCD=120}, -- Arcane Torrent
	{type="DISPEL", spellID=25046, race="BloodElf", class=Rogue, baseCD=120}, -- Arcane Torrent
	{type="DISPEL", spellID=28730, race="BloodElf", class=Warlock, baseCD=120}, -- Arcane Torrent
	{type="DISPEL", spellID=69179, race="BloodElf", class=Warrior, baseCD=120}, -- Arcane Torrent
	-- Dispel (Defensive, Magic)
	{type="DEFMDISPEL", spellID=88423, specs={Druid.Resto}, baseCD=8, mods=DispelMod(88423), ignoreCast=true}, -- Nature's Cure
	{type="DEFMDISPEL", spellID=115450, specs={Monk.MW}, baseCD=8, mods=DispelMod(115450), ignoreCast=true}, -- Detox
	{type="DEFMDISPEL", spellID=4987, specs={Paladin.Holy}, baseCD=8, mods=DispelMod(4987), ignoreCast=true}, -- Cleanse
	{type="DEFMDISPEL", spellID=527, specs={Priest.Disc, Priest.Holy}, baseCD=8, mods=DispelMod(527), ignoreCast=true}, -- Purify
	{type="DEFMDISPEL", spellID=77130, specs={Shaman.Resto}, baseCD=8, mods=DispelMod(77130), ignoreCast=true}, -- Purify Spirit
	-- Raid-Wide Defensives
	{type="RAIDCD", spellID=196718, specs={DH.Havoc}, baseCD=180}, -- Darkness
	{type="RAIDCD", spellID=31821, specs={Paladin.Holy}, baseCD=180}, -- Aura Mastery
	{type="RAIDCD", spellID=204150, specs={Paladin.Prot}, baseCD=180, reqTalents={63}, version=6}, -- Aegis of Light
	{type="RAIDCD", spellID=62618, specs={Priest.Disc}, baseCD=180, reqTalents={71,73}}, -- Power Word: Barrier
	{type="RAIDCD", spellID=207399, specs={Shaman.Resto}, baseCD=300, reqTalents={43}}, -- Ancestral Protection Totem
	{type="RAIDCD", spellID=98008, specs={Shaman.Resto}, baseCD=180}, -- Spirit Link Totem
	{type="RAIDCD", spellID=97462, class=Warrior, baseCD=180}, -- Rallying Cry
	-- External Defensives (Single Target)
	{type="EXTERNAL", spellID=102342, specs={Druid.Resto}, baseCD=60, modTalents={[62]=StaticMod("sub", 15)}}, -- Ironbark
	{type="EXTERNAL", spellID=116849, specs={Monk.MW}, baseCD=120}, -- Life Cocoon
	{type="EXTERNAL", spellID=6940, specs={Paladin.Holy, Paladin.Prot}, baseCD=120}, -- Blessing of Sacrifice
	{type="EXTERNAL", spellID=1022, specs={Paladin.Holy, Paladin.Ret}, baseCD=300}, -- Blessing of Protection
	{type="EXTERNAL", spellID=1022, specs={Paladin.Prot}, baseCD=300, reqTalents={41,42}}, -- Blessing of Protection
	{type="EXTERNAL", spellID=204018, specs={Paladin.Prot}, baseCD=180, reqTalents={43}}, -- Blessing of Spellwarding
	{type="EXTERNAL", spellID=33206, specs={Priest.Disc}, baseCD=180}, -- Pain Supression
	{type="EXTERNAL", spellID=47788, specs={Priest.Holy}, baseCD=180, modTalents={[32]=modGuardianSpirit}}, -- Guardian Spirit
	-- Healing and Healing Buffs
	{type="HEALING", spellID=33891, specs={Druid.Resto}, baseCD=180, reqTalents={53}, ignoreCast=true, mods=EventRemainingMod("SPELL_AURA_APPLIED",117679,180), version=6}, -- Incarnation: Tree of Life
	{type="HEALING", spellID=740, specs={Druid.Resto}, baseCD=180, modTalents={[61]=StaticMod("sub", 60)}}, -- Tranquility
	{type="HEALING", spellID=198664, specs={Monk.MW}, baseCD=180, reqTalents={63}, version=6}, -- Invoke Chi-Ji, the Red Crane
	{type="HEALING", spellID=115310, specs={Monk.MW}, baseCD=180}, -- Revival
	{type="HEALING", spellID=31884, specs={Paladin.Holy}, baseCD=120, reqTalents={61,63}, version=7}, -- Avenging Wrath
	{type="HEALING", spellID=216331, specs={Paladin.Holy}, baseCD=120, reqTalents={62}}, -- Avenging Crusader
	{type="HEALING", spellID=105809, specs={Paladin.Holy}, baseCD=90, reqTalents={53}}, -- Holy Avenger
	{type="HEALING", spellID=633, specs={Paladin.Holy}, baseCD=600, modTalents={[21]=StaticMod("mul", 0.7)}}, -- Lay on Hands
	{type="HEALING", spellID=633, specs={Paladin.Prot, Paladin.Ret}, baseCD=600, modTalents={[51]=StaticMod("mul", 0.7)}}, -- Lay on Hands
	{type="HEALING", spellID=210191, specs={Paladin.Ret}, baseCD=60, charges=2, reqTalents={63}, version=6}, -- Word of Glory
	{type="HEALING", spellID=246287, specs={Priest.Disc}, baseCD=90, reqTalents={73}}, -- Evangelism
	{type="HEALING", spellID=47536, specs={Priest.Disc}, baseCD=90}, -- Rapture
	{type="HEALING", spellID=271466, specs={Priest.Disc}, baseCD=180, reqTalents={72}}, -- Luminous Barrier
	{type="HEALING", spellID=200183, specs={Priest.Holy}, baseCD=120, reqTalents={72}}, -- Apotheosis
	{type="HEALING", spellID=64843, specs={Priest.Holy}, baseCD=180}, -- Divine Hymn
	{type="HEALING", spellID=265202, specs={Priest.Holy}, baseCD=720, reqTalents={73}, mods={CastDeltaMod(34861,-30), CastDeltaMod(2050,-30)}}, -- Holy Word: Salvation
	{type="HEALING", spellID=15286, specs={Priest.Shadow}, baseCD=120, modTalents={[22]=StaticMod("sub", 45)}}, -- Vampiric Embrace
	{type="HEALING", spellID=114052, specs={Shaman.Resto}, baseCD=180, reqTalents={73}}, -- Ascendance
	{type="HEALING", spellID=198838, specs={Shaman.Resto}, baseCD=60, reqTalents={42}}, -- Earthen Wall Totem
	{type="HEALING", spellID=108280, specs={Shaman.Resto}, baseCD=180}, -- Healing Tide Totem
	-- Utility (Movement, Taunts, etc)
	{type="UTILITY", spellID=205636, specs={Druid.Balance}, baseCD=60, reqTalents={13}}, -- Force of Nature (Treants)
	{type="UTILITY", spellID=29166, specs={Druid.Balance, Druid.Resto}, baseCD=180}, -- Innervate
	{type="UTILITY", spellID=106898, specs={Druid.Feral}, baseCD=120, version=2}, -- Stampeding Roar
	{type="UTILITY", spellID=106898, specs={Druid.Guardian}, baseCD=60, version=2}, -- Stampeding Roar
	{type="UTILITY", spellID=116841, class=Monk, baseCD=30, reqTalents={23}, version=6}, -- Tiger's Lust
	{type="UTILITY", spellID=1044, class=Paladin, baseCD=25, version=6}, -- Blessing of Freedom
	{type="UTILITY", spellID=73325, class=Priest, baseCD=90}, -- Leap of Faith
	{type="UTILITY", spellID=64901, specs={Priest.Holy}, baseCD=300}, -- Symbol of Hope
	{type="UTILITY", spellID=114018, class=Rogue, baseCD=360}, -- Shroud of Concealment
	{type="UTILITY", spellID=198103, class=Shaman, baseCD=300, version=2}, -- Earth Elemental
	{type="UTILITY", spellID=8143, class=Shaman, baseCD=60, version=6}, -- Tremor Totem
	{type="UTILITY", spellID=192077, class=Shaman, baseCD=120, reqTalents={53}, version=2}, -- Wind Rush Totem
	{type="UTILITY", spellID=58984, race="NightElf", baseCD=120, version=3}, -- Shadowmeld
	-- Personal Defensives
	{type="PERSONAL", spellID=198589, specs={DH.Havoc}, baseCD=60, mods=EventRemainingMod("SPELL_AURA_APPLIED", 212800, 60)}, -- Blur
	{type="PERSONAL", spellID=48792, class=DK, baseCD=180}, -- Icebound Fortitude
	{type="PERSONAL", spellID=48707, specs={DK.Frost, DK.Unholy}, baseCD=60}, -- Anti-Magic Shell
	{type="PERSONAL", spellID=48707, specs={DK.Blood}, baseCD=60, modTalents={[42]=StaticMod("sub", 15)}}, -- Anti-Magic Shell
	{type="PERSONAL", spellID=48743, specs={DK.Frost, DK.Unholy}, baseCD=120, reqTalents={53}}, -- Death Pact
	{type="PERSONAL", spellID=22812, specs={Druid.Balance, Druid.Guardian, Druid.Resto}, baseCD=60}, -- Barkskin
	{type="PERSONAL", spellID=108238, specs={Druid.Balance, Druid.Feral, Druid.Resto}, baseCD=90, reqTalents={22}, version=6}, -- Renewal
	{type="PERSONAL", spellID=61336, specs={Druid.Feral,Druid.Guardian}, baseCD=180, charges=2, version=6}, -- Survival Instincts
	{type="PERSONAL", spellID=109304, class=Hunter, baseCD=120}, -- Exhilaration
	{type="PERSONAL", spellID=5384, class=Hunter, baseCD=30, version=6}, -- Feign Death
	{type="PERSONAL", spellID=235219, specs={Mage.Frost}, baseCD=300}, -- Cold Snap
	{type="PERSONAL", spellID=122278, class=Monk, baseCD=120, reqTalents={53}}, -- Dampen Harm
	{type="PERSONAL", spellID=243435, specs={Monk.MW}, baseCD=90}, -- Fortifying Brew
	{type="PERSONAL", spellID=122281, specs={Monk.BRM}, baseCD=30, charges=2, reqTalents={52}, version=6}, -- Healing Elixir
	{type="PERSONAL", spellID=122281, specs={Monk.MW}, baseCD=30, charges=2, reqTalents={51}, version=6}, -- Healing Elixir
	{type="PERSONAL", spellID=122783, specs={Monk.MW, Monk.WW}, baseCD=90, reqTalents={52}}, -- Diffuse Magic
	{type="PERSONAL", spellID=122470, specs={Monk.WW}, baseCD=90}, -- Touch of Karma
	{type="PERSONAL", spellID=498, specs={Paladin.Holy}, baseCD=60}, -- Divine Protection
	{type="PERSONAL", spellID=184662, specs={Paladin.Ret}, baseCD=120, modTalents={[51]=StaticMod("mul", 0.7)}}, -- Shield of Vengeance
	{type="PERSONAL", spellID=205191, specs={Paladin.Ret}, baseCD=60, reqTalents={53}}, -- Eye for an Eye
	{type="PERSONAL", spellID=19236, specs={Priest.Disc, Priest.Holy}, baseCD=90}, -- Desperate Prayer
	{type="PERSONAL", spellID=47585, specs={Priest.Shadow}, baseCD=120, duration=6, modTalents={[23]=StaticMod("sub", 30)}, version=8}, -- Dispersion
	{type="PERSONAL", spellID=199754, specs={Rogue.Outlaw}, baseCD=120, version=2}, -- Riposte
	{type="PERSONAL", spellID=5277, specs={Rogue.Sin, Rogue.Sub}, baseCD=120, version=2}, -- Evasion
	{type="PERSONAL", spellID=108271, class=Shaman, baseCD=90}, -- Astral Shift
	{type="PERSONAL", spellID=108416, class=Warlock, baseCD=60, reqTalents={33}, version=6}, -- Dark Pact
	{type="PERSONAL", spellID=104773, class=Warlock, baseCD=180}, -- Unending Resolve
	{type="PERSONAL", spellID=118038, specs={Warrior.Arms}, baseCD=180}, -- Die by the Sword
	{type="PERSONAL", spellID=184364, specs={Warrior.Fury}, baseCD=120}, -- Enraged Regeneration
	-- Tank-Only Defensives
	{type="TANK", spellID=212084, specs={DH.Veng}, baseCD=60, reqTalents={63}, version=6}, -- Fel Devastation
	{type="TANK", spellID=204021, specs={DH.Veng}, baseCD=60}, -- Fiery Brand
	{type="TANK", spellID=187827, specs={DH.Veng}, baseCD=180}, -- Metamorphosis
	{type="TANK", spellID=206931, specs={DK.Blood}, baseCD=30, reqTalents={12}, version=6}, -- Blooddrinker
	{type="TANK", spellID=274156, specs={DK.Blood}, baseCD=45, reqTalents={23}, version=6}, -- Consumption
	{type="TANK", spellID=49028, specs={DK.Blood}, baseCD=120}, -- Dancing Rune Weapon
	{type="TANK", spellID=194679, specs={DK.Blood}, baseCD=25, charges=2, reqTalents={43}, version=6}, -- Rune Tap
	{type="TANK", spellID=194844, specs={DK.Blood}, baseCD=60, reqTalents={73}}, -- Bonestorm
	{type="TANK", spellID=55233, specs={DK.Blood}, baseCD=90, modTalents={[72]=ResourceSpendingMods(DK.Blood, 0.1)}}, -- Vampiric Blood
	{type="TANK", spellID=102558, specs={Druid.Guardian}, baseCD=180, reqTalents={53}, version=6}, -- Incarnation: Guardian of Ursoc
	{type="TANK", spellID=132578, specs={Monk.BRM}, baseCD=180, reqTalents={63}, version=4}, -- Invoke Niuzao
	{type="TANK", spellID=115203, specs={Monk.BRM}, baseCD=420}, -- Fortifying Brew
	{type="TANK", spellID=115176, specs={Monk.BRM}, baseCD=300}, -- Zen Meditation
	{type="TANK", spellID=31850, specs={Paladin.Prot}, baseCD=120, modTalents={[51]=StaticMod("mul", 0.7)}}, -- Ardent Defender
	{type="TANK", spellID=86659, specs={Paladin.Prot}, baseCD=300, version=5}, -- Guardian of the Ancient Kings
	{type="TANK", spellID=12975, specs={Warrior.Prot}, baseCD=180, modTalents={[43]=StaticMod("sub", 60), [71]=ResourceSpendingMods(Warrior.Prot, 0.1)}}, -- Last Stand
	{type="TANK", spellID=871, specs={Warrior.Prot}, baseCD=240, modTalents={[71]=ResourceSpendingMods(Warrior.Prot, 0.1)}}, -- Shield Wall
	{type="TANK", spellID=1160, specs={Warrior.Prot}, baseCD=45, modTalents={[71]=ResourceSpendingMods(Warrior.Prot, 0.1)}}, -- Demoralizing Shout
	{type="TANK", spellID=228920, specs={Warrior.Prot}, baseCD=60, reqTalents={73}, version=6}, -- Ravager
	{type="TANK", spellID=23920, specs={Warrior.Prot}, baseCD=25, version=6}, -- Spell Reflection
	-- Immunities
	{type="IMMUNITY", spellID=196555, specs={DH.Havoc}, baseCD=120, reqTalents={43}}, -- Netherwalk
	{type="IMMUNITY", spellID=186265, class=Hunter, baseCD=180, modTalents={[51]=StaticMod("mul", 0.8)}}, -- Aspect of the Turtle
	{type="IMMUNITY", spellID=45438, specs={Mage.Arcane,Mage.Fire}, baseCD=240}, -- Ice Block
	{type="IMMUNITY", spellID=45438, specs={Mage.Frost}, baseCD=240, mods=CastRemainingMod(235219, 0)}, -- Ice Block
	{type="IMMUNITY", spellID=642, specs={Paladin.Holy}, baseCD=300, modTalents={[21]=StaticMod("mul", 0.7)}}, -- Divine Shield
	{type="IMMUNITY", spellID=642, specs={Paladin.Prot, Paladin.Ret}, baseCD=300, modTalents={[51]=StaticMod("mul", 0.7)}}, -- Divine Shield
	{type="IMMUNITY", spellID=31224, class=Rogue, baseCD=120}, -- Cloak of Shadows
	-- Damage and Damage Buffs
	{type="DAMAGE", spellID=191427, specs={DH.Havoc}, baseCD=240}, -- Metamorphosis
	{type="DAMAGE", spellID=258925, specs={DH.Havoc}, baseCD=60, reqTalents={33}}, -- Fel Barrage
	{type="DAMAGE", spellID=206491, specs={DH.Havoc}, baseCD=120, reqTalents={73}}, -- Nemesis
	{type="DAMAGE", spellID=47568, specs={DK.Frost}, baseCD=120, version=6}, -- Empower Rune Weapon
	{type="DAMAGE", spellID=279302, specs={DK.Frost}, baseCD=180, reqTalents={63}}, -- Frostwyrm's Fury
	{type="DAMAGE", spellID=152279, specs={DK.Frost}, baseCD=120, reqTalents={73}}, -- Breath of Sindragosaa
	{type="DAMAGE", spellID=275699, specs={DK.Unholy}, baseCD=90, modTalents={[71]={CastDeltaMod(47541,-1), CastDeltaMod(207317,-1)}}, version=6}, -- Apocalypse
	{type="DAMAGE", spellID=42650, specs={DK.Unholy}, baseCD=480, modTalents={[71]={CastDeltaMod(47541,-5), CastDeltaMod(207317,-5)}}}, -- Army of the Dead
	{type="DAMAGE", spellID=49206, specs={DK.Unholy}, baseCD=180, reqTalents={73}}, -- Summon Gargoyle
	{type="DAMAGE", spellID=207289, specs={DK.Unholy}, baseCD=75, reqTalents={72}}, -- Unholy Frenzy
	{type="DAMAGE", spellID=194223, specs={Druid.Balance}, baseCD=180, reqTalents={51,52}}, -- Celestial Alignment
	{type="DAMAGE", spellID=202770, specs={Druid.Balance}, baseCD=60, reqTalents={72}, version=6}, -- Fury of Elune
	{type="DAMAGE", spellID=102560, specs={Druid.Balance}, baseCD=180, reqTalents={53}}, -- Incarnation: Chosen of Elune
	{type="DAMAGE", spellID=106951, specs={Druid.Feral}, baseCD=180, version=3}, -- Berserk
	{type="DAMAGE", spellID=102543, specs={Druid.Feral}, baseCD=180, reqTalents={53}}, -- Incarnation: King of the Jungle
	{type="DAMAGE", spellID=19574, specs={Hunter.BM}, baseCD=90, mods=CastDeltaMod(217200,-12)}, -- Bestial Wrath
	{type="DAMAGE", spellID=193530, specs={Hunter.BM}, baseCD=120}, -- Aspect of the Wild
	{type="DAMAGE", spellID=201430, specs={Hunter.BM}, baseCD=180, reqTalents={63}}, -- Stampede
	{type="DAMAGE", spellID=288613, specs={Hunter.MM}, baseCD=120, version=3}, -- Trueshot
	{type="DAMAGE", spellID=266779, specs={Hunter.SV}, baseCD=120}, -- Coordinated Assault
	{type="DAMAGE", spellID=55342, class=Mage, baseCD=120, reqTalents={32}}, -- Mirror Image
	{type="DAMAGE", spellID=12042, specs={Mage.Arcane}, baseCD=90}, -- Arcane Power
	{type="DAMAGE", spellID=190319, specs={Mage.Fire}, baseCD=120}, -- Combustion
	{type="DAMAGE", spellID=12472, specs={Mage.Frost}, baseCD=180}, -- Icy Veins
	{type="DAMAGE", spellID=115080, specs={Monk.WW}, baseCD=120}, -- Touch of Death
	{type="DAMAGE", spellID=123904, specs={Monk.WW}, baseCD=180, reqTalents={63}}, -- Invoke Xuen, the White Tiger
	{type="DAMAGE", spellID=137639, specs={Monk.WW}, baseCD=90, charges=2, reqTalents={71, 72}, version=6}, -- Storm, Earth, and Fire
	{type="DAMAGE", spellID=152173, specs={Monk.WW}, baseCD=90, reqTalents={73}}, -- Serenity
	{type="DAMAGE", spellID=152262, specs={Paladin.Prot}, baseCD=45, reqTalents={73}, version=6}, -- Seraphim
	{type="DAMAGE", spellID=31884, specs={Paladin.Prot}, baseCD=120, version=6}, -- Avenging Wrath
	{type="DAMAGE", spellID=31884, specs={Paladin.Ret}, baseCD=120, reqTalents={71,73}}, -- Avenging Wrath
	{type="DAMAGE", spellID=231895, specs={Paladin.Ret}, baseCD=120, reqTalents={72}}, -- Crusade
	{type="DAMAGE", spellID=280711, specs={Priest.Shadow}, baseCD=60, reqTalents={72}}, -- Dark Ascension
	{type="DAMAGE", spellID=193223, specs={Priest.Shadow}, baseCD=180, reqTalents={73}}, -- Surrender to Madness
	{type="DAMAGE", spellID=13750, specs={Rogue.Outlaw}, baseCD=180}, -- Adrenaline Rush
	{type="DAMAGE", spellID=51690, specs={Rogue.Outlaw}, baseCD=120, reqTalents={73}}, -- Killing Spree
	{type="DAMAGE", spellID=79140, specs={Rogue.Sin}, baseCD=120}, -- Vendetta
	{type="DAMAGE", spellID=121471, specs={Rogue.Sub}, baseCD=180}, -- Shadow Blades
	{type="DAMAGE", spellID=114050, specs={Shaman.Ele}, baseCD=180, reqTalents={73}}, -- Ascendance
	{type="DAMAGE", spellID=192249, specs={Shaman.Ele}, baseCD=150, reqTalents={42}, version=3}, -- Storm Elemental
	{type="DAMAGE", spellID=191634, specs={Shaman.Ele}, baseCD=60, reqTalents={72}, version=3}, -- Stormkeeper
	{type="DAMAGE", spellID=114051, specs={Shaman.Enh}, baseCD=180, reqTalents={73}}, -- Ascendance
	{type="DAMAGE", spellID=51533, specs={Shaman.Enh}, baseCD=180, modTalents={[71]=StaticMod("sub", 30)}, version=6}, -- Feral Spirit
	{type="DAMAGE", spellID=205180, specs={Warlock.Affl}, baseCD=180}, -- Summon Darkglare
	{type="DAMAGE", spellID=113860, specs={Warlock.Affl}, baseCD=120, reqTalents={73}}, -- Dark Soul: Misery
	{type="DAMAGE", spellID=265187, specs={Warlock.Demo}, baseCD=90}, -- Summon Demonic Tyrant
	{type="DAMAGE", spellID=267217, specs={Warlock.Demo}, baseCD=180, reqTalents={73}}, -- Nether Portal
	{type="DAMAGE", spellID=113858, specs={Warlock.Destro}, baseCD=120, reqTalents={73}}, -- Dark Soul: Instability
	{type="DAMAGE", spellID=1122, specs={Warlock.Destro}, baseCD=180}, -- Summon Infernal
	{type="DAMAGE", spellID=227847, specs={Warrior.Arms}, baseCD=90, modTalents={[71]=ResourceSpendingMods(Warrior.Arms, 0.05)}}, -- Bladestorm
	{type="DAMAGE", spellID=107574, specs={Warrior.Arms}, baseCD=120, reqTalents={62}}, -- Avatar
	{type="DAMAGE", spellID=1719, specs={Warrior.Fury}, baseCD=90, modTalents={[72]=ResourceSpendingMods(Warrior.Fury, 0.05)}}, -- Recklessness
	{type="DAMAGE", spellID=46924, specs={Warrior.Fury}, baseCD=60, reqTalents={63}}, -- Bladestorm
	{type="DAMAGE", spellID=107574, specs={Warrior.Prot}, baseCD=120, modTalents={[71]=ResourceSpendingMods(Warrior.Prot, 0.1)}, version=6}, -- Avatar
}

ZT.linkedSpellIDs = {
	[19647]  = {119910, 132409, 115781}, -- Spell Lock
	[132469] = {61391}, -- Typhoon
	[191427] = {200166}, -- Metamorphosis
	[106898] = {77761, 77764}, -- Stampeding Roar
	[86659] = {212641}, -- Guardian of the Ancient Kings (+Glyph)
}

ZT.separateLinkedSpellIDs = {
	[86659] = {212641}, -- Guardian of the Ancient Kings (+Glyph)
}

--##############################################################################
-- Handling custom spells specified by the user in the configuration

local spellConfigFuncHeader = "return function(DK,DH,Druid,Hunter,Mage,Monk,Paladin,Priest,Rogue,Shaman,Warlock,Warrior,StaticMod,DynamicMod,EventDeltaMod,CastDeltaMod,EventRemainingMod,CastRemainingMod,DispelMod)"

local function trim(s) -- From PiL2 20.4
	return (s:gsub("^%s*(.-)%s*$", "%1"))
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

	if type(spellConfig.spellID) ~= "number" then
		prerror("Custom Spell", i, "does not have a valid 'spellID' entry")
		return
	end

	if type(spellConfig.baseCD) ~= "number" then
		prerror("Custom Spell", i, "does not have a valid 'baseCD' entry")
		return
	end

	spellConfig.version = 10000
	spellConfig.isCustom = true

	ZT.spells[#ZT.spells + 1] = spellConfig
end
--[[
for i = 1,16 do
	local spellConfig = ZT.config["custom"..i]
	if spellConfig then
		spellConfig = trim(spellConfig)

		if spellConfig ~= "" then
			local spellConfigFuncStr = spellConfigFuncHeader.." return "..spellConfig.." end"
			local spellConfigFunc = WeakAuras.LoadFunction(spellConfigFuncStr, "ZenTracker Custom Spell "..i)
			if spellConfigFunc then
				local spellConfig = spellConfigFunc(DK,DH,Druid,Hunter,Mage,Monk,Paladin,Priest,Rogue,Shaman,Warlock,Warrior,
					StaticMod,DynamicMod,EventDeltaMod,CastDeltaMod,EventRemainingMod,CastRemainingMod,DispelMod)
				addCustomSpell(spellConfig, i)
			end
		end
	end
end
--]]

--##############################################################################
-- Compiling the complete indexed tables of spells

ZT.spellsByRace = DefaultTable_Create(function() return DefaultTable_Create(function() return {} end) end)
ZT.spellsByClass = DefaultTable_Create(function() return DefaultTable_Create(function() return {} end) end)
ZT.spellsBySpec = DefaultTable_Create(function() return DefaultTable_Create(function() return {} end) end)
ZT.spellsByType = DefaultTable_Create(function() return {} end)
ZT.spellsByID = DefaultTable_Create(function() return {} end)

local function isSpellBlacklisted(spellInfo)
	local spellID = spellInfo.spellID

	local spellName = GetSpellInfo(spellID);
	spellName = spellName:gsub('%s+', '');
	local isBlacklisted = ZT.db.blacklist[spellName];

	return isBlacklisted
end

-- Building a complete list of tracked spells
function ZT:BuildSpellList()
	for _,spellInfo in ipairs(ZT.spells) do
		-- Making the structuring for spell info more uniform
		spellInfo.version = spellInfo.version or 1
		spellInfo.specs = spellInfo.specs and Map_FromTable(spellInfo.specs)
		spellInfo.mods = Table_Create(spellInfo.mods)
		if spellInfo.modTalents then
			for talent,mods in pairs(spellInfo.modTalents) do
				spellInfo.modTalents[talent] = Table_Create(mods)
			end
		end

		spellInfo.isRegistered = false
		spellInfo.frontends = {}

		-- Indexing for faster lookups
		local spells
		if spellInfo.race then
			if spellInfo.class then
				spells = ZT.spellsByRace[spellInfo.race][spellInfo.class]
				spells[#spells + 1] = spellInfo
			else
				for _,class in pairs(AllClasses) do
					spells = ZT.spellsByRace[spellInfo.race][class]
					spells[#spells + 1] = spellInfo
				end
			end
		elseif spellInfo.class then
			if spellInfo.reqTalents then
				for _,talent in ipairs(spellInfo.reqTalents) do
					spells = ZT.spellsByClass[spellInfo.class][talent]
					spells[#spells + 1] = spellInfo
				end
			else
				if spellInfo.modTalents then
					for talent,_ in pairs(spellInfo.modTalents) do
						spells = ZT.spellsByClass[spellInfo.class][talent]
						spells[#spells + 1] = spellInfo
					end
				end
				spells = ZT.spellsByClass[spellInfo.class]["Base"]
				spells[#spells + 1] = spellInfo
			end
		elseif spellInfo.specs then
			for specID,_ in pairs(spellInfo.specs) do
				if spellInfo.reqTalents then
					for _,talent in ipairs(spellInfo.reqTalents) do
						spells = ZT.spellsBySpec[specID][talent]
						spells[#spells + 1] = spellInfo
					end
				else
					if spellInfo.modTalents then
						for talent,_ in pairs(spellInfo.modTalents) do
							spells = ZT.spellsBySpec[specID][talent]
							spells[#spells + 1] = spellInfo
						end
					end
					spells = ZT.spellsBySpec[specID]["Base"]
					spells[#spells + 1] = spellInfo
				end
			end
		else
			spells = ZT.spellsByClass["None"]
			spells[#spells + 1] = spellInfo
		end

		spells = ZT.spellsByType[spellInfo.type]
		spells[#spells + 1] = spellInfo

		spells = ZT.spellsByID[spellInfo.spellID]
		spells[#spells + 1] = spellInfo
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
	local heap = self.heap

	local fixHeapFunc = (time <= timer.time) and self.fixHeapUpwards or self.fixHeapDownwards
	timer.time = time

	fixHeapFunc(self, timer.index)
	self:setupCallback()
end

--##############################################################################
-- Managing the set of <spell, member> pairs that are being watched

local WatchInfo = { nextID = 1 }
local WatchInfoMT = { __index = WatchInfo }

ZT.watching = {}

function WatchInfo:create(member, specInfo, spellInfo, isHidden)
	local watchInfo = {
		watchID = self.nextID,
		member = member,
		spellInfo = spellInfo,
		duration = member:calcSpellCD(spellInfo, specInfo),
		expiration = GetTime(),
		charges = spellInfo.charges,
		isHidden = isHidden,
		isLazy = spellInfo.isLazy,
		ignoreSharing = false,
	}
	self.nextID = self.nextID + 1

	watchInfo = setmetatable(watchInfo, WatchInfoMT)
	return watchInfo
end

function WatchInfo:sendAddEvent()
	if not self.isLazy and not self.isHidden then
		local spellInfo = self.spellInfo
		prdebug(DEBUG_EVENT, "Sending ZT_ADD", spellInfo.type, self.watchID, self.member.name, spellInfo.spellID, self.duration, self.charges)
		WeakAuras.ScanEvents("ZT_ADD", spellInfo.type, self.watchID, self.member, spellInfo.spellID, self.duration, self.charges)

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
		prdebug(DEBUG_EVENT, "Sending ZT_TRIGGER", self.spellInfo.type, self.watchID, self.duration, self.expiration, self.charges)
		WeakAuras.ScanEvents("ZT_TRIGGER", self.spellInfo.type, self.watchID, self.duration, self.expiration, self.charges)
	end
end

function WatchInfo:sendRemoveEvent()
	if not self.isLazy and not self.isHidden then
		prdebug(DEBUG_EVENT, "Sending ZT_REMOVE", self.spellInfo.type, self.watchID)
		WeakAuras.ScanEvents("ZT_REMOVE", self.spellInfo.type, self.watchID)
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
		if self.charges < self.spellInfo.charges then
			self.expiration = self.expiration + self.duration
			prdebug(DEBUG_TIMER, "Adding ready timer of", self.expiration, "for spellID", self.spellInfo.spellID)
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
			prdebug(DEBUG_TIMER, "Updating ready timer from", self.readyTimer.time, "to", self.expiration, "for spellID", self.spellInfo.spellID)
			ZT.timers:update(self.readyTimer, self.expiration)
		else
			prdebug(DEBUG_TIMER, "Adding ready timer of", self.expiration, "for spellID", self.spellInfo.spellID)
			self.readyTimer = ZT.timers:add(self.expiration, function() self:handleReadyTimer() end)
		end

		return true
	else
		if self.readyTimer then
			prdebug(DEBUG_TIMER, "Canceling ready timer for spellID", self.spellInfo.spellID)
			ZT.timers:cancel(self.readyTimer)
			self.readyTimer = nil
		end

		self:handleReadyTimer(self.expiration)
		return false
	end
end

function WatchInfo:startCD()
	if self.charges then
		if self.charges == 0 or self.charges == self.spellInfo.charges then
			self.expiration = GetTime() + self.duration
			self:updateReadyTimer()
		end

		if self.charges > 0 then
			self.charges = self.charges - 1
		end
	else
		self.expiration = GetTime() + self.duration
		self:updateReadyTimer()
	end

	self:sendTriggerEvent()
end

function WatchInfo:updateCDDelta(delta)
	self.expiration = self.expiration + delta

	local time = GetTime()
	local remaining = self.expiration - time

	if self.charges and remaining <= 0 then
		local chargesGained = 1 - floor(remaining / self.duration)
		self.charges = max(self.charges + chargesGained, self.spellInfo.charges)
		if self.charges == self.spellInfo.charges then
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
		if self.charges < self.spellInfo.charges then
			self.charges = self.charges + 1
		end

		-- Below maximum charges the expiration time doesn't change
		if self.charges < self.spellInfo.charges then
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
	charges = GetSpellCharges(self.spellInfo.spellID)
	if charges then
		self.charges = charges
	end
end

function WatchInfo:updatePlayerCD(spellID, ignoreIfReady)
	local startTime, duration, enabled
	if self.charges then
		local charges, maxCharges
		charges, maxCharges, startTime, duration = GetSpellCharges(spellID)
		if charges == maxCharges then
			startTime = 0
		end
		enabled = 1
		self.charges = charges
	else
		startTime, duration, enabled = GetSpellCooldown(spellID)
	end

	if enabled ~= 0 then
		local ignoreRateLimit
		if startTime ~= 0 then
			ignoreRateLimit = (self.expiration < GetTime())
			self.duration = duration
			self.expiration = startTime + duration
		else
			ignoreRateLimit = true
			self.expiration = GetTime()
		end

		if (not ignoreIfReady) or (startTime ~= 0) then
			ZT:sendCDUpdate(self, ignoreRateLimit)
			self:sendTriggerEvent()
		end
	end
end

function ZT:togglePlayerHandlers(watchInfo, enable)
	local spellID = watchInfo.spellInfo.spellID
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
end

function ZT:toggleCombatLogHandlers(watchInfo, enable, specInfo)
	local spellInfo = watchInfo.spellInfo
	local spellID = spellInfo.spellID
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

	for _,modifier in pairs(spellInfo.mods) do
		if modifier.type == "Dynamic" then
			for _,handlerInfo in ipairs(modifier.handlers) do
				toggleHandlerFunc(self.eventHandlers, handlerInfo.type, handlerInfo.spellID, member.GUID, handlerInfo.handler, watchInfo)
			end
		end
	end

	if spellInfo.modTalents then
		for talent, modifiers in pairs(spellInfo.modTalents) do
			if specInfo.talentsMap[talent] then
				for _, modifier in pairs(modifiers) do
					if modifier.type == "Dynamic" then
						for _,handlerInfo in ipairs(modifier.handlers) do
							toggleHandlerFunc(self.eventHandlers, handlerInfo.type, handlerInfo.spellID, member.GUID, handlerInfo.handler, watchInfo)
						end
					end
				end
			end
		end
	end
end

function ZT:watch(spellInfo, member, specInfo)
	-- Only handle registered spells (or those for the player)
	if not spellInfo.isRegistered and not member.isPlayer then
		return
	end

	local spellID = spellInfo.spellID
	local spells = self.watching[spellID]
	if not spells then
		spells = {}
		self.watching[spellID] = spells
	end

	specInfo = specInfo or member.specInfo
	local isHidden = (member.isPlayer and not spellInfo.isRegistered) or member.isHidden

	local watchInfo = spells[member.GUID]
	local isNew = (watchInfo == nil)
	if not watchInfo then
		watchInfo = WatchInfo:create(member, specInfo, spellInfo, isHidden)
		spells[member.GUID] = watchInfo
		member.watching[spellID] = watchInfo
	else
		watchInfo.spellInfo = spellInfo
		watchInfo.charges = spellInfo.charges
		watchInfo.duration = member:calcSpellCD(spellInfo, specInfo)
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
			self:toggleCombatLogHandlers(watchInfo, false, member.specInfo)
		end
		self:toggleCombatLogHandlers(watchInfo, true, specInfo)
	else
		watchInfo.ignoreSharing = false
	end
end

function ZT:unwatch(spellInfo, member)
	-- Only handle registered spells (or those for the player)
	if not spellInfo.isRegistered and not member.isPlayer then
		return
	end

	local spellID = spellInfo.spellID
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
		self:toggleCombatLogHandlers(watchInfo, false, member.specInfo)
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
			local watched = self.watching[spellInfo.spellID]
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
				if member:knowsSpell(spellInfo) and not member.isIgnored then
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
			local watched = self.watching[spellInfo.spellID]
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
		registerFunc(self, frontendID, self.spellsByType[info])
	elseif infoType == "number" then -- Registration info is a spellID
		prdebug(DEBUG_EVENT, "Received", toggle and "ZT_REGISTER" or "ZT_UNREGISTER", "from", frontendID, "for spellID", info)
		registerFunc(self, frontendID, self.spellsByID[info])
	elseif infoType == "table" then -- Registration info is a table of types or spellIDs
		infoType = type(info[1])

		if infoType == "string" then
			prdebug(DEBUG_EVENT, "Received", toggle and "ZT_REGISTER" or "ZT_UNREGISTER", "from", frontendID, "for multiple types")
			for _,type in ipairs(info) do
				registerFunc(self, frontendID, self.spellsByType[type])
			end
		elseif infoType == "number" then
			prdebug(DEBUG_EVENT, "Received", toggle and "ZT_REGISTER" or "ZT_UNREGISTER", "from", frontendID, "for multiple spells")
			for _,spellID in ipairs(info) do
				registerFunc(self, frontendID, self.spellsByID[spellID])
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

function Member:gatherInfo()
	local _,className,_,race,_,name = GetPlayerInfoByGUID(self.GUID)
	self.name = name and gsub(name, "%-[^|]+", "") or nil
	self.class = className and AllClasses[className] or nil
	self.classID = className and AllClasses[className].ID or nil
	self.classColor = className and RAID_CLASS_COLORS[className] or nil
	self.race = race

	if (self.tracking == "Sharing") and self.name then
		prdebug(DEBUG_TRACKING, self.name, "is using ZenTracker with spellsVersion", self.spellsVersion)
	end

	if self.name and membersToIgnore[strlower(self.name)] then
		self.isIgnored = true
		return false
	end

	self.isReady = (self.name ~= nil) and (self.classID ~= nil) and (self.race ~= nil)
	return self.isReady
end

function Member:knowsSpell(spellInfo, specInfo)
	specInfo = specInfo or self.specInfo

	if spellInfo.race and spellInfo.race ~= self.race then
		return false
	end
	if spellInfo.class and spellInfo.class.ID ~= self.classID then
		return false
	end
	if spellInfo.specs and (not specInfo.specID or not spellInfo.specs[specInfo.specID]) then
		return false
	end

	if not spellInfo.reqTalents then
		return true
	end
	for _,t in ipairs(spellInfo.reqTalents) do
		if specInfo.talentsMap[t] then
			return true
		end
	end

	return false
end

function Member:calcSpellCD(spellInfo, specInfo)
	specInfo = specInfo or self.specInfo

	local cooldown = spellInfo.baseCD
	if spellInfo.modTalents then
		for talent,modifiers in pairs(spellInfo.modTalents) do
			if specInfo.talentsMap[talent] then
				for _,modifier in ipairs(modifiers) do
					if modifier.type == "Static" then
						if modifier.sub then
							cooldown = cooldown - modifier.sub
						elseif modifier.mul then
							cooldown = cooldown * modifier.mul
						end
					end
				end
			end
		end
	end

	return cooldown
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

function ZT:addOrUpdateMember(memberInfo)
	local specInfo = memberInfo.specInfo

	local member = self.members[memberInfo.GUID]
	if not member then
		member = Member:create(memberInfo)
		self.members[member.GUID] = member
	end

	if member.isIgnored then
		return
	end

	-- Update if the member is now ready, or if they swapped specs/talents
	local needsUpdate = not member.isReady and member:gatherInfo()
	local needsSpecUpdate = specInfo.specID and (specInfo.specID ~= member.specInfo.specID)
	local needsTalentUpdate = specInfo.talents and (specInfo.talents ~= member.specInfo.talents)

	if member.isReady and (needsUpdate or needsSpecUpdate or needsTalentUpdate) then
		-- This handshake comes before any cooldown updates for newly watched spells
		if member.isPlayer then
			self:sendHandshake(specInfo)
		end

		-- If we are in an encounter, hide the member if they are outside the player's instance
		-- (Note: Previously did this on member creation, which seemed to introduce false positives)
		if needsUpdate and self.inEncounter and not member.isPlayer then
			local _,_,_,instanceID = UnitPosition("player")
			local _,_,_,mInstanceID = UnitPosition(self.inspectLib:GuidToUnit(member.GUID))
			if instanceID ~= mInstanceID then
				member:hide()
			end
		end

		-- Generic Spells (i.e., no class/race/spec)
		-- Note: These are set once and never change
		if needsUpdate then
			for _,spellInfo in ipairs(self.spellsByClass["None"]) do
				self:watch(spellInfo, member, specInfo)
			end
		end

		-- Class Spells (Base) + Race Spells
		-- Note: These are set once and never change
		if needsUpdate then
			for _,spellInfo in ipairs(self.spellsByRace[member.race][member.class]) do
				self:watch(spellInfo, member, specInfo)
			end

			for _,spellInfo in ipairs(self.spellsByClass[member.class]["Base"]) do
				self:watch(spellInfo, member, specInfo)
			end
		end

		-- Class Spells (Talented)
		if needsUpdate or needsTalentUpdate then
			local classSpells = self.spellsByClass[member.class]

			for talent,_ in pairs(specInfo.talentsMap) do
				for _,spellInfo in ipairs(classSpells[talent]) do
					self:watch(spellInfo, member, specInfo)
				end
			end

			if needsTalentUpdate then
				for talent,_ in pairs(member.specInfo.talentsMap) do
					if not specInfo.talentsMap[talent] then
						for _,spellInfo in ipairs(classSpells[talent]) do
							if not member:knowsSpell(spellInfo, specInfo) then
								self:unwatch(spellInfo, member)
							else
								self:watch(spellInfo, member, specInfo)
							end
						end
					end
				end
			end
		end

		-- Specialization Spells (Base/Talented)
		if (needsUpdate or needsSpecUpdate or needsTalentUpdate) and specInfo.specID then
			local specSpells = self.spellsBySpec[specInfo.specID]

			if needsUpdate or needsSpecUpdate then
				for _,spellInfo in ipairs(specSpells["Base"]) do
					self:watch(spellInfo, member, specInfo)
				end
			end
			for talent,_ in pairs(specInfo.talentsMap) do
				for _,spellInfo in ipairs(specSpells[talent]) do
					self:watch(spellInfo, member, specInfo)
				end
			end

			if (needsSpecUpdate or needsTalentUpdate) and member.specInfo.specID then
				specSpells = self.spellsBySpec[member.specInfo.specID]

				if needsSpecUpdate then
					for _,spellInfo in ipairs(specSpells["Base"]) do
						if not member:knowsSpell(spellInfo, specInfo) then
							self:unwatch(spellInfo, member)
						else
							self:watch(spellInfo, member, specInfo)
						end
					end
				end

				for talent,_ in pairs(member.specInfo.talentsMap) do
					if not specInfo.talentsMap[talent] then
						for _,spellInfo in ipairs(specSpells[talent]) do
							if not member:knowsSpell(spellInfo, specInfo) then
								self:unwatch(spellInfo, member)
							else
								self:watch(spellInfo, member, specInfo)
							end
						end
					end
				end
			end
		end

		member.specInfo = specInfo
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
				self:toggleCombatLogHandlers(watchInfo, false, member.specInfo)
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
				watchInfo.charges = watchInfo.spellInfo.charges
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
-- Handling the exchange of addon messages with other ZT clients
--
-- Message Format = <Protocol Version (%d)>:<Message Type (%s)>:<Member GUID (%s)>...
--   Type = "H" (Handshake)
--     ...:<Spec ID (%d)>:<Talents (%s)>:<IsInitial? (%d) [2]>:<Spells Version (%d) [2]>
--   Type = "U" (CD Update)
--     ...:<Spell ID (%d)>:<Duration (%f)>:<Remaining (%f)>:<#Charges (%d) [3]>

ZT.protocolVersion = 3

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
function ZT:sendHandshake(specInfo)
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

	specInfo = specInfo or self.members[GUID].specInfo
	local specID = specInfo.specID or 0
	local talents = specInfo.talents or ""
	local isInitial = self.hasSentHandshake and 0 or 1
	local message = string.format("%d:H:%s:%d:%s:%d:%d", self.protocolVersion, GUID, specID, talents, isInitial, self.spellsVersion)
	sendMessage(message)

	self.hasSentHandshake = true
	self.timeOfNextHandshake = time + self.timeBetweenHandshakes
	if self.handshakeTimer then
		self.timers:cancel(self.handshakeTimer)
		self.handshakeTimer = nil
	end
end

function ZT:sendCDUpdate(watchInfo, ignoreRateLimit)
	local spellID = watchInfo.spellInfo.spellID
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

	local GUID = watchInfo.member.GUID
	local duration = watchInfo.duration
	local remaining = watchInfo.expiration - time
	if remaining < 0 then
		remaining = 0
	end
	local charges = watchInfo.charges and tostring(watchInfo.charges) or "-"
	local message = string.format("%d:U:%s:%d:%0.2f:%0.2f:%s", self.protocolVersion, GUID, spellID, duration, remaining, charges)
	sendMessage(message)

	self.timeOfNextCDUpdate[spellID] = time + self.timeBetweenCDUpdates
end

function ZT:handleHandshake(mGUID, specID, talents, isInitial, spellsVersion)
	specID = tonumber(specID)
	if specID == 0 then
		specID = nil
	end

	local talentsMap = {}
	if talents ~= "" then
		for index in talents:gmatch("%d%d") do
			index = tonumber(index)
			talentsMap[index] = true
		end
	else
		talents = nil
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

	local memberInfo = {
		GUID = mGUID,
		specInfo = {
			specID = specID,
			talents = talents,
			talentsMap = talentsMap,
		},
		tracking = "Sharing",
		spellsVersion = spellsVersion,
	}

	self:addOrUpdateMember(memberInfo)
	if isInitial then
		self:sendHandshake()
	end
end

function ZT:handleCDUpdate(mGUID, spellID, duration, remaining, charges)
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

		-- Protocol V3: Ignore charges if not present
		-- (Note that this shouldn't happen because of spell list version handling)
		if charges then
			charges = tonumber(charges)
			if charges then
				watchInfo.charges = charges
			end
		end

		watchInfo.duration = duration
		watchInfo.expiration = GetTime() + remaining
		watchInfo:sendTriggerEvent()
	end
end

function ZT:handleMessage(message)
	local protocolVersion, type, mGUID, arg1, arg2, arg3, arg4, arg5 = strsplit(":", message)

	-- Ignore any messages sent by the player
	if mGUID == UnitGUID("player") then
		return
	end

	prdebug(DEBUG_MESSAGE, "Received message '"..message.."'")

	if type == "H" then     -- Handshake
		self:handleHandshake(mGUID, arg1, arg2, arg3, arg4, arg5)
	elseif type == "U" then -- CD Update
		self:handleCDUpdate(mGUID, arg1, arg2, arg3, arg4, arg5)
	else
		return
	end
end

--##############################################################################
-- Callback functions for libGroupInspecT for updating/removing members

ZT.delayedUpdates = {}

function ZT:libInspectUpdate(event, GUID, unit, info)
	local specID = info.global_spec_id
	if specID == 0 then
		specID = nil
	end

	local talents
	local talentsMap = {}
	if info.talents then
		for _,talentInfo in pairs(info.talents) do
			local index = (talentInfo.tier * 10) + talentInfo.column
			if not talents then
				talents = ""..index
			else
				talents = talents..","..index
			end

			talentsMap[index] = true
		end
	end

	local memberInfo = {
		GUID = GUID,
		specInfo = {
			specID = specID,
			talents = talents,
			talentsMap = talentsMap,
		},
	}

	if not self.delayedUpdates then
		self:addOrUpdateMember(memberInfo)
	else
		self.delayedUpdates[#self.delayedUpdates + 1] = memberInfo
	end
end

function ZT:libInspectRemove(event, GUID)
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
		for _,memberInfo in ipairs(self.delayedUpdates) do
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