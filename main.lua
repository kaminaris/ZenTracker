local addonName, ZT = ...;

_G[addonName] = ZT;

ZT.inspectLib = LibStub:GetLibrary("LibGroupInSpecT-1.1", true);

-- Class/Spec ID List
local DK = { ID = 6, name = "DEATHKNIGHT", Blood = 250, Frost = 251, Unholy = 252 }
local DH = { ID = 12, name = "DEMONHUNTER", Havoc = 577, Veng = 581 }
local Druid = { ID = 11, name = "DRUID", Balance = 102, Feral = 103, Guardian = 104, Resto = 105 }
local Hunter = { ID = 3, name = "HUNTER", BM = 253, MM = 254, SV = 255 }
local Mage = { ID = 8, name = "MAGE", Arcane = 62, Fire = 63, Frost = 64 }
local Monk = { ID = 10, name = "MONK", BRM = 268, WW = 269, MW = 270 }
local Paladin = { ID = 2, name = "PALADIN", Holy = 65, Prot = 66, Ret = 70 }
local Priest = { ID = 5, name = "PRIEST", Disc = 256, Holy = 257, Shadow = 258 }
local Rogue = { ID = 4, name = "ROGUE", Sin = 259, Outlaw = 260, Sub = 261 }
local Shaman = { ID = 7, name = "SHAMAN", Ele = 262, Enh = 263, Resto = 264 }
local Warlock = { ID = 9, name = "WARLOCK", Affl = 265, Demo = 266, Destro = 267 }
local Warrior = { ID = 1, name = "WARRIOR", Arms = 71, Fury = 72, Prot = 73 }

local AllClasses = {
	[DK.name] = DK, [DH.name] = DH, [Druid.name] = Druid, [Hunter.name] = Hunter,
	[Mage.name] = Mage, [Monk.name] = Monk, [Paladin.name] = Paladin,
	[Priest.name] = Priest, [Rogue.name] = Rogue, [Shaman.name] = Shaman,
	[Warlock.name] = Warlock, [Warrior.name] = Warrior
}

-- Local versions of commonly used functions
local ipairs = ipairs
local pairs = pairs
local print = print
local select = select
local tonumber = tonumber

local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local GetTime = GetTime
local UnitGUID = UnitGUID
local C_ChatInfo_SendAddonMessage = C_ChatInfo.SendAddonMessage

--------------------------------------------------------------------------------
-- BEGIN SPELL COOLDOWN MODIFIERS
--------------------------------------------------------------------------------

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
			watchInfo:updateDelta(delta)
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
			watchInfo:updateRemaining(remaining)
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
				watchInfo:updateDelta(-15)
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
					watchInfo:updateDelta(-5)
				end
			end
		end

		if watchInfo.totemGUID then
			ZT:removeEventHandler("SPELL_AURA_APPLIED", 118905, watchInfo.totemGUID, watchInfo.totemHandler)
		end

		watchInfo.totemGUID = select(8, CombatLogGetCurrentEventInfo())
		ZT:addEventHandler("SPELL_AURA_APPLIED", 118905, watchInfo.totemGUID, watchInfo.totemHandler, watchInfo)
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
				watchInfo:updateRemaining(60)
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
			watchInfo:updateRemaining(8)
		end
	})
end

-- Resource Spending: For every spender, reduce cooldown by (coefficient * cost) seconds
--   Note: By default, I use minimum cost values as to not over-estimate the cooldown reduction
local specIDToSpenderInfo = {
	[DK.Blood] = {resourceType="RUNIC_POWER", spells={[49998]=40, [61999]=30, [206940]=30}},
}

local function ResourceSpendingMods(specID, coefficient)
	local handlers = {}
	local spenderInfo = specIDToSpenderInfo[specID]

	for spellID,cost in pairs(spenderInfo.spells) do
		local delta = -(coefficient * cost)

		handlers[#handlers+1] = {
			type = "SPELL_CAST_SUCCESS",
			spellID = spellID,
			handler = function(watchInfo)
				watchInfo:updateDelta(delta)
			end
		}
	end

	return DynamicMod(handlers)
end

--------------------------------------------------------------------------------
-- END SPELL COOLDOWN MODIFIERS
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- BEGIN TRACKED SPELLS
--------------------------------------------------------------------------------

ZT.typeToTrackedSpells = {}

ZT.typeToTrackedSpells["INTERRUPT"] = {
	{spellID=183752, class=DH, baseCD=15}, -- Consume Magic
	{spellID=47528, class=DK, baseCD=15}, -- Mind Freeze
	{spellID=91802, specs={DK.Unholy}, baseCD=30}, -- Shambling Rush
	{spellID=78675, specs={Druid.Balance}, baseCD=60}, -- Solar Beam
	{spellID=106839, specs={Druid.Feral,Druid.Guardian}, baseCD=15}, -- Skull Bash
	{spellID=147362, specs={Hunter.BM, Hunter.MM}, baseCD=24}, -- Counter Shot
	{spellID=187707, specs={Hunter.SV}, baseCD=15}, -- Muzzle
	{spellID=2139, class=Mage, baseCD=24}, -- Counter Spell
	{spellID=116705, specs={Monk.WW, Monk.BRM}, baseCD=15}, -- Spear Hand Strike
	{spellID=96231, specs={Paladin.Prot, Paladin.Ret}, baseCD=15}, -- Rebuke
	{spellID=15487, specs={Priest.Shadow}, baseCD=45, modTalents={[41]=StaticMod("sub", 15)}}, -- Silence
	{spellID=1766, class=Rogue, baseCD=15}, -- Kick
	{spellID=57994, class=Shaman, baseCD=12}, -- Wind Shear
	{spellID=19647, class=Warlock, baseCD=24}, -- Spell Lock
	{spellID=6552, class=Warrior, baseCD=15}, -- Pummel
}

ZT.typeToTrackedSpells["HARDCC"] = {
	{spellID=179057, specs={DH.Havoc}, baseCD=60, modTalents={[61]=StaticMod("mul", 0.666667)}}, -- Chaos Nova
	{spellID=119381, class=Monk, baseCD=60, modTalents={[41]=StaticMod("sub", 10)}}, -- Leg Sweep
	{spellID=192058, class=Shaman, baseCD=60, modTalents={[33]=modCapTotem}}, -- Capacitor Totem
	{spellID=30283, class=Warlock, baseCD=60, modTalents={[51]=StaticMod("sub", 15)}}, -- Shadowfury
	{spellID=46968, specs={Warrior.Prot}, baseCD=40, modTalents={[52]=modShockwave}}, -- Shockwave
	{spellID=20549, race="Tauren", baseCD=90}, -- War Stomp
	{spellID=255654, race="HighmountainTauren", baseCD=120}, -- Bull Rush
}

