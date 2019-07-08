local _, ZT = ...;

--- @type StdUi
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
	debugCleu = false,
};

local function update(parent, spellInfo, data)
	spellInfo:SetSpell(data);
	StdUi:SetObjSize(spellInfo, nil, 20);
	spellInfo:SetPoint('RIGHT');
	spellInfo:SetPoint('LEFT');

	if not spellInfo.removeBtn.hasOnClick then
		spellInfo.removeBtn:SetScript('OnClick', function(self)
			local spellId = self.parent.spellId;
			local spellList = parent:GetParent():GetParent();

			for k, v in pairs(spellList.data) do
				if v == spellId then
					tremove(spellList.data, k);
					break
				end
			end

			spellList:RefreshList();
		end);

		spellInfo.removeBtn.hasOnClick = true;
	end

	return spellInfo;
end

StdUi:RegisterWidget('SpellList', function(stdUi, parent, width, height, data)
	local spellList = StdUi:ScrollFrame(parent, 200, 400);
	spellList.frameList = {};
	spellList.data = data;

	function spellList:RefreshList()
		StdUi:ObjectList(spellList.scrollChild, self.frameList, 'SpellInfo', update, self.data);
	end

	spellList:RefreshList();

	return spellList;
end);

function ZT:BuildOptionsFrame(parent)
	local column = 4;

	local scrollFrame = StdUi:ScrollFrame(parent, parent:GetWidth(), 400);
	local child = scrollFrame.scrollChild;

	StdUi:EasyLayout(child);

	local spellNames = {};
	local oldType;
	local row
	local columnsTaken = 0;

	for _, spell in pairs(self.spells) do
		local type = spell.type;

		if not oldType or type ~= oldType then
			child:AddRow():AddElement(StdUi:Label(child, type));

			row = child:AddRow();
			columnsTaken = 0;
		end

		local spellName = GetSpellInfo(spell.spellID);
		spellName = spellName:gsub('%s+', '');

		if not spellNames[spellName] then
			if columnsTaken >= 12 then
				row = child:AddRow();
				columnsTaken = 0;
			end

			local option = StdUi:SpellCheckbox(child, nil, 20);
			option:SetSpell(spell.spellID);

			if self.db.blacklist[spellName] then option:SetChecked(true); end
			option.OnValueChanged = function(scb, flag)
				local shortName = scb.spellName:gsub('%s+', '');
				self.db.blacklist[shortName] = flag and true or nil;
			end

			row:AddElement(option, { column = column });
			columnsTaken = columnsTaken + column;
			spellNames[spellName] = true;
		end

		oldType = type;
	end

	return scrollFrame;
end

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

	local debugCleu = StdUi:Checkbox(optionsFrame, 'Debug CLEU');
	if self.db.debugCleu then debugCleu:SetChecked(true); end
	debugCleu.OnValueChanged = function(_, flag) self.db.debugCleu = flag; end

	local scrollFrame = self:BuildOptionsFrame(optionsFrame);

	optionsFrame:AddRow():AddElements(debugEvents, debugMessages, { column = 'even' });
	optionsFrame:AddRow():AddElements(debugTracking, debugCleu, { column = 'even' });

	optionsFrame:AddRow():AddElement(StdUi:Header(optionsFrame, 'Spell Blacklist'));

	optionsFrame:AddRow():AddElements(scrollFrame, { column = 12 });

	optionsFrame:SetScript('OnShow', function(of)
		if not of.layoutDone then
			of:DoLayout();
			scrollFrame.scrollChild:DoLayout();
			of.layoutDone = true;
		end
	end);

	InterfaceOptions_AddCategory(self.optionsFrame);
end