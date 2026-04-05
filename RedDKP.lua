-- RedDKP.lua
-- Distributed DKP system with editors, audit log, smart sync, and auto-sync for non-editors.
if ... ~= "RedDKP" then return end

RedDKP_Data   = RedDKP_Data   or {}
RedDKP_Config = RedDKP_Config or {}
RedDKP_Audit  = RedDKP_Audit  or {}
RedDKP_Usage  = RedDKP_Usage  or {}
RedDKP_ForceSyncStatus = {
    total = 0,
    accepted = 0,
    declined = 0,
}

local addonName      = ...
local REDDKP_VERSION = "1.0.0"
local VERSION_PREFIX = "REDDKP_VER"
local SYNC_PREFIX    = "REDDKP_SYNC"

RedDKP_Config.smartSync      = (RedDKP_Config.smartSync ~= false)
RedDKP_Config.addonUsers     = RedDKP_Config.addonUsers     or {}
RedDKP_Config.onlineEditors  = RedDKP_Config.onlineEditors  or {}
RedDKP_Config.authorizedEditors = RedDKP_Config.authorizedEditors or {}

local mainFrame
local dkpPanel, raidPanel, editorsPanel, auditPanel

local TAB_DKP     = 1
local TAB_GROUP   = 2
local TAB_RAID    = 3
local TAB_EDITORS = 4
local TAB_AUDIT   = 5

local activeTab = TAB_DKP

local SORT_COLOR   = "|cff3399ff"
local NORMAL_COLOR = "|cffffffff"

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RedDKP]|r " .. tostring(msg))
end

local function EnsureSaved()
    RedDKP_Config.authorizedEditors = RedDKP_Config.authorizedEditors or {}
end

local function EnsureConfig()
    RedDKP_Config = RedDKP_Config or {}
    EnsureSaved()
    RedDKP_Config.editorListVersion = RedDKP_Config.editorListVersion or 0
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

local function CheckGuildRestriction()
    local guildName = GetGuildInfo("player")

    if guildName == nil then
        -- Guild info not ready yet, wait for update
        return
    end

    if guildName ~= "Redemption" then
        print("|cffff5555RedDKP: You are not a member of the guild Redemption. Addon disabled.|r")
        RedDKP_Enabled = false
        if RedDKP_MainFrame then RedDKP_MainFrame:Hide() end
    else
        RedDKP_Enabled = true
    end
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

local function RecalcBalance(d)
    d.balance = (d.lastWeek or 0)
              + (d.onTime or 0)
              + (d.attendance or 0)
              + (d.bench or 0)
              - (d.spent or 0)
end

local function RecalculateAllBalances()
    for _, d in pairs(RedDKP_Data) do
        RecalcBalance(d)
    end
end

local function EnsureAddonUsers()
    RedDKP_Config.addonUsers = RedDKP_Config.addonUsers or {}
end

local function EnsureOnlineEditors()
    RedDKP_Config.onlineEditors = RedDKP_Config.onlineEditors or {}
end

local syncWarning

local function SafeSetSyncWarning(text)
    if syncWarning then
        syncWarning:SetText(text or "")
    end
end

local function GenerateAuditID()
    return tostring(time()) .. "-" .. math.random(100000, 999999)
end

local function ShortName(name)
    if not name then return nil end
    return name:match("^[^-]+")
end

local function ColorizeBalance(value)
    value = tonumber(value) or 0

    if value > 0 then
        return "|cff00ff00" .. value .. "|r"   -- green
    elseif value < 0 then
        return "|cffff0000" .. value .. "|r"   -- red
    else
        return tostring(value)                 -- neutral
    end
end

function IsEditor(name)
    return RedDKP_Config.authorizedEditors
        and RedDKP_Config.authorizedEditors[name] == true
end

