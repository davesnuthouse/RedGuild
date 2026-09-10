function CreateDKPLockButton()
-- DKP LOCK BUTTON (Editors only)
local lockBtn = CreateFrame("Button", nil, dkpPanel, "UIPanelButtonTemplate")
lockBtn:SetSize(60, 20)
lockBtn:SetScale(0.8)
lockBtn:SetPoint("TOPRIGHT", dkpPanel, "TOPRIGHT", -20, -50)
lockBtn:SetFrameStrata("HIGH")
lockBtn:SetFrameLevel(1000)

local function UpdateLockButtonText()
    if dkpLocked then
        lockBtn:SetText("Unlock")
    else
        lockBtn:SetText("Lock")
    end
end

-- Only visible to editors
if not IsEditor(UnitName("player")) then
    lockBtn:Hide()
else
    lockBtn:Show()
end

lockBtn:SetScript("OnClick", function()
    dkpLocked = not dkpLocked
    UpdateLockButtonText()
    UpdateAddControls()
    UpdateTable()
end)

UpdateLockButtonText()
	
	-- Clicking anywhere on the DKP panel commits inline edits
	dkpPanel:EnableMouse(true)
	dkpPanel:SetPropagateMouseClicks(true)
	dkpPanel:SetScript("OnMouseDown", function()
		if dkpInlineEdit and dkpInlineEdit:IsShown() then
			dkpInlineEdit.cancelled = false
			if dkpInlineEdit.saveFunc then
				dkpInlineEdit.saveFunc(dkpInlineEdit:GetText())
			end
			dkpInlineEdit:Hide()
		end
	end)
	
end

function CreateDKPTab()
------------------------------------------------------------
-- ADDON VERSION FOOTER INFO LINE (small + grey)
------------------------------------------------------------
local dkpFooter = dkpPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
dkpFooter:SetPoint("BOTTOM", dkpPanel, "BOTTOM", 0, 10)

-- Make it half-size and grey
dkpFooter:SetFont(dkpFooter:GetFont(), 8)   -- default is 12, so 8 is ~half
dkpFooter:SetTextColor(0.7, 0.7, 0.7, 1)    -- light grey

dkpFooter:SetText("RedGuild v" .. REDGUILD_VERSION)
RedGuild_DKPFooter = dkpFooter

--------------------------------------------------------------------
-- DKP TABLE
--------------------------------------------------------------------
do
    syncWarning = dkpPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    syncWarning:SetPoint("BOTTOM", dkpPanel, "BOTTOM", 0, 40)
    syncWarning:SetTextColor(1, 0.2, 0.2)
    SafeSetSyncWarning("WARNING — Your DKP data may be outdated until an editor syncs.")

    local headerY = -55
    local x = 60
    dkpHeaderButtons = dkpHeaderButtons or {}

    for i, h in ipairs(headers) do
        local headerBtn = CreateFrame("Button", nil, dkpPanel)
        headerBtn:SetPoint("TOPLEFT", dkpPanel, "TOPLEFT", x, headerY)
        headerBtn:SetSize(h.width, 16)

        local fs = headerBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetAllPoints()
        fs:SetJustifyH("LEFT")
        fs:SetText(NORMAL_COLOR .. h.text .. "|r")
        headerBtn.text = fs

        headerBtn:SetScript("OnClick", function()
            local field = fieldMap[i]
            if not field 
                or field == "whisper"
                or field == "msRole"
                or field == "osRole"
            then 
                return 
            end

            if currentSortField == field then
                currentSortAscending = not currentSortAscending
            else
                currentSortField = field
                currentSortAscending = false
            end

            for j, hh in ipairs(headers) do
                local btn = dkpHeaderButtons[j]
                if j == i then
                    btn.text:SetText(SORT_COLOR .. hh.text .. "|r")
                else
                    btn.text:SetText(NORMAL_COLOR .. hh.text .. "|r")
                end
            end

            UpdateTable()
        end)

        dkpHeaderButtons[i] = headerBtn
        x = x + h.width + 5
    end

    if dkpHeaderButtons[1] then
        dkpHeaderButtons[1].text:SetText(SORT_COLOR .. headers[1].text .. "|r")
    end
	
