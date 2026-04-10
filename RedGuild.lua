-- RedGuild.lua
-- Distributed DKP system with editors, audit log, smart sync, and auto-sync for non-editors.
if ... ~= "RedGuild" then return end

RedGuild_Data   = RedGuild_Data   or {}
RedGuild_Config = RedGuild_Config or {}
RedGuild_Audit  = RedGuild_Audit  or {}
RedGuild_Usage  = RedGuild_Usage  or {}
RedGuild_ForceSyncStatus = {
    total = 0,
    accepted = 0,
    declined = 0,
}

local addonName      = ...
local REDGUILD_VERSION = "0.6.9"

local REDGUILD_CHAT_PREFIX = "REDGUILD"

RedGuild_Config.smartSync      = (RedGuild_Config.smartSync ~= false)
RedGuild_Config.addonUsers     = RedGuild_Config.addonUsers     or {}
RedGuild_Config.onlineEditors  = RedGuild_Config.onlineEditors  or {}
RedGuild_Config.authorizedEditors = RedGuild_Config.authorizedEditors or {}

RedGuild_Usage = RedGuild_Usage or {}
RedGuild_SyncLocked = true
RedGuild_LastSyncTime = RedGuild_LastSyncTime or "Never"
RedGuild_UIReady = false

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

local protectedInitialized = false

local syncWarning

local LibSerialize = LibStub("LibSerialize")
local LibDeflate   = LibStub("LibDeflate")

-- Ensure inbound chunk buffers exist
REDGUILD_Inbound = REDGUILD_Inbound or {
    DATA = {},
    EDITORSYNC = {},
}

--------------------------------------------------
-- DEBUGGING
--------------------------------------------------

RedGuild_Debug = false
local function D(msg)
    if RedGuild_Debug then
        print("|cff00ff00[RedGuild DEBUG]|r " .. msg)
    end
end

