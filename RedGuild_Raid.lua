function CreateRaidTab()
--------------------------------------------------------------------
-- RL TOOLS PANEL
--------------------------------------------------------------------
RLRows = RLRows or {}
RLSelected = RLSelected or {}
   do
local RLSelectGroupMembers
------------------------------------------------------------
-- RL: SELECT GROUP/RAID MEMBERS CHECKBOX
------------------------------------------------------------
local rlAutoSelectChk = CreateFrame("CheckButton", nil, raidPanel, "ChatConfigCheckButtonTemplate")
rlAutoSelectChk:SetPoint("TOPLEFT", raidPanel, "TOPLEFT", 80, -40)
rlAutoSelectChk:SetSize(18, 18)

local rlAutoSelectLabel = raidPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
rlAutoSelectLabel:SetPoint("LEFT", rlAutoSelectChk, "RIGHT", 4, 0)
rlAutoSelectLabel:SetText("Select group/raid members (10 second refresh)")

rlAutoSelectChk:SetHitRectInsets(4, 4, 4, 4)

rlAutoSelectChk:SetScript("OnClick", function(self)
    if self:GetChecked() then
        -- Turned ON: immediately apply auto-select to current group/raid
        RLSelectGroupMembers()
    else
        -- Turned OFF: ask if we should clear all ticks
        StaticPopup_Show("REDGUILD_CLEAR_RL_TICKS")
    end
end)
	
	----------------------------------------------------------------
-- RL TOOLS: TICKBOX LIST (LEFT HALF)
----------------------------------------------------------------
RLSelected = RLSelected or {}

local rlScroll = CreateFrame("ScrollFrame", nil, raidPanel, "UIPanelScrollFrameTemplate")
rlScroll:SetPoint("TOPLEFT", raidPanel, "TOPLEFT", 50, -60)
rlScroll:SetPoint("BOTTOMLEFT", raidPanel, "BOTTOMLEFT", 30, 30)
rlScroll:SetWidth(raidPanel:GetWidth() * 0.40)

local rlContent = CreateFrame("Frame", nil, rlScroll)
rlContent:SetSize(1, 1)
rlScroll:SetScrollChild(rlContent)

local RL_ROW_HEIGHT = 20
RLRows = {}

------------------------------------------------------------
-- RL: AUTO-SELECT FUNCTION
------------------------------------------------------------
	RLSelectGroupMembers = function()
    if not rlAutoSelectChk:GetChecked() then
        return
    end

    local groupMembers = {}

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name = UnitName("raid"..i)
            if name then
                groupMembers[Ambiguate(name, "short")] = true
            end
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do
            local name = UnitName("party"..i)
            if name then
                groupMembers[Ambiguate(name, "short")] = true
            end
        end
        groupMembers[Ambiguate(UnitName("player"), "short")] = true
    end

    for _, row in ipairs(RLRows) do
        if row:IsShown() and groupMembers[row.name] then
            row.checkbox:SetChecked(true)
            RLSelected[row.name] = true
        end
    end
end

----------------------------------------------------------------
-- RL ROW CREATION
----------------------------------------------------------------
local function CreateRLRow(i)
    local row = CreateFrame("Frame", nil, rlContent)
    row:SetSize(300, RL_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 10, -(i - 1) * RL_ROW_HEIGHT)

    local cb = CreateFrame("CheckButton", nil, row, "ChatConfigCheckButtonTemplate")
    cb:SetPoint("LEFT", 0, 0)
    cb:SetSize(20, 20)
    row.checkbox = cb

    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 5, 0)
    row.nameFS = fs

    cb:SetScript("OnClick", function(self)
        if row.name then
            RLSelected[row.name] = self:GetChecked() or false
        end
    end)

    return row
end

----------------------------------------------------------------
-- RL LIST REFRESH
----------------------------------------------------------------
local function RefreshRLList()
    for _, row in ipairs(RLRows) do
        row:Hide()
    end
    wipe(RLRows)

local names = {}
local nameMap = {}

