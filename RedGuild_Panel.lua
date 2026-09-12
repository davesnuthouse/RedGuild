tabs = {}

function CreateTab(index, text)
    local tab = CreateFrame("Button", addonName.."Tab"..index, mainFrame, "CharacterFrameTabButtonTemplate")
    tab:SetID(index)
    tab:SetText(text)
    PanelTemplates_TabResize(tab, 0)

    tab:SetScript("OnClick", function(self)
        ShowTab(self:GetID())
    end)

    tabs[index] = tab
end

function RealignTabs()
    local last = nil
    for i, tab in ipairs(tabs) do
        if tab:IsShown() then
            tab:ClearAllPoints()
            if not last then
                -- First visible tab always anchors to DKP position
                tab:SetPoint("TOPLEFT", mainFrame, "BOTTOMLEFT", 5, 2)
            else
                tab:SetPoint("LEFT", last, "RIGHT", -15, 0)
            end
            last = tab
        end
    end
end

-- The editor-only tabs (Bid Log, RL Tools, Editors, Audit Log) are
-- always created in CreateUI, but IsEditor() depends on the guild
-- roster (it looks up the player's own rank), which is often not
-- populated yet at that exact moment - it can resolve moments later,
-- once GUILD_ROSTER_UPDATE actually delivers it. Called from every
-- point that can happen so the tabs show up (or disappear, on a rank
-- change) without needing a UI reload.
function RedGuild_UpdateEditorTabVisibility()
    if not tabs[TAB_BIDLOG] then return end   -- CreateUI hasn't run yet

    local editor = IsEditor(UnitName("player"))
    for _, idx in ipairs({ TAB_BIDLOG, TAB_RAID, TAB_EDITORS, TAB_AUDIT }) do
        local tab = tabs[idx]
        if tab then
            if editor then tab:Show() else tab:Hide() end
        end
    end

    RealignTabs()
end

function LayoutPanel(panel)
    panel:SetAllPoints(mainFrame)
    panel:Hide()
end

function ShowTab(id)
    if not RedGuild_UIReady then
        return
    end
    activeTab = id

    for i, tab in ipairs(tabs) do
        if i == id then
            PanelTemplates_SelectTab(tab)
        else
            PanelTemplates_DeselectTab(tab)
        end
    end

    dkpPanel:Hide()
	altPanel:Hide()
    groupPanel:Hide()
    raidPanel:Hide()
	mlPanel:Hide()
    editorsPanel:Hide()
    auditPanel:Hide()
	if bidLogPanel then bidLogPanel:Hide() end

    if id == TAB_DKP then
        dkpPanel:Show()
	elseif id == TAB_ALT then
        altPanel:Show()
    elseif id == TAB_GROUP then
        groupPanel:Show()
    elseif id == TAB_RAID then
        raidPanel:Show()
	elseif id == TAB_ML then
        mlPanel:Show()
    elseif id == TAB_EDITORS then
        editorsPanel:Show()
    elseif id == TAB_AUDIT then
        auditPanel:Show()
    elseif id == TAB_BIDLOG then
        if bidLogPanel then
            bidLogPanel:Show()
            RedGuild_BidLog_Refresh()
        end
    end
end

headers = {
    { text = "Name",       width = 80 },
	{ text = "MS",         width = 30  },
    { text = "OS",         width = 40  },
    { text = "Old Bal",    width = 65  },
    { text = "OnTime",     width = 65  },
    { text = "PostRaid",     width = 70  },
    { text = "Bench",      width = 55  },
    { text = "Spent",      width = 55  },
    { text = "Live Bal",   width = 65  },
	{ text = "Rotated",  width = 55  },
    { text = "",           width = 55  },
}

fieldMap = {
    [1] = "name",
	[2] = "msRole",
    [3] = "osRole",
    [4] = "lastWeek",
    [5] = "onTime",
    [6] = "attendance",
    [7] = "bench",
    [8] = "spent",
    [9] = "balance",
    [10] = "rotated",
	[11] = "whisper",
}

-- Class → Spec list (Blizzard internal spec names)
local CLASS_SPECS = {
    WARRIOR     = { "Arms", "Fury", "Protection" },
    PALADIN     = { "Holy", "Protection", "Retribution" },
    HUNTER      = { "BeastMastery", "Marksmanship", "Survival" },
    ROGUE       = { "Assassination", "Combat", "Subtlety" },
    PRIEST      = { "Discipline", "Holy", "Shadow" },
    SHAMAN      = { "Elemental", "Enhancement", "Restoration" },
    MAGE        = { "Arcane", "Fire", "Frost" },
    WARLOCK     = { "Affliction", "Demonology", "Destruction" },
    DRUID       = { "Balance", "Feral", "Guardian", "Restoration" },
}

-- Spec → Icon path (TBC Anniversary spec icons)
local SPEC_ICONS = {
    -- WARRIOR
    Arms           = "Interface\\Icons\\Ability_Warrior_SavageBlow",
    Fury           = "Interface\\Icons\\Ability_Warrior_InnerRage",
    Protection     = "Interface\\Icons\\Ability_Defend",

    -- PALADIN
    Holy           = "Interface\\Icons\\Spell_Holy_HolyBolt",
    Protection     = "Interface\\Icons\\Spell_Holy_DevotionAura",
    Retribution    = "Interface\\Icons\\Spell_Holy_AuraOfLight",

    -- HUNTER
    BeastMastery   = "Interface\\Icons\\Ability_Hunter_BeastTaming",
    Marksmanship   = "Interface\\Icons\\Ability_Marksmanship",
    Survival       = "Interface\\Icons\\Ability_Hunter_SwiftStrike",

    -- ROGUE
    Assassination  = "Interface\\Icons\\Ability_Rogue_Eviscerate",
    Combat         = "Interface\\Icons\\Ability_BackStab",
    Subtlety       = "Interface\\Icons\\Ability_Stealth",

    -- PRIEST
    Discipline     = "Interface\\Icons\\Spell_Holy_PowerWordShield",
    HolyPriest     = "Interface\\Icons\\Spell_Holy_GuardianSpirit",
    Shadow         = "Interface\\Icons\\Spell_Shadow_ShadowWordPain",

    -- SHAMAN
    Elemental      = "Interface\\Icons\\Spell_Nature_Lightning",
    Enhancement    = "Interface\\Icons\\Spell_Nature_LightningShield",
    RestorationShm = "Interface\\Icons\\Spell_Nature_MagicImmunity",

    -- MAGE
    Arcane         = "Interface\\Icons\\Spell_Holy_MagicalSentry",
    Fire           = "Interface\\Icons\\Spell_Fire_FireBolt02",
    Frost          = "Interface\\Icons\\Spell_Frost_FrostBolt02",

    -- WARLOCK
    Affliction     = "Interface\\Icons\\Spell_Shadow_DeathCoil",
    Demonology     = "Interface\\Icons\\Spell_Shadow_Metamorphosis",
    Destruction    = "Interface\\Icons\\Spell_Shadow_RainOfFire",

    -- DRUID
    Balance        = "Interface\\Icons\\Spell_Nature_StarFall",
    Feral          = "Interface\\Icons\\Ability_Druid_Catform",
    Guardian       = "Interface\\Icons\\Ability_Racial_BearForm",
    Restoration    = "Interface\\Icons\\Spell_Nature_HealingTouch",
}

-- Spec → Role mapping (for Group Builder)
SPEC_ROLES = {
    Arms           = "melee",
    Fury           = "melee",
    Protection     = "tank",

    Holy           = "healer",
    Retribution    = "melee",

    BeastMastery   = "ranged",
    Marksmanship   = "ranged",
    Survival       = "ranged",

    Assassination  = "melee",
    Combat         = "melee",
    Subtlety       = "melee",

    Discipline     = "healer",
    Shadow         = "caster",

    Elemental      = "caster",
    Enhancement    = "melee",
    Restoration    = "healer",

    Arcane         = "caster",
    Fire           = "caster",
    Frost          = "caster",

    Affliction     = "caster",
    Demonology     = "caster",
    Destruction    = "caster",

    Balance        = "caster",
    Feral          = "melee",
    Guardian       = "tank",
    Restoration    = "healer",
}

dkpRows = {}
dkpSortedNames = {}
dkpHeaderButtons = {}
editorRows = {}
auditRows = {}
currentSortField = "name"
currentSortAscending = true


ROW_HEIGHT = 18

ROW_TOTAL_WIDTH = 30 -- delete button column
for _, h in ipairs(headers) do
    ROW_TOTAL_WIDTH = ROW_TOTAL_WIDTH + h.width + 5
end

function CreateDKPRow()
    local row = CreateFrame("Frame", nil, dkpScrollChild)
    row:SetFrameLevel(1)
    row:SetSize(ROW_TOTAL_WIDTH, ROW_HEIGHT)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.15)
    row.bg = bg

    -- DELETE BUTTON
    local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    delBtn:SetSize(15, 15)
    delBtn:SetPoint("LEFT", row, "LEFT", 2, 0)
    delBtn:SetText("x")
    row.deleteButton = delBtn

    -- Only hide for non‑editors (NOT for lock state)
	
	if not IsEditor(UnitName("player")) then
        if dkpLocked then
			row.deleteButton:Hide()
		else
			row.deleteButton:Show()
		end
    end

	-- DELETE/INACTIVE BUTTON
	delBtn:SetScript("OnClick", function()
		if dkpLocked then return end
		if not IsAuthorized() then
			Print("Only editors can modify DKP records.")
			return
		end

		local player = row.name
		if not player then return end

		StaticPopup_Show("REDGUILD_DELETE_PLAYER", player, nil, player)
	end)
	
    -- COLUMNS
    row.cols = {}
    local colX = 30

    for j, h in ipairs(headers) do
        local field = fieldMap[j]
        local col

        if field == "name" then
			col = CreateFrame("Button", nil, row)
			col:SetPoint("LEFT", row, "LEFT", colX, 0)
			col:SetSize(h.width, ROW_HEIGHT)
			col:EnableMouse(true)

			local fs = col:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetAllPoints()
			fs:SetJustifyH("LEFT")
			col.fs = fs
			
			-- NAME CLICK HANDLER (THIS WAS MISSING)
			col:SetScript("OnMouseDown", function(self, button)
				if dkpLocked then return end
				if button ~= "LeftButton" then return end
				if not IsAuthorized() then return end

				local playerName = row.name
				if not playerName then return end

				dkpInlineEdit:Hide()
				fs:Hide()

				dkpInlineEdit.currentFS = fs
				dkpInlineEdit.editPlayer = playerName
				dkpInlineEdit.editField  = "name"

				dkpInlineEdit:ClearAllPoints()
				dkpInlineEdit:SetPoint("LEFT", self, "LEFT", 0, 0)
				dkpInlineEdit:SetWidth(h.width - 4)
				dkpInlineEdit:SetText(playerName)
				dkpInlineEdit:HighlightText()

				dkpInlineEdit.saveFunc = function(newName)
					newName = newName:gsub("^%s*(.-)%s*$", "%1")
					if newName == "" or newName == playerName then return end

					local short = Ambiguate(newName, "short")
					local ok, proper = IsNameInGuild(short)
					if not ok then
						Print("|cffff5555Cannot rename — not in guild.|r")
						return
					end

					newName = proper

					if NameExists(newName, playerName) then
						Print("|cffff5555Name already exists.|r")
						return
					end

					RedGuild_Data[newName] = RedGuild_Data[playerName]
					RedGuild_Data[playerName] = nil

					local _, class = UnitClass(newName)
					if not class and IsInGuild() then
						for gi = 1, GetNumGuildMembers() do
							local gName, _, _, _, _, _, _, _, _, _, gClass = GetGuildRosterInfo(gi)
								if gName and Ambiguate(gName, "short") == newName then
									class = gClass
									break
								end
							end
						end

					if class then
						RedGuild_Data[newName].class = class
					end

					LogAudit(newName, "RENAME_PLAYER", "changed",
						string.format("Renamed by %s | %s → %s", UnitName("player"), playerName, newName)
					)

					suppressWarnings = true
					UpdateTable()
					suppressWarnings = false
				end

				dkpInlineEdit:Show()
			end)

        elseif field == "msRole" or field == "osRole" then
            col = CreateFrame("Button", nil, row)
            col:SetPoint("LEFT", row, "LEFT", colX, 0)
            col:SetSize(16, 16)

            col.icon = col:CreateTexture(nil, "ARTWORK")
            col.icon:SetAllPoints()
            col.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

            row.mainSpecBtn = row.mainSpecBtn or (field == "msRole" and col or row.mainSpecBtn)
            row.offSpecBtn  = row.offSpecBtn  or (field == "osRole" and col or row.offSpecBtn)

            col:SetScript("OnClick", function()
                if dkpLocked then return end
                if not IsAuthorized() then return end

                local player = row.name
                if not player then return end

                local d = EnsurePlayer(player)
                local class = d.class
                if not class then return end

                local specList = CLASS_SPECS[class]
                if not specList or #specList == 0 then return end

                local currentSpec = d[field]
                local idx = 0

                for k, specName in ipairs(specList) do
                    if specName == currentSpec then
                        idx = k
                        break
                    end
                end

                idx = idx + 1
                if idx > #specList then
                    currentSpec = nil
                else
                    currentSpec = specList[idx]
                end

                local old = d[field]
                d[field] = currentSpec

                local icon = currentSpec and SPEC_ICONS[currentSpec] or "Interface\\Icons\\INV_Misc_QuestionMark"
                col.icon:SetTexture(icon)

                LogAudit(player, field, old or "none", currentSpec or "none")
                UpdateTable()
            end)

        elseif field == "rotated" then
            col = CreateFrame("Button", nil, row)
            col:SetPoint("LEFT", row, "LEFT", colX, 0)
            col:SetSize(h.width, ROW_HEIGHT)

            local fs = col:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetAllPoints(col)
            fs:SetJustifyH("LEFT")
            col:SetFontString(fs)

            col:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            col:GetHighlightTexture():SetAlpha(0.3)

            col:SetScript("OnMouseDown", function(self, button)
                if dkpLocked then return end
                if not IsAuthorized() then return end

                local rowIndex = row.index
                if not rowIndex then return end

                local name = row.name
                if not name then return end

                local d = RedGuild_Data[name]
                if not d then return end

                local old = tonumber(d.rotated) or 0
                local new = old

                if button == "LeftButton" then
                    new = old + 1
                elseif button == "RightButton" then
                    new = math.max(0, old - 1)
                end

                if new ~= old then
                    d.rotated = new
                    LogAudit(name, "rotations", old, new)
                    UpdateTable()
                end
            end)

        elseif field == "whisper" then
            col = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            col:SetPoint("LEFT", row, "LEFT", colX + 5, 0)
            col:SetSize(h.width - 10, 16)
            col:SetText("Tell")

            row.tellButton = col

            col:SetScript("OnClick", function()
                local index = row.index
                if not index then return end
                local player = row.name
                if not player then return end
                local d = RedGuild_Data[player]
                if not d then return end
                local msg = string.format(
                    "Your DKP: Previous=%d, OnTime=%d, PostRaid(Attend)=%d, Bench=%d, Spent=%d, CURRENTBalance=%d",
                    d.lastWeek or 0,
                    d.onTime or 0,
                    d.attendance or 0,
                    d.bench or 0,
                    d.spent or 0,
                    d.balance or 0
                )
                SendChatMessage(msg, "WHISPER", nil, player)
                Print("Whisper sent to " .. player)
            end)

        elseif field == "balance" then
            col = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            col:SetPoint("LEFT", row, "LEFT", colX, 0)
            col:SetWidth(h.width)
            col:SetJustifyH("LEFT")
            col:EnableMouse(false)

        else
            col = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            col:SetPoint("LEFT", row, "LEFT", colX, 0)
            col:SetWidth(h.width)
            col:SetJustifyH("LEFT")
            col:EnableMouse(true)

            col:SetScript("OnMouseDown", function(self, button)
                if dkpLocked then return end
                if button ~= "LeftButton" then return end
                if not IsAuthorized() then return end

                dkpInlineEdit:Hide()

                local rowIndex = row.index
                local colIndex = j
                local player   = row.name
                local fieldKey = fieldMap[colIndex]
                if not player or not fieldKey then return end

                local d = EnsurePlayer(player)

                -- NAME EDIT
if fieldKey == "name" then
    if dkpLocked then return end
    if button ~= "LeftButton" then return end
    if not IsAuthorized() then return end

    local playerName = row.name
    if not playerName then return end

    dkpInlineEdit:Hide()
    self:Hide()

    dkpInlineEdit.currentFS = self
    dkpInlineEdit.editPlayer = playerName
    dkpInlineEdit.editField  = "name"

    dkpInlineEdit:ClearAllPoints()
    dkpInlineEdit:SetPoint("LEFT", self, "LEFT", 0, 0)
    dkpInlineEdit:SetWidth(headers[colIndex].width - 4)
    dkpInlineEdit:SetText(playerName)
    dkpInlineEdit:HighlightText()

    dkpInlineEdit.saveFunc = function(newName)
        newName = newName:gsub("^%s*(.-)%s*$", "%1")
        if newName == "" or newName == playerName then return end

        local short = Ambiguate(newName, "short")
        local ok, proper = IsNameInGuild(short)
        if not ok then
            Print("|cffff5555Cannot rename — that player is not in your guild.|r")
            return
        end

        newName = proper

        if NameExists(newName, playerName) then
            Print("|cffff5555A player with that name already exists.|r")
            return
        end

        RedGuild_Data[newName] = RedGuild_Data[playerName]
        RedGuild_Data[playerName] = nil

        local _, class = UnitClass(newName)
        if not class and IsInGuild() then
            for gi = 1, GetNumGuildMembers() do
                local gName, _, _, _, _, _, _, _, _, _, gClass = GetGuildRosterInfo(gi)
                if gName and Ambiguate(gName, "short") == newName then
                    class = gClass
                    break
                end
            end
        end
        if class then
            RedGuild_Data[newName].class = class
        end

        LogAudit(newName, "RENAME_PLAYER", "changed",
            string.format("Renamed by %s | %s → %s", UnitName("player"), playerName, newName)
        )

        suppressWarnings = true
        UpdateTable()
        suppressWarnings = false
    end

    dkpInlineEdit:Show()
    return
end

                -- NUMERIC FIELD EDIT
                self:Hide()
                dkpInlineEdit.currentFS = self

                dkpInlineEdit.editPlayer = player
                dkpInlineEdit.editField  = fieldKey

                dkpInlineEdit:ClearAllPoints()
                dkpInlineEdit:SetPoint("LEFT", self, "LEFT", 0, 0)
                dkpInlineEdit:SetWidth(headers[colIndex].width - 4)
                dkpInlineEdit:SetText(tostring(d[fieldKey] or 0))
                dkpInlineEdit:HighlightText()

                dkpInlineEdit.saveFunc = function(newValue)
                    local num = tonumber(newValue)
                    if not num then return end

                    local playerName = dkpInlineEdit.editPlayer
                    local fieldName  = dkpInlineEdit.editField
                    local dkp = RedGuild_Data[playerName]
                    if not dkp then return end

                    local old = dkp[fieldName]

                    if fieldName == "onTime" and num > 5 then
                        Print("|cffff5555On-Time DKP cannot exceed 5.|r")
                        UpdateTable()
                        return
                    end

                    if fieldName == "attendance" and num > 15 then
                        Print("|cffff5555Attendance DKP cannot exceed 15.|r")
                        UpdateTable()
                        return
                    end

                    if fieldName == "bench" and num > 20 then
                        Print("|cffff5555Bench DKP cannot exceed 20.|r")
                        UpdateTable()
                        return
                    end

                    if old == num then
                        UpdateTable()
                        return
                    end

                    dkp[fieldName] = num
                    RecalcBalance(dkp)

                    if num == 69 then
                        print("|cff00ff00Nice!|r")
                    end

                    LogAudit(playerName, fieldName, old, num)
                    BumpDKPVersion()
                    UpdateTable()
                end

                dkpInlineEdit:Show()
            end)
        end

        row.cols[j] = col
        colX = colX + h.width + 5
    end

    return row