function LogAudit(player, field, old, new)
    if not RedDKP_Enabled then
        return
    end

    -- Only block non‑editors AFTER editor list is synced
    if RedDKP_Config.authorizedEditors and next(RedDKP_Config.authorizedEditors) then
        if not IsEditor(UnitName("player")) then
            return
        end
    end

    table.insert(RedDKP_Audit, {
        id     = GenerateAuditID(),
        time   = date("%Y-%m-%d %H:%M:%S"),
        editor = UnitName("player"),
        name   = player,
        field  = field,
        old    = old,
        new    = new,
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

local function GetProtectedEditor()
    local guildLeader = GetGuildLeader()
    if guildLeader then
        return guildLeader
    end
    return UnitName("player")
end

local function IsRaidLeaderOrMasterLooter()
    if not IsInRaid() then return false end
    if UnitIsGroupLeader("player") then return true end

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

RedDKP_Usage = RedDKP_Usage or {}

local function UsedToday(key)
    local player = UnitName("player")
    RedDKP_Usage[player] = RedDKP_Usage[player] or {}
    return RedDKP_Usage[player][key] == date("%Y-%m-%d")
end

local function MarkUsedToday(key)
    local player = UnitName("player")
    RedDKP_Usage[player] = RedDKP_Usage[player] or {}
    RedDKP_Usage[player][key] = date("%Y-%m-%d")
end

local function CompareVersions(localVer, remoteVer)
    local function split(v)
        local a, b, c = v:match("(%d+)%.(%d+)%.(%d+)")
        return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
    end

    local la, lb, lc = split(localVer)
    local ra, rb, rc = split(remoteVer)

    if ra > la then return true end
    if ra < la then return false end
    if rb > lb then return true end
    if rb < lb then return false end
    return rc > lc
end

local function ParseAuditTime(t)
    -- t = "YYYY-MM-DD HH:MM:SS"
    local year, month, day, hour, min, sec = t:match("(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)")
    return time({
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = min,
        sec = sec,
    })
end

local LibSerialize = LibStub("LibSerialize")
local LibDeflate   = LibStub("LibDeflate")

local function BroadcastNext(names, index)
    if index > #names then
        Print("DKP table broadcast to raid.")
        return
    end

    local name = names[index]
    local d = EnsurePlayer(name)
    local msg = string.format("%-12s (%d)", name, d.balance or 0)

    SendChatMessage(msg, "RAID")

    -- throttle to avoid server dropping messages
    C_Timer.After(0.15, function()
        BroadcastNext(names, index + 1)
    end)
end

local function MarkAddonUserOnline(name)
    EnsureAddonUsers()
    name = Ambiguate(name, "short")
    RedDKP_Config.addonUsers[name] = true
end

local function ClearOfflineAddonUsers()
    EnsureAddonUsers()
    for name in pairs(RedDKP_Config.addonUsers) do
        if not UnitIsConnected(name) then
            RedDKP_Config.addonUsers[name] = nil
        end
    end
end

local function UpdateOnlineEditors()
    EnsureOnlineEditors()
    wipe(RedDKP_Config.onlineEditors)

    if not IsInGuild() then return end

    for i = 1, GetNumGuildMembers() do
        local name, _, rankIndex, _, _, _, _, _, online = GetGuildRosterInfo(i)
        if name and online then
            name = Ambiguate(name, "short")
            if RedDKP_Config.authorizedEditors[name] then
                RedDKP_Config.onlineEditors[name] = rankIndex
            end
        end
    end
end

local function GetHighestRankEditor()
    EnsureOnlineEditors()
    local bestName = nil
    local bestRank = 99

    for name, rank in pairs(RedDKP_Config.onlineEditors) do
        if rank < bestRank then
            bestRank = rank
            bestName = name
        end
    end

    return bestName
end

local tabs = {}

local function CreateTab(index, text)
    local tab = CreateFrame("Button", addonName.."Tab"..index, mainFrame, "CharacterFrameTabButtonTemplate")
    tab:SetID(index)
    tab:SetText(text)
    PanelTemplates_TabResize(tab, 0)
    if index == 1 then
        tab:SetPoint("TOPLEFT", mainFrame, "BOTTOMLEFT", 5, 2)
    else
        tab:SetPoint("LEFT", tabs[index-1], "RIGHT", -15, 0)
    end
    tab:SetScript("OnClick", function(self)
        ShowTab(self:GetID())
    end)
    tabs[index] = tab
end

function LayoutPanel(panel)
    panel:SetAllPoints(mainFrame)
    panel:Hide()
end

function ShowTab(id)
    activeTab = id

    for i, tab in ipairs(tabs) do
        if i == id then
            PanelTemplates_SelectTab(tab)
        else
            PanelTemplates_DeselectTab(tab)
        end
    end

    dkpPanel:Hide()
	groupPanel:Hide()
    raidPanel:Hide()
    editorsPanel:Hide()
    auditPanel:Hide()

    if id == TAB_DKP then
        dkpPanel:Show()
	elseif id == TAB_GROUP then
        groupPanel:Show()
    elseif id == TAB_RAID then
        raidPanel:Show()
    elseif id == TAB_EDITORS then
        editorsPanel:Show()
    elseif id == TAB_AUDIT then
        auditPanel:Show()
    end
end

headers = {
    { text = "Name",       width = 120 },
    { text = "LastWeek",   width = 70  },
    { text = "OnTime",     width = 70  },
    { text = "Attendance", width = 80  },
    { text = "Bench",      width = 60  },
    { text = "Spent",      width = 60  },
    { text = "Balance",    width = 70  },
	{ text = "Rotated",    width = 60  },
    { text = "",           width = 60  },
}

fieldMap = {
    [1] = "name",
    [2] = "lastWeek",
    [3] = "onTime",
    [4] = "attendance",
    [5] = "bench",
    [6] = "spent",
    [7] = "balance",
    [8] = "rotated",
	[9] = "whisper",
}

rows = {}
sortedNames = {}
headerButtons = {}
editorRows = {}
auditRows = {}
currentSortField = "name"
currentSortAscending = true

local scroll
local scrollChild

function UpdateTable()
    sortedNames = {}

    for name in pairs(RedDKP_Data) do
        table.insert(sortedNames, name)
    end

    table.sort(sortedNames, function(a, b)
		local da = RedDKP_Data[a]
		local db = RedDKP_Data[b]

		if not da or not db then return a < b end

		-- Sort by name
		if currentSortField == "name" then
			if currentSortAscending then
				return a < b
			else
				return a > b
			end
		end

		-- Sort by rotated (boolean)
		if currentSortField == "rotated" then
			local va = da.rotated and 1 or 0
			local vb = db.rotated and 1 or 0

			if currentSortAscending then
				return va < vb
			else
				return va > vb
			end
		end

		-- Normal numeric sorting
		local fa = tonumber(da[currentSortField]) or 0
		local fb = tonumber(db[currentSortField]) or 0

		if currentSortAscending then
			return fa < fb
		else
			return fa > fb
		end
    end)

    for i, row in ipairs(rows) do
		local name = sortedNames[i]
		if not name then
			row:Hide()
		else
			local d = RedDKP_Data[name]
			row.index = i

			RecalcBalance(d)

			local classColor = "|cffffffff"
			if d.class then
				local c = RAID_CLASS_COLORS[d.class]
				if c then
					classColor = string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
				end
			end

			-- NAME
			row.cols[1]:SetText(classColor .. name .. "|r")

			-- NUMERIC FIELDS
			row.cols[2]:SetText(d.lastWeek or 0)
			row.cols[3]:SetText(d.onTime or 0)
			row.cols[4]:SetText(d.attendance or 0)
			row.cols[5]:SetText(d.bench or 0)
			row.cols[6]:SetText(d.spent or 0)

			-- BALANCE
			row.cols[7]:SetText(ColorizeBalance(d.balance))

			-- ROTATED
			row.cols[8]:SetText(
				d.rotated
					and "|cff00ff00Yes|r"
					or  "No"
			)

			-- WHISPER BUTTON stays untouched (col 9)

			row:Show()
		end
	end

    local visibleRows = #sortedNames
    local rowHeight = 18

    if scroll and scrollChild then
        scrollChild:SetHeight(visibleRows * rowHeight)

        C_Timer.After(0, function()
            if scroll.ScrollBar then
                local sb = scroll.ScrollBar
                local maxScroll = scroll:GetVerticalScrollRange()

                if maxScroll > 0 then
                    sb:Show()
                else
                    sb:Hide()
                end
            end
        end)
    end
end

local function UpdateAuditLog()
    if not auditRows or not RedDKP_Audit then return end

    table.sort(RedDKP_Audit, function(a, b)
        if not a.time or not b.time then
            return false
        end
        return ParseAuditTime(a.time) > ParseAuditTime(b.time)   -- newest first
    end)

    for i, row in ipairs(auditRows) do
        local entry = RedDKP_Audit[i]

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

local EDITOR_PREFIX      = "REDDKP_EDITORS"
local EDITOR_REQ_PREFIX  = "REDDKP_EDITORS_REQ"

local function BroadcastEditorList()
    EnsureConfig()

    local payload = {
        editors = RedDKP_Config.authorizedEditors,
        version = RedDKP_Config.editorListVersion or 0,
    }

    local serialized = LibSerialize:Serialize(payload)
    local encoded    = LibDeflate:EncodeForWoWAddonChannel(serialized)

    local message = "EDITORSYNC:" .. encoded
    C_ChatInfo.SendAddonMessage(EDITOR_PREFIX, message, "GUILD")
end

local function ApplyEditorList(payload)
    EnsureConfig()

    local incomingVersion = payload.version or 0
    local currentVersion  = RedDKP_Config.editorListVersion or 0

    if incomingVersion <= currentVersion then
        return
    end

    RedDKP_Config.authorizedEditors = payload.editors or {}
    RedDKP_Config.editorListVersion = incomingVersion

    if RefreshEditorList then
        RefreshEditorList()
    end
end

local function OnEditorAddonMessage(prefix, message, channel, sender)
    if prefix == EDITOR_PREFIX then
        if message:sub(1, 12) == "EDITORSYNC:" then
            local encoded = message:sub(13)
            local decoded = LibDeflate:DecodeForWoWAddonChannel(encoded)
            if not decoded then return end

            local ok, payload = LibSerialize:Deserialize(decoded)
            if not ok or type(payload) ~= "table" then return end

            ApplyEditorList(payload)
        end

    elseif prefix == EDITOR_REQ_PREFIX then
        if IsGuildOfficer() or IsAuthorized() then
            BroadcastEditorList()
        end
    end
end

local function RefreshEditorList()
    EnsureSaved()

    if not editorRows or not editorRows[1] then
        return
    end

    local guildLeader = ShortName(GetGuildLeader())
    local PROTECTED_USER = guildLeader
    local fallback = ShortName(UnitName("player"))

    if PROTECTED_USER then
        RedDKP_Config.authorizedEditors[PROTECTED_USER] = true
    elseif fallback then
        RedDKP_Config.authorizedEditors[fallback] = true
    end

    local nameSet = {}

    for name in pairs(RedDKP_Config.authorizedEditors) do
        local short = ShortName(name)
        if short and short ~= "" then
            nameSet[short] = true
        end
    end

    local names = {}
    for short in pairs(nameSet) do
        table.insert(names, short)
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

local function CreateUI()
    --------------------------------------------------------------------
    -- MAIN FRAME
    --------------------------------------------------------------------
    mainFrame = CreateFrame("Frame", "RedDKPFrame", UIParent, "BasicFrameTemplateWithInset")
    mainFrame:SetSize(800, 500)
    mainFrame:SetPoint("CENTER")
    mainFrame:Hide()

    local headerIcon = mainFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    headerIcon:SetTexture("Interface\\AddOns\\RedDKP\\media\\RedDKP_Icon256.png")
    headerIcon:SetSize(128, 128)
    headerIcon:SetPoint("TOP", mainFrame, "LEFT", 20, 290)

    mainFrame.title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    mainFrame.title:SetPoint("CENTER", mainFrame.TitleBg, "CENTER", 0, 0)
    mainFrame.title:SetText("RedDKP - brought to you by a clueless idiot called Lunátic")

    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)
    table.insert(UISpecialFrames, "RedDKPFrame")

    --------------------------------------------------------------------
    -- TABS
    --------------------------------------------------------------------
    CreateTab(TAB_DKP,   "DKP")
    CreateTab(TAB_GROUP, "Group Builder") -- visible to everyone
    if IsEditor(UnitName("player")) then
        CreateTab(TAB_RAID,    "RL Tools")
        CreateTab(TAB_EDITORS, "Editors")
        CreateTab(TAB_AUDIT,   "Audit Log")
    end

    --------------------------------------------------------------------
    -- PANELS
    --------------------------------------------------------------------
    dkpPanel     = CreateFrame("Frame", nil, mainFrame); LayoutPanel(dkpPanel)
    groupPanel   = CreateFrame("Frame", nil, mainFrame); LayoutPanel(groupPanel)
    raidPanel    = CreateFrame("Frame", nil, mainFrame); LayoutPanel(raidPanel)
    editorsPanel = CreateFrame("Frame", nil, mainFrame); LayoutPanel(editorsPanel)
    auditPanel   = CreateFrame("Frame", nil, mainFrame); LayoutPanel(auditPanel)

--------------------------------------------------------------------
-- GROUP BUILDER PANEL
--------------------------------------------------------------------
do
    local title = groupPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("")

    local scroll = CreateFrame("ScrollFrame", nil, groupPanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 50, -20)
    scroll:SetPoint("BOTTOMRIGHT", groupPanel, "BOTTOMRIGHT", -50, 50)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    local ROW_HEIGHT = 20
    groupRows = {}

    ----------------------------------------------------------------
    -- CLASS COLOUR LOOKUP
    ----------------------------------------------------------------
    local CLASS_COLORS = {}
    for class, c in pairs(RAID_CLASS_COLORS) do
        CLASS_COLORS[class] = string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end

    ----------------------------------------------------------------
    -- ONLINE CHECK (returns true/false)
    ----------------------------------------------------------------
    local function IsPlayerOnline(name)
        -- Check raid first
        for i = 1, GetNumGroupMembers() do
            local unit = "raid"..i
            if UnitExists(unit) and UnitName(unit) == name then
                return UnitIsConnected(unit)
            end
        end

        -- Check party
        for i = 1, GetNumSubgroupMembers() do
            local unit = "party"..i
            if UnitExists(unit) and UnitName(unit) == name then
                return UnitIsConnected(unit)
            end
        end

        -- Check self
        if UnitName("player") == name then
            return UnitIsConnected("player")
        end

        -- Check guild roster
        if IsInGuild() then
            for i = 1, GetNumGuildMembers() do
                local gName, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
                if gName and Ambiguate(gName, "short") == name then
                    return online
                end
            end
        end

        return false
    end

    ----------------------------------------------------------------
    -- REFRESH LIST
    ----------------------------------------------------------------
    local function RefreshGroupBuilder()
        for _, row in ipairs(groupRows) do
            row:Hide()
        end
        wipe(groupRows)

        local names = {}
        for name in pairs(RedDKP_Data) do
            table.insert(names, name)
        end
        table.sort(names)

        local i = 0
        for _, name in ipairs(names) do
            i = i + 1
            local row = groupRows[i]

            if not row then
                row = CreateFrame("Frame", nil, content)
                row:SetSize(300, ROW_HEIGHT)

                local cb = CreateFrame("CheckButton", nil, row, "ChatConfigCheckButtonTemplate")
                cb:SetPoint("LEFT", 0, 0)
                cb:SetSize(20, 20)
                row.checkbox = cb

                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetPoint("LEFT", cb, "RIGHT", 5, 0)
                row.nameFS = fs

                groupRows[i] = row
            end

            row:SetPoint("TOPLEFT", 10, -(i - 1) * ROW_HEIGHT)
            row.name = name

            -- class colour
            local class = RedDKP_Data[name].class
            local colour = CLASS_COLORS[class] or "|cffffffff"

            -- online check
            local online = IsPlayerOnline(name)
            local offlineText = online and "" or " |cffaaaaaa(offline)|r"

            row.nameFS:SetText(colour .. name .. "|r" .. offlineText)
            row.checkbox:SetChecked(false)
            row:Show()
        end

        content:SetHeight(i * ROW_HEIGHT)
    end

    ----------------------------------------------------------------
    -- 10-SECOND ONLINE SCAN WHILE TAB IS OPEN
    ----------------------------------------------------------------
    local scanTicker = nil

    local function StartOnlineScan()
        if scanTicker then return end
        scanTicker = C_Timer.NewTicker(10, RefreshGroupBuilder)
    end

    local function StopOnlineScan()
        if scanTicker then
            scanTicker:Cancel()
            scanTicker = nil
        end
    end

    ----------------------------------------------------------------
    -- INVITE BUTTON
    ----------------------------------------------------------------
    local inviteBtn = CreateFrame("Button", nil, groupPanel, "UIPanelButtonTemplate")
    inviteBtn:SetSize(140, 24)
    inviteBtn:SetText("Invite to Group")
    inviteBtn:SetPoint("BOTTOMRIGHT", groupPanel, "BOTTOMRIGHT", -10, 10)

    inviteBtn:SetScript("OnClick", function()
        local selected = {}

        for _, row in ipairs(groupRows) do
            if row:IsShown() and row.checkbox:GetChecked() then
                table.insert(selected, row.name)
            end
        end

        if #selected == 0 then
            Print("No players selected.")
            return
        end

        local numGroup = GetNumGroupMembers()
        local isRaid = IsInRaid()

        if #selected + numGroup > 4 and not isRaid then
            C_PartyInfo.ConvertToRaid()
        end

        for _, name in ipairs(selected) do
            if not UnitInParty(name) and not UnitInRaid(name) then
                C_PartyInfo.InviteUnit(name)
            end
        end
    end)

    ----------------------------------------------------------------
    -- INFO TEXT (BOTTOM LEFT)
    ----------------------------------------------------------------
    local info = groupPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
info:SetPoint("BOTTOMLEFT", groupPanel, "BOTTOMLEFT", 10, 10)
info:SetJustifyH("LEFT")
info:SetText("|cffaaaaaa*This list is populated from the DKP table and scans every 10 seconds (with the tab open) to check who's online.|r")

    ----------------------------------------------------------------
    -- PANEL SHOW/HIDE HANDLERS
    ----------------------------------------------------------------
    groupPanel:SetScript("OnShow", function()
        RefreshGroupBuilder()
        StartOnlineScan()
    end)

    groupPanel:SetScript("OnHide", function()
        StopOnlineScan()
    end)
end

    --------------------------------------------------------------------
    -- RL TOOLS PANEL
    --------------------------------------------------------------------
    do
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
                Print("Already allocated today.")
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
                Print("Already allocated today.")
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
            StaticPopup_Show("REDDKP_BROADCAST_DKP")
        end)
    end

    --------------------------------------------------------------------
    -- EDITORS PANEL
    --------------------------------------------------------------------
    do
        local title = editorsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 10, -10)
        title:SetText("")

        local editorScroll = CreateFrame("ScrollFrame", nil, editorsPanel, "UIPanelScrollFrameTemplate")
        editorScroll:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 70, -30)
        editorScroll:SetPoint("BOTTOMLEFT", editorsPanel, "BOTTOMLEFT", 0, 30)
        editorScroll:SetWidth(200)

        local editorContent = CreateFrame("Frame", nil, editorScroll)
        editorContent:SetWidth(200)
        editorScroll:SetScrollChild(editorContent)

        local EDITOR_ROW_HEIGHT = 18
        local MAX_EDITOR_ROWS = 20

        editorRows = {}

        for i = 1, MAX_EDITOR_ROWS do
            local row = CreateFrame("Button", nil, editorContent)
            row:SetSize(200, EDITOR_ROW_HEIGHT)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * EDITOR_ROW_HEIGHT)

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
        addBtn:SetPoint("LEFT", addBox, "RIGHT", 10, 0)

        local removeBtn = CreateFrame("Button", nil, editorsPanel, "UIPanelButtonTemplate")
        removeBtn:SetSize(80, 22)
        removeBtn:SetText("Remove")
        removeBtn:SetPoint("TOPLEFT", addBtn, "BOTTOMLEFT", 0, -8)

        local removeNote = editorsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        removeNote:SetPoint("TOPLEFT", removeBtn, "BOTTOMLEFT", 0, -4)
        removeNote:SetText("|cffaaaaaa* select name from list and click to remove|r")

        editorsPanel.selectedEditor = nil

        addBtn:SetScript("OnClick", function()
            if not (IsGuildOfficer() or IsEditor(UnitName("player"))) then
                Print("Only guild leaders, officers, or editors can modify the editor list.")
                return
            end
            local name = addBox:GetText():gsub("%s+", "")
            if name == "" then return end
            EnsureSaved()
            RedDKP_Config.authorizedEditors[name] = true
            RedDKP_Config.editorListVersion = (RedDKP_Config.editorListVersion or 0) + 1
            addBox:SetText("")
            RefreshEditorList()
            BroadcastEditorList()
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
            RedDKP_Config.editorListVersion = (RedDKP_Config.editorListVersion or 0) + 1
            editorsPanel.selectedEditor = nil
            RefreshEditorList()
            BroadcastEditorList()
        end)

        editorsPanel:SetScript("OnShow", function()
            C_Timer.After(0.05, RefreshEditorList)
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
    end

    --------------------------------------------------------------------
    -- AUDIT PANEL
    --------------------------------------------------------------------
    do
        local auditScroll = CreateFrame("ScrollFrame", nil, auditPanel, "UIPanelScrollFrameTemplate")
        auditScroll:SetPoint("TOPLEFT", -40, -40)
        auditScroll:SetPoint("BOTTOMRIGHT", -40, 25)

        local auditContent = CreateFrame("Frame", nil, auditScroll)
        auditContent:SetSize(1, 1)
        auditScroll:SetScrollChild(auditContent)

        local MAX_AUDIT_ROWS = 666
        local AUDIT_ROW_HEIGHT = 18

        auditRows = {}

        for i = 1, MAX_AUDIT_ROWS do
            local row = CreateFrame("Frame", nil, auditContent)
            row:SetSize(1, AUDIT_ROW_HEIGHT)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * AUDIT_ROW_HEIGHT)

            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            local offset = 50

            fs:SetPoint("LEFT", offset + 60, 0)
            fs:SetWidth(740 - offset)
            fs:SetJustifyH("LEFT")
            row.text = fs

            auditRows[i] = row
        end

        auditPanel:SetScript("OnShow", UpdateAuditLog)
    end

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
        headerButtons = headerButtons or {}

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

        local scroll = CreateFrame("ScrollFrame", nil, dkpPanel, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", dkpPanel, "TOPLEFT", 30, headerY - 20)
        scroll:SetPoint("BOTTOMRIGHT", dkpPanel, "BOTTOMRIGHT", -30, 60)

        local sb = scroll.ScrollBar
        if sb then
            sb:ClearAllPoints()
            sb:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", -5, -18)
            sb:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", -20, 16)
        end

        scrollChild = CreateFrame("Frame", nil, scroll)
        scrollChild:SetSize(1, 1)
        scroll:SetScrollChild(scrollChild)

        local MAX_ROWS = 666
        local ROW_HEIGHT = 18

        rows = {}

        for i = 1, MAX_ROWS do
            local row = CreateFrame("Frame", nil, scrollChild)
            row:SetSize(1, ROW_HEIGHT)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0, 0, 0, 0.15)
            row.bg = bg

            local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            delBtn:SetSize(15, 15)
            delBtn:SetPoint("LEFT", row, "LEFT", 2, 0)
            delBtn:SetText("X")
            row.deleteButton = delBtn

            if not IsEditor(UnitName("player")) then
                row.deleteButton:Hide()
            end

            row.cols = {}
            local colX = 30

            for j, h in ipairs(headers) do
                local field = fieldMap[j]

                if field == "name" then
                    local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    nameFS:SetPoint("LEFT", row, "LEFT", colX, 0)
                    nameFS:SetWidth(h.width)
                    nameFS:SetJustifyH("LEFT")
                    nameFS:EnableMouse(true)
                    row.cols[j] = nameFS

                elseif field == "rotated" then
                    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    fs:SetPoint("LEFT", row, "LEFT", colX, 0)
                    fs:SetWidth(h.width)
                    fs:SetJustifyH("LEFT")
                    fs:EnableMouse(true)
                    row.cols[j] = fs

                elseif field == "whisper" then
                    local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                    btn:SetPoint("LEFT", row, "LEFT", colX + 5, 0)
                    btn:SetSize(h.width - 10, 16)
                    btn:SetText("Tell")
                    row.cols[j] = btn

                elseif field == "balance" then
                    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    fs:SetPoint("LEFT", row, "LEFT", colX, 0)
                    fs:SetWidth(h.width)
                    fs:SetJustifyH("LEFT")
                    row.cols[j] = fs

                else
                    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    fs:SetPoint("LEFT", row, "LEFT", colX, 0)
                    fs:SetWidth(h.width)
                    fs:SetJustifyH("LEFT")
                    fs:EnableMouse(true)
                    row.cols[j] = fs
                end

                colX = colX + h.width + 5
            end

            rows[i] = row
        end

        ----------------------------------------------------------------
        -- INLINE EDIT BOX
        ----------------------------------------------------------------
        inlineEdit = CreateFrame("EditBox", nil, scrollChild, "InputBoxTemplate")
        inlineEdit:SetAutoFocus(true)
        inlineEdit:SetSize(80, 18)
        inlineEdit:Hide()
        inlineEdit.cancelled = false
        inlineEdit:SetFrameStrata("HIGH")

        inlineEdit:SetScript("OnEscapePressed", function(self)
            self.cancelled = true
            self:Hide()
        end)

        inlineEdit:SetScript("OnEnterPressed", function(self)
            self.cancelled = false
            if self.saveFunc then self.saveFunc(self:GetText()) end
            self:Hide()
        end)

        inlineEdit:SetScript("OnEditFocusLost", function(self)
            if not self.cancelled and self.saveFunc then
                self.saveFunc(self:GetText())
            end
            self:Hide()
        end)

        inlineEdit:SetScript("OnHide", function(self)
            if self.currentFS then
                self.currentFS:Show()
                self.currentFS = nil
            end
        end)

        ----------------------------------------------------------------
        -- PER-ROW SCRIPTS: DELETE, WHISPER, EDIT
        ----------------------------------------------------------------
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
                local field = fieldMap[j]

                -- Whisper button (last column)
                if field == "whisper" then
                    col:SetScript("OnClick", function()
                        local index = row.index
                        if not index then return end
                        local player = sortedNames[index]
                        if not player then return end
                        local d = RedDKP_Data[player]
                        if not d then return end
                        local msg = string.format(
                            "Your DKP: LastWeek=%d, OnTime=%d, Attendance=%d, Bench=%d, Spent=%d, CURRENTBalance=%d",
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
                    col:EnableMouse(false)

                elseif field == "rotated" then
                    col:SetScript("OnMouseDown", function(self, button)
                        if button ~= "LeftButton" then return end
                        if not IsAuthorized() then return end

                        local player = sortedNames[row.index]
                        if not player then return end

                        local d = EnsurePlayer(player)
                        local old = d.rotated
                        d.rotated = not d.rotated

                        LogAudit(player, "rotated", tostring(old), tostring(d.rotated))
                        UpdateTable()
                    end)

                else
                    col:SetScript("OnMouseDown", function(self, button)
                        if button ~= "LeftButton" then return end
                        if not IsAuthorized() then return end

                        inlineEdit:Hide()

                        local rowIndex = row.index
                        local colIndex = j
                        local player   = sortedNames[rowIndex]
                        local field    = fieldMap[colIndex]
                        if not player or not field then return end

                        local d = EnsurePlayer(player)

                        -- NAME EDIT
                        if field == "name" then
                            local playerName = sortedNames[row.index]
                            if not playerName then return end

                            inlineEdit:Hide()
                            self:Hide()

                            inlineEdit.currentFS = self
                            inlineEdit.editPlayer = playerName
                            inlineEdit.editField  = "name"

                            inlineEdit:ClearAllPoints()
                            inlineEdit:SetPoint("LEFT", self, "LEFT", 0, 0)
                            inlineEdit:SetWidth(headers[colIndex].width - 4)
                            inlineEdit:SetText(playerName)
                            inlineEdit:HighlightText()

                            inlineEdit.saveFunc = function(newName)
                                newName = newName:gsub("^%s*(.-)%s*$", "%1")
                                if newName == "" or newName == playerName then return end

                                if RedDKP_Data[newName] then
                                    Print("|cffff5555A player with that name already exists.|r")
                                    return
                                end

                                RedDKP_Data[newName] = RedDKP_Data[playerName]
                                RedDKP_Data[playerName] = nil

                                local _, class = UnitClass(newName)
                                if class then
                                    RedDKP_Data[newName].class = class
                                elseif IsInGuild() then
                                    for i = 1, GetNumGuildMembers() do
                                        local gName, _, _, _, _, _, _, _, _, _, gClass = GetGuildRosterInfo(i)
                                        if gName and Ambiguate(gName, "short") == newName then
                                            RedDKP_Data[newName].class = gClass
                                            break
                                        end
                                    end
                                end

                                local editor = UnitName("player")
                                LogAudit(newName, "RENAME_PLAYER", "changed",
                                    string.format("Renamed by %s | %s → %s", editor, playerName, newName)
                                )

                                UpdateTable()
                            end

                            inlineEdit:Show()
                            return
                        end

                        -- NUMERIC FIELD EDIT
                        self:Hide()
                        inlineEdit.currentFS = self

                        inlineEdit.editPlayer = player
                        inlineEdit.editField  = field

                        inlineEdit:ClearAllPoints()
                        inlineEdit:SetPoint("LEFT", self, "LEFT", 0, 0)
                        inlineEdit:SetWidth(headers[colIndex].width - 4)
                        inlineEdit:SetText(tostring(d[field] or 0))
                        inlineEdit:HighlightText()

                        inlineEdit.saveFunc = function(newValue)
                            local num = tonumber(newValue)
                            if not num then return end

                            local playerName = inlineEdit.editPlayer
                            local fieldName  = inlineEdit.editField
                            local dkp = RedDKP_Data[playerName]
                            if not dkp then return end

                            local old = dkp[fieldName]

                            if fieldName == "onTime" and num > 10 then
                                Print("|cffff5555On-Time DKP cannot exceed 10.|r")
                                UpdateTable()
                                return
                            end

                            if fieldName == "attendance" and num > 30 then
                                Print("|cffff5555Attendance DKP cannot exceed 30.|r")
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
                            UpdateTable()
                        end

                        inlineEdit:Show()
                    end)
                end
            end
        end
    end

    --------------------------------------------------------------------
    -- ADD PLAYER INPUT
    --------------------------------------------------------------------
    do
        local addInput = CreateFrame("EditBox", nil, dkpPanel, "InputBoxTemplate")
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

            catcher:SetScript("OnMouseDown", function()
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

        local addButton = CreateFrame("Button", nil, dkpPanel, "UIPanelButtonTemplate")
        addButton:SetSize(100, 22)
        addButton:SetPoint("LEFT", addInput, "RIGHT", 10, 0)
        addButton:SetText("Add")

        if not IsEditor(UnitName("player")) then
            addButton:Hide()
        end

        addButton:SetScript("OnClick", function()
            if not IsAuthorized() then
                Print("Only editors can add DKP records.")
                return
            end

            local name = addInput:GetText():gsub("%s+", "")
            if name == "" then return end

            local upper = string.upper(name)
            for existingName in pairs(RedDKP_Data) do
                if string.upper(existingName) == upper then
                    Print("|cffff0000A DKP record already exists for:|r " .. existingName)
                    return
                end
            end

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
            StaticPopup_Show("REDDKP_REQUEST_SYNC_CONFIRM")
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
            StaticPopup_Show("REDDKP_FORCE_SYNC_CONFIRM")
        end)
    end

    --------------------------------------------------------------------
    -- FINALIZE
    --------------------------------------------------------------------
    RecalculateAllBalances()
    UpdateTable()
    ShowTab(TAB_DKP)
end

-- Smart sync payload helpers
local function BuildSyncPayload()
    return {
        sender = UnitName("player"),
        dkp    = RedDKP_Data,
        audit  = RedDKP_Audit,
        time   = time(),
        smart  = RedDKP_Config.smartSync,
    }
end

local function EncodePayload(tbl)
    local serialized = LibSerialize:Serialize(tbl)
    local compressed = LibDeflate:CompressDeflate(serialized)
    return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

local function DecodePayload(data)
    local decoded = LibDeflate:DecodeForWoWAddonChannel(data)
    if not decoded then return nil end
    local decompressed = LibDeflate:DecompressDeflate(decoded)
    if not decompressed then return nil end
    local ok, tbl = LibSerialize:Deserialize(decompressed)
    if not ok then return nil end
    return tbl
end

local function ApplySyncData(sender, encoded)
    sender = Ambiguate(sender, "short")

    local payload = DecodePayload(encoded)
    if not payload then
        Print("Sync failed: corrupted data.")
        return
    end

    RedDKP_Data = {}
    for name, dkpEntry in pairs(payload.dkp) do
        RedDKP_Data[name] = dkpEntry
    end

    if payload.smart then
        local existing = {}
        for _, entry in ipairs(RedDKP_Audit) do
            if entry.id then
                existing[entry.id] = true
            end
        end

        for _, entry in ipairs(payload.audit or {}) do
            if entry.id and not existing[entry.id] then
                table.insert(RedDKP_Audit, entry)
            end
        end

        table.insert(RedDKP_Audit, {
            id     = GenerateAuditID(),
            field  = "SMART_SYNC_ACCEPTED",
            name   = sender,
            old    = "pending",
            new    = "accepted",
            time   = date("%Y-%m-%d %H:%M:%S"),
            editor = UnitName("player"),
        })
    else
        RedDKP_Audit = {}
        for _, entry in ipairs(payload.audit or {}) do
            table.insert(RedDKP_Audit, entry)
        end
        table.insert(RedDKP_Audit, {
            id     = GenerateAuditID(),
            field  = "SYNC_ACCEPTED",
            name   = sender,
            old    = "pending",
            new    = "accepted",
            time   = date("%Y-%m-%d %H:%M:%S"),
            editor = UnitName("player"),
        })
    end

    table.sort(RedDKP_Audit, function(a, b)
        return (a.time or "") > (b.time or "")
    end)

    SafeSetSyncWarning("")
    UpdateTable()
    LogAudit(sender, "SYNC_APPLIED", "old data", "New DKP + audit data applied")
    Print("Sync completed from " .. sender)
end

local function CheckForceSyncCompletion()
    local s = RedDKP_ForceSyncStatus
    if s.accepted + s.declined >= s.total then
        LogAudit(UnitName("player"), "FORCE_SYNC_SUMMARY",
            "pending",
            string.format("%d accepted, %d declined", s.accepted, s.declined)
        )
        Print(string.format("Force Sync Summary: %d accepted, %d declined", s.accepted, s.declined))
    end
end

local function HandleSyncRequest(requester, sender, isRequestSync)
    requester = Ambiguate(requester, "short")
    MarkAddonUserOnline(requester)

    if not IsAuthorized() and not isRequestSync then
        C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "REQ_ACCEPT:" .. requester, "WHISPER", requester)
        return
    end

    StaticPopup_Show("REDDKP_REQUEST_SYNC_CONFIRM", requester, nil, requester)
end

local function HandleSyncResponse(sender, msgType)
    sender = Ambiguate(sender, "short")

    if msgType == "REQ_ACCEPT" then
        LogAudit(sender, "REQUEST_SYNC_ACCEPTED", "pending", "Editor accepted sync request")
        Print(sender .. " accepted your sync request.")
        local payload = BuildSyncPayload()
        local encoded = EncodePayload(payload)
        C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "DATA:" .. encoded, "WHISPER", sender)
        return
    end

    if msgType == "REQ_DECLINE" then
        LogAudit(sender, "REQUEST_SYNC_DECLINED", "pending", "Editor declined sync request")
        Print(sender .. " declined your sync request.")
        SafeSetSyncWarning("WARNING — You declined sync. Your data may be outdated.")
        return
    end

    if msgType == "FORCE_ACCEPT" then
        LogAudit(sender, "FORCE_SYNC_ACCEPTED", "pending", "User accepted force sync")

        RedDKP_ForceSyncStatus.accepted = RedDKP_ForceSyncStatus.accepted + 1
        CheckForceSyncCompletion()

        local payload = BuildSyncPayload()
        local encoded = EncodePayload(payload)
        C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "DATA:" .. encoded, "WHISPER", sender)
        Print(sender .. " accepted force sync.")
        return
    end

    if msgType == "FORCE_DECLINE" then
        LogAudit(sender, "FORCE_SYNC_DECLINED", "pending", "User declined force sync")

        RedDKP_ForceSyncStatus.declined = RedDKP_ForceSyncStatus.declined + 1
        CheckForceSyncCompletion()

        Print(sender .. " declined force sync.")
        return
    end
