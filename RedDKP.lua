-- RedDKP.lua
-- Simple DKP tracker with editors, raid tools, import/export, and audit log.

RedDKP_Data           = RedDKP_Data           or {}
RedDKP_Config         = RedDKP_Config         or {}
RedDKP_Audit          = RedDKP_Audit          or {}
RedDKP_Usage          = RedDKP_Usage          or {}
RedDKP_ImpExp_Export  = RedDKP_ImpExp_Export  or nil
RedDKP_ImpExp_Import  = RedDKP_ImpExp_Import  or nil

local addonName = ...
local mainFrame
local dkpPanel, raidPanel, editorsPanel, ioPanel, auditPanel

local TAB_DKP     = 1
local TAB_RAID    = 2
local TAB_EDITORS = 3
local TAB_IO      = 4
local TAB_AUDIT   = 5

local activeTab = TAB_DKP

local SORT_COLOR   = "|cff3399ff"
local NORMAL_COLOR = "|cffffffff"

--------------------------------------------------
-- UTILITIES
--------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RedDKP]|r " .. tostring(msg))
end

local function EnsureSaved()
    RedDKP_Config.authorizedEditors = RedDKP_Config.authorizedEditors or {}
end

local function EnsurePlayer(name)
    RedDKP_Data[name] = RedDKP_Data[name] or {
        rotated    = false,
        lastWeek   = 0,
        onTime     = 0,
        attendance = 0,
        bench      = 0,
        spent      = 0,
        balance    = 0,
        class      = nil,
    }
    return RedDKP_Data[name]
end

local function IsAuthorized()
    EnsureSaved()
    local player = UnitName("player")
    return RedDKP_Config.authorizedEditors[player] and true or false
end

local function IsGuildOfficer()
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex == 0 or rankIndex == 1
end

local function RecalculateAllBalances()
    for _, d in pairs(RedDKP_Data) do
        d.balance = (d.lastWeek or 0)
                  + (d.onTime or 0)
                  + (d.attendance or 0)
                  + (d.bench or 0)
                  - (d.spent or 0)
    end
end

local function LogAudit(player, field, oldValue, newValue)
    table.insert(RedDKP_Audit, 1, {
        player = player,
        field  = field,
        old    = oldValue,
        new    = newValue,
        editor = UnitName("player"),
        time   = date("%Y-%m-%d %H:%M:%S"),
    })
end

local function GetGuildLeader()
    if not IsInGuild() then return nil end
    for i = 1, GetNumGuildMembers() do
        local name, _, rankIndex = GetGuildRosterInfo(i)
        if name and rankIndex == 0 then
            return Ambiguate(name, "short")
        end
    end
    return nil
end

local function IsRaidLeaderOrMasterLooter()
    if not IsInRaid() then return false end

    if UnitIsGroupLeader("player") then
        return true
    end

    local method, mlParty, mlRaid = GetLootMethod()
    if method == "master" then
        local mlName
        if mlRaid then
            mlName = GetRaidRosterInfo(mlRaid)
        elseif mlParty then
            mlName = UnitName("party"..mlParty)
        end
        if mlName and mlName == UnitName("player") then
            return true
        end
    end

    return false
end

local function UsedToday(key)
    local player = UnitName("player")
    RedDKP_Usage[player] = RedDKP_Usage[player] or {}
    local last = RedDKP_Usage[player][key]
    local today = date("%Y-%m-%d")
    return last == today
end

local function MarkUsedToday(key)
    local player = UnitName("player")
    RedDKP_Usage[player] = RedDKP_Usage[player] or {}
    RedDKP_Usage[player][key] = date("%Y-%m-%d")
end

--------------------------------------------------
-- MAIN FRAME + TABS
--------------------------------------------------

local function LayoutPanel(panel)
    panel:SetAllPoints(mainFrame)
    panel:SetPoint("TOPLEFT", 10, -40)
    panel:SetPoint("BOTTOMRIGHT", -10, 10)
end

local tabs = {}

local function ShowTab(tab)
    if (tab == TAB_RAID or tab == TAB_IO) and not IsAuthorized() then
        Print("You must be an editor to access this tab.")
        return
    end

    activeTab = tab
    for i, t in ipairs(tabs) do
        if i == tab then
            PanelTemplates_SelectTab(t)
        else
            PanelTemplates_DeselectTab(t)
        end
    end

    dkpPanel:Hide()
    raidPanel:Hide()
    editorsPanel:Hide()
    ioPanel:Hide()
    auditPanel:Hide()

    if tab == TAB_DKP then
        dkpPanel:Show()
    elseif tab == TAB_RAID then
        raidPanel:Show()
    elseif tab == TAB_EDITORS then
        editorsPanel:Show()
    elseif tab == TAB_IO then
        ioPanel:Show()
    elseif tab == TAB_AUDIT then
        auditPanel:Show()
    end
end

local function CreateTab(index, text)
    local tab = CreateFrame("Button", addonName.."Tab"..index, mainFrame, "CharacterFrameTabButtonTemplate")
    tab:SetID(index)
    tab:SetText(text)
    PanelTemplates_TabResize(tab, 0)
    if index == 1 then
        tab:SetPoint("TOPLEFT", mainFrame, "BOTTOMLEFT", 5, 7)
    else
        tab:SetPoint("LEFT", tabs[index-1], "RIGHT", -15, 0)
    end
    tab:SetScript("OnClick", function(self)
        ShowTab(self:GetID())
    end)
    tabs[index] = tab
