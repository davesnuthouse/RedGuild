function CreateMLTab()
--------------------------------------------------------------------
-- ML SCORECARD PANEL
--------------------------------------------------------------------
mlShowGroupOnly = false
do
    ----------------------------------------------------------------
    -- COLUMN HEADERS
    ----------------------------------------------------------------
    local headerFrame = CreateFrame("Frame", nil, mlPanel)
    headerFrame:SetPoint("TOPLEFT", mlPanel, "TOPLEFT", 60, -40)
    headerFrame:SetSize(600, 20)

local headers = {
    { text = "Name",      width = 140 },
    { text = "Main (MS)", width = 150  },
    { text = "Main (OS)", width = 150  },
    { text = "Notes",     width = 200 },
}

    local x = 0
    for _, h in ipairs(headers) do
        local fs = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("LEFT", headerFrame, "LEFT", x, 0)
        fs:SetWidth(h.width)
        fs:SetJustifyH("LEFT")
        fs:SetText(h.text)
        x = x + h.width + 5
    end

    ----------------------------------------------------------------
    -- SCROLLING TABLE
    ----------------------------------------------------------------
    local scroll = CreateFrame("ScrollFrame", nil, mlPanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", mlPanel, "TOPLEFT", 60, -60)
    scroll:SetPoint("BOTTOMRIGHT", mlPanel, "BOTTOMRIGHT", -45, 40)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
	
	------------------------------------------------------------
	-- FIX: Prevent ScrollFrame from blocking window dragging
	------------------------------------------------------------
	scroll:EnableMouse(false)
	content:EnableMouse(false)

	-- Disable mouse on scrollbar + buttons if they exist
	local sb = scroll.ScrollBar
	if sb then
		sb:EnableMouse(false)
		if sb.ScrollUpButton then sb.ScrollUpButton:EnableMouse(false) end
		if sb.ScrollDownButton then sb.ScrollDownButton:EnableMouse(false) end
	end

	-- Some UIPanelScrollFrameTemplates include a background texture
	if scroll.Background then
		scroll.Background:EnableMouse(false)
	end

local COL_NAME     = 1
local COL_MAIN_MS  = 2
local COL_MAIN_OS  = 3
local COL_NOTES    = 4

local ROW_HEIGHT = 18
mlRows = {}

----------------------------------------------------------------
-- INLINE EDIT FOR NOTES
----------------------------------------------------------------
inlineEditML = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
inlineEditML:SetAutoFocus(false)
inlineEditML:SetSize(200, 18)
inlineEditML:Hide()
inlineEditML.cancelled = false
inlineEditML:SetFrameStrata("HIGH")

inlineEditML:SetScript("OnEscapePressed", function(self)
    self.cancelled = true
    self:Hide()
end)

inlineEditML:SetScript("OnEnterPressed", function(self)
    self.cancelled = false
    if self.saveFunc then self.saveFunc(self:GetText()) end
    self:Hide()
end)

inlineEditML:SetScript("OnEditFocusLost", function(self)
    -- Do NOT save again if Enter already handled it
    if not self.cancelled and self.saveFunc and self:IsVisible() then
        self.saveFunc(self:GetText())
    end
    self:Hide()
end)

inlineEditML:SetScript("OnHide", function(self)
    if self.currentFS then
        self.currentFS:Show()
        self.currentFS = nil
    end
end)

function CreateMLRow(i)
    local row = CreateFrame("Frame", nil, content)
    row:SetSize(1, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

    row.cols = {}

local widths = {
    [COL_NAME]     = 140,
    [COL_MAIN_MS]  = 150,
    [COL_MAIN_OS]  = 150,
    [COL_NOTES]    = 200,
}

    local x = 0
    for col = COL_NAME, COL_NOTES do
        if col == COL_NAME then
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", row, "LEFT", x, 0)
            fs:SetWidth(widths[col])
            fs:SetJustifyH("LEFT")
            row.cols[col] = fs

        elseif col == COL_MAIN_MS or col == COL_MAIN_OS then
            local btn = CreateFrame("Button", nil, row)
            btn:SetPoint("LEFT", row, "LEFT", x, 0)
            btn:SetSize(widths[col], ROW_HEIGHT)

            local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:ClearAllPoints()
			fs:SetPoint("LEFT", btn, "LEFT", 2, 0)
			fs:SetWidth(widths[col] - 4)
			fs:SetJustifyH("LEFT")
			btn:SetFontString(fs)

            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
			local hl = btn:GetHighlightTexture()
			hl:ClearAllPoints()
			hl:SetPoint("LEFT", btn, "LEFT", 0, 0)
			hl:SetPoint("RIGHT", btn, "LEFT", widths[col], 0)
			hl:SetAlpha(0.3)

            row.cols[col] = btn

        elseif col == COL_NOTES then
            local btn = CreateFrame("Button", nil, row)
            btn:SetPoint("LEFT", row, "LEFT", x, 0)
            btn:SetSize(widths[col], ROW_HEIGHT)

            local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:ClearAllPoints()
			fs:SetPoint("LEFT", btn, "LEFT", 2, 0)
			fs:SetWidth(widths[col] - 4)
			fs:SetJustifyH("LEFT")
			btn:SetFontString(fs)

            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
			local hl = btn:GetHighlightTexture()
			hl:ClearAllPoints()
			hl:SetPoint("LEFT", btn, "LEFT", 0, 0)
			hl:SetPoint("RIGHT", btn, "LEFT", widths[col], 0)
			hl:SetAlpha(0.3)

            row.cols[col] = btn
        end

        x = x + widths[col] + 5
    end

    return row
end

    ----------------------------------------------------------------
    -- REFRESH FUNCTION
    ----------------------------------------------------------------

local function CommitInlineML()
    if not inlineEditML then return end
    if not inlineEditML:IsShown() then return end
    if inlineEditML.cancelled then return end
    if not inlineEditML.saveFunc then return end

    local text = inlineEditML:GetText() or ""
    inlineEditML.saveFunc(text)
    inlineEditML:Hide()
end

function RefreshMLTools()
    if not mlRows then return end
	
	-- Ensure ML data exists for all DKP players
	for name in pairs(RedGuild_Data or {}) do
		EnsureML(name)
	end

    ----------------------------------------------------------------
    -- BUILD SORTED LIST OF ML NAMES
    ----------------------------------------------------------------
local CLASS_COLORS = {}
for class, c in pairs(RAID_CLASS_COLORS) do
    CLASS_COLORS[class] = string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end

local names = {}
for name in pairs(RedGuild_ML or {}) do
    if type(name) == "string" then
        table.insert(names, name)
    end
end

table.sort(names)

local filtered = {}
for _, name in ipairs(names) do
    if IsNameInGuild(name) then

        -- class colour
        local class = RedGuild_Data[name] and RedGuild_Data[name].class
        local colour = CLASS_COLORS[class] or "|cffaaaaaa"

                -- main/alt tag (white)
        local tag = ""
        if IsMain(name) then
            tag = " |cffffffff(main)|r"
        elseif IsAlt(name) then
            tag = " |cffffffff(alt)|r"
		else
			tag = " |cffffffff(unknown)|r"
        end

        -- final display string (FLAT STRING)
        local display = colour .. name .. "|r" .. tag

        table.insert(filtered, display)
    end
end

	names = filtered

----------------------------------------------------------------
-- GROUP FILTER
----------------------------------------------------------------
if mlShowGroupOnly then
    local filtered = {}

    for _, name in ipairs(names) do
        local inGroup = false

        if IsInRaid() then
            for i = 1, GetNumGroupMembers() do
                local rName = UnitName("raid"..i)
                if rName and Ambiguate(rName, "short") == name then
                    inGroup = true
                    break
                end
            end

        elseif IsInGroup() then
            for i = 1, GetNumSubgroupMembers() do
                local pName = UnitName("party"..i)
                if pName and Ambiguate(pName, "short") == name then
                    inGroup = true
                    break
                end
            end

            -- include yourself
            if Ambiguate(UnitName("player"), "short") == name then
                inGroup = true
            end

        else
            -- solo: only show yourself
            if Ambiguate(UnitName("player"), "short") == name then
                inGroup = true
            end
        end

        if inGroup then
            table.insert(filtered, name)
        end
    end

    ----------------------------------------------------------------
    -- 2. ADD missing group/raid members not already in the DKP list
    ----------------------------------------------------------------
    local function addIfMissing(unit)
        local uName = UnitName(unit)
        if uName then
            uName = Ambiguate(uName, "short")
            local found = false

            for _, existing in ipairs(filtered) do
                if existing == uName then
                    found = true
                    break
                end
            end

            if not found then
                table.insert(filtered, uName)
				EnsureML(uName)
            end
        end
    end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            addIfMissing("raid"..i)
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do
            addIfMissing("party"..i)
        end
        addIfMissing("player")
    else
        addIfMissing("player")
    end

    names = filtered
end

    ----------------------------------------------------------------
    -- ENSURE ROW POOL MATCHES DATA SIZE
    ----------------------------------------------------------------
    local needed = #names
    local current = #mlRows

    if needed > current then
        for i = current + 1, needed do
            if CreateMLRow then
                mlRows[i] = CreateMLRow(i)
            end
        end
    end

----------------------------------------------------------------
-- RENDER ROWS (CLEAN, NO FILTERING HERE)
----------------------------------------------------------------
local visibleCount = #names  -- this MUST already be filtered list

for i = 1, visibleCount do
    local name = names[i]
    local d = RedGuild_Data[name]

    local row = mlRows[i]
    if not row then break end

    row.name = name

    local mlData = EnsureML(name)

    ------------------------------------------------------------
    -- COLUMN REFERENCES
    ------------------------------------------------------------
local nameFS = row.cols[COL_NAME]
local mainMSBtn = row.cols[COL_MAIN_MS]
local mainOSBtn = row.cols[COL_MAIN_OS]
local notesBtn  = row.cols[COL_NOTES]

    ------------------------------------------------------------
    -- NAME (CLASS COLOUR)
    ------------------------------------------------------------
    local class = d and d.class
    local color = class and RAID_CLASS_COLORS[class]
    local hex = "|cffffffff"

    if color then
        hex = string.format("|cff%02x%02x%02x",
            color.r * 255,
            color.g * 255,
            color.b * 255
        )
    end

    nameFS:SetText(hex .. name .. "|r")

    ------------------------------------------------------------
    -- VALUES
    ------------------------------------------------------------
mainMSBtn:SetText(tostring(mlData.mlMainMS or 0))
mainOSBtn:SetText(tostring(mlData.mlMainOS or 0))
    notesBtn:SetText(mlData.mlNotes or "")

    ------------------------------------------------------------
    -- CLICK HANDLERS (unchanged logic, just safer name usage)
    ------------------------------------------------------------
local function makeMLHandler(field)
    return function(self, button)
        local thisName = self:GetParent().name
        if not thisName then return end

        local ml = EnsureML(thisName)
        local old = tonumber(ml[field] or 0) or 0

        if button == "LeftButton" then
            ml[field] = old + 1
        elseif button == "RightButton" then
            ml[field] = math.max(0, old - 1)
        end

        RefreshMLTools()
    end
end

mainMSBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mainOSBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

mainMSBtn:SetScript("OnClick", makeMLHandler("mlMainMS"))
mainOSBtn:SetScript("OnClick", makeMLHandler("mlMainOS"))

    ------------------------------------------------------------
    -- NOTES EDIT
    ------------------------------------------------------------
    notesBtn:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end

        CommitInlineML()

        local thisName = self:GetParent().name
        if not thisName then return end

        local ml = EnsureML(thisName)
        local fs = self:GetFontString()
        if not fs then return end

        fs:Hide()

        inlineEditML:ClearAllPoints()
        inlineEditML:SetPoint("LEFT", self, "LEFT", 0, 0)
        inlineEditML:SetWidth(self:GetWidth() - 4)
        inlineEditML:SetText(ml.mlNotes or "")
        inlineEditML:HighlightText()
        C_Timer.After(0, function()
			inlineEditML:SetFocus()
		end)
		inlineEditML:SetCursorPosition(strlen(inlineEditML:GetText()))

        inlineEditML.currentFS = fs
        inlineEditML.cancelled = false

        inlineEditML.saveFunc = function(text)
            ml.mlNotes = text or ""
            fs:SetText(ml.mlNotes)
            fs:Show()
            inlineEditML.currentFS = nil
        end

        inlineEditML:Show()
    end)

    row:Show()
end

----------------------------------------------------------------
-- HIDE UNUSED ROWS
----------------------------------------------------------------
for i = visibleCount + 1, #mlRows do
    local row = mlRows[i]
    if row then
        row.name = nil
        row:Hide()
    end
end
end

    ----------------------------------------------------------------
    -- BOTTOM WARNING
    ----------------------------------------------------------------
    local note = mlPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("BOTTOMLEFT", mlPanel, "BOTTOMLEFT", 20, 10)
    note:SetJustifyH("LEFT")
    note:SetText("|cffaaaaaaBroadcast (to raid) button only works if you are a RL or RA.|r")

    ----------------------------------------------------------------
    -- BROADCAST DKP BUTTON
    ----------------------------------------------------------------
    local broadcastBtn = CreateFrame("Button", nil, mlPanel, "UIPanelButtonTemplate")
    broadcastBtn:SetSize(140, 24)
    broadcastBtn:SetText("Broadcast DKP")
    broadcastBtn:SetPoint("BOTTOMRIGHT", mlPanel, "BOTTOMRIGHT", -10, 10)
    mlPanel.broadcastBtn = broadcastBtn

    broadcastBtn:SetScript("OnClick", function()
        if not IsRaidLeaderOrMasterLooter() then
            print("|cffff0000You must be the Raid leader or Assistant to broadcast DKP (to the raid group).|r")
            return
        end
        StaticPopup_Show("REDGUILD_BROADCAST_DKP")
    end)

----------------------------------------------------------------
-- RESET ML VALUES BUTTON
----------------------------------------------------------------
local resetBtn = CreateFrame("Button", nil, mlPanel, "UIPanelButtonTemplate")
resetBtn:SetSize(100, 24)
resetBtn:SetText("Reset")
resetBtn:SetPoint("RIGHT", mlPanel.broadcastBtn, "LEFT", -10, 0)

resetBtn:SetScript("OnClick", function()
    for name, d in pairs(RedGuild_Data or {}) do
        if d and IsNameInGuild(name) then
            local ml = EnsureML(name)

            local oldMainMS  = tonumber(ml.mlMainMS or 0) or 0
			local oldMainOS   = tonumber(ml.mlMainOS or 0) or 0
            local oldNotes = ml.mlNotes or ""

            if oldMainMS ~= 0 then
                ml.mlMainMS = 0
            end
			
            if oldMainOS ~= 0 then
                ml.mlMainOS = 0
            end

            if oldNotes ~= "" then
                ml.mlNotes = ""
                LogAudit(name, "mlNotes", oldNotes, "")
            end
        end
    end

    RefreshMLTools()
    print("|cff00ff00ML values reset for all players.|r")
end)

----------------------------------------------------------------
-- COUNTDOWN STATE
----------------------------------------------------------------
local mlCountdownPaused = false
local mlCountdownActive = false
local mlCountdownTimer = nil
local mlCountdownIndex = 0

---------------------------------------------------------------
-- COUNTDOWN BUTTON
----------------------------------------------------------------
local countdownBtn = CreateFrame("Button", nil, mlPanel, "UIPanelButtonTemplate")
countdownBtn:SetSize(100, 24)
countdownBtn:SetText("Countdown")

countdownBtn:SetPoint("TOPRIGHT", mlPanel, "TOPRIGHT", -10, -30)

----------------------------------------------------------------
-- PAUSE BUTTON
----------------------------------------------------------------
local pauseBtn = CreateFrame("Button", nil, mlPanel, "UIPanelButtonTemplate")
pauseBtn:SetSize(100, 24)
pauseBtn:SetText("Pause Count")

-- Anchor to the left of Countdown
pauseBtn:SetPoint("RIGHT", countdownBtn, "LEFT", -5, 0)


----------------------------------------------------------------
-- COUNTDOWN LOGIC
----------------------------------------------------------------

countdownBtn:SetScript("OnClick", function()
    if not IsInRaid() then
        print("|cffff0000Countdown can only be used while in a raid.|r")
        return
    end
	
	if mlCountdownActive then
        print("|cffff0000Countdown already running.|r")
        return
    end

    mlCountdownActive = true
    mlCountdownPaused = false
	mlCountdownIndex = 0
    pauseBtn:SetText("Pause")

    local a, c = C_Timer.After, SendChatMessage
	local delay = 1
	
    mlCountdownTimer = C_Timer.NewTicker(1, function()
            
            if mlCountdownPaused then
                return
            end

            local remaining = 5 - mlCountdownIndex
			
            if remaining > 0 then
				SendChatMessage(remaining, "RAID_WARNING")
			else
				SendChatMessage("\\o/ SOLD \\o/", "RAID_WARNING")
            mlCountdownActive = false
            mlCountdownTimer:Cancel()
            mlCountdownTimer = nil
			return
        end

        mlCountdownIndex = mlCountdownIndex + 1
    end, 666) -- 6 ticks: 5,4,3,2,1,SOLD
end)

----------------------------------------------------------------
-- PAUSE LOGIC
----------------------------------------------------------------

pauseBtn:SetScript("OnClick", function()
    if not mlCountdownActive then
        print("|cffff0000No countdown is running.|r")
        return
    end

    mlCountdownPaused = not mlCountdownPaused

    if mlCountdownPaused then
        pauseBtn:SetText("Resume")
        print("|cffffff00Countdown paused.|r")
    else
        pauseBtn:SetText("Pause")
        print("|cff00ff00Countdown resumed.|r")
    end
end)

----------------------------------------------------------------
-- SHOW GROUP/RAID ONLY CHECKBOX
----------------------------------------------------------------
local showGroupChk = CreateFrame("CheckButton", nil, mlPanel, "ChatConfigCheckButtonTemplate")

-- Anchor it directly to the LEFT of the Reset button
showGroupChk:SetPoint("RIGHT", resetBtn, "LEFT", -160, 0)
showGroupChk:SetSize(24, 24)
showGroupChk.tooltip = "Show only players currently in your group or raid."

local chkLabel = mlPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chkLabel:SetPoint("LEFT", showGroupChk, "RIGHT", 2, 0)
chkLabel:SetText("Show group/raid players only")

showGroupChk:SetScript("OnClick", function(self)
    mlShowGroupOnly = self:GetChecked() or false
    RefreshMLTools()
end)

----------------------------------------------------------------
-- PANEL SHOW
----------------------------------------------------------------
mlPanel:SetScript("OnShow", function()
    RefreshMLTools()
end)

----------------------------------------------------------------
-- PANEL HIDE
----------------------------------------------------------------
mlPanel:SetScript("OnHide", function()
    if inlineEditML and inlineEditML:IsShown() then
        inlineEditML.cancelled = true
        inlineEditML:Hide()
    end
end)
end

end