ZT.typeToTrackedSpells["SOFTCC"] = {
	{spellID=202138, specs={DH.Veng}, baseCD=90, reqTalents={53}}, -- Sigil of Chains
	{spellID=207684, specs={DH.Veng}, baseCD=90}, -- Sigil of Misery
	{spellID=202137, specs={DH.Veng}, baseCD=60, modTalents={[52]=StaticMod("mul", 0.8)}}, -- Sigil of Silence
	{spellID=108199, specs={DK.Blood}, baseCD=120, modTalents={[52]=StaticMod("sub", 30)}}, -- Gorefiend's Grasp
	{spellID=207167, specs={DK.Frost}, baseCD=60, reqTalents={33}}, -- Blinding Sleet
	{spellID=132469, class=Druid, baseCD=30, reqTalents={43}}, -- Typhoon
	{spellID=102359, class=Druid, baseCD=30, reqTalents={42}}, -- Mass Entanglement
	{spellID=99, specs={Druid.Guardian}, baseCD=30}, -- Incapacitating Roar
	{spellID=236748, specs={Druid.Guardian}, baseCD=30, reqTalents={22}}, -- Intimidating Roar
	{spellID=102793, specs={Druid.Resto}, baseCD=60}, -- Ursol's Vortex
	{spellID=109248, class=Hunter, baseCD=30, reqTalents={53}}, -- Binding Shot
	{spellID=116844, class=Monk, baseCD=45, reqTalents={43}}, -- Ring of Peace
	{spellID=8122, specs={Priest.Disc,Priest.Holy}, baseCD=60, modTalents={[41]=StaticMod("sub", 30)}}, -- Psychic Scream
	{spellID=8122, specs={Priest.Shadow}, baseCD=60}, -- Psychic Scream
	{spellID=204263, specs={Priest.Disc,Priest.Holy}, baseCD=45, reqTalents={43}}, -- Shining Force
	{spellID=51490, specs={Shaman.Ele}, baseCD=45}, -- Thunderstorm
}

ZT.typeToTrackedSpells["STHARDCC"] = {
	{spellID=211881, specs={DH.Havoc}, baseCD=30, reqTalents={63}}, -- Fel Eruption
	{spellID=221562, specs={DK.Blood}, baseCD=45}, -- Asphyxiate
	{spellID=108194, specs={DK.Unholy}, baseCD=45, reqTalents={33}}, -- Asphyxiate
	{spellID=108194, specs={DK.FrostDK}, baseCD=45, reqTalents={32}}, -- Asphyxiate
	{spellID=5211, class=Druid, baseCD=50, reqTalents={41}}, -- Mighty Bash
	{spellID=19577, specs={Hunter.BM,Hunter.Surv}, baseCD=60}, -- Intimidation
	{spellID=853, specs={Paladin.Holy}, baseCD=60, modTalents={[31]=CastDeltaMod(275773, -10)}}, -- Hammer of Justice
	{spellID=853, specs={Paladin.Prot}, baseCD=60, modTalents={[31]=CastDeltaMod(275779, -6)}}, -- Hammer of Justice
	{spellID=853, specs={Paladin.Ret}, baseCD=60}, -- Hammer of Justice
	{spellID=88625, specs={Priest.Holy}, baseCD=60, reqTalents={42}, mods=CastDeltaMod(585, -4), modTalents={[71]=CastDeltaMod(585, -1.333333)}}, -- Holy Word: Chastise
	{spellID=64044, specs={Priest.Shadow}, baseCD=45, reqTalents={43}}, -- Psychic Horror
	{spellID=6789, class=Warlock, baseCD=45, reqTalents={52}}, -- Mortal Coil
	{spellID=107570, specs={Warrior.Prot}, baseCD=30, reqTalents={53}}, -- Storm Bolt
	{spellID=107570, specs={Warrior.Arms,Warrior.Fury}, baseCD=30, reqTalents={23}}, -- Storm Bolt
}

ZT.typeToTrackedSpells["STSOFTCC"] = {
	{spellID=217832, class=DH, baseCD=45}, -- Imprison
	{spellID=2094, specs={Rogue.Sin,Rogue.Sub}, baseCD=120}, -- Blind
	{spellID=2094, specs={Rogue.Outlaw}, baseCD=120, modTalents={[52]=StaticMod("sub", 30)}}, -- Blind
	{spellID=115078, class=Monk, baseCD=45}, -- Paralysis
	{spellID=187650, class=Hunter, baseCD=30}, -- Freezing Trap
}

ZT.typeToTrackedSpells["DISPEL"] = {
	{spellID=202719, race="BloodElf", class=DH, baseCD=90}, -- Arcane Torrent
	{spellID=50613, race="BloodElf", class=DK, baseCD=90}, -- Arcane Torrent
	{spellID=80483, race="BloodElf", class=Hunter, baseCD=90}, -- Arcane Torrent
	{spellID=28730, race="BloodElf", class=Mage, baseCD=90}, -- Arcane Torrent
	{spellID=129597, race="BloodElf", class=Monk, baseCD=90}, -- Arcane Torrent
	{spellID=155145, race="BloodElf", class=Paladin, baseCD=90}, -- Arcane Torrent
	{spellID=232633, race="BloodElf", class=Priest, baseCD=90}, -- Arcane Torrent
	{spellID=25046, race="BloodElf", class=Rogue, baseCD=90}, -- Arcane Torrent
	{spellID=28730, race="BloodElf", class=Warlock, baseCD=90}, -- Arcane Torrent
	{spellID=69179, race="BloodElf", class=Warrior, baseCD=90}, -- Arcane Torrent
	{spellID=32375, class=Priest, baseCD=45}, -- Mass Dispel
}

ZT.typeToTrackedSpells["DEFMDISPEL"] = {
	{spellID=88423, specs={Druid.Resto}, baseCD=8, mods=DispelMod(88423), ignoreCast=true}, -- Nature's Cure
	{spellID=115450, specs={Monk.MW}, baseCD=8, mods=DispelMod(115450), ignoreCast=true}, -- Detox
	{spellID=4987, specs={Paladin.Holy}, baseCD=8, mods=DispelMod(4987), ignoreCast=true}, -- Cleanse
	{spellID=527, specs={Priest.Disc,Priest.Holy}, baseCD=8, mods=DispelMod(527), ignoreCast=true}, -- Purify
	{spellID=77130, specs={Shaman.Resto}, baseCD=8, mods=DispelMod(77130), ignoreCast=true}, -- Purify Spirit
}