end

--------------------------------------------------
-- DKP TABLE
--------------------------------------------------

local headers = {
    { text = "Player",    width = 140 },
    { text = "Rotated",   width = 70  },
    { text = "LastWeek",  width = 80  },
    { text = "OnTime",    width = 60  },
    { text = "Attend",    width = 60  },
    { text = "Bench",     width = 60  },
    { text = "Spent",     width = 60  },
    { text = "Balance",   width = 80  },
    { text = "",          width = 60  },
}

local fieldMap = {
    [1] = "player",
    [2] = "rotated",
    [3] = "lastWeek",
    [4] = "onTime",
    [5] = "attendance",
    [6] = "bench",
    [7] = "spent",
    [8] = "balance",
    [9] = "whisper",
}

local rows = {}
local sortedNames = {}
local inlineEdit
local headerButtons = {}
local scroll

local currentSortField = "player"
local currentSortAscending = false

local function UpdateTable()
    wipe(sortedNames)
    for name in pairs(RedDKP_Data) do
        table.insert(sortedNames, name)
    end

    table.sort(sortedNames, function(a, b)
        local da = EnsurePlayer(a)
        local db = EnsurePlayer(b)

        local va = currentSortField == "player" and a or (da[currentSortField] or 0)
        local vb = currentSortField == "player" and b or (db[currentSortField] or 0)

        va = tostring(va)
        vb = tostring(vb)

        if va == vb then
            return a < b
        end

        if currentSortAscending then
            return va < vb
        else
            return va > vb
        end
    end)

    for i, row in ipairs(rows) do
        local name = sortedNames[i]
        if name then
            local d = EnsurePlayer(name)

            d.balance = (d.lastWeek or 0)
                      + (d.onTime or 0)
                      + (d.attendance or 0)
                      + (d.bench or 0)
                      - (d.spent or 0)

            row.index = i
            row:Show()

            local class = d.class
            if class and RAID_CLASS_COLORS[class] then
                local c = RAID_CLASS_COLORS[class]
                local hex = string.format("%02x%02x%02x", c.r*255, c.g*255, c.b*255)
                row.cols[1]:SetText("|cff" .. hex .. name .. "|r")
                row.bg:SetColorTexture(c.r, c.g, c.b, 0.10)
            else
                row.cols[1]:SetText(name)
                row.bg:SetColorTexture(0, 0, 0, 0.15)
            end

            row.cols[2]:SetText(d.rotated and "Yes" or "No")
            row.cols[3]:SetText(d.lastWeek or 0)
            row.cols[4]:SetText(d.onTime or 0)
            row.cols[5]:SetText(d.attendance or 0)
            row.cols[6]:SetText(d.bench or 0)
            row.cols[7]:SetText(d.spent or 0)

            local balance = d.balance or 0
            local lastWeek = d.lastWeek or 0
            local colour
            if balance > lastWeek then
                colour = "|cff00ff00"
            elseif balance < lastWeek then
                colour = "|cffff0000"
            else
                colour = "|cffffffff"
            end
            row.cols[8]:SetText(colour .. balance .. "|r")

            row.cols[9]:Show()
        else
            row.index = nil
            row:Hide()
        end
    end

    if scroll then
        if #sortedNames > 20 then
            scroll:EnableMouseWheel(true)
            if scroll.ScrollBar then scroll.ScrollBar:Show() end
        else
            scroll:SetVerticalScroll(0)
            scroll:EnableMouseWheel(false)
            if scroll.ScrollBar then scroll.ScrollBar:Hide() end
        end
    end
end

--------------------------------------------------
-- AUDIT LOG UI
--------------------------------------------------

local auditRows = {}
local function UpdateAuditLog()
    for i, row in ipairs(auditRows) do
        local entry = RedDKP_Audit[i]
        if entry then
            row.text:SetText(string.format("[%s] %s changed %s's %s from %s to %s",
                entry.time,
                entry.editor,
                entry.player,
                entry.field,
                tostring(entry.old),
                tostring(entry.new)
            ))
            row:Show()
        else
            row:Hide()
        end
    end
end

--------------------------------------------------
-- EDITORS PANEL (data helpers)
--------------------------------------------------

local editorRows = {}

local function RefreshEditorList()
    EnsureSaved()

    local guildLeader = GetGuildLeader()
    local fallback = UnitName("player")

    if guildLeader then
        RedDKP_Config.authorizedEditors[guildLeader] = true
    else
        RedDKP_Config.authorizedEditors[fallback] = true
    end

    local names = {}
    for name in pairs(RedDKP_Config.authorizedEditors) do
        table.insert(names, name)
    end
    table.sort(names)

    for i = 1, #editorRows do
        local row = editorRows[i]
        local name = names[i]

        if name then
            row.name = name

            local isProtected =
                (guildLeader and name == guildLeader) or
                (not guildLeader and name == fallback)

            if isProtected then
                row.text:SetText("|cff00aaff" .. name .. "|r")
                row.isProtected = true
            else
                row.text:SetText(name)
                row.isProtected = false
            end

            row:Show()
        else
            row.name = nil
            row.text:SetText("")
            row.isProtected = false
            row:Hide()
        end
    end