end

local function AttemptAutoSync()
    EnsureAddonUsers()
    EnsureOnlineEditors()

    if IsAuthorized() then
        SafeSetSyncWarning("WARNING — Editor data does NOT auto-sync. You must sync manually.")
        return
    end

    UpdateOnlineEditors()
    local bestEditor = GetHighestRankEditor()

    if not bestEditor then
        SafeSetSyncWarning("WARNING — No editor online. Your DKP data may be outdated.")
        return
    end

    C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "REQUEST:" .. UnitName("player"), "WHISPER", bestEditor)
    Print("Requesting automatic sync from " .. bestEditor .. "...")
end

-- Popups
StaticPopupDialogs["REDDKP_REQUEST_SYNC_CONFIRM"] = {
    text = "Are you sure you want to sync?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        local best = GetHighestRankEditor()
        if not best then
            SafeSetSyncWarning("WARNING — No editors online. Your data may be outdated.")
            Print("No editor online.")
            LogAudit(UnitName("player"), "REQUEST_SYNC", "none", "User requested sync but no Editors were online")
            return
        end
        C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "REQ_SYNC:" .. UnitName("player"), "WHISPER", best)
        Print("Requested sync from " .. best)
        LogAudit(UnitName("player"), "REQUEST_SYNC", "none", "User requested sync")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDDKP_FORCE_SYNC_CONFIRM"] = {
    text = "Force sync will overwrite ALL guild DKP with YOUR data. Proceed?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        LogAudit(UnitName("player"), "FORCE_SYNC_INITIATED", "none", "Editor initiated force sync")

        EnsureAddonUsers()
        local me = UnitName("player")

        RedDKP_ForceSyncStatus.total    = 0
        RedDKP_ForceSyncStatus.accepted = 0
        RedDKP_ForceSyncStatus.declined = 0

        for name in pairs(RedDKP_Config.addonUsers) do
            if name ~= me and UnitIsConnected(name) and UnitInGuild(name) then
                RedDKP_ForceSyncStatus.total = RedDKP_ForceSyncStatus.total + 1
                C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "FORCE_REQ:" .. me, "WHISPER", name)
            end
        end
        Print("Force sync request sent to " .. RedDKP_ForceSyncStatus.total .. " users.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDDKP_DELETE_PLAYER"] = {
    text = "Delete DKP record for %s?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, player)
        RedDKP_Data[player] = nil
        UpdateTable()

        local deleter = UnitName("player")

        LogAudit(player, "DELETE_PLAYER", "removed",
            string.format("Deleted by %s | Player removed: %s", deleter, player)
        )

        Print("Deleted DKP record for " .. player)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDDKP_FORCE_SYNC_RECEIVE"] = {
    text = "%s wants to force sync DKP data. Accept?",
    button1 = "Accept",
    button2 = "Decline",
    OnAccept = function(self, editor)
        C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "FORCE_ACCEPT:" .. UnitName("player"), "WHISPER", editor)
    end,
    OnCancel = function(self, editor)
        C_ChatInfo.SendAddonMessage(SYNC_PREFIX, "FORCE_DECLINE:" .. UnitName("player"), "WHISPER", editor)
        SafeSetSyncWarning("WARNING — You declined sync. Your data may be outdated.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDDKP_ON_TIME_CHECK"] = {
    text = "Allocate On-Time DKP to all raid members?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        if not IsRaidLeaderOrMasterLooter() then return end
        for i = 1, GetNumGroupMembers() do
            local name = GetRaidRosterInfo(i)
            if name then
                name = Ambiguate(name, "short")
                local d = EnsurePlayer(name)
                local old = d.onTime or 0
                local new = old + 5
				if new > 10 then
					new = 10
					Print("|cffff5555On-Time DKP cannot exceed 10 in a single DKP week. Value capped.|r")
				end

				d.onTime = new
                RecalcBalance(d)
                LogAudit(name, "onTime", old, d.onTime)
            end
        end
        UpdateTable()
        Print("On-Time DKP allocated.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDDKP_ALLOCATE_ATTENDANCE"] = {
    text = "Allocate Attendance DKP to all raid members?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        if not IsRaidLeaderOrMasterLooter() then return end
        for i = 1, GetNumGroupMembers() do
            local name = GetRaidRosterInfo(i)
            if name then
                name = Ambiguate(name, "short")
                local d = EnsurePlayer(name)
                local old = d.attendance or 0
                local new = old + 15
				if new > 30 then
					new = 30
					Print("|cffff5555Attendance DKP cannot exceed 30 in a single DKP week. Value capped.|r")
				end

				d.attendance = new
                RecalcBalance(d)
                LogAudit(name, "attendance", old, d.attendance)
            end
        end
        UpdateTable()
        Print("Attendance DKP allocated.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDDKP_NEW_WEEK"] = {
    text = "Start a new DKP week? This will move current totals into LastWeek.",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        for name, d in pairs(RedDKP_Data) do
            local oldBalance = d.balance or 0

            d.lastWeek   = oldBalance
            d.onTime     = 0
            d.attendance = 0
            d.bench      = 0
            d.spent      = 0
            d.balance    = 0

            LogAudit(name, "LastWeek", "their previous balance of "..oldBalance, "prepare for new week")
        end
        UpdateTable()
        Print("A new DKP week has begun.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDDKP_BROADCAST_DKP"] = {
    text = "Broadcast DKP table to the raid?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        if not IsInRaid() then
            Print("You must be in a raid to broadcast DKP.")
            return
        end

        SendChatMessage("Name (Current Balance)", "RAID")

        local names = {}
        for name in pairs(RedDKP_Data) do
            table.insert(names, name)
        end
        table.sort(names, function(a, b) return a > b end)

        BroadcastNext(names, 1)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- LibDBIcon Minimap Button
local LDB = LibStub("LibDataBroker-1.1"):NewDataObject("RedDKP", {
    type = "data source",
    text = "RedDKP",
    icon = "Interface\\AddOns\\RedDKP\\media\\RedDKP_Minimap64.png",

    OnClick = function(_, button)
        if not RedDKP_Enabled then
            print("|cffff5555RedDKP is disabled for your character as you are not in Redemption guild.|r")
            return
        end

        if button == "LeftButton" then
            if mainFrame:IsShown() then
                mainFrame:Hide()
            else
                mainFrame:Show()
                ShowTab(TAB_DKP)
            end

        elseif button == "RightButton" then
            mainFrame:Show()
            ShowTab(TAB_DKP)
        end
    end,

    OnTooltipShow = function(tt)
        tt:AddLine("RedDKP")
        tt:AddLine("|cff00ff00Left-click|r to open DKP")
    end,
})

local icon = LibStub("LibDBIcon-1.0")

local function EnsureMinimapConfig()
    if not RedDKP_Config.minimap then
        RedDKP_Config.minimap = { hide = false }
    end
end

function RedDKP_ResetMinimapButton()
    EnsureMinimapConfig()
    RedDKP_Config.minimap.minimapPos = 45
    icon:Refresh("RedDKP", RedDKP_Config.minimap)
    print("|cff00ff00RedDKP minimap icon reset.|r")
end

-- Unified event frame
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_GUILD_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")

C_ChatInfo.RegisterAddonMessagePrefix(SYNC_PREFIX)
C_ChatInfo.RegisterAddonMessagePrefix(EDITOR_PREFIX)
C_ChatInfo.RegisterAddonMessagePrefix(EDITOR_REQ_PREFIX)
C_ChatInfo.RegisterAddonMessagePrefix(VERSION_PREFIX)

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end

        EnsureSaved()
        EnsureMinimapConfig()

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
        icon:Register("RedDKP", LDB, RedDKP_Config.minimap)

        Print("Loaded.")
        return
    end

    if event == "PLAYER_LOGIN" then
        CheckGuildRestriction()

        C_Timer.After(3, function()
            if C_ChatInfo.SendAddonMessage then
                if IsInGuild() then
                    C_ChatInfo.SendAddonMessage(VERSION_PREFIX, REDDKP_VERSION, "GUILD")
                end
                if IsInRaid() then
                    C_ChatInfo.SendAddonMessage(VERSION_PREFIX, REDDKP_VERSION, "RAID")
                end
            end
        end)

        C_Timer.After(3, function()
            if IsEditor(UnitName("player")) then
                BroadcastEditorList()
            else
                C_ChatInfo.SendAddonMessage(EDITOR_REQ_PREFIX, "?", "GUILD")
            end
        end)

        C_Timer.After(5, function()
            UpdateOnlineEditors()
            AttemptAutoSync()
        end)

        return
    end

    if event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        CheckGuildRestriction()
        UpdateOnlineEditors()
        return
    end

    if event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = arg1, arg2, arg3, arg4
        if not msg or not sender then return end

        sender = Ambiguate(sender, "short")

        if prefix == SYNC_PREFIX then
            local cmd, data = msg:match("^(%w+):(.*)$")
            if not cmd then return end

            if cmd == "REQUEST" then
                HandleSyncRequest(data, sender, false)
                return
            end

            if cmd == "REQ_SYNC" then
                HandleSyncRequest(data, sender, true)
                return
            end

            if cmd == "REQ_ACCEPT" then
                HandleSyncResponse(sender, "REQ_ACCEPT")
                return
            end

            if cmd == "REQ_DECLINE" then
                HandleSyncResponse(sender, "REQ_DECLINE")
                return
            end

            if cmd == "FORCE_REQ" then
                StaticPopup_Show("REDDKP_FORCE_SYNC_RECEIVE", sender, nil, sender)
                return
            end

            if cmd == "FORCE_ACCEPT" then
                HandleSyncResponse(sender, "FORCE_ACCEPT")
                return
            end

            if cmd == "FORCE_DECLINE" then
                HandleSyncResponse(sender, "FORCE_DECLINE")
                return
            end

            if cmd == "DATA" then
                ApplySyncData(sender, data)
                return
            end

            return
        end

        if prefix == EDITOR_PREFIX or prefix == EDITOR_REQ_PREFIX then
            OnEditorAddonMessage(prefix, msg, channel, sender)
            return
        end
    end
end)

-- Slash Commands
SLASH_REDDKP1 = "/reddkp"
SlashCmdList["REDDKP"] = function(msg)
    msg = (msg or ""):lower():trim()

    if msg == "show" then
        mainFrame:Show()
        ShowTab(TAB_DKP)
        return
    end

    if msg == "hide" then
        mainFrame:Hide()
        return
    end

    if msg == "toggle" then
        if mainFrame:IsShown() then
            mainFrame:Hide()
        else
            mainFrame:Show()
            ShowTab(TAB_DKP)
        end
        return
    end

    if msg == "minimap" then
        RedDKP_ResetMinimapButton()
        return
    end

    if msg == "help" or msg == "" then
        print("|cffffd100RedDKP Commands:|r")
        print("|cff00ff00/reddkp show|r   - Open the DKP window")
        print("|cff00ff00/reddkp hide|r   - Hide the DKP window")
        print("|cff00ff00/reddkp toggle|r - Toggle the DKP window")
        print("|cff00ff00/reddkp minimap|r - Reset minimap icon position")
        print("|cff00ff00/reddkp help|r   - Show this help list")
        return
    end

    print("|cffff5555Unknown command. Use /reddkp help|r")
end