ZT.typeToTrackedSpells["EXTERNAL"] = {
	{spellID=196718, specs={DH.Havoc}, baseCD=180}, -- Darkness
	{spellID=102342, specs={Druid.Resto}, baseCD=60, modTalents={[62]=StaticMod("sub", 15)}}, -- Ironbark
	{spellID=116849, specs={Monk.MW}, baseCD=120}, -- Life Cocoon
	{spellID=31821, specs={Paladin.Holy}, baseCD=180}, -- Aura Mastery
	{spellID=6940, specs={Paladin.Holy,Paladin.Prot}, baseCD=120}, -- Blessing of Sacrifice
	{spellID=1022, specs={Paladin.Holy,Paladin.Ret}, baseCD=300}, -- Blessing of Protection
	{spellID=1022, specs={Paladin.Prot}, baseCD=300, reqTalents={41,42}}, -- Blessing of Protection
	{spellID=204018, specs={Paladin.Prot}, baseCD=180, reqTalents={43}}, -- Blessing of Spellwarding
	{spellID=62618, specs={Priest.Disc}, baseCD=180, reqTalents={71,73}}, -- Power Word: Barrier
	{spellID=271466, specs={Priest.Disc}, baseCD=180, reqTalents={72}}, -- Luminous Barrier
	{spellID=33206, specs={Priest.Disc}, baseCD=180}, -- Pain Supression
	{spellID=47788, specs={Priest.Holy}, baseCD=180, modTalents={[32]=modGuardianSpirit}}, -- Guardian Spirit
	{spellID=98008, specs={Shaman.Resto}, baseCD=180}, -- Spirit Link Totem
	{spellID=97462, class=Warrior, baseCD=180}, -- Rallying Cry
}

ZT.typeToTrackedSpells["HEALING"] = {
	{spellID=740, specs={Druid.Resto}, baseCD=180, modTalents={[61]=StaticMod("sub", 60)}}, -- Tranquility
	{spellID=115310, specs={Monk.MW}, baseCD=180}, -- Revival
	{spellID=216331, specs={Paladin.Holy}, baseCD=120, reqTalents={62}}, -- Avenging Crusader
	{spellID=105809, specs={Paladin.Holy}, baseCD=90, reqTalents={53}}, -- Holy Avenger
	{spellID=633, specs={Paladin.Holy}, baseCD=600, modTalents={[21]=StaticMod("mul", 0.7)}}, -- Lay on Hands
	{spellID=633, specs={Paladin.Prot,Paladin.Ret}, baseCD=600, modTalents={[51]=StaticMod("mul", 0.7)}}, -- Lay on Hands
	{spellID=210191, specs={Paladin.Ret}, baseCD=60, reqTalents={63}}, -- Word of Glory
	{spellID=47536, specs={Priest.Disc}, baseCD=90}, -- Rapture
	{spellID=246287, specs={Priest.Disc}, baseCD=75, reqTalents={73}}, -- Evangelism
	{spellID=64843, specs={Priest.Holy}, baseCD=180}, -- Divine Hymn
	{spellID=200183, specs={Priest.Holy}, baseCD=120, reqTalents={72}}, -- Apotheosis
	{spellID=265202, specs={Priest.Holy}, baseCD=720, reqTalents={73}, mods={CastDeltaMod(34861,-30), CastDeltaMod(2050,-30)}}, -- Holy Word: Salvation
	{spellID=15286, specs={Priest.Shadow}, baseCD=120, modTalents={[22]=StaticMod("sub", 45)}}, -- Vampiric Embrace
	{spellID=108280, specs={Shaman.Resto}, baseCD=180}, -- Healing Tide Totem
	{spellID=198838, specs={Shaman.Resto}, baseCD=60, reqTalents={42}}, -- Earthen Wall Totem
	{spellID=207399, specs={Shaman.Resto}, baseCD=300, reqTalents={43}}, -- Ancestral Protection Totem
	{spellID=114052, specs={Shaman.Resto}, baseCD=180, reqTalents={73}}, -- Ascendance
}

ZT.typeToTrackedSpells["UTILITY"] = {
	{spellID=205636, specs={Druid.Balance}, baseCD=60, reqTalents={13}}, -- Force of Nature (Treants)
	{spellID=73325, class=Priest, baseCD=90}, -- Leap of Faith
	{spellID=114018, class=Rogue, baseCD=360}, -- Shroud of Concealment
	{spellID=29166, specs={Druid.Balance,Druid.Resto}, baseCD=180}, -- Innervate
	{spellID=64901, specs={Priest.Holy}, baseCD=300}, -- Symbol of Hope
}

ZT.typeToTrackedSpells["PERSONAL"] = {
	{spellID=198589, specs={DH.Havoc}, baseCD=60, mods=EventRemainingMod("SPELL_AURA_APPLIED", 212800, 60)}, -- Blur
	{spellID=187827, specs={DH.Veng}, baseCD=180}, -- Metamorphosis
	{spellID=48707, specs={DK.Blood}, baseCD=60, modTalents={[42]=StaticMod("sub", 15)}}, -- Anti-Magic Shell
	{spellID=48707, specs={DK.Frost,DK.Unholy}, baseCD=60}, -- Anti-Magic Shell
	{spellID=48743, specs={DK.Frost,DK.Unholy}, baseCD=120, reqTalents={53}}, -- Death Pact
	{spellID=48792, class=DK, baseCD=180}, -- Icebound Fortitude
	{spellID=55233, specs={DK.Blood}, baseCD=90, modTalents={[72]=ResourceSpendingMods(DK.Blood, 0.1)}}, -- Vampiric Blood
	{spellID=22812, specs={Druid.Balance,Druid.Guardian,Druid.Resto}, baseCD=60}, -- Barkskin
	{spellID=61336, specs={Druid.Feral,Druid.Guardian}, baseCD=180}, -- Survival Instincts
	{spellID=109304, class=Hunter, baseCD=120}, -- Exhilaration
	{spellID=235219, specs={Mage.Frost}, baseCD=300}, -- Cold Snap
	{spellID=122278, class=Monk, baseCD=120, reqTalents={53}}, -- Dampen Harm
	{spellID=122783, specs={Monk.MW, Monk.WW}, baseCD=90, reqTalents={52}}, -- Diffuse Magic
	{spellID=115203, specs={Monk.BRM}, baseCD=420}, -- Fortifying Brew
	{spellID=115176, specs={Monk.BRM}, baseCD=300}, -- Zen Meditation
	{spellID=243435, specs={Monk.MW}, baseCD=90}, -- Fortifying Brew
	{spellID=122470, specs={Monk.WW}, baseCD=90}, -- Touch of Karma
	{spellID=498, specs={Paladin.Holy}, baseCD=60}, -- Divine Protection
	{spellID=31850, specs={Paladin.Prot}, baseCD=120}, -- Ardent Defender
	{spellID=86659, specs={Paladin.Prot}, baseCD=300}, -- Guardian of the Ancient Kings
	{spellID=184662, specs={Paladin.Ret}, baseCD=120}, -- Shield of Vengeance
	{spellID=205191, specs={Paladin.Ret}, baseCD=60, reqTalents={53}}, -- Eye for an Eye
	{spellID=19236, specs={Priest.Disc, Priest.Holy}, baseCD=90}, -- Desperate Prayer
	{spellID=47585, specs={Priest.Shadow}, baseCD=120}, -- Dispersion
	{spellID=108271, class=Shaman, baseCD=90}, -- Astral Shift
	{spellID=104773, class=Warlock, baseCD=180}, -- Unending Resolve
	{spellID=118038, specs={Warrior.Arms}, baseCD=180}, -- Die by the Sword
	{spellID=184364, specs={Warrior.Fury}, baseCD=120}, -- Enraged Regeneration
	{spellID=12975, specs={Warrior.Prot}, baseCD=180, modTalents={[43]=StaticMod("sub", 60)}}, -- Last Stand
	{spellID=871, specs={Warrior.Prot}, baseCD=240}, -- Shield Wall
}