----------------------------------------------------------------
-- DKP FILTER CHECKBOXES (top-left above table)
----------------------------------------------------------------
--if IsEditor(UnitName("player")) then

----------------------------------------------------------------
-- SHOW GROUP/RAID ONLY (still to the right of Show Only Me)
----------------------------------------------------------------
local showGroupChk = CreateFrame("CheckButton", nil, dkpPanel, "ChatConfigCheckButtonTemplate")
showGroupChk:SetPoint("TOPLEFT", dkpPanel, "TOPLEFT", 200, -30)
showGroupChk:SetSize(18, 18)

local showGroupLabel = dkpPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
showGroupLabel:SetPoint("LEFT", showGroupChk, "RIGHT", 4, 0)
showGroupLabel:SetText("Show group/raid players only")

-- Only editors see it
--if not IsEditor(UnitName("player")) then
--    showGroupChk:Hide()
--    showGroupLabel:Hide()
--end

showGroupChk:SetScript("OnClick", function(self)
    C_Timer.After(0, function()
        dkpShowGroupOnly = self:GetChecked()
        UpdateTable()
    end)
end)

--end

----------------------------------------------------------------
-- SHOW ONLY ME (all users)
----------------------------------------------------------------
local showMeChk = CreateFrame("CheckButton", nil, dkpPanel, "ChatConfigCheckButtonTemplate")

showMeChk:SetPoint("TOPLEFT", dkpPanel, "TOPLEFT", 80, -30)
showMeChk:SetSize(18, 18)

local showMeLabel = dkpPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
showMeLabel:SetPoint("LEFT", showMeChk, "RIGHT", 4, 0)
showMeLabel:SetText("Show only me")

showMeChk:SetScript("OnClick", function(self)
    dkpShowOnlyMe = self:GetChecked() or false
    UpdateTable()
end)

----------------------------------
-- DKP TABLE SCROLL
----------------------------------

dkpScroll = CreateFrame("ScrollFrame", nil, dkpPanel, "UIPanelScrollFrameTemplate")
dkpScroll:SetPoint("TOPLEFT", dkpPanel, "TOPLEFT", 30, headerY - 20)
dkpScroll:SetPoint("BOTTOMRIGHT", dkpPanel, "BOTTOMRIGHT", -30, 60)

dkpScrollChild = CreateFrame("Frame", nil)
dkpScrollChild:SetWidth(dkpScroll:GetWidth())
dkpScroll:SetScrollChild(dkpScrollChild)
dkpScrollChild:SetParent(dkpScroll)
dkpScrollChild:ClearAllPoints()
dkpScrollChild:SetPoint("TOPLEFT", 0, 0)

local sb = dkpScroll.ScrollBar
if sb then
    sb:ClearAllPoints()
    sb:SetPoint("TOPRIGHT", dkpScroll, "TOPRIGHT", -5, -18)
    sb:SetPoint("BOTTOMRIGHT", dkpScroll, "BOTTOMRIGHT", -20, 16)

    sb:SetValueStep(ROW_HEIGHT)

    sb:SetScript("OnValueChanged", function(self, value)
        dkpScroll:SetVerticalScroll(value)
        UpdateTable()
    end)
end

dkpScroll:SetScript("OnVerticalScroll", function(self, offset)

    self:SetVerticalScroll(offset)
    UpdateTable()
end)

UpdateTable()
end


-- GLOBAL CODE BLOCK --

----------------------------------------------------------------
-- INLINE EDIT BOX
----------------------------------------------------------------
    dkpInlineEdit = CreateFrame("EditBox", nil, dkpScrollChild, "InputBoxTemplate")
    dkpInlineEdit._handled = false
    dkpInlineEdit:SetAutoFocus(true)
    dkpInlineEdit:SetSize(80, 18)
    dkpInlineEdit:Hide()
    dkpInlineEdit.cancelled = false
    dkpInlineEdit:SetFrameStrata("HIGH")

dkpInlineEdit:SetScript("OnEscapePressed", function(self)
    self.cancelled = true
    self._submitted = false
    self._handled = true
    self:Hide()
end)

