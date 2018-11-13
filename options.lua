local _, ZT = ...;

local StdUi = LibStub('StdUi');

local defaults = {
	showMine  = {
		INTERRUPT  = true,
		HARDCC     = true,
		STHARDCC   = true,
		SOFTCC     = true,
		STSOFTCC   = true,
		EXTERNAL   = true,
		HEALING    = true,
		DISPEL     = true,
		DEFMDISPEL = true,
		UTILITY    = true,
		PERSONAL   = true,
		IMMUNITY   = true,
		DAMAGE     = true,
		TANK       = true,
	},
	blacklist = {},

	debugEvents = false,
	debugMessages = false,
	debugTracking = false,
};

function ZT:RegisterOptions()
	if not ZenTrackerDb or type(ZenTrackerDb) ~= 'table' then
		ZenTrackerDb = defaults;
	end

	self.db = ZenTrackerDb;

	if self.optionsFrame then
		return;
	end

	local optionsFrame = StdUi:PanelWithTitle(UIParent, 100, 100, 'Zen Tracker');
	optionsFrame.name = 'Zen Tracker';
	optionsFrame:Hide();

	self.optionsFrame = optionsFrame;

	StdUi:EasyLayout(optionsFrame, { padding = { top = 40 } });

	local debugEvents = StdUi:Checkbox(optionsFrame, 'Debug Events');
	if self.db.debugEvents then debugEvents:SetChecked(true); end
	debugEvents.OnValueChanged = function(_, flag) self.db.debugEvents = flag; end

	local debugMessages = StdUi:Checkbox(optionsFrame, 'Debug Messages');
	if self.db.debugMessages then debugMessages:SetChecked(true); end
	debugMessages.OnValueChanged = function(_, flag) self.db.debugMessages = flag; end

	local debugTracking = StdUi:Checkbox(optionsFrame, 'Debug Tracking');
	if self.db.debugTracking then debugTracking:SetChecked(true); end
	debugTracking.OnValueChanged = function(_, flag) self.db.debugTracking = flag; end


	optionsFrame:AddRow():AddElements(debugEvents, debugMessages, debugTracking, { column = 'even' });

	optionsFrame:SetScript('OnShow', function(of)
		of:DoLayout();
	end);

	InterfaceOptions_AddCategory(self.optionsFrame);
end