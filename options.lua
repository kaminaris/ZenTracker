local _, ZT = ...;

Local

function ZT:RegisterOptionWindow()
	if self.optionsFrame then
		return;
	end

	self.optionsFrame = StdUi:PanelWithTitle(UIParent, 100, 100, 'Keystone Manager');
	self.optionsFrame.name = 'Keystone Manager';
	self.optionsFrame:Hide();

	local enabled = StdUi:Checkbox(self.optionsFrame, 'Enable Addon');
	if self.db.enabled then enabled:SetChecked(true); end
	enabled.OnValueChanged = function(_, flag) KeystoneManager.db.enabled = flag; end

	local announce = StdUi:Checkbox(self.optionsFrame, 'Announce new key in party channel');
	if self.db.announce then announce:SetChecked(true);	end
	announce.OnValueChanged = function(_, flag)	KeystoneManager.db.announce = flag;	end


	StdUi:GlueTop(enabled, self.optionsFrame, 10, -40, 'LEFT');
	StdUi:GlueBelow(announce, enabled, 0, -10, 'LEFT');

	InterfaceOptions_AddCategory(self.optionsFrame);
end