dkpInlineEdit:SetScript("OnEnterPressed", function(self)
    self.cancelled = false
    self._submitted = true
    self._handled = true

    if self.saveFunc then
        self.saveFunc(self:GetText())
    end

    self:Hide()
end)

dkpInlineEdit:SetScript("OnEditFocusLost", function(self)
    if not self.cancelled and not self._submitted and not self._handled then
        if self.saveFunc then
            self.saveFunc(self:GetText())
        end
    end

    self._submitted = false
    self._handled = false
    self:Hide()
end)

dkpInlineEdit:SetScript("OnHide", function(self)
    self._submitted = false
    self._handled = false

    if self.currentFS then
        self.currentFS:Show()
        self.currentFS = nil
    end
end)

--------------------------------------------------------------------
-- ADD PLAYER INPUT
--------------------------------------------------------------------
    do
        dkpPanel.addInput = CreateFrame("EditBox", nil, dkpPanel, "InputBoxTemplate")
		local addInput = dkpPanel.addInput
        addInput:SetSize(140, 20)
        addInput:SetPoint("BOTTOMLEFT", dkpPanel, "BOTTOMLEFT", 20, 10)
        addInput:SetAutoFocus(false)

        if not IsEditor(UnitName("player")) then
            addInput:Hide()
        end

		addInput:HookScript("OnEditFocusGained", function(self)
			if self._clickCatcher then return end

			local catcher = CreateFrame("Frame", nil, UIParent)
			catcher:SetAllPoints(UIParent)
			catcher:EnableMouse(true)
			catcher:SetFrameStrata("TOOLTIP")

			catcher:SetScript("OnMouseDown", function(_, button)
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    x, y = x / scale, y / scale

    local addButton = dkpPanel.addButton
    if addButton and addButton:IsVisible() then
        local left, right = addButton:GetLeft(), addButton:GetRight()
        local top, bottom = addButton:GetTop(), addButton:GetBottom()

        if left and right and top and bottom then
            if x >= left and x <= right and y >= bottom and y <= top then
                -- FIX: allow the click to go through
                self:ClearFocus()
                catcher:Hide()
                return
            end
        end
    end

    -- Click was outside the button → normal behaviour
    self:ClearFocus()
    catcher:Hide()
	end)

		catcher:SetScript("OnHide", function()
			catcher:SetParent(nil)
			self._clickCatcher = nil
		end)

		self._clickCatcher = catcher
	end)

        addInput:SetScript("OnEscapePressed", addInput.ClearFocus)
        addInput:SetScript("OnEnterPressed", addInput.ClearFocus)

        dkpPanel.addButton = CreateFrame("Button", nil, dkpPanel, "UIPanelButtonTemplate")
		local addButton = dkpPanel.addButton
        addButton:SetSize(75, 22)
        addButton:SetPoint("LEFT", addInput, "RIGHT", 10, 0)
        addButton:SetText("Add")

        if not IsEditor(UnitName("player")) then
            addButton:Hide()
        end

-- Fix: prevent first click from being eaten by focus loss
addButton:RegisterForClicks("AnyUp")
addButton:SetScript("OnMouseDown", function() end)

addButton:SetScript("OnClick", function()
    if not IsAuthorized() then
        Print("Only editors can add DKP records.")
		UpdateTable()
        return
    end

    local raw = addInput:GetText()
    if not raw or raw == "" then return end

    local short = Ambiguate(raw, "short")
    if not short or short == "" then return end

    -- Validate guild membership (hard reject)
    local ok, proper = IsNameInGuild(short)
    if not ok then
        Print("|cffff0000RedGuild:|r Cannot add DKP record — player is not in your guild.")
        return
    end

    local name = proper  -- use correct capitalization

    -- Duplicate check (case-insensitive)
    local upper = string.upper(name)
	
	for existingName, dkp in pairs(RedGuild_Data) do
		if type(dkp) == "table" and string.upper(existingName) == upper then
			Print("|cffff0000A DKP record already exists for:|r " .. existingName)
			return
		end
    end

    local d = EnsurePlayer(name)

-- Try UnitClass first (party/raid/target)
local _, class = UnitClass(name)

-- If not found, fall back to guild roster
if not class and IsInGuild() then
    for i = 1, GetNumGuildMembers() do
        local gName, _, _, _, _, _, _, _, _, _, gClass = GetGuildRosterInfo(i)
        if gName and Ambiguate(gName, "short") == name then
            class = gClass
            break
        end
    end
end

-- Assign if found
if class then
    d.class = class
end

    addInput:SetText("")
	BumpDKPVersion()
    UpdateTable()
	RefreshMLTools()
    Print("Added DKP record for " .. name)
end)
    end

    --------------------------------------------------------------------
    -- SYNC BUTTONS
    --------------------------------------------------------------------
    do
        local requestBtn = CreateFrame("Button", nil, dkpPanel, "UIPanelButtonTemplate")
        requestBtn:SetSize(120, 24)
        requestBtn:SetText("Request SYNC")
        requestBtn:SetPoint("BOTTOMRIGHT", dkpPanel, "BOTTOMRIGHT", -10, 10)
