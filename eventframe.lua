local addonName, ZT = ...;

local WeakAuras = WeakAuras;
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo;
local CreateFrame = CreateFrame;
local hooksecurefunc = hooksecurefunc;

local eventFrame = CreateFrame('Frame');

ZT.eventFrame = eventFrame;

eventFrame:RegisterEvent('ADDON_LOADED');

eventFrame:SetScript('OnEvent', function(self, e, ...)
	self[e](self, e, ...);
end);

function eventFrame:COMBAT_LOG_EVENT_UNFILTERED(event, ...)
	local _, eventType, _, sourceGUID, _, _, _, destGUID, _, _, _, spellID = CombatLogGetCurrentEventInfo();
	ZT.eventHandlers:handle(eventType, spellID, sourceGUID)
end

function eventFrame:ENCOUNTER_START(event)
	if event == "ENCOUNTER_START" or event == "ENCOUNTER_END" then
		local _,instanceType = IsInInstance()
		if instanceType ~= "raid" then
			return
		end
	end

	if event == "ENCOUNTER_START" or event == "CHALLENGE_MODE_START" then
		ZT:startEncounter(event)
	elseif event == "ENCOUNTER_END" or event == "CHALLENGE_MODE_COMPLETED" or event == "PLAYER_ENTERING_WORLD" then
		ZT:endEncounter(event)
	end
end
eventFrame.CHALLENGE_MODE_START = eventFrame.ENCOUNTER_START;
eventFrame.ENCOUNTER_END = eventFrame.ENCOUNTER_START;
eventFrame.CHALLENGE_MODE_COMPLETED = eventFrame.ENCOUNTER_START;
eventFrame.PLAYER_ENTERING_WORLD = eventFrame.ENCOUNTER_START;

function eventFrame:CHAT_MSG_ADDON(event, prefix, message, type, sender)
	if prefix == "ZenTracker" then
		ZT:handleMessage(message)
	end
end

function eventFrame:GROUP_JOINED()
	ZT:sendHandshake()
end

function ZT.ScanEvents(...)
	local event, type, frontendID = ...;

	if event == 'ZT_REGISTER' then
		ZT:registerFrontEnd(frontendID, type)
	elseif event == 'ZT_UNREGISTER' then
		ZT:unregisterFrontEnd(frontendID, type)
	elseif
		event == 'SPELL_COOLDOWN_READY' or
		event == 'SPELL_COOLDOWN_CHANGED'
	then
		ZT.eventHandlers:handle(event, type, 0)
	end
end

function eventFrame:SPELLS_CHANGED()
	ZT:handleDelayedUpdates();
end

function eventFrame:ADDON_LOADED(event, addon)
	if addon ~= addonName then
		return;
	end

	ZT:RegisterOptions();
	ZT:Init();

	eventFrame:RegisterEvent('COMBAT_LOG_EVENT_UNFILTERED');

	eventFrame:RegisterEvent('CHALLENGE_MODE_START');
	eventFrame:RegisterEvent('CHALLENGE_MODE_COMPLETED');
	eventFrame:RegisterEvent('PLAYER_ENTERING_WORLD');
	eventFrame:RegisterEvent('ENCOUNTER_START');
	eventFrame:RegisterEvent('ENCOUNTER_END');

	eventFrame:RegisterEvent('CHAT_MSG_ADDON');
	eventFrame:RegisterEvent('GROUP_JOINED');
	eventFrame:RegisterEvent('SPELLS_CHANGED');

	hooksecurefunc(WeakAuras, 'ScanEvents', ZT.ScanEvents);
end