-- 1. Add all ML entries
for name in pairs(RedGuild_ML or {}) do
    names[#names+1] = name
    nameMap[name] = true
end

-- 2. If group-only mode is active, add group/raid members even if missing from ML
if mlShowGroupOnly then
    local function AddIfMissing(unit)
        local raw = UnitName(unit)
        if raw then
            local short = Ambiguate(raw, "short")
            if not nameMap[short] then
                names[#names+1] = short
                nameMap[short] = true
            end
        end
    end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            AddIfMissing("raid"..i)
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do
            AddIfMissing("party"..i)
        end
        AddIfMissing("player")
    else
        -- solo: include yourself
        AddIfMissing("player")
    end
end

table.sort(names)

    local i = 0
    for _, name in ipairs(names) do
        local d = RedGuild_Data[name]
        if d then
            i = i + 1
            local row = RLRows[i]

            if not row then
                row = CreateRLRow(i)
                RLRows[i] = row
            end

            row.name = name

            local class = d.class
            local c = RAID_CLASS_COLORS[class]
            local hex = "|cffffffff"
            if c then
                hex = string.format("|cff%02x%02x%02x", c.r*255, c.g*255, c.b*255)
            end

            row.nameFS:SetText(hex .. name .. "|r")
            row.checkbox:SetChecked(RLSelected[name] or false)

            row:Show()
        end
    end

    rlContent:SetHeight(i * RL_ROW_HEIGHT)
	RLSelectGroupMembers()
end

------------------------------------------------------------
-- RL: 10-SECOND AUTO-SELECT SCAN
------------------------------------------------------------
local rlTicker = nil

local function StartRLAutoScan()
    if not rlTicker then
        rlTicker = C_Timer.NewTicker(10, function()
            RefreshRLList()
        end)
    end
end

local function StopRLAutoScan()
    if rlTicker then
        rlTicker:Cancel()
        rlTicker = nil
    end
end

----------------------------------------------------------------
-- RL PANEL SHOW/HIDE
----------------------------------------------------------------
raidPanel:SetScript("OnShow", function()
    RefreshRLList()
    StartRLAutoScan()
end)

raidPanel:SetScript("OnHide", function()
    StopRLAutoScan()
end)
	
    local onTimeBtn = CreateFrame("Button", nil, raidPanel, "UIPanelButtonTemplate")
    onTimeBtn:SetSize(200, 30)
    onTimeBtn:SetPoint("TOPRIGHT", raidPanel, "TOPRIGHT", -100, -60)
    onTimeBtn:SetText("Allocate On Time DKP")
onTimeBtn:SetScript("OnClick", function()
    if not IsAuthorized() then
        Print("Only an editor can perform this function.")
        return
    end

    if not RLTools_HasSelections() then
        Print("|cffff0000RedGuild:|r No players selected in RL Tools.")
        return
    end

    local missing = GetMissingDKPGroupMembers()
	if #missing > 0 then
		local list = table.concat(missing, ", ")
		StaticPopup_Show("REDGUILD_MISSING_DKP_WARNING", list, nil, "REDGUILD_ON_TIME_CHECK")
	else
		StaticPopup_Show("REDGUILD_ON_TIME_CHECK")
	end
	end)

    local attendanceBtn = CreateFrame("Button", nil, raidPanel, "UIPanelButtonTemplate")
    attendanceBtn:SetSize(200, 30)
    attendanceBtn:SetPoint("TOP", onTimeBtn, "BOTTOM", 0, -20)
    attendanceBtn:SetText("Allocate Attendance DKP")
	attendanceBtn:SetScript("OnClick", function()
    if not IsAuthorized() then
        Print("Only an editor can perform this function.")
        return
    end

    if not RLTools_HasSelections() then
        Print("|cffff0000RedGuild:|r No players selected in RL Tools.")
        return
    end

	local missing = GetMissingDKPGroupMembers()
	if #missing > 0 then
		local list = table.concat(missing, ", ")
		StaticPopup_Show("REDGUILD_MISSING_DKP_WARNING", list, nil, "REDGUILD_ALLOCATE_ATTENDANCE")
	else
		StaticPopup_Show("REDGUILD_ALLOCATE_ATTENDANCE")
	end
	end)

    local benchBtn = CreateFrame("Button", nil, raidPanel, "UIPanelButtonTemplate")
    benchBtn:SetSize(200, 30)
    benchBtn:SetPoint("TOP", attendanceBtn, "BOTTOM", 0, -20)
    benchBtn:SetText("Allocate Bench")
benchBtn:SetScript("OnClick", function()
    if not IsAuthorized() then
        Print("Only an editor can perform this function.")
        return
    end

    if not RLTools_HasSelections() then
        Print("|cffff0000RedGuild:|r No players selected in RL Tools.")
        return
    end

    StaticPopup_Show("REDGUILD_ALLOCATE_BENCH")
end)

    local newWeekBtn = CreateFrame("Button", nil, raidPanel, "UIPanelButtonTemplate")
    newWeekBtn:SetSize(200, 30)
    newWeekBtn:SetPoint("BOTTOMRIGHT", raidPanel, "BOTTOMRIGHT", -100, 20)
    newWeekBtn:SetText("Start New DKP Session")
    newWeekBtn:SetScript("OnClick", function()
        if not IsAuthorized() then
            Print("Only editors can start a new DKP session.")
            return
        end
        StaticPopup_Show("REDGUILD_NEW_WEEK")
    end)
end

end