ZT.typeToTrackedSpells["IMMUNITY"] = {
	{spellID=196555, specs={DH.Havoc}, baseCD=120, reqTalents={43}}, -- Netherwalk
	{spellID=186265, class=Hunter, baseCD=180, modTalents={[51]=StaticMod("mul", 0.8)}}, -- Aspect of the Turtle
	{spellID=45438, specs={Mage.Arcane,Mage.Fire}, baseCD=240}, -- Ice Block
	{spellID=45438, specs={Mage.Frost}, baseCD=240, mods=CastRemainingMod(235219, 0)}, -- Ice Block
	{spellID=642, class=Paladin, baseCD=300}, -- Divine Shield
	{spellID=31224, class=Rogue, baseCD=120}, -- Cloak of Shadows
}

ZT.typeToTrackedSpells["DAMAGE"] = {
	{spellID=191427, specs={DH.Havoc}, baseCD=240}, -- Metamorphosis
	{spellID=258925, specs={DH.Havoc}, baseCD=60, reqTalents={33}}, -- Fel Barrage
	{spellID=206491, specs={DH.Havoc}, baseCD=120, reqTalents={73}}, -- Nemesis
	{spellID=279302, specs={DK.Frost}, baseCD=180, reqTalents={63}}, -- Frostwyrm's Fury
	{spellID=152279, specs={DK.Frost}, baseCD=120, reqTalents={73}}, -- Breath of Sindragosaa
	{spellID=42650, specs={DK.Unholy}, baseCD=480}, -- Army of the Dead
	{spellID=49206, specs={DK.Unholy}, baseCD=180, reqTalents={73}}, -- Summon Gargoyle
	{spellID=207289, specs={DK.Unholy}, baseCD=75, reqTalents={72}}, -- Unholy Frenzy
	{spellID=194223, specs={Druid.Balance}, baseCD=180, reqTalents={51,52}}, -- Celestial Alignment
	{spellID=102560, specs={Druid.Balance}, baseCD=180, reqTalents={53}}, -- Incarnation: Chosen of Elune
	{spellID=102543, specs={Druid.Feral}, baseCD=180, reqTalents={53}}, -- Incarnation: King of the Jungle
	{spellID=19574, specs={Hunter.BM}, baseCD=90}, -- Bestial Wrath
	{spellID=193530, specs={Hunter.BM}, baseCD=120}, -- Aspect of the Wild
	{spellID=201430, specs={Hunter.BM}, baseCD=180, reqTalents={63}}, -- Stampede
	{spellID=193526, specs={Hunter.MM}, baseCD=180}, -- Trueshot
	{spellID=266779, specs={Hunter.SV}, baseCD=120}, -- Coordinated Assault
	{spellID=12042, specs={Mage.Arcane}, baseCD=90}, -- Arcane Power
	{spellID=190319, specs={Mage.Fire}, baseCD=120}, -- Combustion
	{spellID=12472, specs={Mage.Frost}, baseCD=180}, -- Icy Veins
	{spellID=55342, class=Mage, baseCD=120, reqTalents={32}}, -- Mirror Image
	{spellID=115080, specs={Monk.WW}, baseCD=120}, -- Touch of Death
	{spellID=123904, specs={Monk.WW}, baseCD=180, reqTalents={63}}, -- Xuen
	{spellID=137639, specs={Monk.WW}, baseCD=90, reqTalents={71, 72}}, -- Storm, Earth, and Fire
	{spellID=152173, specs={Monk.WW}, baseCD=90, reqTalents={73}}, -- Serenity
	{spellID=31884, specs={Paladin.Ret}, baseCD=120, reqTalents={71,73}}, -- Avenging Wrath
	{spellID=231895, specs={Paladin.Ret}, baseCD=120, reqTalents={72}}, -- Crusade
	{spellID=280711, specs={Priest.Shadow}, baseCD=60, reqTalents={72}}, -- Dark Ascension
	{spellID=193223, specs={Priest.Shadow}, baseCD=240, reqTalents={73}}, -- Surrender to Madness
	{spellID=79140, specs={Rogue.Sin}, baseCD=120}, -- Vendetta
	{spellID=121471, specs={Rogue.Sub}, baseCD=180}, -- Shadow Blades
	{spellID=13750, specs={Rogue.Outlaw}, baseCD=180}, -- Adrenaline Rush
	{spellID=51690, specs={Rogue.Outlaw}, baseCD=120, reqTalents={73}}, -- Killing Spree
	{spellID=114050, specs={Shaman.Ele}, baseCD=180, reqTalents={73}}, -- Ascendance
	{spellID=114051, specs={Shaman.Enh}, baseCD=180, reqTalents={73}}, -- Ascendance
	{spellID=205180, specs={Warlock.Affl}, baseCD=180}, -- Summon Darkglare
	{spellID=113860, specs={Warlock.Affl}, baseCD=120, reqTalents={73}}, -- Dark Soul: Misery
	{spellID=265187, specs={Warlock.Demo}, baseCD=90}, -- Summon Demonic Tyrant
	{spellID=267217, specs={Warlock.Demo}, baseCD=180, reqTalents={73}}, -- Nether Portal
	{spellID=113858, specs={Warlock.Destro}, baseCD=120, reqTalents={73}}, -- Dark Soul: Instability
	{spellID=1122, specs={Warlock.Destro}, baseCD=180}, -- Summon Infernal
	{spellID=227847, specs={Warrior.Arms}, baseCD=90}, -- Bladestorm
	{spellID=107574, specs={Warrior.Arms}, baseCD=120, reqTalents={62}}, -- Avatar
	{spellID=1719, specs={Warrior.Fury}, baseCD=90}, -- Recklessness
	{spellID=46924, specs={Warrior.Fury}, baseCD=60, reqTalents={63}}, -- Bladestorm
}