end

function UpdateTable()
    if not dkpRows then dkpRows = {} end
    if type(dkpRows) ~= "table" then dkpRows = {} end

    ----------------------------------------------------------------
    -- BUILD CLEAN NAME LIST
    ----------------------------------------------------------------
    local allNames = {}

    for name in pairs(RedGuild_Data) do
        if type(name) == "string" then
            local trimmed = strtrim(name)
            if trimmed ~= "" then
                table.insert(allNames, trimmed)
            end
        end
    end

    ----------------------------------------------------------------
    -- FILTER (NO INVALID / INACTIVE / HIDDEN LOGIC)
    ----------------------------------------------------------------
    local filtered = {}

    for _, name in ipairs(allNames) do
        table.insert(filtered, name)
    end

    ----------------------------------------------------------------
    -- SHOW ONLY ME FILTER
    ----------------------------------------------------------------
    if dkpShowOnlyMe then
        local me = Ambiguate(UnitName("player"), "short")
        filtered = { me }
    end

    ----------------------------------------------------------------
    -- GROUP FILTER
    ----------------------------------------------------------------
    if dkpShowGroupOnly then
        local groupFiltered = {}

        if not IsInRaid() and not IsInGroup() then
            local me = Ambiguate(UnitName("player"), "short")
            filtered = { me }
        else
            for _, name in ipairs(filtered) do
                local inGroup = false

                if IsInRaid() then
                    for i = 1, GetNumGroupMembers() do
                        local r = UnitName("raid"..i)
                        if r and Ambiguate(r, "short") == name then
                            inGroup = true
                            break
                        end
                    end
                else
                    for i = 1, GetNumSubgroupMembers() do
                        local p = UnitName("party"..i)
                        if p and Ambiguate(p, "short") == name then
                            inGroup = true
                            break
                        end
                    end

                    if Ambiguate(UnitName("player"), "short") == name then
                        inGroup = true
                    end
                end

                if inGroup then
                    table.insert(groupFiltered, name)
                end
            end

            filtered = groupFiltered
        end
    end

    ----------------------------------------------------------------
    -- SORT
    ----------------------------------------------------------------
    table.sort(filtered, function(a, b)
        if not a and not b then return false end
        if not a then return false end
        if not b then return true end

        if currentSortField == "name" then
            if currentSortAscending then
                return tostring(a) < tostring(b)
            else
                return tostring(a) > tostring(b)
            end
        end

        local da = RedGuild_Data[a] or {}
        local db = RedGuild_Data[b] or {}

        local field = currentSortField
        local va, vb

        if field == "msRole" or field == "osRole" then
            va = tostring(da[field] or "")
            vb = tostring(db[field] or "")
        elseif field == "rotated" then
            va = tonumber(da.rotated) or 0
            vb = tonumber(db.rotated) or 0
        else
            va = tonumber(da[field]) or 0
            vb = tonumber(db[field]) or 0
        end

        if va ~= vb then
            if currentSortAscending then
                return va < vb
            else
                return va > vb
            end
        end

        return tostring(a) < tostring(b)
    end)

    ----------------------------------------------------------------
    -- FINAL DATA SET
    ----------------------------------------------------------------
    dkpSortedNames = filtered or {}
    local totalRows = #dkpSortedNames

    ----------------------------------------------------------------
    -- SCROLL + VIEWPORT (18px aligned)
    ----------------------------------------------------------------
    local rowHeight      = ROW_HEIGHT or 18
    local viewportHeight = dkpScroll:GetHeight() or 300
    local maxVisibleRows = math.floor(viewportHeight / rowHeight)

    -- Correct maxOffset (row-based, not pixel-based)
    local maxOffset = math.max(0, totalRows - maxVisibleRows)

    local scrollPos = dkpScroll:GetVerticalScroll() or 0
    local offset    = math.floor(scrollPos / rowHeight)
    offset = math.max(0, math.min(offset, totalRows - maxVisibleRows))

    ----------------------------------------------------------------
    -- ENSURE ROWS EXIST
    ----------------------------------------------------------------
    for i = #dkpRows + 1, maxVisibleRows do
        dkpRows[i] = CreateDKPRow()
    end

    ----------------------------------------------------------------
    -- RENDER
    ----------------------------------------------------------------
    for i = 1, maxVisibleRows do
        local dataIndex = i + offset
        local row = dkpRows[i]

        if dataIndex <= totalRows then
            local name = dkpSortedNames[dataIndex]
            local d = RedGuild_Data[name] or EnsurePlayer(name)
			
			-- Normalize missing fields
			d.class      = d.class      or "UNKNOWN"
			d.msRole     = d.msRole     or "UNKNOWN"
			d.osRole     = d.osRole     or "UNKNOWN"
			d.lastWeek   = d.lastWeek   or 0
			d.onTime     = d.onTime     or 0
			d.attendance = d.attendance or 0
			d.bench      = d.bench      or 0
			d.spent      = d.spent      or 0
			d.rotated    = d.rotated    or 0
			d.balance    = d.balance    or 0
			
			----------------------------------------------------------------
			-- CAP LAST WEEK AT 300
