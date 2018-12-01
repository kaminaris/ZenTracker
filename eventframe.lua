local addonName, ZT = ...;

local WeakAuras = WeakAuras;
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
	ZT:handleEvent(eventType, spellID, sourceGUID)
end

function eventFrame:ENCOUNTER_START(event)
	ZT:startEncounter(event);
end
eventFrame.CHALLENGE_MODE_START = eventFrame.ENCOUNTER_START;

function eventFrame:ENCOUNTER_END(event, id)
	ZT:endEncounter(event);
end
eventFrame.CHALLENGE_MODE_COMPLETED = eventFrame.ENCOUNTER_END;
eventFrame.PLAYER_ENTERING_WORLD = eventFrame.ENCOUNTER_END;

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
		ZT:registerFrontEnd(type, frontendID)
	elseif event == 'ZT_UNREGISTER' then
		ZT:unregisterFrontEnd(type, frontendID)
	elseif
		event == 'SPELL_COOLDOWN_STARTED' or
		event == 'SPELL_COOLDOWN_READY' or
		event == 'SPELL_COOLDOWN_CHANGED'
	then
		ZT:handleEvent(event, type, 0)
	end
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

	hooksecurefunc(WeakAuras, 'ScanEvents', ZT.ScanEvents);
end