ZT.typeToTrackedSpells["TANK"] = {
	{spellID=49028, specs={DK.Blood}, baseCD=120}, -- Dancing Rune Weapon
	{spellID=194679, specs={DK.Blood}, baseCD=25, reqTalents={43}}, -- Rune Tap
	{spellID=194844, specs={DK.Blood}, baseCD=60, reqTalents={73}}, -- Bonestorm
	{spellID=204021, specs={DH.Veng}, baseCD=60}, -- Fiery Brand
	{spellID=1160, specs={Warrior.Prot}, baseCD=45}, -- Demoralizing Shout
}

ZT.linkedSpellIDs = {
	[19647]  = {119910, 132409, 115781}, -- Spell Lock
	[132469] = {61391}, -- Typhoon
	[191427] = {200166} -- Metamorphosis
}

ZT.specialConfigSpellIDs = {
	[202719] = "ArcaneTorrent",
	[50613]  = "ArcaneTorrent",
	[80483]  = "ArcaneTorrent",
	[28730]  = "ArcaneTorrent",
	[129597] = "ArcaneTorrent",
	[155145] = "ArcaneTorrent",
	[232633] = "ArcaneTorrent",
	[25046]  = "ArcaneTorrent",
	[28730]  = "ArcaneTorrent",
	[69179]  = "ArcaneTorrent",
	[221562] = "Asphyxiate",
	[108194] = "Asphyxiate",
}