----------------------------------------------------------------
			if d.lastWeek > 300 then
				d.lastWeek = 300
			end

            row.name = name
            row.index = dataIndex
			
			----------------------------------------------------------------
			-- HIGHLIGHT LOGGED-IN PLAYER ROW
----------------------------------------------------------------
			local me = Ambiguate(UnitName("player"), "short")

			if name == me then
				row.bg:SetColorTexture(0.20, 0.40, 0.80, 0.25)
			else
				row.bg:SetColorTexture(0, 0, 0, 0.15)
			end

            row:Show()
			row:SetPoint("TOPLEFT", dkpScrollChild, "TOPLEFT", 0, -(dataIndex - 1) * rowHeight) 
            row:SetParent(dkpScrollChild)

            RecalcBalance(d)

            --------------------------------------------------------
            -- LOCK STATE
            --------------------------------------------------------
            if row.deleteButton and row.reactivateButton then
                if dkpLocked or not IsEditor(UnitName("player")) then
                    row.deleteButton:Hide()
                else
                    row.deleteButton:Show()
                end
            end

            if row.mainSpecBtn then
                row.mainSpecBtn:EnableMouse(not dkpLocked)
            end

            if row.offSpecBtn then
                row.offSpecBtn:EnableMouse(not dkpLocked)
            end

            if row.tellButton then
                row.tellButton:Show()
            end
			
			-- DELETE BUTTON VISIBILITY
			if dkpLocked or not IsEditor(UnitName("player")) then
				row.deleteButton:Hide()
			else
				row.deleteButton:Show()
			end

            --------------------------------------------------------
            -- DISPLAY NAME (alt + not-in-guild markers)
            --------------------------------------------------------
            local classColor = "|cffffffff"
            if d.class then
                local c = RAID_CLASS_COLORS[d.class]
                if c then
                    classColor = string.format("|cff%02x%02x%02x",
                        c.r * 255, c.g * 255, c.b * 255)
                end
            end

            local displayName = name

            -- ALT MARKER
            local isAlt = RedGuild_AltParent[name] and RedGuild_AltParent[name] ~= name
            if isAlt then
                displayName = "~" .. displayName
            end

            -- NOT IN GUILD MARKER
            if not IsNameInGuild(name) then
                displayName = "-" .. displayName
            end

            row.cols[1].fs:SetText(classColor .. displayName .. "|r")
            row.cols[2].icon:SetTexture(SPEC_ICONS[d.msRole] or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.cols[3].icon:SetTexture(SPEC_ICONS[d.osRole] or "Interface\\Icons\\INV_Misc_QuestionMark")

            row.cols[4]:SetText(d.lastWeek or 0)
            row.cols[5]:SetText(d.onTime or 0)
            row.cols[6]:SetText(d.attendance or 0)
            row.cols[7]:SetText(d.bench or 0)
            row.cols[8]:SetText(d.spent or 0)
            row.cols[9]:SetText(ColorizeBalance(d))
            row.cols[10]:SetText(tonumber(d.rotated) or 0)

        else
            row:Hide()
            row.name = nil
            row.index = nil
        end
    end

    ----------------------------------------------------------------
    -- SCROLL HEIGHT
    ----------------------------------------------------------------
    dkpScrollChild:SetHeight(totalRows * rowHeight + rowHeight)
end

function UpdateAuditLog()
    if not auditRows or not RedGuild_Audit then return end
	
	-- Remove entries older than 30 days
	local cutoff = time() - (30 * 24 * 60 * 60)  -- 30 days in seconds

	for i = #RedGuild_Audit, 1, -1 do
		local entry = RedGuild_Audit[i]
		if entry and entry.time then
			local ts = ParseAuditTime(entry.time)
			if ts and ts < cutoff then
				table.remove(RedGuild_Audit, i)
			end
		end
	end

    table.sort(RedGuild_Audit, function(a, b)
        if not a.time or not b.time then
            return false
        end
        return ParseAuditTime(a.time) > ParseAuditTime(b.time)   -- newest first
    end)

    for i, row in ipairs(auditRows) do
        local entry = RedGuild_Audit[i]

        if entry then
            local t  = entry.time   or "unknown"
            local s  = entry.editor or "unknown"
            local n  = entry.name   or "unknown"
            local f  = entry.field  or "unknown"
            local o  = (entry.old ~= nil) and tostring(entry.old) or "nil"
            local nw = (entry.new ~= nil) and tostring(entry.new) or "nil"

            row.text:SetText(string.format("[%s] %s changed %s's %s from %s to %s",
                t, s, n, f, o, nw
            ))

            row:Show()
        else
            row:Hide()
        end
    end
end

-- Lists the guild's current rank 1 / rank 5 members - editor status
-- is read straight from the live guild roster, so there is no list to
-- broadcast or apply anymore.
function RefreshEditorList()
    if not editorRows then return end

    -- Fixed editors, in sync priority order (Celevius first).
    local names = EDITOR_PRIORITY

    -- Fill rows
    local i = 1
    for _, name in ipairs(names) do
        local row = editorRows[i]
        if not row then break end

        row.name = name

        local key = NormalizeName(name)
        local ver = RedGuild_Config.EditorVersions and RedGuild_Config.EditorVersions[key]

        if ver then
            row.text:SetText(string.format("%s (v%s)", name, ver))
        else
            row.text:SetText(string.format("%s (—)", name))
        end

        row:Show()
        i = i + 1
    end

    -- Hide unused rows
    for j = i, #editorRows do
        editorRows[j].name = nil
        editorRows[j].text:SetText("")
        editorRows[j]:Hide()
    end
end