local function CountKeys(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end

--------------------------------------------------
-- Classic-family Compatibility Layer
--------------------------------------------------

function RedGuild_ConvertToRaid()
    if type(ConvertToRaid) == "function" then
        return ConvertToRaid()
    end

    if C_PartyInfo and type(C_PartyInfo.ConvertToRaid) == "function" then
        return C_PartyInfo.ConvertToRaid()
    end
end

function RedGuild_Invite(name)
    if type(InviteUnit) == "function" then
        return InviteUnit(name)
    end

    if C_PartyInfo and type(C_PartyInfo.InviteUnit) == "function" then
        return C_PartyInfo.InviteUnit(name)
    end
end

local function RedGuild_GetSyncChannelAndTarget(target)
    if RedGuild_Debug_UseGuildChannel then
        return "GUILD", nil
    else
        return "WHISPER", target
    end
end

--------------------------------------------------
-- Chunked whisper sender for sync traffic
--------------------------------------------------
local REDGUILD_MAX_CHUNK = 200  -- keep well under 255-byte whisper limit
local RedGuild_OutboundSeq = 0

function RedGuild_Send(msgType, payload, target)
    if not target or target == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[RedGuild SENDDBG]|r missing target for msgType="..tostring(msgType))
        return
    end

    payload = payload or ""

    -- Messages that are always small can still go as single packets
    if msgType ~= "DATA" and msgType ~= "EDITORSYNC" then
        local msg = string.format("%s:%s:%s", REDGUILD_CHAT_PREFIX, msgType, payload)
        SendChatMessage(msg, "WHISPER", nil, target)
        D(string.format("SEND %s -> %s (single)", msgType, target))
        return
    end

    -- Large payloads (DATA, EDITORSYNC) are chunked
    RedGuild_OutboundSeq = RedGuild_OutboundSeq + 1
    local seq = RedGuild_OutboundSeq

    local total = math.ceil(#payload / REDGUILD_MAX_CHUNK)
    if total == 0 then total = 1 end

    for i = 1, total do
    local startIdx = (i - 1) * REDGUILD_MAX_CHUNK + 1
    local chunk = payload:sub(startIdx, startIdx + REDGUILD_MAX_CHUNK - 1)

    local msg = string.format(
        "%s:%s:%d:%d:%d:%s",
        REDGUILD_CHAT_PREFIX,
        msgType,
        seq,
        i,
        total,   -- NEW FIELD
        chunk
    )

    SendChatMessage(msg, "WHISPER", nil, target)
    D(string.format("SEND %s seq=%d part=%d/%d to=%s len=%d",
        msgType, seq, i, total, target, #chunk))
end
end

function RedGuild_RequestRoster()
    if C_GuildInfo and type(C_GuildInfo.GuildRoster) == "function" then
        return C_GuildInfo.GuildRoster()
    end
end

--------------------------------------------------
-- Basic Helpers
--------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RedGuild]|r " .. tostring(msg))
end

local function EnsureSaved()
    RedGuild_Config.authorizedEditors = RedGuild_Config.authorizedEditors or {}
end

local function EnsureConfig()
    RedGuild_Config = RedGuild_Config or {}
    EnsureSaved()
    RedGuild_Config.editorListVersion = RedGuild_Config.editorListVersion or 0
end

local function EnsurePlayer(name)
    RedGuild_Data[name] = RedGuild_Data[name] or {
        lastWeek   = 0,
        onTime     = 0,
        attendance = 0,
        bench      = 0,
        spent      = 0,
        balance    = 0,
		rotated    = 0,
        class      = nil,
    }
	
	-- MIGRATION: convert old boolean rotated values
    if RedGuild_Data[name].rotated == false then
        RedGuild_Data[name].rotated = 0
    end
	
    return RedGuild_Data[name]
end

local function TablesEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end

    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    for k, v in pairs(b) do
        if a[k] ~= v then return false end
    end

    return true
end

--------------------------------------------------
-- Guild / Name Utilities
--------------------------------------------------

local function CheckGuildRestriction()
    local guildName = GetGuildInfo("player")

    if guildName == nil then
        return
    end

    if guildName ~= "Redemption" then
        print("|cffff5555RedGuild: You are not a member of the guild Redemption. Addon disabled.|r")
        RedGuild_Enabled = false
        if RedGuild_MainFrame then RedGuild_MainFrame:Hide() end
    else
        RedGuild_Enabled = true
    end
end

local function IsGuildOfficer()
	-- Note to myself... I changed this to only look for guild leader because it has the editors to fall back on
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex == 0
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

local function ShortName(name)
    if not name then return nil end
    return name:match("^[^-]+")
end

local function RecalcBalance(d)
    d.balance = (d.lastWeek or 0)
              + (d.onTime or 0)
              + (d.attendance or 0)
              + (d.bench or 0)
              - (d.spent or 0)
end

local function RecalculateAllBalances()
    for _, d in pairs(RedGuild_Data) do
        RecalcBalance(d)
    end
end

local function EnsureAddonUsers()
    RedGuild_Config.addonUsers = RedGuild_Config.addonUsers or {}
end

local function EnsureOnlineEditors()
    RedGuild_Config.onlineEditors = RedGuild_Config.onlineEditors or {}
end

function IsPlayerOnline(name)
    -- Check raid
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

    -- Check player
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

    return
end	

local function SafeSetSyncWarning(text)
    if syncWarning then
        syncWarning:SetText(text or "")
    end
end

local function GenerateAuditID()
    return tostring(time()) .. "-" .. math.random(100000, 999999)
end

local function ColorizeBalance(value)
    value = tonumber(value) or 0

    if value > 0 then
        return "|cff00ff00" .. value .. "|r"
    elseif value < 0 then
        return "|cffff0000" .. value .. "|r"
    else
        return tostring(value)
    end
end

local function NormalizeName(name)
    if not name then return nil end
    name = Ambiguate(name, "short")
    if not name or name == "" then return nil end
    return name:lower():gsub("%s+", "")
end

local function IsAuthorized()
    EnsureSaved()

D(string.format(
    "AUTH CHECK → player='%s' norm='%s' authorized=%s",
    tostring(UnitName("player")),
    tostring(NormalizeName(UnitName("player"))),
    tostring(RedGuild_Config.authorizedEditors[NormalizeName(UnitName("player"))])
))

    local player = NormalizeName(UnitName("player"))
    if not player then return false end

    local editors = RedGuild_Config.authorizedEditors
    if not editors then return false end

    return editors[player] and true or false
end

function IsEditor(name)
    if not name then
        name = UnitName("player")
    end

    local key = NormalizeName(name)
    if not key then return false end

    return RedGuild_Config.authorizedEditors
        and RedGuild_Config.authorizedEditors[key] == true
end

function LogAudit(player, field, old, new)
    if not RedGuild_Enabled then
        return
    end

    if RedGuild_Config.authorizedEditors and next(RedGuild_Config.authorizedEditors) then
        if not IsEditor(UnitName("player")) then
            return
        end
    end

    table.insert(RedGuild_Audit, {
        id     = GenerateAuditID(),
        time   = date("%Y-%m-%d %H:%M:%S"),
        editor = UnitName("player"),
        name   = player,
        field  = field,
        old    = old,
        new    = new,
    })
end

local function IsNameInGuild(name)
    if not IsInGuild() then
        return false
    end

    local total = GetNumGuildMembers()
    if total == 0 then
        -- Guild roster not ready yet: assume valid for now
        return true
    end

    for i = 1, total do
        local gName = GetGuildRosterInfo(i)
        if gName and Ambiguate(gName, "short") == name then
            return true
        end
    end

    return false
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

local function NameExists(newName, oldName)
    newName = strtrim(newName)

    if newName == "" then
        return false
    end

    local newLower = strlower(newName)

    for name, d in pairs(RedGuild_Data) do
        if type(name) == "string" then
            local trimmed = strtrim(name)
            if trimmed ~= "" then
                if trimmed ~= oldName then
                    if not d.invalid then
                        if strlower(trimmed) == newLower then
                            return true
                        end
                    end
                end
            end
        end
    end

    return false
end

local function UsedToday(key)
    local player = UnitName("player")
    RedGuild_Usage[player] = RedGuild_Usage[player] or {}
    return RedGuild_Usage[player][key] == date("%Y-%m-%d")
end

local function MarkUsedToday(key)
    local player = UnitName("player")
    RedGuild_Usage[player] = RedGuild_Usage[player] or {}
    RedGuild_Usage[player][key] = date("%Y-%m-%d")
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

local function BroadcastNext(names, index)
    if index > #names then
        Print("DKP table broadcast to raid.")
        return
    end

    local name = names[index]
    local d = EnsurePlayer(name)
    local msg = string.format("%-12s (%d)", name, d.balance or 0)

    SendChatMessage(msg, "RAID")

    C_Timer.After(0.15, function()
        BroadcastNext(names, index + 1)
    end)
end

local function MarkAddonUserOnline(name)
    EnsureAddonUsers()
    local key = NormalizeName(name)
    if not key then return end
    RedGuild_Config.addonUsers[key] = true
end

local function ClearOfflineAddonUsers()
    EnsureAddonUsers()
    for name in pairs(RedGuild_Config.addonUsers) do
        if not IsPlayerOnline(name) then
            RedGuild_Config.addonUsers[name] = nil
        end
    end
end

local function EnsureProtectedEditor()
    RedGuild_Config.authorizedEditors = RedGuild_Config.authorizedEditors or {}

    -- Try to get the real guild leader
    local guildLeader = ShortName(GetGuildLeader())
    if guildLeader then
        local key = NormalizeName(guildLeader)
        if key then
            RedGuild_Config.authorizedEditors[key] = true
            RedGuild_Config.protectedEditor = key
        end
        return
    end

    -- If guild leader cannot be determined, DO NOTHING.
    -- Do NOT auto-add anyone else.
end

--------------------------------------------------------------------
-- UPDATE ONLINE EDITORS + VERSION NEGOTIATION
--------------------------------------------------------------------

local function GetHighestRankEditor()
    D("GetHighestRankEditor called")
    EnsureOnlineEditors()

    local bestName = nil
    local bestRank = 99

    for short, info in pairs(RedGuild_Config.onlineEditors) do
        local realName = info.name
        local rankIndex = info.rankIndex or 99

        if rankIndex < bestRank then
            bestRank = rankIndex
            bestName = realName
        end
    end

    D("Highest rank editor = " .. tostring(bestName))
    return bestName
end

local function UpdateOnlineEditors()
    if not IsInGuild() then return end

    local total = GetNumGuildMembers()
    if total == 0 then
        C_Timer.After(1, UpdateOnlineEditors)
        return
    end

    RedGuild_Config.onlineEditors = {}

    for i = 1, total do
        local name, _, rankIndex, _, _, _, _, _, online = GetGuildRosterInfo(i)
        if name then
            local real = Ambiguate(name, "short")
            local key  = NormalizeName(real)

            if RedGuild_Config.authorizedEditors[key] and online then
                RedGuild_Config.onlineEditors[key] = {
                    name = real,
                    rankIndex = rankIndex
                }
            end
        end
    end

    ---------------------------------------------------------
    -- RULE 1: Users request editor list from highest‑rank editor
    ---------------------------------------------------------
    local me = NormalizeName(UnitName("player"))
    if not IsAuthorized() then
        local best = GetHighestRankEditor()
        if best then
            D("EDITOR SYNC → User requesting editor list from " .. best)
            RedGuild_Send("EDITORREQ", me, best)
        end
        return
    end

    ---------------------------------------------------------
    -- RULE 2: Editors request lists from other editors
    ---------------------------------------------------------
    local myVersion = RedGuild_Config.editorListVersion or 0

    for key, info in pairs(RedGuild_Config.onlineEditors) do
        if key ~= me and RedGuild_Config.addonUsers[key] then
            D("EDITOR SYNC → Editor requesting list from " .. info.name)
            RedGuild_Send("EDITORREQ", me, info.name)
        end
    end
end

local function DebugSync(prefix, direction, sender, msg)
    print("|cff00ff00[SYNC-DEBUG]|r",
        direction,
        prefix,
        sender or "",
        msg or "")
end

local function RedGuild_ChatFilter(self, event, msg, sender, ...)
    if type(msg) == "string" and msg:find("^" .. REDGUILD_CHAT_PREFIX .. ":") then
        return true -- suppress from all visible chat frames
    end
    return false
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", RedGuild_ChatFilter)
ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", RedGuild_ChatFilter)

local tabs = {}

local function CreateTab(index, text)
    local tab = CreateFrame("Button", addonName.."Tab"..index, mainFrame, "CharacterFrameTabButtonTemplate")
    tab:SetID(index)
    tab:SetText(text)
    PanelTemplates_TabResize(tab, 0)

    tab:SetScript("OnClick", function(self)
        ShowTab(self:GetID())
    end)

    tabs[index] = tab
end

local function RealignTabs()
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
    { text = "Name",       width = 80 },
	{ text = "MS",         width = 30  },
    { text = "OS",         width = 40  },
    { text = "LastWeek",   width = 65  },
    { text = "OnTime",     width = 65  },
    { text = "Attend",     width = 70  },
    { text = "Bench",      width = 55  },
    { text = "Spent",      width = 55  },
    { text = "Balance",    width = 65  },
	{ text = "Rotations",  width = 55  },
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

local ROLE_ICONS = {
    { key = nil,      icon = "Interface\\Icons\\INV_Misc_QuestionMark" },
    { key = "tank",   icon = "Interface\\Icons\\Ability_Defend" },
    { key = "melee",  icon = "Interface\\Icons\\Ability_BackStab" },
    { key = "ranged", icon = "Interface\\Icons\\Ability_Hunter_SniperShot" },
    { key = "caster", icon = "Interface\\Icons\\Spell_Frost_FrostBolt02" },
    { key = "healer", icon = "Interface\\Icons\\Spell_Holy_HolyBolt" },
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

    -- Reset all row indexes to avoid stale references
    for i = 1, #rows do
        rows[i].index = nil
    end

    ----------------------------------------------------------------
    -- GUILD VALIDATION HELPER
    ----------------------------------------------------------------
    local function IsNameInGuild(name)
        if not IsInGuild() then return false end
        for i = 1, GetNumGuildMembers() do
            local gName = GetGuildRosterInfo(i)
            if gName and Ambiguate(gName, "short") == name then
                return true
            end
        end
        return false
    end

    ----------------------------------------------------------------
    -- BUILD SORT LIST + VALIDATE DKP ENTRIES
    ----------------------------------------------------------------
    for name, d in pairs(RedGuild_Data) do

        ------------------------------------------------------------
        -- VALIDATE GUILD MEMBERSHIP
        ------------------------------------------------------------
        if not IsNameInGuild(name) then
            d.note = "(check name)"
            d.invalid = true
        else
            d.invalid = false
        end

        ------------------------------------------------------------
        -- FILTER OUT INVALID OR CORRUPTED KEYS
        ------------------------------------------------------------
        if not d.invalid and type(name) == "string" then
            local trimmed = strtrim(name)
            if trimmed ~= "" then
                table.insert(sortedNames, trimmed)
            end
        end
    end

    ----------------------------------------------------------------
    -- CLEAN SORTED NAMES (remove any nil / non-string / empty)
    ----------------------------------------------------------------
    do
        local cleaned = {}
        for _, name in ipairs(sortedNames) do
            if type(name) == "string" then
                local trimmed = strtrim(name)
                if trimmed ~= "" then
                    table.insert(cleaned, trimmed)
                end
            end
        end
        sortedNames = cleaned
    end

    ----------------------------------------------------------------
    -- SORTING (NIL-SAFE)
    ----------------------------------------------------------------
    if currentSortField == "name" then

        -- Simple alphabetical sort
        table.sort(sortedNames, function(a, b)
            if currentSortAscending then
                return a < b
            else
                return a > b
            end
        end)

    else

        table.sort(sortedNames, function(a, b)
            if not a or not b then return false end

            local da = RedGuild_Data[a] or {}
            local db = RedGuild_Data[b] or {}

            local field = currentSortField
            local va, vb

            -- ROLE SORT (string)
            if field == "msRole" or field == "osRole" then
                va = tostring(da[field] or "")
                vb = tostring(db[field] or "")

            -- ROTATED SORT (boolean)
            elseif field == "rotated" then
				va = tonumber(da.rotated) or 0
				vb = tonumber(db.rotated) or 0

            -- NUMERIC SORT (default)
            else
                va = tonumber(da[field]) or 0
                vb = tonumber(db[field]) or 0
            end

            -- Primary comparison
            if va ~= vb then
                if currentSortAscending then
                    return va < vb
                else
                    return va > vb
                end
            end

            -- Tie-breaker: name
            return a < b
        end)

    end

    ----------------------------------------------------------------
    -- RENDER ROWS
    ----------------------------------------------------------------
    for i = 1, #rows do
        local row  = rows[i]
        local name = sortedNames[i]

        if not name then

            row:Hide()

        else

            local d = RedGuild_Data[name]
            row.index = i

            RecalcBalance(d)

            local classColor = "|cffffffff"
            if d.class then
                local c = RAID_CLASS_COLORS[d.class]
                if c then
                    classColor = string.format("|cff%02x%02x%02x",
                        c.r * 255, c.g * 255, c.b * 255)
                end
            end

            local displayName = name
            if d.invalid then
                displayName = displayName .. " |cffff0000(check name)|r"
            end

            -- NAME
            row.cols[1]:SetText(classColor .. displayName .. "|r")

            -- MS ROLE ICON
            do
                local role = d.msRole
                local icon = nil
                for _, r in ipairs(ROLE_ICONS) do
                    if r.key == role then
                        icon = r.icon
                        break
                    end
                end
                row.cols[2].icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            end

            -- OS ROLE ICON
            do
                local role = d.osRole
                local icon = nil
                for _, r in ipairs(ROLE_ICONS) do
                    if r.key == role then
                        icon = r.icon
                        break
                    end
                end
                row.cols[3].icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            end

            -- NUMERIC FIELDS
            row.cols[4]:SetText(d.lastWeek or 0)
            row.cols[5]:SetText(d.onTime or 0)
            row.cols[6]:SetText(d.attendance or 0)
            row.cols[7]:SetText(d.bench or 0)
            row.cols[8]:SetText(d.spent or 0)
            row.cols[9]:SetText(ColorizeBalance(d.balance))

            -- ROTATED
            local rot = tonumber(d.rotated) or 0
			row.cols[10]:SetText(rot)
        end
    end

    ----------------------------------------------------------------
    -- SCROLL HEIGHT
    ----------------------------------------------------------------
    local visibleRows = #sortedNames
    local rowHeight   = 18

    if scroll and scrollChild then
        scrollChild:SetHeight(visibleRows * rowHeight)

        C_Timer.After(0, function()
            if scroll.ScrollBar then
                local sb = scroll.ScrollBar
                local maxScroll = scroll:GetVerticalScrollRange()
                if maxScroll > 0 then sb:Show() else sb:Hide() end
            end
        end)
    end
end

local function UpdateAuditLog()
    if not auditRows or not RedGuild_Audit then return end

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

--------------------------------------------------------------------
-- BROADCAST EDITOR LIST TO A SINGLE TARGET
--------------------------------------------------------------------
local function BroadcastEditorListTo(target)
    EnsureConfig()

    local key = NormalizeName(target)
    if not key then return end

    ---------------------------------------------------------
    -- RULE 4: Only send to addon users AND only if online
    ---------------------------------------------------------
    if not RedGuild_Config.addonUsers[key] then
        D("EDITOR SYNC → Skipping " .. target .. " (not addon user)")
        return
    end

    if not IsPlayerOnline(target) then
        D("EDITOR SYNC → Skipping " .. target .. " (offline)")
        return
    end

    local payload = {
        editors = RedGuild_Config.authorizedEditors,
        version = RedGuild_Config.editorListVersion or 0,
    }

    local serialized  = LibSerialize:Serialize(payload)
    local compressed  = LibDeflate:CompressDeflate(serialized)
    local encoded     = LibDeflate:EncodeForPrint(compressed)

    D("EDITOR SYNC → Sending version " .. tostring(payload.version) .. " to " .. tostring(target))
    RedGuild_Send("EDITORSYNC", encoded, target)
end

--------------------------------------------------------------------
-- APPLY EDITOR LIST (version‑aware, protected, user‑safe)
--------------------------------------------------------------------
local function ApplyEditorList(payload)
    D("EDITOR SYNC → ApplyEditorList called")

    if type(payload) ~= "table" or type(payload.editors) ~= "table" then
        D("EDITOR SYNC ERROR: payload invalid")
        return
    end

    local incomingEditors = payload.editors
    local incomingVersion = tonumber(payload.version) or 0

    local localEditors  = RedGuild_Config.authorizedEditors or {}
    local localVersion  = tonumber(RedGuild_Config.editorListVersion or 0)

    D("EDITOR SYNC → Incoming version=" .. tostring(incomingVersion))
    D("EDITOR SYNC → Local version=" .. tostring(localVersion))

    ---------------------------------------------------------
    -- RULE 2: Editors only accept higher‑version lists
    ---------------------------------------------------------
    if incomingVersion <= localVersion then
        D("EDITOR SYNC → Incoming version not newer — ignored")
        return
    end

    ---------------------------------------------------------
    -- RULE 3: Guild leader is protected and cannot be removed
    ---------------------------------------------------------
    local protected = RedGuild_Config.protectedEditor
    if protected then
        incomingEditors[protected] = true
    end

    ---------------------------------------------------------
    -- Apply new list
    ---------------------------------------------------------
    RedGuild_Config.authorizedEditors = incomingEditors
    RedGuild_Config.editorListVersion = incomingVersion

    D("EDITOR SYNC → Applied new editor list (version " .. incomingVersion .. ")")

    UpdateOnlineEditors()
    RefreshEditorList()
end

local function OnEditorAddonMessage(prefix, message, channel, sender)
    D("EditorAddonMessage prefix="..tostring(prefix).." sender="..tostring(sender))

    sender = Ambiguate(sender or "", "short")
    local senderKey = NormalizeName(sender)

    -- EDITORSYNC: incoming editor list
    if prefix == EDITOR_PREFIX then
        if message:sub(1, 12) == "EDITORSYNC:" then
            local encoded = message:sub(13)

            local decoded = LibDeflate:DecodeForPrint(encoded)
            if not decoded then return end

            local decompressed = LibDeflate:DecompressDeflate(decoded)
            if not decompressed then return end

            local ok, payload = LibSerialize:Deserialize(decompressed)
            if not ok or type(payload) ~= "table" then return end

            D("Received EDITORSYNC payload from "..sender)

            ApplyEditorList(payload)
            UpdateOnlineEditors()
        end
        return
    end

    -- EDITOR_REQ_PREFIX: someone is asking for the editor list
    if prefix == EDITOR_REQ_PREFIX then
        if IsAuthorized() or IsGuildOfficer() then
            D("Received EDITOR REQ from "..sender.." — broadcasting list")
            BroadcastEditorList()
        end
        return
    end
end

local function RefreshEditorList()
    D("EDITOR SYNC → RefreshEditorList() called")
    EnsureSaved()

    if not editorRows or not editorRows[1] then
        D("EDITOR SYNC → No editorRows available, aborting")
        return
    end

    -- Determine protected editor (normalized key)
    local protectedKey = RedGuild_Config.protectedEditor
    D("EDITOR SYNC → Protected editor key = " .. tostring(protectedKey))

    -- Build a set of unique short names
    local nameSet = {}
    local totalEditors = 0

    for key in pairs(RedGuild_Config.authorizedEditors) do
        totalEditors = totalEditors + 1
        local short = ShortName(key)
        if short and short ~= "" then
            nameSet[short] = true
        end
    end

    D("EDITOR SYNC → AuthorizedEditors count = " .. tostring(totalEditors))
    D("EDITOR SYNC → Unique short names = " .. tostring(CountKeys(nameSet)))

    -- Convert to sorted list of objects
    local names = {}
    for short in pairs(nameSet) do
        table.insert(names, { name = short })
    end

    table.sort(names, function(a, b)
        return a.name < b.name
    end)

    D("EDITOR SYNC → Sorted editor list:")
    for i, entry in ipairs(names) do
        D("   [" .. i .. "] " .. tostring(entry.name))
    end

    -- Populate UI rows
    for i = 1, #editorRows do
        local row = editorRows[i]
        local entry = names[i]

        if entry then
            local name = entry.name
            row.name = name

            -- Normalized key for comparison
            local key = NormalizeName(name)

            if key == protectedKey then
                row.text:SetText("|cffffd700" .. name .. "|r")
                row.isProtected = true
                D("EDITOR SYNC → Row " .. i .. " = PROTECTED " .. name)
            else
                row.text:SetText(name)
                row.isProtected = false
                D("EDITOR SYNC → Row " .. i .. " = " .. name)
            end

            row:Show()
        else
            row.name = nil
            row.text:SetText("")
            row.isProtected = false
            row:Hide()
            D("EDITOR SYNC → Row " .. i .. " hidden (no entry)")
        end
    end
end

local function CreateUI()
    --------------------------------------------------------------------
    -- MAIN FRAME
    --------------------------------------------------------------------
    mainFrame = CreateFrame("Frame", "RedGuildFrame", UIParent, "BasicFrameTemplateWithInset")
    mainFrame:SetSize(800, 500)
    mainFrame:SetPoint("CENTER")
    mainFrame:Hide()

    local headerIcon = mainFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    headerIcon:SetTexture("Interface\\AddOns\\RedGuild\\media\\RedGuild_Icon256.png")
    headerIcon:SetSize(128, 128)
    headerIcon:SetPoint("TOP", mainFrame, "LEFT", 20, 290)

    mainFrame.title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    mainFrame.title:SetPoint("CENTER", mainFrame.TitleBg, "CENTER", 0, 0)
    mainFrame.title:SetText("Redemption Guild UI - brought to you by a clueless idiot called Lunátic")

    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)
    table.insert(UISpecialFrames, "RedGuildFrame")

    --------------------------------------------------------------------
    -- TABS
    --------------------------------------------------------------------
    CreateTab(TAB_DKP,   "DKP")
    CreateTab(TAB_GROUP, "Group Builder")
    if IsEditor(UnitName("player")) then
        CreateTab(TAB_RAID,    "RL Tools")
        CreateTab(TAB_EDITORS, "Editors")
        CreateTab(TAB_AUDIT,   "Audit Log")
    end
	RealignTabs()
    --------------------------------------------------------------------
    -- PANELS
    --------------------------------------------------------------------
    dkpPanel     = CreateFrame("Frame", nil, mainFrame); LayoutPanel(dkpPanel)
	-- Clicking anywhere on the DKP panel commits inline edits
	dkpPanel:EnableMouse(true)
	dkpPanel:SetPropagateMouseClicks(true)
	dkpPanel:SetScript("OnMouseDown", function()
		if inlineEdit and inlineEdit:IsShown() then
			inlineEdit.cancelled = false
			if inlineEdit.saveFunc then
				inlineEdit.saveFunc(inlineEdit:GetText())
			end
			inlineEdit:Hide()
		end
	end)
	
    groupPanel   = CreateFrame("Frame", nil, mainFrame); LayoutPanel(groupPanel)
    raidPanel    = CreateFrame("Frame", nil, mainFrame); LayoutPanel(raidPanel)
    editorsPanel = CreateFrame("Frame", nil, mainFrame); LayoutPanel(editorsPanel)
    auditPanel   = CreateFrame("Frame", nil, mainFrame); LayoutPanel(auditPanel)
	
--------------------------------------------------------------------
-- GROUP BUILDER PANEL
--------------------------------------------------------------------
    selectedState = selectedState or {}
do
    local title = groupPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 30, -30)
    title:SetText("")

------------------------------------------------------------
-- LEFT SIDE: SCROLL LIST (HALF WIDTH)
------------------------------------------------------------
local scroll = CreateFrame("ScrollFrame", nil, groupPanel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", groupPanel, "TOPLEFT", 30, -60)
scroll:SetPoint("BOTTOMLEFT", groupPanel, "BOTTOMLEFT", 30, 50)
scroll:SetWidth(groupPanel:GetWidth() * 0.40)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(1, 1)
scroll:SetScrollChild(content)

local ROW_HEIGHT = 20
groupRows = {}


------------------------------------------------------------
-- RIGHT SIDE: INFO BOX (INDEPENDENT)
------------------------------------------------------------
local infoBox = CreateFrame("Frame", nil, groupPanel, "BackdropTemplate")
infoBox:SetPoint("TOPRIGHT", groupPanel, "TOPRIGHT", -30, -60)
infoBox:SetPoint("BOTTOMRIGHT", groupPanel, "BOTTOMRIGHT", -30, 50)
infoBox:SetWidth(groupPanel:GetWidth() * 0.45)

infoBox:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
infoBox:SetBackdropColor(0, 0, 0, 0.6)

local infoText = infoBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
infoText:SetPoint("TOPLEFT", 10, -10)
infoText:SetJustifyH("LEFT")
infoText:SetWidth(infoBox:GetWidth() - 20)
infoText:SetText("No players selected.")

    ------------------------------------------------------------
    -- CLASS COLOUR LOOKUP
    ------------------------------------------------------------
    local CLASS_COLORS = {}
    for class, c in pairs(RAID_CLASS_COLORS) do
        CLASS_COLORS[class] = string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end

    ------------------------------------------------------------
    -- INFO BOX UPDATE FUNCTION
    ------------------------------------------------------------
    local function UpdateGroupBuilderInfo()
        local selected = {}
        local classCounts = {}
        local roleCounts = {
            tank = 0,
            melee = 0,
			ranged = 0,
            caster = 0,
            healer = 0,
			unknown = 0,
        }

        for _, row in ipairs(groupRows) do
            if row:IsShown() and row.checkbox:GetChecked() then
                table.insert(selected, row.name)

                local class = RedGuild_Data[row.name].class
				classCounts[class] = (classCounts[class] or 0) + 1

				-- MAIN SPEC ROLE ONLY
				local role = RedGuild_Data[row.name].msRole

				if role == "tank" then
				roleCounts.tank = roleCounts.tank + 1

				elseif role == "melee" then
				roleCounts.melee = roleCounts.melee + 1

				elseif role == "ranged" then
				roleCounts.ranged = roleCounts.ranged + 1

				elseif role == "caster" then
				roleCounts.caster = roleCounts.caster + 1

				elseif role == "healer" then
				roleCounts.healer = roleCounts.healer + 1

				else
					roleCounts.unknown = roleCounts.unknown + 1
				end
            end
        end

        local lines = {}

        table.insert(lines, string.format("Selected: |cffffff00%d|r", #selected))

        table.insert(lines, "")
        table.insert(lines, "Classes:")
        for class, count in pairs(classCounts) do
            local c = RAID_CLASS_COLORS[class]
            if c then
                local hex = string.format("|cff%02x%02x%02x", c.r*255, c.g*255, c.b*255)
                table.insert(lines, string.format("  %s%s|r: %d", hex, class, count))
            else
                table.insert(lines, string.format("  %s: %d", class, count))
            end
        end

        table.insert(lines, "")
        table.insert(lines, "Roles:")
        table.insert(lines, string.format("  Tanks: %d", roleCounts.tank))
        table.insert(lines, string.format("  Melee DPS: %d", roleCounts.melee))
		table.insert(lines, string.format("  Ranged DPS: %d", roleCounts.ranged))
        table.insert(lines, string.format("  Caster DPS: %d", roleCounts.caster))
        table.insert(lines, string.format("  Healers: %d", roleCounts.healer))
		table.insert(lines, string.format("  Unknown: %d", roleCounts.unknown))

        infoText:SetText(table.concat(lines, "\n"))
		infoText:SetText(infoText:GetText() .. "\n\n|cffff3333Roles counted are MAIN spec only.|r")
    end

------------------------------------------------------------
-- REFRESH LIST 
------------------------------------------------------------
local function RefreshGroupBuilder()
    for _, row in ipairs(groupRows) do
        row:Hide()
    end
    wipe(groupRows)

    local names = {}
    for name in pairs(RedGuild_Data) do
        table.insert(names, name)
    end
    table.sort(names)

    local i = 0
    for _, name in ipairs(names) do

        --------------------------------------------------------
        -- SKIP INVALID DKP ENTRIES
        --------------------------------------------------------
        if not RedGuild_Data[name].invalid then

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

                cb:SetScript("OnClick", function(self)
                    if row.name then
                        selectedState[row.name] = self:GetChecked() or false
                    end
                    UpdateGroupBuilderInfo()
                end)

                groupRows[i] = row
            end

            row:SetPoint("TOPLEFT", 10, -(i - 1) * ROW_HEIGHT)
            row.name = name

            local class = RedGuild_Data[name].class
            local colour = CLASS_COLORS[class] or "|cffffffff"

            local online = IsPlayerOnline(name)
            local offlineText = online and "" or " |cffaaaaaa(offline)|r"

            row.nameFS:SetText(colour .. name .. "|r" .. offlineText)

            -- Restore previous selection state (default false)
            row.checkbox:SetChecked(selectedState[name] or false)

            row:Show()
        end
    end

    content:SetHeight(i * ROW_HEIGHT)
    UpdateGroupBuilderInfo()
end

    ------------------------------------------------------------
    -- 10-SECOND ONLINE SCAN
    ------------------------------------------------------------
    local scanTicker = nil
    local function StartOnlineScan()
        if not scanTicker then
            scanTicker = C_Timer.NewTicker(10, RefreshGroupBuilder)
        end
    end
    local function StopOnlineScan()
        if scanTicker then
            scanTicker:Cancel()
            scanTicker = nil
        end
    end

    ------------------------------------------------------------
    -- INVITE BUTTON (NO AUTO-UNTICK)
    ------------------------------------------------------------
local inviteBtn = CreateFrame("Button", nil, groupPanel, "UIPanelButtonTemplate")
inviteBtn:SetSize(140, 24)
inviteBtn:SetText("Invite to Group")
inviteBtn:SetPoint("BOTTOMRIGHT", groupPanel, "BOTTOMRIGHT", -10, 10)

inviteBtn:SetScript("OnClick", function()
    local pending = {}
    local playerName = Ambiguate(UnitName("player"), "short")

    -- Build list of players to invite
    for _, row in ipairs(groupRows) do
        if row:IsShown() and row.checkbox:GetChecked() then
            local name = row.name
            if name ~= playerName and not UnitInParty(name) and not UnitInRaid(name) then
                table.insert(pending, name)
            end
        end
    end

    if #pending == 0 then
        Print("No players selected.")
        return
    end

    local function InviteAllOnce()
        for _, name in ipairs(pending) do
            RedGuild_Invite(name)
        end
    end

    -- If not already in a raid, convert first, then invite
    if not IsInRaid() then
        RedGuild_ConvertToRaid()
        C_Timer.After(1.5, InviteAllOnce)
    else
        InviteAllOnce()
    end
end)

    ------------------------------------------------------------
    -- INFO TEXT (BOTTOM LEFT)
    ------------------------------------------------------------
    local info = groupPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("BOTTOMLEFT", groupPanel, "BOTTOMLEFT", 10, 10)
    info:SetJustifyH("LEFT")
    info:SetText("|cffaaaaaa*This list is populated from the DKP table and scans every 10 seconds (with the tab open) to check who's online.|r")

    ------------------------------------------------------------
    -- PANEL SHOW/HIDE
    ------------------------------------------------------------
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
            StaticPopup_Show("REDGUILD_ON_TIME_CHECK")
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
            StaticPopup_Show("REDGUILD_ALLOCATE_ATTENDANCE")
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
            StaticPopup_Show("REDGUILD_NEW_WEEK")
        end)

        local broadcastBtn = CreateFrame("Button", nil, raidPanel, "UIPanelButtonTemplate")
        broadcastBtn:SetSize(220, 30)
        broadcastBtn:SetPoint("BOTTOM", raidPanel, "BOTTOM", 0, 10)
        broadcastBtn:SetText("Broadcast DKP Table to Raid")
        broadcastBtn:SetScript("OnClick", function()
            StaticPopup_Show("REDGUILD_BROADCAST_DKP")
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

    -- Highlight texture
    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(0.2, 0.4, 1, 0.3)
    hl:Hide()
    row.highlight = hl

    -- Text label
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", 2, 0)
    fs:SetJustifyH("LEFT")
    row.text = fs

    -- Click handler
    row:SetScript("OnClick", function(self)
        editorsPanel.selectedEditor = self.name

        -- Clear all highlights
        for _, r in ipairs(editorRows) do
            if r.highlight then
                r.highlight:Hide()
            end
        end

        -- Highlight this row if it has a name
        if self.name then
            self.highlight:Show()
        end
    end)

    -- Store row
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
                Print("Only guild leader or editors can add to the editor list.")
                return
            end
            local raw = addBox:GetText()
			local key = NormalizeName(raw)
			if not key then return end
			EnsureSaved()
			RedGuild_Config.authorizedEditors[key] = true
            RedGuild_Config.editorListVersion = (RedGuild_Config.editorListVersion or 0) + 1
            addBox:SetText("")
            RefreshEditorList()
			-- Broadcast to all known addon users
			local me = NormalizeName(UnitName("player"))
for name in pairs(RedGuild_Config.addonUsers) do
    if name ~= me and IsPlayerOnline(name) then
        BroadcastEditorListTo(name)
        D("Broadcasting editor list to " .. tostring(name))
    end
end
        end)

        removeBtn:SetScript("OnClick", function()
            if not (IsGuildOfficer() or IsEditor(UnitName("player"))) then
                Print("Only guild leader can remove from the editor list.")
                return
            end

            local display = editorsPanel.selectedEditor
			if not display then return end

			local key = NormalizeName(display)
			if not key then return end

			RedGuild_Config.authorizedEditors[key] = nil
            RedGuild_Config.editorListVersion = (RedGuild_Config.editorListVersion or 0) + 1
            editorsPanel.selectedEditor = nil
            RefreshEditorList()
			-- Broadcast to all known addon users
			local me = NormalizeName(UnitName("player"))
for name in pairs(RedGuild_Config.addonUsers) do
    if name ~= me and IsPlayerOnline(name) then
        BroadcastEditorListTo(name)
        D("Broadcasting editor list to " .. tostring(name))
    end
end
        end)

        editorsPanel:SetScript("OnShow", function()
            C_Timer.After(0.05, RefreshEditorList)
            
			local canEditEditors = IsGuildOfficer() or IsEditor(UnitName("player"))

    if not canEditEditors then
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

------------------------------------------------------------
-- DKP FOOTER INFO LINE (small + grey)
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
		row:SetFrameLevel(1)
        row:SetSize(1, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.15)
		bg:SetDrawLayer("BACKGROUND", 0)
        row.bg = bg

        local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        delBtn:SetSize(15, 15)
        delBtn:SetPoint("LEFT", row, "LEFT", 2, 0)
        delBtn:SetText("x")
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

            elseif field == "msRole" or field == "osRole" then
				local btn = CreateFrame("Button", nil, row)
				btn:SetPoint("LEFT", row, "LEFT", colX, 0)
				btn:SetSize(16, 16) 

                btn.icon = btn:CreateTexture(nil, "ARTWORK")
				btn.icon:SetSize(16, 16)
                btn.icon:SetAllPoints()
				btn.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

                row.cols[j] = btn

elseif field == "rotated" then
    local btn = CreateFrame("Button", nil, row)
    btn:SetPoint("LEFT", row, "LEFT", colX, 0)
    btn:SetSize(h.width, ROW_HEIGHT)

    -- Create a proper text region
    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetAllPoints(btn)
    fs:SetJustifyH("LEFT")
    btn:SetFontString(fs)

    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    btn:GetHighlightTexture():SetAlpha(0.3)

    row.cols[j] = btn

    btn:SetScript("OnMouseDown", function(self, button)
        if not IsAuthorized() then return end

        local rowIndex = row.index
        if not rowIndex then return end

        local name = sortedNames[rowIndex]
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
            StaticPopup_Show("REDGUILD_DELETE_PLAYER", player, nil, player)
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
                    local d = RedGuild_Data[player]
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



            elseif field == "msRole" or field == "osRole" then
                col:SetScript("OnClick", function()
                    if not IsAuthorized() then return end

                    local player = sortedNames[row.index]
                    if not player then return end

                    local d = EnsurePlayer(player)

                    -- Determine current index
                    local current = 1
                    for i, role in ipairs(ROLE_ICONS) do
                        if role.key == d[field] then
                            current = i
                            break
                        end
                    end

                    -- Next role
                    current = current + 1
                    if current > #ROLE_ICONS then current = 1 end

                    d[field] = ROLE_ICONS[current].key
                    col.icon:SetTexture(ROLE_ICONS[current].icon)

                    LogAudit(player, field, "changed", d[field] or "none")
                    UpdateTable()
                end)

            elseif field ~= "rotated" then
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

                            local oldName = playerName
                            if NameExists(newName, oldName) then
                                Print("|cffff5555A player with that name already exists.|r")
                                return
                            end

                            RedGuild_Data[newName] = RedGuild_Data[playerName]
                            RedGuild_Data[playerName] = nil

                            local _, class = UnitClass(newName)
                            if class then
                                RedGuild_Data[newName].class = class
                            elseif IsInGuild() then
                                for i = 1, GetNumGuildMembers() do
                                    local gName, _, _, _, _, _, _, _, _, _, gClass = GetGuildRosterInfo(i)
                                    if gName and Ambiguate(gName, "short") == newName then
                                        RedGuild_Data[newName].class = gClass
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
                        local dkp = RedGuild_Data[playerName]
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
            for existingName in pairs(RedGuild_Data) do
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
    EnsureSaved()
    EnsureOnlineEditors()
    UpdateOnlineEditors()

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

    local bestEditor = GetHighestRankEditor()
    if not bestEditor then
        Print("No editor online — cannot request sync.")
        return
    end

    RedGuild_Send("REQUEST", meReal, bestEditor)
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
            StaticPopup_Show("REDGUILD_FORCE_SYNC_CONFIRM")
        end)
    end

    --------------------------------------------------------------------
    -- FINALIZE
    --------------------------------------------------------------------
    RecalculateAllBalances()

-- Only build the table immediately if the guild roster looks sane
if IsInGuild() and GetNumGuildMembers() > 0 then
    D("CreateUI: guild roster ready, calling UpdateTable immediately")
    UpdateTable()
else
    D("CreateUI: guild roster not ready, deferring first UpdateTable")
end

if RedGuild_DKPFooter then
    local count = 0
    for _ in pairs(RedGuild_Config.onlineEditors or {}) do count = count + 1 end
    RedGuild_DKPFooter:SetText(
        string.format("RedGuild v%s  |  Editors Online: %d  |  Last Sync: %s",
            REDGUILD_VERSION, count, RedGuild_LastSyncTime or "Never")
    )
end

RedGuild_UIReady = true
ShowTab(TAB_DKP)
end

-----------------------------
-- Smart sync payload helpers
-----------------------------

local function BuildSyncPayload()
    return {
        sender = UnitName("player"),
        dkp    = RedGuild_Data,
        audit  = RedGuild_Audit,
        time   = time(),
        smart  = RedGuild_Config.smartSync,
    }
end

local function EncodePayload(tbl)
    local serialized  = LibSerialize:Serialize(tbl)
    local compressed  = LibDeflate:CompressDeflate(serialized)
    return LibDeflate:EncodeForPrint(compressed)   -- TEXT SAFE
end

local function DecodePayload(data)
    local decoded = LibDeflate:DecodeForPrint(data)   -- MATCHES EncodeForPrint
    if not decoded then return nil end

    local decompressed = LibDeflate:DecompressDeflate(decoded)
    if not decompressed then return nil end

    local ok, tbl = LibSerialize:Deserialize(decompressed)
    if not ok then return nil end

    return tbl
end

local function ApplySyncData(sender, encoded)
	D("ApplySyncData from "..tostring(sender))
    EnsureSaved()

    if not sender or sender == "" then return end
    sender = Ambiguate(sender, "short")

    -- Never apply your own data
    if sender == UnitName("player") then
        return
    end

    -- Do not apply during startup lock
    if RedGuild_SyncLocked then
        SafeSetSyncWarning("Sync received during startup — ignored.")
        return
    end

    if not encoded or encoded == "" then
        SafeSetSyncWarning("Received empty sync payload — ignored.")
        return
    end

    local ok, payload = pcall(DecodePayload, encoded)
    if not ok or type(payload) ~= "table" then
        SafeSetSyncWarning("Failed to decode sync payload — ignored.")
        return
    end

	D("Decoded sync payload OK")

    if type(payload.dkp) ~= "table" or type(payload.audit) ~= "table" then
        SafeSetSyncWarning("Invalid sync payload structure — ignored.")
        return
    end

    RedGuild_Data = payload.dkp
    RedGuild_Audit = payload.audit

    SafeSetSyncWarning("")
    UpdateTable()
    LogAudit(sender, "SYNC_APPLIED", "old data", "New DKP + audit data applied")
    RedGuild_LastSyncTime = date("%Y-%m-%d %H:%M:%S")
if RedGuild_DKPFooter then
    local count = 0
    for _ in pairs(RedGuild_Config.onlineEditors or {}) do count = count + 1 end
    RedGuild_DKPFooter:SetText(
        string.format("RedGuild v%s  |  Editors Online: %d  |  Last Sync: %s",
            REDGUILD_VERSION, count, RedGuild_LastSyncTime)
    )
end
	D("Sync applied successfully")
	
end

local function CheckForceSyncCompletion()
    local s = RedGuild_ForceSyncStatus
    if not s or not s.total then return end

    if (s.accepted + s.declined) >= s.total then
        LogAudit(UnitName("player"), "FORCE_SYNC_SUMMARY", "pending",
            string.format("%d accepted, %d declined", s.accepted, s.declined)
        )
        Print(string.format("Force Sync Summary: %d accepted, %d declined", s.accepted, s.declined))
    end
end

local function HandleSyncRequest(requester, sender, isRequestSync)
    EnsureSaved()
    D("HandleSyncRequest CALLED requester="..tostring(requester).." sender="..tostring(sender))

    -- Real UTF-8 names for chat
    local requesterReal = Ambiguate(requester or "", "short")
    local senderReal    = Ambiguate(sender or "", "short")

    if not requesterReal or requesterReal == "" or not senderReal or senderReal == "" then
        return
    end

    if RedGuild_SyncLocked then
        return
    end

    -- Track addon user using the real name (MarkAddonUserOnline normalizes internally)
    MarkAddonUserOnline(requesterReal)
    D("IsAuthorized() = "..tostring(IsAuthorized()))

    -- Only editors respond with data; non-editors do nothing
    if not IsAuthorized() then
        return
    end

    local payload = BuildSyncPayload()
    local encoded = EncodePayload(payload)

	-- DEBUG: log the exact name we are about to whisper to
	D(string.format("[DATA DEBUG] reply target=%s type=%s", tostring(requesterReal), tostring(type(requesterReal))))

    D("SYNC REQUEST → Sending DATA to " .. tostring(requesterReal))
    -- Whisper sync data back to requester using REAL name
    RedGuild_Send("DATA", encoded, requesterReal)
    Print("Sent sync data to " .. requesterReal)
end

local function HandleSyncResponse(sender, msgType)
    sender = Ambiguate(sender, "short")

    if msgType == "FORCE_ACCEPT" then
        LogAudit(sender, "FORCE_SYNC_ACCEPTED", "pending", "User accepted force sync")

        RedGuild_ForceSyncStatus.accepted = RedGuild_ForceSyncStatus.accepted + 1
        CheckForceSyncCompletion()

        local payload = BuildSyncPayload()
        local encoded = EncodePayload(payload)

        -- Whisper sync data directly to the accepter
        RedGuild_Send("DATA", encoded, sender)

        Print(sender .. " accepted force sync.")
        return
    end

    if msgType == "FORCE_DECLINE" then
        LogAudit(sender, "FORCE_SYNC_DECLINED", "pending", "User declined force sync")

        RedGuild_ForceSyncStatus.declined = RedGuild_ForceSyncStatus.declined + 1
        CheckForceSyncCompletion()

        Print(sender .. " declined force sync.")
        return
    end
end

local function AttemptAutoSync()
    D("AttemptAutoSync called")

    EnsureSaved()
    EnsureAddonUsers()
    UpdateOnlineEditors()
    EnsureOnlineEditors()

    if not next(RedGuild_Config.authorizedEditors) then
        SafeSetSyncWarning("Waiting for editor list...")
        return
    end

    local me = UnitName("player")
    if not me then
        SafeSetSyncWarning("Player name unavailable — sync aborted.")
        return
    end

    D("AuthorizedEditors count=" .. CountKeys(RedGuild_Config.authorizedEditors))

    -- Editors / GM never auto‑sync
    if IsAuthorized() or IsGuildOfficer() then
        SafeSetSyncWarning("Editor detected — auto-sync disabled.")
        return
    end

    if RedGuild_SyncLocked then
        return
    end

    if not IsInGuild() or GetNumGuildMembers() == 0 then
        SafeSetSyncWarning("Guild roster not ready — sync delayed.")
        return
    end

    local oc = 0
    for _ in pairs(RedGuild_Config.onlineEditors) do oc = oc + 1 end
    D("OnlineEditors count="..oc)

    UpdateOnlineEditors()
    local bestEditor = GetHighestRankEditor()

    if not bestEditor then
        SafeSetSyncWarning("No editor online — your DKP may be outdated.")
        return
    end

    local bestNorm = NormalizeName(bestEditor)
    if not bestNorm then
        SafeSetSyncWarning("Invalid editor name — sync aborted.")
        return
    end

    if bestNorm == NormalizeName(me) then
        SafeSetSyncWarning("Editor detected as self — sync aborted.")
        return
    end

    D("Sending sync request to "..bestEditor)

    -- Request sync from the highest‑rank online editor via WHISPER
    local meReal = Ambiguate(me, "short")
	RedGuild_Send("REQUEST", meReal, bestEditor)
    if RedGuild_DKPFooter then
    local count = 0
    for _ in pairs(RedGuild_Config.onlineEditors or {}) do count = count + 1 end
    RedGuild_DKPFooter:SetText(
        string.format("RedGuild v%s  |  Editors Online: %d  |  Last Sync: %s",
            REDGUILD_VERSION, count, RedGuild_LastSyncTime or "Never")
    )
	end
end

-- Popups
StaticPopupDialogs["REDGUILD_FORCE_SYNC_CONFIRM"] = {
    text = "Force sync will overwrite ALL guild DKP with YOUR data. Proceed?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        LogAudit(UnitName("player"), "FORCE_SYNC_INITIATED", "none", "Editor initiated force sync")

        EnsureAddonUsers()
        local me = UnitName("player")

        RedGuild_ForceSyncStatus.total    = 0
        RedGuild_ForceSyncStatus.accepted = 0
        RedGuild_ForceSyncStatus.declined = 0

        for name in pairs(RedGuild_Config.addonUsers) do
		
			if name ~= me and IsPlayerOnline(name) then
				-- Only guild members should receive FORCE_REQ
				if IsInGuild() then
					for i = 1, GetNumGuildMembers() do
						local gName = Ambiguate((GetGuildRosterInfo(i)), "short")
						if gName == name then
							RedGuild_ForceSyncStatus.total = RedGuild_ForceSyncStatus.total + 1
							local meReal = Ambiguate(UnitName("player"), "short")
							RedGuild_Send("FORCE_REQ", meReal, name)
						end
					end
				end
			end
		end
        Print("Force sync request sent to " .. RedGuild_ForceSyncStatus.total .. " users.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDGUILD_FORCE_SYNC_RECEIVE"] = {
    text = "Accept sync data from %s?",
    button1 = "Accept",
    button2 = "Decline",
    OnAccept = function(self, editor)
        RedGuild_Send("FORCE_ACCEPT", UnitName("player"), editor)
    end,
    OnCancel = function(self, editor)
        RedGuild_Send("FORCE_DECLINE", UnitName("player"), editor)
        SafeSetSyncWarning("WARNING — You declined sync. Your data may be outdated.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDGUILD_ON_TIME_CHECK"] = {
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

StaticPopupDialogs["REDGUILD_ALLOCATE_ATTENDANCE"] = {
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

StaticPopupDialogs["REDGUILD_NEW_WEEK"] = {
    text = "Start a new DKP week? This will move current totals into LastWeek.",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        for name, d in pairs(RedGuild_Data) do
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

StaticPopupDialogs["REDGUILD_BROADCAST_DKP"] = {
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
        for name in pairs(RedGuild_Data) do
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
local LDB = LibStub("LibDataBroker-1.1"):NewDataObject("RedGuild", {
    type = "data source",
    text = "RedGuild",
    icon = "Interface\\AddOns\\RedGuild\\media\\RedGuild_Minimap64.png",

    OnClick = function(_, button)
		if not RedGuild_UIReady then
			return
		end
		
        if not RedGuild_Enabled then
            print("|cffff5555RedGuild is disabled for your character as you are not in Redemption guild.|r")
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
        tt:AddLine("RedGuild")
        tt:AddLine("|cff00ff00Left-click|r to open DKP")
    end,
})

local icon = LibStub("LibDBIcon-1.0")

local function EnsureMinimapConfig()
    if not RedGuild_Config.minimap then
        RedGuild_Config.minimap = { hide = false }
    end
end

function RedGuild_ResetMinimapButton()
    EnsureMinimapConfig()
    RedGuild_Config.minimap.minimapPos = 45
    icon:Refresh("RedGuild", RedGuild_Config.minimap)
    print("|cff00ff00RedGuild minimap icon reset.|r")
end

-- Unified event frame
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_GUILD_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_WHISPER")

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5)

    --if addon == "RedGuild" then
    --C_ChatInfo.RegisterAddonMessagePrefix(REDGUILD_CHAT_PREFIX) 
    --end
    ---------------------------------------------------------
    -- 1. ADDON_LOADED
    ---------------------------------------------------------
    if event == "ADDON_LOADED" and arg1 == addonName then

        -- Register addon prefix ONCE, at the correct time
        C_ChatInfo.RegisterAddonMessagePrefix(REDGUILD_CHAT_PREFIX)

        EnsureSaved()
        EnsureMinimapConfig()

        -- Normalize authorized editor keys
        if RedGuild_Config and RedGuild_Config.authorizedEditors then
            local fixed = {}
            for name, v in pairs(RedGuild_Config.authorizedEditors) do
                if type(name) == "string" then
                    local key = name:lower():gsub("%s+", "")
                    fixed[key] = true
                end
            end
            RedGuild_Config.authorizedEditors = fixed
        end

        -- Populate class data if guild roster is already cached
        if IsInGuild() then
            for i = 1, GetNumGuildMembers() do
                local gName, _, _, _, _, _, _, _, _, _, gClass = GetGuildRosterInfo(i)
                if gName and gClass then
                    gName = Ambiguate(gName, "short")
                    local d = RedGuild_Data[gName]
                    if d then
                        d.class = gClass
                    end
                end
            end
        end

        -- Minimap icon
        icon:Register("RedGuild", LDB, RedGuild_Config.minimap)

        return
    end

    ---------------------------------------------------------
    -- 2. PLAYER_LOGIN
    ---------------------------------------------------------
    if event == "PLAYER_LOGIN" then
	
		local me = NormalizeName(UnitName("player"))
		RedGuild_Config.addonUsers[me] = true

        CheckGuildRestriction()
        CreateUI()
        UpdateOnlineEditors()
        C_GuildInfo.GuildRoster()

        EnsureSaved()
        EnsureProtectedEditor()

        -- Small delay to let roster/chat settle, then auto-sync
        C_Timer.After(3, function()
            if not IsInGuild() then return end
            AttemptAutoSync()
        end)
		
		-- Periodic editor list refresh for users (every 60s)
		C_Timer.NewTicker(60, function()
			UpdateOnlineEditors()
		end)
		
        return
    end

    ---------------------------------------------------------
    -- 3. GUILD_ROSTER_UPDATE / PLAYER_GUILD_UPDATE
    ---------------------------------------------------------
    if event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        CheckGuildRestriction()
        UpdateOnlineEditors()

        if not firstRosterReady then
            if IsInGuild() and GetNumGuildMembers() > 0 then
                local anyName = select(1, GetGuildRosterInfo(1))
                if anyName then
                    firstRosterReady = true
                    EnsureProtectedEditor()

                    for i = 1, GetNumGuildMembers() do
                        local gName, _, _, _, _, _, _, _, _, _, gClass = GetGuildRosterInfo(i)
                        if gName and gClass then
                            gName = Ambiguate(gName, "short")
                            local d = RedGuild_Data[gName]
                            if d then
                                d.class = gClass
                            end
                        end
                    end

                    UpdateTable()
                    RedGuild_SyncLocked = false
                    SafeSetSyncWarning("")
                end
            end
        end

        return
    end

---------------------------------------------------------
-- 4. CHAT_MSG_WHISPER (all REDGUILD sync traffic)
---------------------------------------------------------
if event == "CHAT_MSG_WHISPER" then

    local text, sender = arg1, arg2
    if not text or not sender then return end

    sender = Ambiguate(sender, "short")

    -----------------------------------------------------
    -- CHUNKED MESSAGES (DATA / EDITORSYNC)
    -----------------------------------------------------
    if text:find("^" .. REDGUILD_CHAT_PREFIX .. ":DATA:") or
       text:find("^" .. REDGUILD_CHAT_PREFIX .. ":EDITORSYNC:") then

        -- NEW 6‑FIELD FORMAT:
        -- PREFIX : TYPE : SEQ : PART : TOTAL : CHUNK
        local prefix, msgType, seqStr, partStr, totalStr, chunk =
            text:match("^([^:]+):([^:]+):(%d+):(%d+):(%d+):(.*)$")

        if prefix and (msgType == "DATA" or msgType == "EDITORSYNC") then
            local seq   = tonumber(seqStr)
            local part  = tonumber(partStr)
            local total = tonumber(totalStr)

            if not seq or not part or not total then
                return
            end

            D(string.format("WHISPER IN %s seq=%d part=%d/%d from=%s len=%d",
                msgType, seq, part, total, sender, #chunk))

            -- Ensure bucket exists
            local bucket = REDGUILD_Inbound[msgType]
            bucket[seq] = bucket[seq] or { parts = {}, total = total, from = sender }

            local entry = bucket[seq]
            entry.parts[part] = chunk
            entry.total = total  -- ensure total is always stored

            -----------------------------------------------------
            -- COMPLETION CHECK
            -----------------------------------------------------
            local complete = true
            for i = 1, entry.total do
                if not entry.parts[i] then
                    complete = false
                    break
                end
            end

            if complete then
                D(string.format("CHUNK ASSEMBLY COMPLETE → %s", msgType))

                local full = table.concat(entry.parts, "")
                bucket[seq] = nil -- clear buffer

                -----------------------------------------------------
                -- APPLY DATA SYNC
                -----------------------------------------------------
                if msgType == "DATA" then
                    ApplySyncData(entry.from or sender, full)
                    return
                end

                -----------------------------------------------------
                -- APPLY EDITOR LIST SYNC (version‑aware)
                -----------------------------------------------------
                if msgType == "EDITORSYNC" then
                    D("EDITOR SYNC ← All parts received for EDITORSYNC from " .. tostring(entry.from))

                    local decoded = LibDeflate:DecodeForPrint(full)
                    if not decoded then
                        D("EDITOR SYNC ERROR: DecodeForPrint failed")
                        return
                    end

                    local decompressed = LibDeflate:DecompressDeflate(decoded)
                    if not decompressed then
                        D("EDITOR SYNC ERROR: DecompressDeflate failed")
                        return
                    end

                    local ok, tbl = LibSerialize:Deserialize(decompressed)
                    if not ok or type(tbl) ~= "table" then
                        D("EDITOR SYNC ERROR: Deserialize failed or returned non-table")
                        return
                    end

                    D("EDITOR SYNC ← Decoded table: version=" .. tostring(tbl.version)
                        .. " editors=" .. tostring(tbl.editors and CountKeys(tbl.editors) or 0))

                    ApplyEditorList(tbl)
                    return
                end
            end

            return
        end
    end

    -----------------------------------------------------
    -- FALLBACK: SIMPLE MESSAGES (REQUEST, FORCE_REQ, etc.)
    -----------------------------------------------------
    local prefix2, msgType2, payload = text:match("^([^:]+):([^:]+):(.*)$")
    if prefix2 ~= REDGUILD_CHAT_PREFIX then
        return
    end

    local msgType = msgType2

    D("WHISPER IN type="..tostring(msgType).." from="..tostring(sender))

    -----------------------------------------------------
    -- EDITOR LIST REQUEST (EDITORREQ)
    -----------------------------------------------------
    if msgType == "EDITORREQ" then
        local requester = NormalizeName(payload)
        if not requester then return end

        ---------------------------------------------------------
        -- RULE 4: Only respond to addon users
        ---------------------------------------------------------
        if not RedGuild_Config.addonUsers[requester] then
            D("EDITOR SYNC → Ignoring request from non-addon user " .. tostring(requester))
            return
        end

        ---------------------------------------------------------
        -- RULE 2: Only editors respond
        ---------------------------------------------------------
        if IsAuthorized() or IsGuildOfficer() then
            BroadcastEditorListTo(requester)
        end
        return
    end

    -----------------------------------------------------
    -- EDITOR LIST SYNC (fallback simple form)
    -- (rarely used now; chunked handler above is primary)
    -----------------------------------------------------
    if msgType == "EDITORSYNC" then
        local decoded = LibDeflate:DecodeForPrint(payload)
        if not decoded then return end

        local decompressed = LibDeflate:DecompressDeflate(decoded)
        if not decompressed then return end

        local ok, tbl = LibSerialize:Deserialize(decompressed)
        if not ok or type(tbl) ~= "table" then return end

        ApplyEditorList(tbl)
        return
    end

    -----------------------------------------------------
    -- SYNC REQUESTS
    -----------------------------------------------------
    if msgType == "REQUEST" then
        HandleSyncRequest(payload, sender, false)
        return
    end

    if msgType == "FORCE_REQ" then
        StaticPopup_Show("REDGUILD_FORCE_SYNC_RECEIVE", sender, nil, sender)
        return
    end

    if msgType == "FORCE_ACCEPT" then
        HandleSyncResponse(sender, "FORCE_ACCEPT")
        return
    end

    if msgType == "FORCE_DECLINE" then
        HandleSyncResponse(sender, "FORCE_DECLINE")
        return
    end

    -----------------------------------------------------
    -- VERSION (ignored)
    -----------------------------------------------------
    if msgType == "VERSION" then
        return
    end

    return
end
end)

-- Slash Commands
SLASH_REDGUILD1 = "/redguild"
SlashCmdList["REDGUILD"] = function(msg)
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
        RedGuild_ResetMinimapButton()
        return
    end

    if msg == "debug" then
        RedGuild_Debug = not RedGuild_Debug
        if RedGuild_Debug then
            print("|cff00ff00[RedGuild] Debug mode ENABLED|r")
        else
            print("|cffff0000[RedGuild] Debug mode DISABLED|r")
        end
        return
	end

    if msg == "help" or msg == "" then
        print("|cffffd100RedGuild Commands:|r")
        print("|cff00ff00/redguild show|r   - Open the DKP window")
        print("|cff00ff00/redguild hide|r   - Hide the DKP window")
        print("|cff00ff00/redguild toggle|r - Toggle the DKP window")
        print("|cff00ff00/redguild minimap|r - Reset minimap icon position")
        print("|cff00ff00/redguild help|r   - Show this help list")
        return
    end

    print("|cffff5555Unknown command. Use /redguild help|r")
end