-- Building a complete list of tracked spells
function ZT:BuildSpellList()
	self.spellIDToInfo = {}

	for type,spells in pairs(self.typeToTrackedSpells) do
		for _,spellInfo in ipairs(spells) do
			spellInfo.type = type

			-- Creating a lookup map from list of valid specs
			if spellInfo.specs then
				local specsMap = {}
				for _,specID in ipairs(spellInfo.specs) do
					specsMap[specID] = true
				end
				spellInfo.specs = specsMap
			end

			-- Placing single modifiers inside of a table (or creating an empty table if none)
			if spellInfo.mods then
				if spellInfo.mods.type then
					spellInfo.mods = { spellInfo.mods }
				end
			else
				spellInfo.mods = {}
			end

			-- Placing single talent modifiers inside of a table (or creating an empty table if none)
			if spellInfo.modTalents then
				for talent,modifiers in pairs(spellInfo.modTalents) do
					if modifiers.type then
						spellInfo.modTalents[talent] = { modifiers }
					end
				end
			else
				spellInfo.modTalents = {}
			end

			local spellID = spellInfo.spellID
			local allSpellInfo = self.spellIDToInfo[spellID]
			if not allSpellInfo then
				-- Checking if this spellID is blacklisted
				local spellName = GetSpellInfo(spellID);
				spellName = spellName:gsub('%s+', '');

				local isBlacklisted = self.db.blacklist[spellName];

				allSpellInfo = {
					type = type,
					variants = { spellInfo },
					isBlacklisted = isBlacklisted,
				}
				self.spellIDToInfo[spellID] = allSpellInfo
			else
				local variants = allSpellInfo.variants
				variants[#variants+1] = spellInfo
			end
		end
	end
end

--------------------------------------------------------------------------------
-- END TRACKED SPELLS
--------------------------------------------------------------------------------

-- Handling the sending of events to the front-end WAs
local function sendFrontEndTrigger(watchInfo)
	if watchInfo.isHidden then
		return
	end

	if ZT.db.debugEvents then
		print("[ZT] Sending ZT_TRIGGER", watchInfo.spellInfo.type, watchInfo.watchID, watchInfo.duration, watchInfo.expiration)
	end
	WeakAuras.ScanEvents("ZT_TRIGGER", watchInfo.spellInfo.type, watchInfo.watchID, watchInfo.duration, watchInfo.expiration)
end

local function sendFrontEndAdd(watchInfo)
	if watchInfo.isHidden then
		return
	end
	local spellInfo = watchInfo.spellInfo

	if ZT.db.debugEvents then
		print("[ZT] Sending ZT_ADD", spellInfo.type, watchInfo.watchID, watchInfo.member.name, spellInfo.spellID)
	end
	WeakAuras.ScanEvents("ZT_ADD", spellInfo.type, watchInfo.watchID, watchInfo.member, spellInfo.spellID)

	if watchInfo.expiration > GetTime() then
		sendFrontEndTrigger(watchInfo)
	end
end

local function sendFrontEndRemove(watchInfo)
	if watchInfo.isHidden then
		return
	end
	if ZT.db.debugEvents then
		print("[ZT] Sending ZT_REMOVE", watchInfo.spellInfo.type, watchInfo.watchID)
	end
	WeakAuras.ScanEvents("ZT_REMOVE", watchInfo.spellInfo.type, watchInfo.watchID)
end

-- Handling combatlog and WeakAura events by invoking specified handler functions
ZT.eventHandlers = {}

function ZT:addEventHandler(type, spellID, sourceGUID, handler, data)
	local types = self.eventHandlers[spellID]
	if not types then
		types = {}
		self.eventHandlers[spellID] = types
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

	handlers[handler] = data
end

function ZT:removeEventHandler(type, spellID, sourceGUID, handler)
	local types = self.eventHandlers[spellID]
	if types then
		local sources = types[type]
		if sources then
			local handlers = sources[sourceGUID]
			if handlers then
				handlers[handler] = nil
			end
		end
	end
end

function ZT:removeAllEventHandlers(sourceGUID)
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
		for unit in WA_IterateGroupMembers() do
			if UnitGUID(unit.."pet") == sourceGUID then
				sourceGUID = UnitGUID(unit)
				break
			end
		end
	end

	return sourceGUID
end

function ZT:handleEvent(type, spellID, sourceGUID)
	local types = self.eventHandlers[spellID]
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

	for handler,data in pairs(handlers) do
		handler(data)
	end
end

-- Managing the set of (spellID,sourceGUID) pairs that are being watched
ZT.nextWatchID = 1
ZT.watching = {}

local function WatchInfo_startCooldown(self)
	self.expiration = GetTime() + self.duration
	sendFrontEndTrigger(self)
end

local function WatchInfo_updateDelta(self, delta)
	self.expiration = self.expiration + delta
	sendFrontEndTrigger(self)
end

local function WatchInfo_updateRemaining(self, remaining)
	self.expiration = GetTime() + remaining
	sendFrontEndTrigger(self)
end

local function WatchInfo_update(self, ignoreIfReady, ignoreRateLimit)
	local startTime, duration, enabled = GetSpellCooldown(self.spellInfo.spellID)
	if enabled ~= 0 then
		if startTime ~= 0 then
			self.duration = duration
			self.expiration = startTime + duration
		else
			self.expiration = GetTime()
		end

		if (not ignoreIfReady) or (startTime ~= 0) then
			sendFrontEndTrigger(self)
			ZT:sendCDUpdate(self, ignoreRateLimit)
		end
	end
end

local function WatchInfo_handleStarted(self)
	WatchInfo_update(self, false, true)
end

local function WatchInfo_handleChanged(self)
	WatchInfo_update(self, false, false)
end

local function WatchInfo_handleReady(self)
	self.expiration = GetTime()
	sendFrontEndTrigger(self)
	ZT:sendCDUpdate(self, true)
end

local function WatchInfo_hide(self)
	sendFrontEndRemove(self)
	self.isHidden = true
end

local function WatchInfo_unhide(self)
	self.isHidden = false
	sendFrontEndAdd(self)
end

function ZT:togglePlayerHandlers(watchInfo, enable)
	local spellID = watchInfo.spellInfo.spellID
	local toggleEventHandler = enable and self.addEventHandler or self.removeEventHandler

	if enable then
		WeakAuras.WatchSpellCooldown(spellID)
	end
	toggleEventHandler(self, "SPELL_COOLDOWN_STARTED", spellID, 0, WatchInfo_handleStarted, watchInfo)
	toggleEventHandler(self, "SPELL_COOLDOWN_CHANGED", spellID, 0, WatchInfo_handleChanged, watchInfo)
	toggleEventHandler(self, "SPELL_COOLDOWN_READY", spellID, 0, WatchInfo_handleReady, watchInfo)
end

function ZT:toggleCombatLogHandlers(watchInfo, enable, specInfo)
	local spellInfo = watchInfo.spellInfo
	local spellID = spellInfo.spellID
	local member = watchInfo.member
	local toggleEventHandler = enable and self.addEventHandler or self.removeEventHandler

	if not spellInfo.ignoreCast then
		toggleEventHandler(self, "SPELL_CAST_SUCCESS", spellID, member.GUID, WatchInfo_startCooldown, watchInfo)

		local links = self.linkedSpellIDs[spellID]
		if links then
			for _,linkedSpellID in ipairs(links) do
				toggleEventHandler(self, "SPELL_CAST_SUCCESS", linkedSpellID, member.GUID, WatchInfo_startCooldown, watchInfo)
			end
		end
	end

	for _,modifier in pairs(spellInfo.mods) do
		if modifier.type == "Dynamic" then
			for _,handlerInfo in ipairs(modifier.handlers) do
				toggleEventHandler(self, handlerInfo.type, handlerInfo.spellID, member.GUID, handlerInfo.handler, watchInfo)
			end
		end
	end

	for talent, modifiers in pairs(spellInfo.modTalents) do
		if specInfo.talentsMap[talent] then
			for _, modifier in pairs(modifiers) do
				if modifier.type == "Dynamic" then
					for _,handlerInfo in ipairs(modifier.handlers) do
						toggleEventHandler(self, handlerInfo.type, handlerInfo.spellID, member.GUID, handlerInfo.handler, watchInfo)
					end
				end
			end
		end
	end
end

function ZT:watch(spellInfo, member, specInfo, isHidden)
	specInfo = specInfo or member.specInfo

	local spellID = spellInfo.spellID
	local spells = self.watching[spellID]
	if not spells then
		spells = {}
		self.watching[spellID] = spells
	end

	local watchInfo = spells[member.GUID]
	local isNew = (watchInfo == nil)

	if not watchInfo then
		watchInfo = {
			watchID = self.nextWatchID,
			member = member,
			spellInfo = spellInfo,
			duration = member:computeCooldown(spellInfo, specInfo),
			expiration = GetTime(),
			isHidden = isHidden,
			startCooldown = WatchInfo_startCooldown,
			update = WatchInfo_update,
			updateDelta = WatchInfo_updateDelta,
			updateRemaining = WatchInfo_updateRemaining,
		}
		self.nextWatchID = self.nextWatchID + 1

		spells[member.GUID] = watchInfo
		member.watching[spellID] = watchInfo

		sendFrontEndAdd(watchInfo)
	else
		watchInfo.spellInfo = spellInfo
		watchInfo.duration = member:computeCooldown(spellInfo, specInfo)

		if watchInfo.isHidden and not isHidden then
			WatchInfo_unhide(watchInfo)
		end
	end

	if member.isPlayer then
		watchInfo:update(true)
	end

	if member.isPlayer then
		if isNew then
			self:togglePlayerHandlers(watchInfo, true)
		end
	elseif member.tracking == "CombatLog" then
		if isNew then
			self:toggleCombatLogHandlers(watchInfo, true, specInfo)
		else
			self:toggleCombatLogHandlers(watchInfo, false, member.specInfo)
			self:toggleCombatLogHandlers(watchInfo, true, specInfo)
		end
	end
end

function ZT:unwatch(spellInfo, member, specInfo, keepHidden)
	local spellID = spellInfo.spellID
	local sources = self.watching[spellID]
	if not sources then
		return
	end

	local watchInfo = sources[member.GUID]
	if watchInfo then
		if member.isPlayer then
			if keepHidden then
				WatchInfo_hide(watchInfo)
				return
			end

			self:togglePlayerHandlers(watchInfo, false)
		elseif member.tracking == "CombatLog" then
			self:toggleCombatLogHandlers(watchInfo, false, specInfo or member.specInfo)
		end

		self.watching[spellInfo.spellID][member.GUID] = nil
		member.watching[spellID] = nil

		sendFrontEndRemove(watchInfo)
	end
end

-- Tracking types registered by front-end WAs
ZT.registration = {}

function ZT:isTypeRegistered(type)
	return self.registration[type] and (next(self.registration[type], nil) ~= nil)
end

function ZT:rebroadcast(type)
	for _,sources in pairs(self.watching) do
		for _,watchInfo in pairs(sources) do
			if (watchInfo.spellInfo.type == type) then
				sendFrontEndAdd(watchInfo)
			end
		end
	end
end

function ZT:registerFrontEnd(type, frontendID)
	local frontends = self.registration[type]
	if not frontends then
		frontends = {}
		self.registration[type] = frontends
	end

	if not frontends[frontendID] then
		local typeWasRegistered = self:isTypeRegistered(type)
		self.registration[type][frontendID] = true

		if self.db.debugEvents then
			print("[ZT] Received ZT_REGISTER", type, frontendID, " -> New", typeWasRegistered and "(Type Registered)" or "(Type Unregistered)")
		end

		if typeWasRegistered then
			self:rebroadcast(type)
		else
			for _,member in pairs(self.members) do
				if (not member.isPlayer) or (self.db.showMine[type]) then
					for _,allSpellInfo in pairs(self.spellIDToInfo) do
						if (not allSpellInfo.isBlacklisted) and (type == allSpellInfo.type) then
							for _,spellInfo in pairs(allSpellInfo.variants) do
								if member:checkSpellRequirements(spellInfo) then
									self:watch(spellInfo, member, member.specInfo, member.isHidden)
									break
								end
							end
						end
					end
				end
			end
		end
	else
		if self.db.debugEvents then
			print("[ZT] Received ZT_REGISTER", type, frontendID, " -> Existing")
		end

		self:rebroadcast(type)
	end
end

function ZT:unregisterFrontEnd(type, frontendID)
	self.registration[type][frontendID] = nil

	if not self:isTypeRegistered(type) then
		if self.db.debugEvents then
			print("[ZT] Received ZT_UNREGISTER", type)
		end

		for _,member in pairs(self.members) do
			for spellID,watchInfo in pairs(member.watching) do
				local spellInfo = watchInfo.spellInfo
				if spellInfo.type == type then
					self:unwatch(spellInfo, member, member.specInfo, true)
				end
			end
		end
	end
end

-- Utility functions for operating over all spells available for a group member
ZT.members = {}
ZT.inEncounter = false

local function Member_checkSpellRequirements(self, spellInfo, specInfo)
	if not specInfo then
		specInfo = self.specInfo
	end

	if spellInfo.race and spellInfo.race ~= self.race then
		return false
	end
	if spellInfo.class and spellInfo.class.ID ~= self.classID then
		return false
	end
	if spellInfo.specs and (not specInfo.specID or not spellInfo.specs[specInfo.specID]) then
		return false
	end

	if spellInfo.reqTalents then
		local talented = false
		for _,t in ipairs(spellInfo.reqTalents) do
			if specInfo.talentsMap[t] then
				talented = true
				break
			end
		end

		if not talented then
			return false
		end
	end

	return true
end

local function Member_computeCooldown(self, spellInfo, specInfo)
	if not specInfo then
		specInfo = self.specInfo
	end

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

local function Member_hide(self)
	if not self.isHidden and not self.isPlayer then
		self.isHidden = true
		for _,watchInfo in pairs(self.watching) do
			WatchInfo_hide(watchInfo)
		end
	end
end

local function Member_unhide(self)
	if self.isHidden and not self.isPlayer then
		self.isHidden = false
		for _,watchInfo in pairs(self.watching) do
			WatchInfo_unhide(watchInfo)
		end
	end
end

function ZT:addOrUpdateMember(memberInfo)
	local member = self.members[memberInfo.GUID]
	if not member then
		member = memberInfo
		member.watching = {}
		member.tracking = member.tracking and member.tracking or "CombatLog"
		member.isPlayer = (member.GUID == UnitGUID("player"))
		member.isHidden = (not member.isPlayer and self.inEncounter)
		member.isReady = false
		member.checkSpellRequirements = Member_checkSpellRequirements
		member.computeCooldown = Member_computeCooldown
		self.members[memberInfo.GUID] = member
	end

	-- Gathering all necessary information about the member (if we don't have it already)
	local justBecameReady = false
	if not member.isReady then
		local _,className,_,race,_,name = GetPlayerInfoByGUID(member.GUID)
		member.name = name and gsub(name, "%-[^|]+", "") or nil
		if self.db.debugTracking and (member.tracking == "Sharing") and member.name then
			print(member.name, "is using ZenTracker")
		end
		member.class = className and AllClasses[className] or nil
		member.classID = className and AllClasses[className].ID or nil
		member.classColor = className and RAID_CLASS_COLORS[className] or nil
		member.race = race

		member.isReady = (member.name ~= nil) and (member.classID ~= nil) and (member.race ~= nil)
		justBecameReady = member.isReady
	end

	local specInfo = memberInfo.specInfo

	-- Update if the member is now ready, or if they swapped specs/talents
	local needsUpdate = justBecameReady
	if specInfo.specID and specInfo.talents then
		if (specInfo.specID ~= member.specInfo.specID) or (specInfo.talents ~= member.specInfo.talents) then
			needsUpdate = true
		end
	end

	if needsUpdate then
		-- If we are updating information about the player, send a handshake now
		if member.isPlayer then
			self:sendHandshake(specInfo)
		end

		-- Watching/Unwatching relevant spell cooldowns
		for spellID, allSpellInfo in pairs(self.spellIDToInfo) do
			local isRegistered = self:isTypeRegistered(allSpellInfo.type)
			local isBlacklisted = allSpellInfo.isBlacklisted
			local hasSpell = false

			if member.isPlayer then -- If player, watch all possible spells (but some may be hidden)
				for _,spellInfo in ipairs(allSpellInfo.variants) do
					hasSpell = member:checkSpellRequirements(spellInfo, specInfo)
					if hasSpell then
						local isHidden = (not isRegistered) or (not self.db.showMine[allSpellInfo.type]) or isBlacklisted
						self:watch(spellInfo, member, specInfo, isHidden)
						break
					end
				end
			elseif isRegistered and (not isBlacklisted) then -- Otherwise if group member, only watch relevant spells
				for _,spellInfo in ipairs(allSpellInfo.variants) do
					hasSpell = member:checkSpellRequirements(spellInfo, specInfo)
					if hasSpell then
						self:watch(spellInfo, member, specInfo, member.isHidden)
						break
					end
				end
			end

			local prevWatchInfo = member.watching[spellID]
			if not hasSpell and prevWatchInfo then
				self:unwatch(prevWatchInfo.spellInfo, member)
			end
		end

		member.specInfo = specInfo
	end

	-- If tracking changed from "CombatLog" to "Sharing", remove event handlers and send a handshake/updates
	if (member.tracking == "CombatLog") and (memberInfo.tracking == "Sharing") then
		member.tracking = "Sharing"
		if self.db.debugTracking and member.name then
			print(member.name, "is using ZenTracker")
		end

		self:removeAllEventHandlers(member.GUID)
		self:sendHandshake()

		local time = GetTime()
		for _,watchInfo in pairs(self.members[UnitGUID("player")].watching) do
			if watchInfo.expiration > time then
				self:sendCDUpdate(watchInfo)
			end
		end
	end
end

function ZT:resetEncounterCDs()
	for _,member in pairs(self.members) do
		if not member.isPlayer and member.tracking ~= "Sharing" then
			for _,watchInfo in pairs(member.watching) do
				if watchInfo.duration >= 180 then
					WatchInfo_updateRemaining(watchInfo, 0)
				end
			end
		end
	end
end

function ZT:startEncounter(event)
	-- Note: This shouldn't happen, but in case it does...
	if self.inEncounter then
		for _,member in pairs(self.members) do
			Member_unhide(member)
		end
	end

	self.inEncounter = true
	local _,_,_,instanceID = UnitPosition("player")
	for _,member in pairs(self.members) do
		local _,_,_,mInstanceID = UnitPosition(self.inspectLib:GuidToUnit(member.GUID))
		if mInstanceID ~= instanceID then
			Member_hide(member)
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
			Member_unhide(member)
		end
	end

	if event == "ENCOUNTER_END" then
		self:resetEncounterCDs()
	end
end

-- Message Format = <Protocol Version (%d)>:<Message Type (%s)>:<Member GUID (%s)>...
--   Type = "H" (Handshake)
--     ...:<Spec ID (%d)>:<Talents (%s)>
--   Type = "U" (CD Update)
--     ...:<Spell ID (%d)>:<Duration (%f)>:<Remaining (%f)>

ZT.protocolVersion = 1

ZT.timeBetweenHandshakes = 5 --seconds
ZT.timeOfLastHandshake = 0
ZT.queuedHandshake = false

ZT.timeBetweenCDUpdates = 5 --seconds (per spellID)
ZT.timeOfLastCDUpdate = {}
ZT.queuedCDUpdates = {}

local function sendMessage(message)
	if not IsInGroup() and not IsInRaid() then
		return
	end

	if ZT.DEBUG_MESSAGES then
		print("[ZT] Sending Message '"..message.."'")
	end

	local channel = IsInGroup(2) and "INSTANCE_CHAT" or "RAID"
	C_ChatInfo_SendAddonMessage("ZenTracker", message, channel)
end

function ZT:sendHandshake(specInfo)
	local time = GetTime()
	local timeSinceLastHandshake = (time - self.timeOfLastHandshake)
	if timeSinceLastHandshake < self.timeBetweenHandshakes then
		if not self.queuedHandshake then
			self.queuedHandshake = true
			C_Timer.After(self.timeBetweenHandshakes - timeSinceLastHandshake, function() self:sendHandshake() end)
		end
		return
	end

	local GUID = UnitGUID("player")
	specInfo = specInfo or self.members[GUID].specInfo
	local specID = specInfo.specID or 0
	local talents = specInfo.talents or ""
	local message = string.format("%d:H:%s:%d:%s", self.protocolVersion, GUID, specID, talents)
	sendMessage(message)

	self.timeOfLastHandshake = time
	self.queuedHandshake = false
end

function ZT:sendCDUpdate(watchInfo, ignoreRateLimit, wasQueued)
	local spellID = watchInfo.spellInfo.spellID
	local time = GetTime()
	local remaining = watchInfo.expiration - time
	if remaining < 0 then
		remaining = 0
	end

	if not ignoreRateLimit then
		local isQueued = self.queuedCDUpdates[spellID]
		if wasQueued then
			if not isQueued then
				return -- Ignore since an update occured while this update was queued
			end
		else
			if isQueued then
				return -- Ignore since an update is already queued
			else
				local timeOfLastCDUpdate = self.timeOfLastCDUpdate[spellID]
				if timeOfLastCDUpdate then
					local timeSinceLastCDUpdate = (time - self.timeOfLastCDUpdate[spellID])
					if timeSinceLastCDUpdate < self.timeBetweenCDUpdates then
						self.queuedCDUpdates[spellID] = true
						C_Timer.After(self.timeBetweenCDUpdates - timeSinceLastCDUpdate, function() self:sendCDUpdate(watchInfo, false, true) end)
						return -- Ignore since an update has now been queued
					end
				end
			end
		end
	end

	local GUID = watchInfo.member.GUID
	local duration = watchInfo.duration
	local message = string.format("%d:U:%s:%d:%0.2f:%0.2f", self.protocolVersion, GUID, spellID, duration, remaining)
	sendMessage(message)

	self.timeOfLastCDUpdate[spellID] = time
	self.queuedCDUpdates[spellID] = false
end

function ZT:handleHandshake(mGUID, specID, talents)
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

	local memberInfo = {
		GUID = mGUID,
		specInfo = {
			specID = specID,
			talents = talents,
			talentsMap = talentsMap,
		},
		tracking = "Sharing",
	}

	self:addOrUpdateMember(memberInfo)
end

function ZT:handleCDUpdate(mGUID, spellID, duration, remaining)
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
		if not watchInfo then
			return
		end

		if member.tracking == "CombatLog" then
			member.tracking = "Sharing"
			if self.db.debugTracking then
				print(member.name, "is using ZenTracker")
			end
			self:removeAllEventHandlers(member.GUID)
		end

		watchInfo.duration = duration
		watchInfo:updateRemaining(remaining)
	end
end

function ZT:handleMessage(message)
	local protocolVersion, type, mGUID, arg1, arg2, arg3, arg4, arg5 = strsplit(":", message)
	protocolVersion = tonumber(protocolVersion)

	-- Ignore any messages sent by the player
	if mGUID == UnitGUID("player") then
		return
	end

	if ZT.db.debugMessages then
		print("[ZT] Received Message '"..message.."'")
	end

	if type == "H" then     -- Handshake
		self:handleHandshake(mGUID, arg1, arg2, arg3, arg4, arg5)
	elseif type == "U" then -- CD Update
		self:handleCDUpdate(mGUID, arg1, arg2, arg3, arg4, arg5)
	else
		return
	end
end

-- Callback functions for libGroupInspecT for updating/removing members
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

	self:addOrUpdateMember(memberInfo)
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

function ZT:Init()
	self:BuildSpellList();

	if not C_ChatInfo.RegisterAddonMessagePrefix("ZenTracker") then
		print("[ZT] Error: Could not register addon message prefix. Defaulting to local-only cooldown tracking.")
	end

	self.inspectLib.RegisterCallback(self, "GroupInSpecT_Update", "libInspectUpdate")
	self.inspectLib.RegisterCallback(self, "GroupInSpecT_Remove", "libInspectRemove")
	--self.inspectLib:Rescan() -- Keep it here in case library fails
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