end

--------------------------------------------------
-- MINIMAP BUTTON
--------------------------------------------------

local function CreateFallbackMinimapButton()
    local btn = CreateFrame("Button", "RedDKP_MinimapButton", Minimap)
    btn:SetSize(32, 32)
    btn:SetFrameStrata("MEDIUM")

    --------------------------------------------------
    -- SAVED POSITION (ANGLE AROUND MINIMAP)
    --------------------------------------------------
    RedDKP_Config.minimapAngle = RedDKP_Config.minimapAngle or 45

    --------------------------------------------------
    -- ICON
    --------------------------------------------------
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icon:SetAllPoints(btn)
    icon:SetMask("Interface\\Minimap\\UI-Minimap-Background")

    --------------------------------------------------
    -- BORDER (correct size for 32x32 icon)
    --------------------------------------------------
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("CENTER", btn, "CENTER", 11, -12)

    --------------------------------------------------
    -- HIGHLIGHT
    --------------------------------------------------
    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints(btn)

    --------------------------------------------------
    -- POSITIONING AROUND MINIMAP
    --------------------------------------------------
    local function UpdateButtonPosition()
        local angle = math.rad(RedDKP_Config.minimapAngle)
        local radius = 80  -- good default for Anniversary minimap

        local x = math.cos(angle) * radius
        local y = math.sin(angle) * radius

        btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    --------------------------------------------------
    -- DRAGGING (circular movement)
    --------------------------------------------------
    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()

            px = px / scale
            py = py / scale

            local angle = math.deg(math.atan2(py - my, px - mx))
            RedDKP_Config.minimapAngle = angle

            UpdateButtonPosition()
        end)
    end)

    btn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    btn:RegisterForDrag("LeftButton")

    --------------------------------------------------
    -- CLICK ACTIONS
    --------------------------------------------------
    btn:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            if mainFrame:IsShown() then
                mainFrame:Hide()
            else
                mainFrame:Show()
                ShowTab(TAB_DKP)
            end
        elseif button == "RightButton" then
            mainFrame:Show()
            ShowTab(TAB_EDITORS)
        end
    end)

    --------------------------------------------------
    -- INITIAL POSITION
    --------------------------------------------------
    UpdateButtonPosition()
end

--------------------------------------------------
-- POPUPS
--------------------------------------------------