requestBtn:SetScript("OnClick", function()
    -- Editors get a confirmation popup
    if IsEditor(UnitName("player")) then
        StaticPopupDialogs["REDGUILD_REQUEST_SYNC_EDITOR_CONFIRM"] = {
            text = "Sync from another editor?",
            button1 = "Yes",
            button2 = "No",
            OnAccept = function()
                ------------------------------------------------------------
                -- ORIGINAL SYNC REQUEST CODE (unchanged)
                ------------------------------------------------------------
                EnsureSaved()

                local meReal = Ambiguate(UnitName("player"), "short")
                if not meReal or meReal == "" then
                    Print("Unable to determine your character name for sync.")
                    return
                end

                if RedGuild_SyncLocked then
                    Print("Sync is currently locked. Please wait a few seconds and try again.")
                    return
                end

                if not IsInGuild() then
                    Print("Guild roster not ready — cannot request sync yet.")
                    return
                end

                local num = GetNumGuildMembers()
                if num == 0 then
                    Print("Guild roster not ready — cannot request sync yet.")
                    return
                end

                local bestEditor = GetPreferredEditor()
                if not bestEditor then
                    Print("No editor online — cannot request sync.")
                    return
                end

                RedGuild_Send("REQUEST", meReal .. "|" .. tostring(RedGuild_Config.dkpVersion or 0), bestEditor)
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
        }

        StaticPopup_Show("REDGUILD_REQUEST_SYNC_EDITOR_CONFIRM")
        return
    end

    ------------------------------------------------------------
    -- NON‑EDITORS: run original code immediately
    ------------------------------------------------------------
    EnsureSaved()

    local meReal = Ambiguate(UnitName("player"), "short")
    if not meReal or meReal == "" then
        Print("Unable to determine your character name for sync.")
        return
    end

    if RedGuild_SyncLocked then
        Print("Sync is currently locked. Please wait a few seconds and try again.")
        return
    end

    if not IsInGuild() then
        Print("Guild roster not ready — cannot request sync yet.")
        return
    end

    local num = GetNumGuildMembers()
    if num == 0 then
        Print("Guild roster not ready — cannot request sync yet.")
        return
    end

    local bestEditor = GetPreferredEditor()
    if not bestEditor then
        Print("No editor online — cannot request sync.")
        return
    end

    RedGuild_Send("REQUEST", meReal .. "|" .. tostring(RedGuild_Config.dkpVersion or 0), bestEditor)
end)

        local forceBtn = CreateFrame("Button", nil, dkpPanel, "UIPanelButtonTemplate")
        forceBtn:SetSize(120, 24)
        forceBtn:SetText("FORCE Sync")
        forceBtn:SetPoint("RIGHT", requestBtn, "LEFT", -10, 0)

        if not IsEditor(UnitName("player")) then
            forceBtn:Hide()
        end

        forceBtn:SetScript("OnClick", function()
            if not IsAuthorized() then return end
		    if RedGuild_Config.hideMeFromSync then
				StaticPopup_Show("REDGUILD_FORCE_SYNC_BLOCKED")
				return
			end
			
            StaticPopup_Show("REDGUILD_FORCE_SYNC_CONFIRM")
        end)
    end

end