StaticPopupDialogs["REDDKP_DELETE_PLAYER"] = {
    text = "Delete DKP record for %s?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, player)
        local d = RedDKP_Data[player]
        if d then
            for field, oldValue in pairs(d) do
                LogAudit(player, field, tostring(oldValue), "REMOVED")
            end
        end
        RedDKP_Data[player] = nil
        UpdateTable()
        Print("Deleted DKP record for " .. player)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDDKP_ON_TIME_CHECK"] = {
    text = "Allocate On Time DKP to all raid members currently in the raid group.",
    button1 = "Confirm",
    button2 = "Cancel",
    OnAccept = function()
        for i = 1, GetNumGroupMembers() do
            local name = GetRaidRosterInfo(i)
            if name and RedDKP_Data[name] then
                local d = EnsurePlayer(name)
                local old = d.onTime or 0
                d.onTime = old + 5
                d.balance = (d.lastWeek or 0)
                          + (d.onTime or 0)
                          + (d.attendance or 0)
                          + (d.bench or 0)
                          - (d.spent or 0)
                LogAudit(name, "onTime", old, d.onTime)
            end
        end
        UpdateTable()
        Print("On Time DKP awarded to raid members.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDDKP_ALLOCATE_ATTENDANCE"] = {
    text = "Award 15 Attendance DKP to all raid members?",
    button1 = "Award",
    button2 = "Cancel",
    OnAccept = function()
        for i = 1, GetNumGroupMembers() do
            local name = GetRaidRosterInfo(i)
            if name and RedDKP_Data[name] then
                local d = EnsurePlayer(name)
                local old = d.attendance or 0
                d.attendance = old + 15
                d.balance = (d.lastWeek or 0)
                          + (d.onTime or 0)
                          + (d.attendance or 0)
                          + (d.bench or 0)
                          - (d.spent or 0)
                LogAudit(name, "attendance", old, d.attendance)
            end
        end
        UpdateTable()
        Print("Attendance DKP awarded to raid members.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDDKP_RECALC_BALANCES"] = {
    text = "Recalculate ALL balances?\nThis cannot be undone.",
    button1 = "Recalculate",
    button2 = "Cancel",
    OnAccept = function()
        RecalculateAllBalances()
        UpdateTable()
        Print("All balances recalculated.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDDKP_BROADCAST_DKP"] = {
    text = "Broadcast the entire DKP table to the raid?\nThis may be spammy.",
    button1 = "Broadcast",
    button2 = "Cancel",
    OnAccept = function()
        if not IsInRaid() then
            Print("You must be in a raid to broadcast DKP.")
            return
        end

        SendChatMessage("Name       Bal  LW  OT  AT  Bench  Spent", "RAID")
        local names = {}
        for name in pairs(RedDKP_Data) do
            table.insert(names, name)
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local d = EnsurePlayer(name)
            local msg = string.format(
                "%-10s %4d %3d %3d %3d %5d %6d",
                name,
                d.balance or 0,
                d.lastWeek or 0,
                d.onTime or 0,
                d.attendance or 0,
                d.bench or 0,
                d.spent or 0
            )
            SendChatMessage(msg, "RAID")
        end
        Print("DKP table broadcast to raid.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDDKP_NEW_WEEK"] = {
    text = "Start a new DKP week?\nThis will move all balances to Last Week and reset OnTime, Attendance, Bench, and Spent.",
    button1 = "Start Week",
    button2 = "Cancel",
    OnAccept = function()
        for name, d in pairs(RedDKP_Data) do
            local oldBalance = d.balance or 0

            d.lastWeek   = oldBalance
            d.onTime     = 0
            d.attendance = 0
            d.bench      = 0
            d.spent      = 0

            d.balance = oldBalance

            LogAudit(name, "newWeek", "previous balance: "..oldBalance, "week reset")
        end

        UpdateTable()
        Print("A new DKP week has begun.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

--------------------------------------------------
-- INITIALIZE UI
--------------------------------------------------

local function CreateUI()
    mainFrame = CreateFrame("Frame", "RedDKPFrame", UIParent, "BasicFrameTemplateWithInset")
    mainFrame:SetSize(800, 500)
    mainFrame:SetPoint("CENTER")
    mainFrame:Hide()
    mainFrame.title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    mainFrame.title:SetPoint("CENTER", mainFrame.TitleBg, "CENTER", 0, 0)
    mainFrame.title:SetText("RedDKP - brought to you by a clueless idiot called Lunátic")

    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)
    table.insert(UISpecialFrames, "RedDKPFrame")

    CreateTab(TAB_DKP,     "DKP")
    CreateTab(TAB_RAID,    "RL Tools")
    CreateTab(TAB_EDITORS, "Editors")
    CreateTab(TAB_IO,      "Import / Export")
    CreateTab(TAB_AUDIT,   "Audit Log")

    dkpPanel     = CreateFrame("Frame", nil, mainFrame); LayoutPanel(dkpPanel)
    raidPanel    = CreateFrame("Frame", nil, mainFrame); LayoutPanel(raidPanel)
    editorsPanel = CreateFrame("Frame", nil, mainFrame); LayoutPanel(editorsPanel)
    ioPanel      = CreateFrame("Frame", nil, mainFrame); LayoutPanel(ioPanel)
    auditPanel   = CreateFrame("Frame", nil, mainFrame); LayoutPanel(auditPanel)

    local function UpdateTabVisibility()
        local isEditor = IsAuthorized()
        if not isEditor then
            if tabs[TAB_RAID] then tabs[TAB_RAID]:Hide() end
            if tabs[TAB_IO]   then tabs[TAB_IO]:Hide()   end
        else
            if tabs[TAB_RAID] then tabs[TAB_RAID]:Show() end
            if tabs[TAB_IO]   then tabs[TAB_IO]:Show()   end
        end
    end
    UpdateTabVisibility()

    --------------------------------------------------
    -- DKP PANEL: HEADERS
    --------------------------------------------------

    local headerY = -10
    local x = 40
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
            if not field or field == "whisper" then return end

            if currentSortField == field then
                currentSortAscending = not currentSortAscending
            else
                currentSortField = field
                currentSortAscending = false
            end

            for j, hh in ipairs(headers) do
                local btn = headerButtons[j]
                if j == i then
                    btn.text:SetText(SORT_COLOR .. hh.text .. "|r")
                else
                    btn.text:SetText(NORMAL_COLOR .. hh.text .. "|r")
                end
            end

            UpdateTable()
        end)

        headerButtons[i] = headerBtn
        x = x + h.width + 5
    end

    if headerButtons[1] then
        headerButtons[1].text:SetText(SORT_COLOR .. headers[1].text .. "|r")
    end

    --------------------------------------------------
    -- DKP PANEL: SCROLLABLE ROWS
    --------------------------------------------------

    scroll = CreateFrame("ScrollFrame", nil, dkpPanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", dkpPanel, "TOPLEFT", 10, headerY - 20)
    scroll:SetPoint("BOTTOMRIGHT", dkpPanel, "BOTTOMRIGHT", -30, 50)

    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(1, 1)
    scroll:SetScrollChild(scrollChild)

    local MAX_ROWS = 100
    local ROW_HEIGHT = 18

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, scrollChild)
        row:SetSize(1, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i-1)*ROW_HEIGHT)

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.15)
        row.bg = bg

        local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        delBtn:SetSize(18, 18)
        delBtn:SetPoint("LEFT", row, "LEFT", 2, 0)
        delBtn:SetText("X")
        row.deleteButton = delBtn

        row.cols = {}
        local colX = 30
        for j, h in ipairs(headers) do
            if j < #headers then
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetPoint("LEFT", row, "LEFT", colX, 0)
                fs:SetWidth(h.width)
                fs:SetJustifyH("LEFT")
                row.cols[j] = fs
            else
                local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                btn:SetPoint("LEFT", row, "LEFT", colX + 5, 0)
                btn:SetSize(h.width - 10, 16)
                btn:SetText("Tell")
                row.cols[j] = btn
            end
            colX = colX + h.width + 5
        end

        rows[i] = row
    end

    scrollChild:SetHeight(MAX_ROWS * ROW_HEIGHT)

    inlineEdit = CreateFrame("EditBox", nil, dkpPanel, "InputBoxTemplate")
    inlineEdit:SetAutoFocus(true)
    inlineEdit:SetSize(80, 18)
    inlineEdit:Hide()
    inlineEdit:SetScript("OnEscapePressed", function(self) self:Hide() end)
    inlineEdit:SetScript("OnEnterPressed", function(self)
        if self.saveFunc then self.saveFunc(self:GetText()) end
        self:Hide()
    end)
    inlineEdit:SetScript("OnShow", function(self)
        self:ClearFocus()
        C_Timer.After(0, function()
            if self:IsShown() then self:SetFocus() end
        end)
    end)

    for _, row in ipairs(rows) do
        local delBtn = row.deleteButton
        delBtn:SetScript("OnClick", function()
            if not IsAuthorized() then
                Print("Only editors can delete DKP records.")
                return
            end
            local player = sortedNames[row.index]
            if not player then return end
            StaticPopup_Show("REDDKP_DELETE_PLAYER", player, nil, player)
        end)

        for j, col in ipairs(row.cols) do
            if j < #headers then
                local fs = col
                fs:EnableMouse(true)
                fs:SetScript("OnMouseDown", function(self, button)
                    if button ~= "LeftButton" then return end
                    if not IsAuthorized() then return end

                    inlineEdit:Hide()

                    local rowIndex = row.index
                    local colIndex = j
                    local player   = sortedNames[rowIndex]
                    local field    = fieldMap[colIndex]
                    if not player or not field then return end

                    local d = EnsurePlayer(player)

                    if field == "rotated" then
                        local old = d.rotated
                        d.rotated = not d.rotated
                        LogAudit(player, "rotated", tostring(old), tostring(d.rotated))
                        UpdateTable()
                        return
                    end

                    if field ~= "lastWeek" and field ~= "onTime" and field ~= "attendance"
                       and field ~= "bench" and field ~= "spent" then
                        return
                    end

                    inlineEdit:ClearAllPoints()
                    inlineEdit:SetPoint("LEFT", self, "LEFT", 0, 0)
                    inlineEdit:SetWidth(headers[colIndex].width - 4)
                    inlineEdit:SetText(tostring(d[field] or 0))
                    inlineEdit:HighlightText()

                    inlineEdit.saveFunc = function(newValue)
                        local num = tonumber(newValue)
                        if not num then return end
                        local old = d[field]
                        d[field] = num
                        d.balance = (d.lastWeek or 0)
                                  + (d.onTime or 0)
                                  + (d.attendance or 0)
                                  + (d.bench or 0)
                                  - (d.spent or 0)
                        LogAudit(player, field, old, num)
                        UpdateTable()
                    end

                    inlineEdit:Show()
                end)
            else
                local whisperBtn = col
                whisperBtn:SetScript("OnClick", function()
                    local index = row.index
                    if not index then return end
                    local player = sortedNames[index]
                    if not player then return end
                    local d = RedDKP_Data[player]
                    if not d then return end
                    local msg = string.format(
                        "Your DKP: LastWeek=%d, OnTime=%d, Attendance=%d, Bench=%d, Spent=%d, Balance=%d",
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
            end
        end
    end

    --------------------------------------------------
    -- DKP PANEL: ADD NEW RECORD
    --------------------------------------------------

    local addInput = CreateFrame("EditBox", nil, dkpPanel, "InputBoxTemplate")
    addInput:SetSize(140, 20)
    addInput:SetPoint("BOTTOMLEFT", dkpPanel, "BOTTOMLEFT", 10, 10)
    addInput:SetAutoFocus(false)

    local addButton = CreateFrame("Button", nil, dkpPanel, "UIPanelButtonTemplate")
    addButton:SetSize(100, 22)
    addButton:SetPoint("LEFT", addInput, "RIGHT", 10, 0)
    addButton:SetText("Add")
    addButton:SetScript("OnClick", function()
        if not IsAuthorized() then
            Print("Only editors can add DKP records.")
            return
        end
        local name = addInput:GetText():gsub("%s+", "")
        if name == "" then return end
        local d = EnsurePlayer(name)

        local _, class = UnitClass(name)
        if class then
            d.class = class
        elseif IsInGuild() then
            for i = 1, GetNumGuildMembers() do
                local gName, _, _, _, _, _, _, _, _, _, gClass = GetGuildRosterInfo(i)
                if gName and Ambiguate(gName, "short") == name then
                    d.class = gClass
                    break
                end
            end
        end

        addInput:SetText("")
        UpdateTable()
        Print("Added DKP record for " .. name)
    end)

    --------------------------------------------------
    -- DKP PANEL: SYNC + RECALCULATE BALANCES BUTTONS
    --------------------------------------------------

    local recalcBtn = CreateFrame("Button", nil, dkpPanel, "UIPanelButtonTemplate")
    recalcBtn:SetSize(160, 24)
    recalcBtn:SetText("Recalculate Balances")
    recalcBtn:SetPoint("BOTTOMRIGHT", dkpPanel, "BOTTOMRIGHT", -10, 10)
    recalcBtn:SetScript("OnClick", function()
        if not IsAuthorized() then
            Print("Only editors can recalculate balances.")
            return
        end
        StaticPopup_Show("REDDKP_RECALC_BALANCES")
    end)

    local syncBtn = CreateFrame("Button", nil, dkpPanel, "UIPanelButtonTemplate")
    syncBtn:SetSize(100, 24)
    syncBtn:SetText("Sync")
    syncBtn:SetPoint("RIGHT", recalcBtn, "LEFT", -10, 0)
    syncBtn:SetScript("OnClick", function()
        Print("feature to be added")
    end)

    --------------------------------------------------
    -- RAID LEADER TOOLS PANEL
    --------------------------------------------------

    local onTimeBtn = CreateFrame("Button", nil, raidPanel, "UIPanelButtonTemplate")
    onTimeBtn:SetSize(200, 30)
    onTimeBtn:SetPoint("TOP", raidPanel, "TOP", 0, -40)
    onTimeBtn:SetText("Allocate On Time DKP")
    onTimeBtn:SetScript("OnClick", function()
        if not IsRaidLeaderOrMasterLooter() then
            Print("Only the raid leader or master looter can perform this function.")
            return
        end
        if UsedToday("onTime") then
            Print("Ignored duplicate allocation. You may need to manually edit DKP if this was a mistake.")
            return
        end
        StaticPopup_Show("REDDKP_ON_TIME_CHECK")
        MarkUsedToday("onTime")
    end)

    local attendanceBtn = CreateFrame("Button", nil, raidPanel, "UIPanelButtonTemplate")
    attendanceBtn:SetSize(200, 30)
    attendanceBtn:SetPoint("TOP", onTimeBtn, "BOTTOM", 0, -20)
    attendanceBtn:SetText("Allocate Attendance DKP")
    attendanceBtn:SetScript("OnClick", function()
        if not IsRaidLeaderOrMasterLooter() then
            Print("Only the raid leader or master looter can perform this function.")
            return
        end
        if UsedToday("attendance") then
            Print("Ignored duplicate allocation. You may need to manually edit DKP if this was a mistake.")
            return
        end
        StaticPopup_Show("REDDKP_ALLOCATE_ATTENDANCE")
        MarkUsedToday("attendance")
    end)

    local newWeekBtn = CreateFrame("Button", nil, raidPanel, "UIPanelButtonTemplate")
    newWeekBtn:SetSize(200, 30)
    newWeekBtn:SetPoint("TOP", attendanceBtn, "BOTTOM", 0, -20)
    newWeekBtn:SetText("Start a New DKP Week")
    newWeekBtn:SetScript("OnClick", function()
        if not IsAuthorized() then
            Print("Only editors can start a new DKP week.")
            return
        end
        StaticPopup_Show("REDDKP_NEW_WEEK")
    end)

    local broadcastBtn = CreateFrame("Button", nil, raidPanel, "UIPanelButtonTemplate")
    broadcastBtn:SetSize(220, 30)
    broadcastBtn:SetPoint("BOTTOM", raidPanel, "BOTTOM", 0, 10)
    broadcastBtn:SetText("Broadcast DKP Table to Raid")
    broadcastBtn:SetScript("OnClick", function()
        if not IsAuthorized() then
            Print("Only editors can broadcast DKP.")
            return
        end
        StaticPopup_Show("REDDKP_BROADCAST_DKP")
    end)

    --------------------------------------------------
    -- EDITORS PANEL UI
    --------------------------------------------------

    local title = editorsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("Editors")

    local editorScroll = CreateFrame("ScrollFrame", nil, editorsPanel, "UIPanelScrollFrameTemplate")
    editorScroll:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    editorScroll:SetPoint("BOTTOMLEFT", editorsPanel, "BOTTOMLEFT", 0, 30)
    editorScroll:SetWidth(200)

    local editorContent = CreateFrame("Frame", nil, editorScroll)
    editorContent:SetWidth(200)
    editorScroll:SetScrollChild(editorContent)

    local EDITOR_ROW_HEIGHT = 18
    local MAX_EDITOR_ROWS = 20

    for i = 1, MAX_EDITOR_ROWS do
        local row = CreateFrame("Button", nil, editorContent)
        row:SetSize(200, EDITOR_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i-1)*EDITOR_ROW_HEIGHT)

        local hl = row:CreateTexture(nil, "BACKGROUND")
        hl:SetAllPoints()
        hl:SetColorTexture(0.2, 0.4, 1, 0.3)
        hl:Hide()
        row.highlight = hl

        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", 2, 0)
        fs:SetJustifyH("LEFT")
        row.text = fs

        row:SetScript("OnClick", function()
            editorsPanel.selectedEditor = row.name
            for _, r in ipairs(editorRows) do
                if r.highlight then r.highlight:Hide() end
            end
            if row.name then
                row.highlight:Show()
            end
        end)

        editorRows[i] = row
    end

    editorContent:SetHeight(MAX_EDITOR_ROWS * EDITOR_ROW_HEIGHT)

    local addBox = CreateFrame("EditBox", nil, editorsPanel, "InputBoxTemplate")
    addBox:SetSize(140, 20)
    addBox:SetPoint("TOPLEFT", editorScroll, "TOPRIGHT", 90, 0)
    addBox:SetAutoFocus(false)

    local addBtn = CreateFrame("Button", nil, editorsPanel, "UIPanelButtonTemplate")
    addBtn:SetSize(80, 22)
    addBtn:SetText("Add")

    local removeBtn = CreateFrame("Button", nil, editorsPanel, "UIPanelButtonTemplate")
    removeBtn:SetSize(80, 22)
    removeBtn:SetText("Remove")

    addBtn:ClearAllPoints()
    addBtn:SetPoint("LEFT", addBox, "RIGHT", 10, 0)

    removeBtn:ClearAllPoints()
    removeBtn:SetPoint("TOPLEFT", addBtn, "BOTTOMLEFT", 0, -8)

    local removeNote = editorsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    removeNote:SetPoint("TOPLEFT", removeBtn, "BOTTOMLEFT", 0, -4)
    removeNote:SetText("|cffaaaaaa* select name from list and click to remove|r")

    editorsPanel.selectedEditor = nil

    addBtn:SetScript("OnClick", function()
        if not IsGuildOfficer() then
            Print("Only guild officers can modify the editor list.")
            return
        end
        local name = addBox:GetText():gsub("%s+", "")
        if name == "" then return end
        EnsureSaved()
        RedDKP_Config.authorizedEditors[name] = true
        addBox:SetText("")
        RefreshEditorList()
    end)

    removeBtn:SetScript("OnClick", function()
        if not IsGuildOfficer() then
            Print("Only guild officers can modify the editor list.")
            return
        end

        local name = editorsPanel.selectedEditor
        if not name then return end

        local guildLeader = GetGuildLeader()
        local fallback = UnitName("player")

        if (guildLeader and name == guildLeader) or (not guildLeader and name == fallback) then
            Print("You cannot remove the protected editor: " .. name)
            return
        end

        EnsureSaved()
        RedDKP_Config.authorizedEditors[name] = nil
        editorsPanel.selectedEditor = nil
        RefreshEditorList()
    end)

    editorsPanel:SetScript("OnShow", function()
        C_Timer.After(0, RefreshEditorList)
        if not IsGuildOfficer() then
            addBox:Hide()
            addBtn:Hide()
            removeBtn:Hide()
            removeNote:Hide()
        else
            addBox:Show()
            addBtn:Show()
            removeBtn:Show()
            removeNote:Show()
        end
    end)

    local note = editorsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    note:SetPoint("BOTTOMLEFT", editorsPanel, "BOTTOMLEFT", 10, 10)
    note:SetJustifyH("LEFT")
    note:SetText("|cffaaaaaa* Guild leaders are editors by default.|r")

    --------------------------------------------------
    -- IMPORT / EXPORT PANEL (CSV via SavedVariables)
    --------------------------------------------------

    local ioTitle = ioPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ioTitle:SetPoint("TOPLEFT", 10, -10)
    ioTitle:SetText("Import / Export (CSV / LUA hybrid file)")

    local exportCSV = CreateFrame("Button", nil, ioPanel, "UIPanelButtonTemplate")
    exportCSV:SetSize(220, 26)
    exportCSV:SetPoint("TOPLEFT", ioTitle, "BOTTOMLEFT", 0, -20)
    exportCSV:SetText("Export CSV to SavedVariables")

    local importCSV = CreateFrame("Button", nil, ioPanel, "UIPanelButtonTemplate")
    importCSV:SetSize(220, 26)
    importCSV:SetPoint("LEFT", exportCSV, "RIGHT", 20, 0)
    importCSV:SetText("Import CSV from SavedVariables")

    local function BuildCSV()
        local lines = {}
        table.insert(lines, "name,rotated,lastWeek,onTime,attendance,bench,spent,balance,class")

        local names = {}
        for name in pairs(RedDKP_Data) do
            table.insert(names, name)
        end
        table.sort(names)

        for _, name in ipairs(names) do
            local d = EnsurePlayer(name)
            table.insert(lines, string.format(
                "%s,%s,%d,%d,%d,%d,%d,%d,%s",
                name,
                d.rotated and "true" or "false",
                d.lastWeek or 0,
                d.onTime or 0,
                d.attendance or 0,
                d.bench or 0,
                d.spent or 0,
                d.balance or 0,
                d.class or ""
            ))
        end

        return table.concat(lines, "\n")
    end

    exportCSV:SetScript("OnClick", function()
        if not IsAuthorized() then
            Print("Only editors can export DKP data.")
            return
        end
        RedDKP_ImpExp_Export = BuildCSV()
        Print("CSV data exported to LUA file. Log out and open:")
        Print("World of Warcraft/_anniversary_/WTF/Account/<ACCOUNT>/SavedVariables/RedDKP.lua")
    end)

    local function ParseCSVLine(line)
        local fields = {}
        for v in string.gmatch(line, "([^,]+)") do
            table.insert(fields, v)
        end
        return fields
    end

    importCSV:SetScript("OnClick", function()
        if not IsAuthorized() then
            Print("Only editors can import DKP data.")
            return
        end

        local text = RedDKP_ImpExp_Import
        if not text or text == "" then
            Print("No CSV data found in World of Warcraft/_anniversary_/WTF/Account/<ACCOUNT>/SavedVariables/RedDKP.lua")
			Print("Create or Edit LUA file first.")
            return
        end

        local lines = { strsplit("\n", text) }
        if #lines <= 1 then
            Print("CSV appears to be empty or missing data rows.")
            return
        end

        table.remove(lines, 1) -- remove header

        for _, line in ipairs(lines) do
            line = line:gsub("\r", "")
            if line ~= "" then
                local f = ParseCSVLine(line)
                local name = f[1]
                if name and name ~= "" then
                    local d = EnsurePlayer(name)

                    local old = {
                        rotated    = d.rotated,
                        lastWeek   = d.lastWeek,
                        onTime     = d.onTime,
                        attendance = d.attendance,
                        bench      = d.bench,
                        spent      = d.spent,
                        balance    = d.balance,
                        class      = d.class,
                    }

                    d.rotated    = (f[2] == "true" or f[2] == "1")
                    d.lastWeek   = tonumber(f[3]) or d.lastWeek
                    d.onTime     = tonumber(f[4]) or d.onTime
                    d.attendance = tonumber(f[5]) or d.attendance
                    d.bench      = tonumber(f[6]) or d.bench
                    d.spent      = tonumber(f[7]) or d.spent
                    -- f[8] is balance; we will recalc after import
                    d.class      = (f[9] and f[9] ~= "") and f[9] or d.class

                    for k, v in pairs(d) do
                        if old[k] ~= v then
                            LogAudit(name, k, tostring(old[k]), tostring(v))
                        end
                    end
                end
            end
        end

        RecalculateAllBalances()
        UpdateTable()
        Print("CSV import complete. Records merged or created for names present in the CSV.")
    end)

    local footer1 = ioPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer1:SetPoint("BOTTOMLEFT", ioPanel, "BOTTOMLEFT", 10, 50)
    footer1:SetJustifyH("LEFT")
    footer1:SetText("|cffaaaaaa* Blizzard to not allow import and export to CSV files from within World of Warcraft.|r")

    local footer2 = ioPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer2:SetPoint("BOTTOMLEFT", ioPanel, "BOTTOMLEFT", 10, 30)
    footer2:SetJustifyH("LEFT")
    footer2:SetText("|cffaaaaaa* Exported CSV is written to: World of Warcraft/_anniversary_/WTF/Account/<ACCOUNT>/SavedVariables/RedDKP.lua|r")

    local footer3 = ioPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer3:SetPoint("BOTTOMLEFT", ioPanel, "BOTTOMLEFT", 10, 10)
    footer3:SetJustifyH("LEFT")
    footer3:SetText("|cffaaaaaa* Please export the data to the LUA file first before importing, being mindful to maintain the formatting of the file when you edit.|r")

    --------------------------------------------------
    -- AUDIT PANEL
    --------------------------------------------------

    local auditScroll = CreateFrame("ScrollFrame", nil, auditPanel, "UIPanelScrollFrameTemplate")
    auditScroll:SetPoint("TOPLEFT", 10, -10)
    auditScroll:SetPoint("BOTTOMRIGHT", -30, 10)

    local auditContent = CreateFrame("Frame", nil, auditScroll)
    auditContent:SetSize(1, 1)
    auditScroll:SetScrollChild(auditContent)

    local MAX_AUDIT_ROWS = 30
    local AUDIT_ROW_HEIGHT = 18

    for i = 1, MAX_AUDIT_ROWS do
        local row = CreateFrame("Frame", nil, auditContent)
        row:SetSize(1, AUDIT_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i-1)*AUDIT_ROW_HEIGHT)

        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", 0, 0)
        fs:SetWidth(740)
        fs:SetJustifyH("LEFT")
        row.text = fs

        auditRows[i] = row
    end

    auditPanel:SetScript("OnShow", UpdateAuditLog)

    --------------------------------------------------
    -- INITIAL STATE
    --------------------------------------------------

    RecalculateAllBalances()
    UpdateTable()
    ShowTab(TAB_DKP)
end

--------------------------------------------------
-- EVENT HANDLER
--------------------------------------------------

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, event, name)
    if name ~= addonName then return end
    EnsureSaved()

    if IsInGuild() then
        for i = 1, GetNumGuildMembers() do
            local gName, _, _, _, _, _, _, _, _, _, gClass = GetGuildRosterInfo(i)
            if gName and gClass then
                gName = Ambiguate(gName, "short")
                local d = RedDKP_Data[gName]
                if d then
                    d.class = gClass
                end
            end
        end
    end

    CreateUI()
    CreateFallbackMinimapButton()
    Print("Loaded.")
end)