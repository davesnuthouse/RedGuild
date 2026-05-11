-- RedGuild.lua
-- Guild tool packed with features to assist with group/raid creation.
if ... ~= "RedGuild" then return end

RedGuild_Data   	= RedGuild_Data   or {}
RedGuild_BackupData = RedGuild_BackupData or {}
RedGuild_Alts   	= RedGuild_Alts   or {}
RedGuild_AltParent 	= RedGuild_AltParent or {}
RedGuild_ML 		= RedGuild_ML 	  or {}
RedGuild_Config 	= RedGuild_Config or {}
RedGuild_Audit  	= RedGuild_Audit  or {}
RedGuild_Usage  	= RedGuild_Usage  or {}

local addonName      = ...
local REDGUILD_VERSION = "1.8.69"

local REDGUILD_CHAT_PREFIX = "REDGUILD"

RedGuild_Config.smartSync      		= (RedGuild_Config.smartSync ~= false)
RedGuild_Config.addonUsers     		= RedGuild_Config.addonUsers     or {}
RedGuild_Config.onlineEditors  		= RedGuild_Config.onlineEditors  or {}
RedGuild_Config.authorizedEditors 	= RedGuild_Config.authorizedEditors or {}
RedGuild_Config.hideMeFromSync 		= RedGuild_Config.hideMeFromSync or false
RedGuild_Config.EditorVersions 		= RedGuild_Config.EditorVersions or {}

RedGuild_Usage = RedGuild_Usage or {}
RedGuild_SyncLocked = true

RedGuild_Config.lastVersionSync     = RedGuild_Config.lastVersionSync     or "Never"
RedGuild_Config.lastVersionSyncFrom = RedGuild_Config.lastVersionSyncFrom or "?"
RedGuild_Config.lastDKPSync         = RedGuild_Config.lastDKPSync         or "Never"
RedGuild_Config.lastDKPSyncFrom     = RedGuild_Config.lastDKPSyncFrom     or "?"
RedGuild_Config.lastAltSync         = RedGuild_Config.lastAltSync         or "Never"
RedGuild_Config.lastAltSyncFrom     = RedGuild_Config.lastAltSyncFrom     or "?"
RedGuild_Config.lastEditorSync      = RedGuild_Config.lastEditorSync      or "Never"
RedGuild_Config.lastEditorSyncFrom  = RedGuild_Config.lastEditorSyncFrom  or "?"


RedGuild_Config.altsVersion = RedGuild_Config.altsVersion or 0

RedGuild_UIReady = false

local mainFrame
local dkpPanel, altPanel, groupPanel, mlPanel, raidPanel, editorsPanel, auditPanel

local TAB_DKP     = 1
local TAB_ALT     = 2
local TAB_GROUP   = 3
local TAB_ML      = 4
local TAB_RAID    = 5
local TAB_EDITORS = 6
local TAB_AUDIT   = 7

local activeTab = TAB_DKP
local dkpLocked = true

local SORT_COLOR   = "|cff3399ff"
local NORMAL_COLOR = "|cffffffff"

AllDKPNames = AllDKPNames or {}
dkpShowGroupOnly = false

local protectedInitialized = false

local syncWarning
local suppressWarnings = false

local showHiddenRecords = false

local LibSerialize = LibStub("LibSerialize")
local LibDeflate   = LibStub("LibDeflate")

-- Ensure inbound chunk buffers exist
REDGUILD_Inbound = REDGUILD_Inbound or {
    DATA      = {},
    EDITORSYNC = {},
    FORCE_REQ = {},
	ALTS       = {},
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

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RedGuild]|r " .. tostring(msg))
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

--------------------------------------------------
-- SYNC HELPERS
--------------------------------------------------

local function GetSyncAgeState(timestamp)
    if not timestamp or timestamp == "Never" then
        return "red"
    end

    local year, month, day, hour, min, sec =
        timestamp:match("(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)")

    if not year then
        return "red"
    end

    local t = time({
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = min,
        sec = sec,
    })

    local ageDays = (time() - t) / 86400

    if ageDays < 4 then
        return "green"
    elseif ageDays < 7 then
        return "orange"
    else
        return "red"
    end
end

function UpdateSyncStatus()
    if not statusBox or not statusText then return end

    -- PRIORITY 1: Hidden from sync (blue)
    if RedGuild_Config.hideMeFromSync then
        statusBox:SetColorTexture(0, 0, 1)
        return
    end

    -- Determine freshness of each sync type
    local dkpState 	      = GetSyncAgeState(RedGuild_Config.lastDKPSync)
    local altState  	  = GetSyncAgeState(RedGuild_Config.lastAltSync)
    local editorState 	  = GetSyncAgeState(RedGuild_Config.lastEditorSync)

    -- If ANY are red → red
    if dkpState == "red" or altState == "red" or editorState == "red" then
        statusBox:SetColorTexture(1, 0, 0)
        return
    end

    -- If ANY are orange → orange
    if dkpState == "orange" or altState == "orange" or editorState == "orange" then
        statusBox:SetColorTexture(1, 0.65, 0)
        return
    end

    -- Otherwise all are green → green
    statusBox:SetColorTexture(0, 1, 0)
end

local function ColourForSyncAge(timestamp)
    if not timestamp or timestamp == "Never" then
        return "|cffff0000Never|r" -- treat missing as red
    end

    -- Parse "YYYY-MM-DD HH:MM:SS"
    local year, month, day, hour, min, sec =
        timestamp:match("(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)")

    if not year then
        return "|cffff0000Invalid|r"
    end

    local t = time({
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = min,
        sec = sec,
    })

    local ageDays = (time() - t) / 86400

    if ageDays < 4 then
        return "|cff00ff00" .. timestamp .. "|r" -- green
    elseif ageDays < 7 then
        return "|cffffa500" .. timestamp .. "|r" -- orange
    else
        return "|cffff0000" .. timestamp .. "|r" -- red
    end
end

local function GetExactName(name)
    -- Ambiguate("none") returns the full, exact name Blizzard expects
    local exact = Ambiguate(name, "none")
    return exact
end

local REDGUILD_MAX_CHUNK = 200
local RedGuild_OutboundSeq = 0
RedGuild_Data   = RedGuild_Data   or {}
RedGuild_Config = RedGuild_Config or {}
RedGuild_Audit  = RedGuild_Audit  or {}
RedGuild_Usage  = RedGuild_Usage  or {}

-- [FORCE SYNC REWRITE — GLOBAL STATE]
RedGuild_ForceSyncStatus = {
    total = 0,
    accepted = 0,
    declined = 0,
    autoAccepted = {},
    acceptedEditors = {},
    declinedEditors = {},
}

local RedGuild_PendingForceSync = {
    editor = nil,
    snapshot = nil,
}

local function RedGuild_ShowForceSyncSummary()
    local s = RedGuild_ForceSyncStatus
    local function join(list)
        if not list or #list == 0 then return "None" end
        table.sort(list, function(a, b) return a:lower() < b:lower() end)
        return table.concat(list, ", ")
    end

    Print("Force Sync Summary:")
    Print("  Auto accepted (non editors): " .. join(s.autoAccepted))
    Print("  Accepted (editors): " .. join(s.acceptedEditors))
    Print("  Declined (editors): " .. join(s.declinedEditors))
end

local function RedGuild_GetSyncChannel(msgType, target)
    -- Small whisper responses
    if msgType == "FORCE_ACCEPT"
        or msgType == "FORCE_DECLINE"
    then
        if not target then return nil, nil end
        return "WHISPER", GetExactName(target)
    end

    -- Chunked guild broadcasts
    if msgType == "DATA"
        or msgType == "EDITORSYNC"
        or msgType == "FORCE_REQ"
    then
        return "GUILD", nil
    end

    -- Everything else → guild
    return "GUILD", nil
end

function RedGuild_Send(msgType, payload, target)
    if not msgType then return end
	
	-- Block all outbound sync if user opted out
    if RedGuild_Config.hideMeFromSync then
        return
    end
	
    payload = payload or ""

    local channel, actualTarget = RedGuild_GetSyncChannel(msgType, target)
    if not channel then
        D("RedGuild_Send: no valid channel for msgType="..tostring(msgType))
        return
    end

    -- Fix whisper targets
    if channel == "WHISPER" then
        if not actualTarget or actualTarget == "" then
            D("RedGuild_Send: WHISPER without target for msgType="..tostring(msgType))
            return
        end
        actualTarget = Ambiguate(actualTarget, "none")
    end

	-- Small messages (everything except chunked DKP types)
	local isChunked =
		msgType == "DATA" or
		msgType == "EDITORSYNC" or
		msgType == "FORCE_REQ" or
		msgType == "ALTS"		

	-- ALT SYNC MESSAGES ARE ALWAYS SMALL
	if not isChunked then
		local msg = string.format("%s:%s:%s", REDGUILD_CHAT_PREFIX, msgType, payload)
		C_ChatInfo.SendAddonMessage(REDGUILD_CHAT_PREFIX, msg, channel, actualTarget)
		return
	end

    -- Chunked messages (DATA, EDITORSYNC, FORCE_REQ)
    RedGuild_OutboundSeq = RedGuild_OutboundSeq + 1
    local seq = RedGuild_OutboundSeq

    local total = math.ceil(#payload / REDGUILD_MAX_CHUNK)
    if total == 0 then total = 1 end

    for i = 1, total do
        local startIdx = (i - 1) * REDGUILD_MAX_CHUNK + 1
        local chunk = payload:sub(startIdx, startIdx + REDGUILD_MAX_CHUNK - 1)

        local msg = string.format(
            "%s:%s:%d:%d:%d:%s",
            REDGUILD_CHAT_PREFIX, msgType, seq, i, total, chunk
        )

        C_ChatInfo.SendAddonMessage(REDGUILD_CHAT_PREFIX, msg, channel, actualTarget)
    end
end

local function RedGuild_CreateDKPBackup()
    RedGuild_BackupData.data      = CopyTable(RedGuild_Data)
    RedGuild_BackupData.dkpVersion   = tonumber(RedGuild_Config.dkpVersion or 0)
    RedGuild_BackupData.timestamp = date("%Y-%m-%d %H:%M:%S")
    RedGuild_BackupData.from      = RedGuild_PendingForceSync and RedGuild_PendingForceSync.editor or "unknown"

    D("DKP backup created (version " .. tostring(RedGuild_BackupData.dkpVersion) .. ")")
end

--------------------------------------------------
-- Basic Helpers
--------------------------------------------------

local function EnsureSaved()
    RedGuild_Config.authorizedEditors = RedGuild_Config.authorizedEditors or {}
end

local function EnsureConfig()
    RedGuild_Config = RedGuild_Config or {}

    RedGuild_Config.authorizedEditors = RedGuild_Config.authorizedEditors or {}
    RedGuild_Config.editorListVersion = RedGuild_Config.editorListVersion or 0

    -- Guild leader protection
    if not RedGuild_Config.protectedEditor then
        local gm = GetGuildMaster()
        if gm then
            RedGuild_Config.protectedEditor = NormalizeName(gm)
        end
    end
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
		inactive   = false,
    }
	
	-- MIGRATION: convert old boolean rotated values
    if RedGuild_Data[name].rotated == false then
        RedGuild_Data[name].rotated = 0
    end
	
    return RedGuild_Data[name]
end

local function EnsureML(name)
    if not RedGuild_ML[name] then
        RedGuild_ML[name] = {
            mlMainMS = 0,   -- Main (MS)
            mlAltMS  = 0,   -- Alt  (MS)
            mlMainOS = 0,   -- Main (OS)
            mlAltOS  = 0,   -- Alt  (OS)
            mlNotes  = "",
        }
    end

    return RedGuild_ML[name]
end

local function BumpDKPVersion()
    RedGuild_Config.dkpVersion = (RedGuild_Config.dkpVersion or 0) + 1
end

local function PopulateGuildClasses()
    if not IsInGuild() then return end
    for i = 1, GetNumGuildMembers() do
        local gName, _, _, _, _, _, _, _, _, _, gClass = GetGuildRosterInfo(i)
        if gName and gClass then
            gName = Ambiguate(gName, "short")
            local d = RedGuild_Data[gName]
            if d then d.class = gClass end
        end
    end
end

function UpdateAddControls()
    if not dkpPanel or not dkpPanel.addInput or not dkpPanel.addButton then
        return
    end

    if dkpLocked then
        dkpPanel.addInput:Hide()
        dkpPanel.addButton:Hide()
    else
        if IsEditor(UnitName("player")) then
            dkpPanel.addInput:Show()
            dkpPanel.addButton:Show()
        end
    end
end

local function RLTools_HasSelections()
    for _, row in ipairs(RLRows) do
        if row:IsShown() and row.checkbox:GetChecked() then
            return true
        end
    end
    return false
end

local function CountOnlineAddonUsers()
    local count = 0
    for name in pairs(RedGuild_Config.addonUsers) do
        if IsPlayerOnline(name) then
            count = count + 1
        end
    end
    return count
end

local function GetMissingDKPGroupMembers()
    local missing = {}

    local function Check(unit)
        local raw = UnitName(unit)
        if raw then
            local short = Ambiguate(raw, "short")
            if not RedGuild_Data[short] then
                table.insert(missing, short)
            end
        end
    end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            Check("raid"..i)
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do
            Check("party"..i)
        end
        Check("player")
    else
        -- solo
        Check("player")
    end

    return missing
end

--------------------------------------------------
-- Guild / Name Utilities
--------------------------------------------------

function IsNameInGuild(name)
    if not IsInGuild() then return false end
    for i = 1, GetNumGuildMembers() do
        local gName = GetGuildRosterInfo(i)
        if gName and Ambiguate(gName, "short") == name then
            return true
        end
    end
    return false
end

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
              + (d.bench or 0)
              - (d.spent or 0)

    -- Hard cap at 300
    if d.balance > 300 then
        d.balance = 300
    end
end

local function RuntimeInvalid(name)
    if IsInGuild() and GetNumGuildMembers() > 0 then
        return not IsNameInGuild(name)
    end
    return false
end

local function RecalculateAllBalances()
    for _, d in pairs(RedGuild_Data) do
        RecalcBalance(d)
    end
end

local function EnsureAddonUsers()
    RedGuild_Config.addonUsers = RedGuild_Config.addonUsers or {}
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

local function IsActiveGuildMember(name)
    local ok = IsNameInGuild(name)
    return ok == true
end	

local function SafeSetSyncWarning(text)
    if syncWarning then
        syncWarning:SetText(text or "")
    end
end

local function GenerateAuditID()
    return tostring(time()) .. "-" .. math.random(100000, 999999)
end

local function ColorizeBalance(d)
    if not d then
        return "0"
    end

    local balance  = tonumber(d.balance)  or 0
    local lastWeek = tonumber(d.lastWeek) or 0

    -- Hard cap colour: purple for 300
    if balance == 300 then
        return "|cffa335ee" .. balance .. "|r"   -- epic purple
    end

    if balance > lastWeek then
        return "|cff00ff00" .. balance .. "|r"   -- green
    elseif balance < lastWeek then
        return "|cffff0000" .. balance .. "|r"   -- red
    else
        return tostring(balance)                 -- white/neutral
    end
end

local function NormalizeName(name)
    if not name then return nil end

    -- Remove realm suffix
    name = Ambiguate(name, "short")
    if not name or name == "" then return nil end

    -- Strip leading/trailing whitespace
    name = name:gsub("^%s*(.-)%s*$", "%1")

    -- Lowercase + remove spaces
    name = name:lower():gsub("%s+", "")

    return name
end

local function IsAddonUserOnlineForTooltip(name)
    local target = NormalizeName(name)
    if not target or not IsInGuild() then
        return false
    end

    local num = GetNumGuildMembers()
    for i = 1, num do
        local gName, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
        if gName and NormalizeName(gName) == target then
            return online
        end
    end

    return false
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
    if not IsInGuild() then return false end
    if not name or name == "" then return false end

    local norm = NormalizeName(name)

    for i = 1, GetNumGuildMembers() do
        local gName = GetGuildRosterInfo(i)
        if gName then
            local short = Ambiguate(gName, "short")
            if NormalizeName(short) == norm then
                return true, short   -- return TRUE and the properly capitalized guild name
            end
        end
    end

    return false
end

local function IsRaidLeaderOrMasterLooter()

    -- TBC Anniversary: Master Looter API is broken (always nil)
    -- Raid leader detection must be done via raid roster

    if not IsInRaid() then
        return false
    end

    -- Check if player is raid leader
    for i = 1, GetNumGroupMembers() do
        local name, rank = GetRaidRosterInfo(i)
        -- rank == 2 means RAID LEADER
        if rank == 2 then
            if Ambiguate(name, "short") == UnitName("player") then
                return true
            end
        end
    end

    -- Check if player is raid assistant
    if UnitIsGroupAssistant("player") then
        return true
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
                    if not isInvalid then
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

local function CountOutdatedUsers()

    if not RedGuild_Config.AddonVersions then
        return 0
    end

    local count = 0
    local latest = REDGUILD_VERSION

    if not RedGuild_Config.AddonVersions then
        return 0
    end

    for name, ver in pairs(RedGuild_Config.AddonVersions or {}) do
        if CompareVersions(latest, ver) then
            count = count + 1
        end
    end

    return count
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

local function GetHighestVersionEditor()
    local bestEditor = nil
    local bestVersion = -1

    for name, ver in pairs(RedGuild_Config.EditorVersions) do
        if IsEditor(name) and IsAddonUserOnlineForTooltip(name) then
            if tonumber(ver) and ver > bestVersion then
                bestVersion = ver
                bestEditor = name
            end
        end
    end

    return bestEditor, bestVersion
end

--------------------------------------------------------------------
-- UPDATE ONLINE EDITORS + VERSION NEGOTIATION
--------------------------------------------------------------------

local function GetHighestRankEditor()
    D("GetHighestRankEditor called")

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

            local hasList = next(RedGuild_Config.authorizedEditors) ~= nil

            -- If user has no editor list yet, treat ALL guild officers as editors
            local isEditor
            if hasList then
                isEditor = RedGuild_Config.authorizedEditors[key]
            else
                -- Bootstrap mode: treat officers as editors
                isEditor = (rankIndex <= 2)   -- 0 = GM, 1 = lunatics, 2 = warmaster
            end

            if isEditor and online then
                RedGuild_Config.onlineEditors[key] = {
                    name = real,
                    rankIndex = rankIndex
                }
            end
        end
    end
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
	altPanel:Hide()
    groupPanel:Hide()
    raidPanel:Hide()
	mlPanel:Hide()
    editorsPanel:Hide()
    auditPanel:Hide()

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
local SPEC_ROLES = {
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

local dkpScroll
local dkpScrollChild

local ROW_HEIGHT = 18

function CreateDKPRow()
    local row = CreateFrame("Frame", nil, dkpScrollChild)
    row:SetFrameLevel(1)
    row:SetSize(1, ROW_HEIGHT)

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
        row.deleteButton:Hide()
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

		StaticPopup_Show("REDGUILD_INACTIVE_OR_DELETE", player, nil, player)
	end)
	
	-- REACTIVATE BUTTON (hidden by default)
	local reactBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	reactBtn:SetSize(15, 15)
	reactBtn:SetPoint("LEFT", delBtn, "LEFT", 0, 0)
	reactBtn:SetText("+")
	reactBtn:Hide()
	row.reactivateButton = reactBtn

	reactBtn:SetScript("OnClick", function()
		if dkpLocked then return end
		if not IsAuthorized() then return end

		local player = row.name
		if not player then return end

		local d = RedGuild_Data[player]
		if not d then return end

		d.inactive = false
		BumpDKPVersion()
		UpdateTable()
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
    -- FILTER
    ----------------------------------------------------------------
    local filtered = {}

    for _, name in ipairs(allNames) do
        local d = RedGuild_Data[name]
        local isInvalid = RuntimeInvalid(name)
        local isInactive = d and d.inactive

        if (not isInvalid or showHiddenRecords)
        and (not isInactive or showHiddenRecords) then
            table.insert(filtered, name)
        end
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
        -- Hard safety
        if not a and not b then return false end
        if not a then return false end
        if not b then return true end

        --------------------------------------------------------
        -- NAME SORT
        --------------------------------------------------------
        if currentSortField == "name" then
            if currentSortAscending then
                return tostring(a) < tostring(b)
            else
                return tostring(a) > tostring(b)
            end
        end

        --------------------------------------------------------
        -- DATA SORT
        --------------------------------------------------------
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

        -- Primary comparison
        if va ~= vb then
            if currentSortAscending then
                return va < vb
            else
                return va > vb
            end
        end

        -- Tie-breaker (ALWAYS BOOLEAN)
        return tostring(a) < tostring(b)
    end)

    ----------------------------------------------------------------
    -- FINAL DATA SET
    ----------------------------------------------------------------
    dkpSortedNames = filtered or {}
    local totalRows = #dkpSortedNames

    ----------------------------------------------------------------
    -- SCROLL + VIEWPORT
    ----------------------------------------------------------------
    local rowHeight = ROW_HEIGHT or 18
    local viewportHeight = dkpScroll:GetHeight() or 300
    local maxVisibleRows = math.floor(viewportHeight / rowHeight) + 1

    -- Get current scroll safely
    local scrollPos = dkpScroll:GetVerticalScroll() or 0

    -- Convert to row offset
    local offset = math.floor(scrollPos / rowHeight)

    -- Clamp offset (prevents missing rows at bottom)
    local maxOffset = math.max(0, totalRows - maxVisibleRows)
    offset = math.max(0, math.min(offset, maxOffset))

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

            row.name = name
            row.index = dataIndex

            row:Show()
            row:SetPoint("TOPLEFT", dkpScrollChild, "TOPLEFT", 0, -(i - 1) * rowHeight)

            RecalcBalance(d)

            --------------------------------------------------------
            -- LOCK STATE
            --------------------------------------------------------
            if row.deleteButton and row.reactivateButton then
                if dkpLocked or not IsEditor(UnitName("player")) then
                    row.deleteButton:Hide()
                    row.reactivateButton:Hide()
                else
                    if d.inactive then
                        row.deleteButton:Hide()
                        row.reactivateButton:Show()
                    else
                        row.deleteButton:Show()
                        row.reactivateButton:Hide()
                    end
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

            --------------------------------------------------------
            -- DISPLAY
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
            if RuntimeInvalid(name) then
                displayName = "|cffff0000-|r " .. displayName
            end

			local isAlt = RedGuild_AltParent[name] and RedGuild_AltParent[name] ~= name

			local displayName = name

			if RuntimeInvalid(name) then
				displayName = "|cffff0000-|r " .. displayName
			end

			if isAlt then
				displayName = "~" .. displayName
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
    dkpScrollChild:SetHeight(totalRows * rowHeight)

    ----------------------------------------------------------------
    -- FINAL SCROLL CLAMP
    ----------------------------------------------------------------
    local maxScroll = dkpScroll:GetVerticalScrollRange()
    if dkpScroll:GetVerticalScroll() > maxScroll then
        dkpScroll:SetVerticalScroll(maxScroll)
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
-- BROADCAST EDITOR LIST
--------------------------------------------------------------------
local function BroadcastEditorListTo(target)
    EnsureConfig()

    if not target or target == "" then
        D("EDITOR SYNC → No target")
        return
    end
	
	if not IsActiveGuildMember(target) then
		D("EDITOR SYNC → target not in guild, skipping")
		return
	end

    local payload = {
        editors = RedGuild_Config.authorizedEditors or {},
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
    local normalized = {}
	for key, v in pairs(incomingEditors) do
		local nk = NormalizeName(key)
		if nk and nk ~= "" then
			normalized[nk] = true
		end
	end

RedGuild_Config.authorizedEditors = normalized
    RedGuild_Config.editorListVersion = incomingVersion

    D("EDITOR SYNC → Applied new editor list (version " .. incomingVersion .. ")")

    UpdateOnlineEditors()
    RefreshEditorList()
end

function RefreshEditorList()
    if not editorRows then return end

    local protected = RedGuild_Config.protectedEditor

    -- Convert dictionary → array
    local names = {}
    for name in pairs(RedGuild_Config.authorizedEditors or {}) do
        table.insert(names, name)
    end
    table.sort(names)

    -- Fill rows
    local i = 1
    for _, name in ipairs(names) do
        local row = editorRows[i]
        if not row then break end

        row.name = name

        -- Fetch known version (may be nil)
        local ver = RedGuild_Config.EditorVersions and RedGuild_Config.EditorVersions[name]
		
		-- Normalize for version lookup
        local key = NormalizeName(name)
        local ver = RedGuild_Config.EditorVersions and RedGuild_Config.EditorVersions[key]
		
		-- Build display text
        local display
        if ver then
            display = string.format("%s (v%s)", name, ver)
        else
            display = string.format("%s (—)", name)
        end
		
        -- GOLD for protected editor
        if protected and NormalizeName(name) == NormalizeName(protected) then
            row.text:SetText("|cffffd700" .. name .. "|r")
        else
            row.text:SetText(name)
        end

        row:Show()
        i = i + 1
    end

    -- Hide unused rows
    for j = i, #editorRows do
        editorRows[j].name = nil
        editorRows[j].text:SetText("")
        editorRows[j].highlight:Hide()
        editorRows[j]:Hide()
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
	mainFrame:SetFrameLevel(666)
	
	mainFrame:SetMovable(true)
	mainFrame:EnableMouse(true)
	mainFrame:RegisterForDrag("LeftButton")
	mainFrame:SetScript("OnDragStart", function(self)
		self:StartMoving()
	end)
	
	mainFrame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
	end)
	
	table.insert(UISpecialFrames, "RedGuildFrame")

    local headerIcon = mainFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    headerIcon:SetTexture("Interface\\AddOns\\RedGuild\\media\\RedGuild_Icon256.png")
    headerIcon:SetSize(128, 128)
    headerIcon:SetPoint("TOP", mainFrame, "LEFT", 20, 290)

    mainFrame.title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    mainFrame.title:SetPoint("CENTER", mainFrame.TitleBg, "CENTER", 0, 0)
    mainFrame.title:SetText("Redemption Guild UI - brought to you by a clueless idiot called Lunátic")

--------------------------------------------------------------------
-- SYNC INDICATOR (TITLE BAR)
--------------------------------------------------------------------
local closeBtn = mainFrame.CloseButton or _G[mainFrame:GetName().."CloseButton"]

local syncButton = CreateFrame("Frame", nil, mainFrame)
syncButton:SetPoint("RIGHT", closeBtn, "LEFT", -10, 0)
syncButton:SetSize(40, 20)
syncButton:EnableMouse(true)

-- "Sync" label
statusText = syncButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
statusText:SetPoint("LEFT", syncButton, "LEFT", 0, 0)
statusText:SetText("Sync")

-- coloured status box AFTER the text
statusBox = syncButton:CreateTexture(nil, "OVERLAY")
statusBox:SetPoint("LEFT", statusText, "RIGHT", 4, 0)
statusBox:SetSize(12, 12)

--------------------------------------------------------------------
-- TOOLTIP FOR SYNC INDICATOR
--------------------------------------------------------------------
local addonVersions = RedGuild_Config.AddonVersions or {}

syncButton:SetScript("OnEnter", function()
    GameTooltip:SetOwner(syncButton, "ANCHOR_TOPRIGHT")
    GameTooltip:ClearLines()

    GameTooltip:AddLine("|cffffff00Sync Status|r")
    GameTooltip:AddLine(" ")

	-- Addon users
	local total = CountKeys(RedGuild_Config.addonUsers or {})

	local online = 0
	for name in pairs(RedGuild_Config.addonUsers or {}) do
		if IsAddonUserOnlineForTooltip(name) then
			online = online + 1
		end
	end

	GameTooltip:AddLine("|cffffffffAddon users: |r" .. online .. " / " .. total)

	--Outdated addon users
	local outdated = CountOutdatedUsers()
	GameTooltip:AddLine("|cffffffffOutdated addon users: |r" .. outdated)

    GameTooltip:AddLine(" ")

    -- Version sync
    GameTooltip:AddLine("|cffffff00Addon Version Sync|r")
    GameTooltip:AddLine("|cffffffffLast: |r" .. ColourForSyncAge(RedGuild_Config.lastVersionSync or "Never"))
    GameTooltip:AddLine("|cffffffffFrom: |r" .. (RedGuild_Config.lastVersionSyncFrom or "?"))
    GameTooltip:AddLine(" ")

-- DKP sync
GameTooltip:AddLine("|cffffff00DKP Sync|r")
GameTooltip:AddLine("|cffffffffLast: |r" .. ColourForSyncAge(RedGuild_Config.lastDKPSync or "Never"))
GameTooltip:AddLine("|cffffffffFrom: |r" .. (RedGuild_Config.lastDKPSyncFrom or "?"))
GameTooltip:AddLine("|cffffffffTable Version: |r" .. (RedGuild_Config.dkpVersion or "?"))
GameTooltip:AddLine(" ")

-- Alt sync
GameTooltip:AddLine("|cffffff00Alt Tracker Sync|r")
GameTooltip:AddLine("|cffffffffLast: |r" .. ColourForSyncAge(RedGuild_Config.lastAltSync or "Never"))
GameTooltip:AddLine("|cffffffffFrom: |r" .. (RedGuild_Config.lastAltSyncFrom or "?"))
GameTooltip:AddLine(" ")

-- Editor sync
GameTooltip:AddLine("|cffffff00Editor Sync|r")
GameTooltip:AddLine("|cffffffffLast: |r" .. ColourForSyncAge(RedGuild_Config.lastEditorSync or "Never"))
GameTooltip:AddLine("|cffffffffFrom: |r" .. (RedGuild_Config.lastEditorSyncFrom or "?"))

    GameTooltip:Show()
end)

syncButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

    --------------------------------------------------------------------
    -- TABS
    --------------------------------------------------------------------
	CreateTab(TAB_DKP,   "DKP")
	CreateTab(TAB_ALT,   "Alt Tracker")
	CreateTab(TAB_GROUP, "Inviter")
	CreateTab(TAB_ML, "ML Scorecard")
	
-- Force refresh when switching to ML tab
-- Force refresh when switching to ML tab
tabs[TAB_ML]:HookScript("OnClick", function()
    C_Timer.After(0.05, RefreshMLTools)
end)
	
	if IsEditor(UnitName("player")) then
    CreateTab(TAB_RAID, "RL Tools")
    CreateTab(TAB_EDITORS, "Editors")
    CreateTab(TAB_AUDIT,   "Audit Log")
	end

	RealignTabs()
    --------------------------------------------------------------------
    -- PANELS
    --------------------------------------------------------------------
    dkpPanel     = CreateFrame("Frame", nil, mainFrame); LayoutPanel(dkpPanel)
	
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
	
    altPanel = CreateFrame("Frame", nil, mainFrame); LayoutPanel(altPanel)
	groupPanel   = CreateFrame("Frame", nil, mainFrame); LayoutPanel(groupPanel)
	mlPanel      = CreateFrame("Frame", nil, mainFrame); LayoutPanel(mlPanel)
    raidPanel    = CreateFrame("Frame", nil, mainFrame); LayoutPanel(raidPanel)
    editorsPanel = CreateFrame("Frame", nil, mainFrame); LayoutPanel(editorsPanel)
    auditPanel   = CreateFrame("Frame", nil, mainFrame); LayoutPanel(auditPanel)
	
--------------------------------------------------------------------
-- ALT TRACKER PANEL
--------------------------------------------------------------------
do
    --------------------------------------------------------------------
    -- CONFIG
    --------------------------------------------------------------------
    local PANEL_WIDTH = 800
    local PANEL_HEIGHT = 450

    local LEFT_WIDTH = 300
    local RIGHT_WIDTH = 300
    local GAP = 50

    local TOPBAR_WIDTH = 400
    local ROW_HEIGHT = 20
	
	local PendingAlt = nil

    ----------------------------------------------------------------
    -- UTILITY: GET PLAYER NAME
    ----------------------------------------------------------------
    local function GetPlayerName()
        local name = UnitName("player")
        return name and Ambiguate(name, "none") or "Unknown"
    end

    ----------------------------------------------------------------
    -- UTILITY: CLASS COLOUR
    ----------------------------------------------------------------
    local function GetClassColor(name)
        local num = GetNumGuildMembers()
        for i = 1, num do
            local gName, _, _, _, _, _, _, _, _, _, class = GetGuildRosterInfo(i)
            if gName and Ambiguate(gName, "none") == name then
                local c = RAID_CLASS_COLORS[class]
                if c then
                    return string.format("|cff%02x%02x%02x", c.r*255, c.g*255, c.b*255)
                end
            end
        end
        return "|cffffffff"
    end

    ----------------------------------------------------------------
    -- UTILITY: GUILD ROSTER SNAPSHOT
    ----------------------------------------------------------------
    local function BuildGuildRosterList()
		--commented out refresh as might be causing lag spikes
        --if C_GuildInfo and C_GuildInfo.GuildRoster then
        --    C_GuildInfo.GuildRoster()
        --end

        local names = {}
        local num = GetNumGuildMembers()

        for i = 1, num do
            local info = GetGuildRosterInfo(i)
            local name = type(info) == "table" and info.name or info
            if name then
                name = Ambiguate(name, "none")
                table.insert(names, name)
            end
        end

        table.sort(names)
        return names
    end

    local GuildRosterCache = BuildGuildRosterList()

    ----------------------------------------------------------------
    -- UTILITY: CHECK IF NAME IS A MAIN
    ----------------------------------------------------------------
    function IsMain(name)
        return RedGuild_Alts[name] ~= nil
    end

    ----------------------------------------------------------------
    -- UTILITY: CHECK IF NAME IS AN ALT
    ----------------------------------------------------------------
    function IsAlt(name)
        return RedGuild_AltParent[name] ~= nil
    end

    ----------------------------------------------------------------
    -- UTILITY: GET MAIN OF ALT
    ----------------------------------------------------------------
    local function GetMainOf(alt)
        return RedGuild_AltParent[alt]
    end

    ----------------------------------------------------------------
    -- UTILITY: SAFE MESSAGE
    ----------------------------------------------------------------
    local function Msg(text)
        print("|cffff5555RedGuild AltTracker:|r " .. text)
    end

    ----------------------------------------------------------------
    -- TOP BAR FRAME (CENTERED)
    ----------------------------------------------------------------
    local topBar = CreateFrame("Frame", nil, altPanel)
    topBar:SetSize(TOPBAR_WIDTH, 40)
    topBar:SetPoint("TOP", altPanel, "TOP", -50, -40)

    topBar.text = topBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    topBar.text:SetPoint("LEFT", topBar, "LEFT", 0, 0)

----------------------------------------------------------------
-- DROPDOWN 1: MAIN / ALT
----------------------------------------------------------------
local statusDrop = CreateFrame("Frame", nil, topBar, "UIDropDownMenuTemplate")
statusDrop:SetPoint("LEFT", topBar.text, "RIGHT", 10, 0)

----------------------------------------------------------------
-- TEXT BETWEEN DROPDOWNS: "of"
----------------------------------------------------------------
topBar.mainLabel = topBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
topBar.mainLabel:SetPoint("LEFT", statusDrop, "RIGHT", 0, 0)
topBar.mainLabel:SetText("of")
topBar.mainLabel:Hide()

----------------------------------------------------------------
-- DROPDOWN 2: SELECT MAIN (ONLY WHEN ALT)
----------------------------------------------------------------
local mainSelectDrop = CreateFrame("Frame", nil, topBar, "UIDropDownMenuTemplate")
mainSelectDrop:SetPoint("LEFT", topBar.mainLabel, "RIGHT", 0, 0)
mainSelectDrop:Hide()

    ----------------------------------------------------------------
    -- LEFT PANEL (MAINS LIST)
    ----------------------------------------------------------------
    local leftPanel = CreateFrame("Frame", nil, altPanel, "BackdropTemplate")
    leftPanel:SetSize(LEFT_WIDTH, PANEL_HEIGHT - 80)
    leftPanel:SetPoint("TOPLEFT", altPanel, "TOPLEFT", 75, -80)
    leftPanel:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    leftPanel:SetBackdropColor(0,0,0,0.7)

    ----------------------------------------------------------------
    -- RIGHT PANEL (ALT SUMMARY)
    ----------------------------------------------------------------
    local rightPanel = CreateFrame("Frame", nil, altPanel, "BackdropTemplate")
    rightPanel:SetSize(RIGHT_WIDTH, PANEL_HEIGHT - 80)
    rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", GAP, 0)
    rightPanel:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    rightPanel:SetBackdropColor(0,0,0,0.7)
	
----------------------------------------------------------------
-- ADD MAIN (EDITOR ONLY)
----------------------------------------------------------------
leftPanel.addMainBtn = CreateFrame("Button", nil, leftPanel, "UIPanelButtonTemplate")
leftPanel.addMainBtn:SetSize(100, 22)
leftPanel.addMainBtn:SetPoint("BOTTOMLEFT", 20, -30)
leftPanel.addMainBtn:SetText("Add Main")

leftPanel.addMainInput = CreateFrame("EditBox", nil, leftPanel, "InputBoxTemplate")
leftPanel.addMainInput:SetSize(140, 22)
leftPanel.addMainInput:SetPoint("LEFT", leftPanel.addMainBtn, "RIGHT", 10, 0)
leftPanel.addMainInput:SetAutoFocus(false)
leftPanel.addMainInput:SetMaxLetters(12)

-- Editor visibility
local function UpdateAddMainVisibility()
    if IsEditor(GetPlayerName()) then
        leftPanel.addMainBtn:Show()
        leftPanel.addMainInput:Show()
    else
        leftPanel.addMainBtn:Hide()
        leftPanel.addMainInput:Hide()
    end
end

altPanel:HookScript("OnShow", UpdateAddMainVisibility)
UpdateAddMainVisibility()

leftPanel.addMainBtn:SetScript("OnClick", function()
    local name = leftPanel.addMainInput:GetText()
    if not name or name == "" then
        Msg("Please enter a character name.")
        return
    end

    name = Ambiguate(name, "none")

    -- Validate guild membership
    local valid = false
    for _, gName in ipairs(GuildRosterCache) do
        if NormalizeName(gName) == NormalizeName(name) then
            valid = true
            break
        end
    end

    if not valid then
        Msg(name .. " is not a valid guild member.")
        return
    end

    -- Cannot be an alt
    if IsAlt(name) then
        Msg(name .. " is currently an alt. Remove them from their main first.")
        return
    end

    -- Cannot already be a main
    if IsMain(name) then
        Msg(name .. " is already a main.")
        return
    end

    -- Add as main
    RedGuild_Alts[name] = {}
    RedGuild_AltParent[name] = nil

    -- Version bump
    RedGuild_Config.altsVersion = (RedGuild_Config.altsVersion or 0) + 1

    -- Broadcast
    BroadcastAltFieldUpdate("AltParent", { alt = name, main = nil })
    BroadcastAltFieldUpdate("AddMain",   { main = name })

    leftPanel.addMainInput:SetText("")
    RefreshMainsList()
    rightPanel.update()
    UpdateTopBar()
end)

    ----------------------------------------------------------------
    -- LEFT PANEL: SCROLL LIST OF MAINS
    ----------------------------------------------------------------
    local mainsScroll = CreateFrame("ScrollFrame", nil, leftPanel, "UIPanelScrollFrameTemplate")
    mainsScroll:SetPoint("TOPLEFT", 10, -10)
    mainsScroll:SetPoint("BOTTOMRIGHT", -30, 10)

    local mainsContent = CreateFrame("Frame", nil, mainsScroll)
    mainsContent:SetSize(LEFT_WIDTH - 40, 1)
    mainsScroll:SetScrollChild(mainsContent)

    local mainRows = {}
    local selectedMain = nil
    ----------------------------------------------------------------
    -- BUILD LIST OF CONFIRMED MAINS
    ----------------------------------------------------------------
    local function GetConfirmedMains()
        local mains = {}

        -- Any key in RedGuild_Alts is a main
        for main, _ in pairs(RedGuild_Alts) do
            table.insert(mains, main)
        end

        -- Any character marked as Main in the top bar (no parent)
        for _, name in ipairs(GuildRosterCache) do
            if not RedGuild_AltParent[name] and not RedGuild_Alts[name] then
                -- Only include if explicitly set as main by user
                -- (We track this by ensuring RedGuild_Alts[name] exists)
                -- If not, skip.
            end
        end

        table.sort(mains)
        return mains
    end

    ----------------------------------------------------------------
    -- LEFT PANEL: CREATE A ROW
    ----------------------------------------------------------------
    local function CreateMainRow(i)
        local row = CreateFrame("Button", nil, mainsContent)
        row:SetSize(LEFT_WIDTH - 40, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

        row.nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.nameFS:SetPoint("LEFT", 4, 0)

        row.countFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.countFS:SetPoint("RIGHT", -4, 0)

        row:SetScript("OnClick", function()
            selectedMain = row.name
            rightPanel:Show()
            rightPanel.update()
        end)

        return row
    end

    ----------------------------------------------------------------
    -- LEFT PANEL: REFRESH MAINS LIST
    ----------------------------------------------------------------
    function RefreshMainsList()
        local mains = GetConfirmedMains()
        local needed = #mains
        local current = #mainRows

        if needed > current then
            for i = current + 1, needed do
                mainRows[i] = CreateMainRow(i)
            end
        end

        for i, name in ipairs(mains) do
            local row = mainRows[i]
            row.name = name

		local color = GetClassColor(name)

		local statusText = ""
		if IsPlayerOnline(name) then
			statusText = " |cff55ff55(online)|r"
		else
			-- check if any alt is online
			local alts = RedGuild_Alts[name] or {}
			for _, alt in ipairs(alts) do
				if IsPlayerOnline(alt) then
					statusText = " |cffffff55(on alt)|r"
					break
				end
			end
		end

		row.nameFS:SetText(color .. name .. "|r" .. statusText)

            local count = RedGuild_Alts[name] and #RedGuild_Alts[name] or 0
            row.countFS:SetText(count)

            row:Show()
        end

        for i = needed + 1, #mainRows do
            mainRows[i]:Hide()
        end

        mainsContent:SetHeight(needed * ROW_HEIGHT)
    end

    ----------------------------------------------------------------
    -- RIGHT PANEL: UI ELEMENTS
    ----------------------------------------------------------------
    rightPanel.title = rightPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    rightPanel.title:SetPoint("TOPLEFT", 10, -10)

    rightPanel.altList = CreateFrame("Frame", nil, rightPanel)
    rightPanel.altList:SetPoint("TOPLEFT", 10, -40)
    rightPanel.altList:SetSize(RIGHT_WIDTH - 20, 1)

    rightPanel.altRows = {}

	----------------------------------------------------------------
	-- DELETE MAIN BUTTON (TOP RIGHT)
	----------------------------------------------------------------
	rightPanel.deleteMainBtn = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate")
	rightPanel.deleteMainBtn:SetSize(24, 24)
	rightPanel.deleteMainBtn:SetPoint("TOPRIGHT", -6, -6)
	rightPanel.deleteMainBtn:SetText("X")
	rightPanel.deleteMainBtn:SetNormalFontObject("GameFontHighlightSmall")
	rightPanel.deleteMainBtn:Hide()  -- editor-only

    ----------------------------------------------------------------
    -- RIGHT PANEL: CREATE ALT ROW
    ----------------------------------------------------------------
local function CreateAltRow(i)
    local row = CreateFrame("Frame", nil, rightPanel.altList)
    row:SetSize(RIGHT_WIDTH - 20, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

    row.nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.nameFS:SetPoint("LEFT", 4, 0)

    -- REMOVE BUTTON FIRST
    row.removeBtn = CreateFrame("Button", nil, row)
    row.removeBtn:SetPoint("RIGHT", -4, 0)
    row.removeBtn:SetSize(60, ROW_HEIGHT)

    row.removeBtn.text = row.removeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.removeBtn.text:SetPoint("CENTER")
    row.removeBtn.text:SetText("|cffff4444(remove)|r")

    -- NOW SET MAIN BUTTON
    row.setMainBtn = CreateFrame("Button", nil, row)
    row.setMainBtn:SetPoint("RIGHT", row.removeBtn, "LEFT", -5, 0)
    row.setMainBtn:SetSize(80, ROW_HEIGHT)

    row.setMainBtn.text = row.setMainBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.setMainBtn.text:SetPoint("CENTER")
    row.setMainBtn.text:SetText("|cff55ff55(set main)|r")
    row.setMainBtn:Hide()

    return row
end

    ----------------------------------------------------------------
    -- RIGHT PANEL: UPDATE FUNCTION
    ----------------------------------------------------------------
    function rightPanel.update()
        if not selectedMain then
            rightPanel.title:SetText("No main selected")
            for _, r in ipairs(rightPanel.altRows) do r:Hide() end
            return
        end

        local color = GetClassColor(selectedMain)
        rightPanel.title:SetText(color .. selectedMain .. "|r")

        local alts = RedGuild_Alts[selectedMain] or {}
        table.sort(alts)

        local needed = #alts
        local current = #rightPanel.altRows

        if needed > current then
            for i = current + 1, needed do
                rightPanel.altRows[i] = CreateAltRow(i)
            end
        end

        for i, alt in ipairs(alts) do
            local row = rightPanel.altRows[i]
            local c = GetClassColor(alt)
            local onlineText = IsPlayerOnline(alt) and " |cff55ff55(online)|r" or ""
			row.nameFS:SetText(c .. alt .. "|r" .. onlineText)
		
			if IsEditor(GetPlayerName()) then
				row.setMainBtn:Show()
			else
				row.setMainBtn:Hide()
			end

			row.setMainBtn:SetScript("OnClick", function()
				PromoteToMain(alt)
				ResetRightPanel()
				RefreshMainsList()
				UpdateTopBar()
			end)
			
			local viewer = GetPlayerName()
			local parent = RedGuild_AltParent[alt]

			if IsEditor(viewer) or (parent == viewer) then
				row.removeBtn:Show()
			else
				row.removeBtn:Hide()
			end

            row.removeBtn:SetScript("OnClick", function()
                -- Remove alt
                RedGuild_AltParent[alt] = nil
                for idx = #alts, 1, -1 do
                    if alts[idx] == alt then table.remove(alts, idx) end
                end
                rightPanel.update()
                RefreshMainsList()
				RedGuild_Config.altsVersion = (RedGuild_Config.altsVersion or 0) + 1
				BroadcastAltFieldUpdate("AltParent", { alt = alt, main = nil })
				BroadcastAltFieldUpdate("RemoveAltFromMain", { main = selectedMain, alt = alt })
            end)

            row:Show()
        end

        for i = needed + 1, #rightPanel.altRows do
            rightPanel.altRows[i]:Hide()
        end

        rightPanel.altList:SetHeight(needed * ROW_HEIGHT)
    end
	
	----------------------------------------------------------------
	-- RESET RIGHT PANEL (SAFE GLOBAL WRAPPER)
	----------------------------------------------------------------
	local function ResetRightPanel()
		selectedMain = nil
		rightPanel.update()
	end

	_G.ResetRightPanel = ResetRightPanel
	
    ----------------------------------------------------------------
    -- MAIN / ALT SWITCHING LOGIC
    ----------------------------------------------------------------

    -- Promote an alt to main (swap)
function PromoteToMain(alt)
    local oldMain = RedGuild_AltParent[alt]
    if not oldMain then return end

    -- promoted alt becomes a true main
    RedGuild_AltParent[alt] = nil
	
    -- (optional but sane to ensure a list exists)
    RedGuild_Alts[alt] = RedGuild_Alts[alt] or {}

    -- Old main's alt list
    local oldList = RedGuild_Alts[oldMain] or {}

    -- New main's alt list (keep any existing alts on alt)
    local newList = RedGuild_Alts[alt] or {}

    ----------------------------------------------------------------
    -- MOVE ALL ALTS FROM OLD MAIN → NEW MAIN
    ----------------------------------------------------------------
    for i = #oldList, 1, -1 do
        local a = oldList[i]

        if a == alt then
            -- Remove the promoted alt from old main's list
            table.remove(oldList, i)
        else
            -- Move this alt under the new main
            RedGuild_AltParent[a] = alt
            table.insert(newList, a)

            -- Remove from old main
            table.remove(oldList, i)

            -- Broadcast this alt's new parent
            BroadcastAltFieldUpdate("AltParent", { alt = a, main = alt })
            BroadcastAltFieldUpdate("AddAltToMain", { main = alt, alt = a })
        end
    end

    ----------------------------------------------------------------
    -- OLD MAIN BECOMES AN ALT OF THE NEW MAIN
    ----------------------------------------------------------------
    RedGuild_AltParent[oldMain] = alt
    table.insert(newList, oldMain)

    BroadcastAltFieldUpdate("AltParent", { alt = oldMain, main = alt })
    BroadcastAltFieldUpdate("AddAltToMain", { main = alt, alt = oldMain })

    ----------------------------------------------------------------
    -- FINAL TABLE ASSIGNMENTS
    ----------------------------------------------------------------
    RedGuild_Alts[alt] = newList

    if #oldList == 0 then
        RedGuild_Alts[oldMain] = nil
    else
        RedGuild_Alts[oldMain] = oldList
    end

    ----------------------------------------------------------------
    -- VERSION BUMP
    ----------------------------------------------------------------
    RedGuild_Config.altsVersion = (RedGuild_Config.altsVersion or 0) + 1
end

function AssignAlt(alt, main)
    -- If this character is a main, only block if they have alts
    if IsMain(alt) then
        local altCount = RedGuild_Alts[alt] and #RedGuild_Alts[alt] or 0
        if altCount > 0 then
            Msg(alt .. " is designated as a main and has alts. Please reassign those alts first.")
            return false
        end

        -- They are a main with zero alts → allow demotion
        RedGuild_Alts[alt] = nil
    end

    -- Remove from previous parent
    local oldMain = RedGuild_AltParent[alt]
    if oldMain then
        local t = RedGuild_Alts[oldMain]
        if t then
            for i = #t, 1, -1 do
                if t[i] == alt then table.remove(t, i) end
            end
        end
    end

    -- Assign new parent
    RedGuild_AltParent[alt] = main
    RedGuild_Alts[main] = RedGuild_Alts[main] or {}
    table.insert(RedGuild_Alts[main], alt)

    RedGuild_Config.altsVersion = (RedGuild_Config.altsVersion or 0) + 1

    BroadcastAltFieldUpdate("AltParent", { alt = alt, main = main })
    BroadcastAltFieldUpdate("AddAltToMain", { main = main, alt = alt })

    return true
end
	
----------------------------------------------------------------
-- INITIALIZER FOR MAIN-SELECT DROPDOWN
----------------------------------------------------------------
local function InitMainSelectDropdown(self, level)
    local player = GetPlayerName()
    local mains  = GetConfirmedMains()

    for _, name in ipairs(mains) do
        if name ~= player then
            local info = UIDropDownMenu_CreateInfo()
            info.text = name
            info.func = function()
    if AssignAlt(player, name) then
        -- Version bump
        RedGuild_Config.altsVersion = (RedGuild_Config.altsVersion or 0) + 1

        -- Broadcast the change
        BroadcastAltFieldUpdate("AltParent", { alt = player, main = name })
        BroadcastAltFieldUpdate("AddAltToMain", { main = name, alt = player })
    end

    PendingAlt = nil
    RefreshMainsList()
    rightPanel.update()
    UpdateTopBar()
end
            UIDropDownMenu_AddButton(info)
        end
    end
end

UIDropDownMenu_SetWidth(mainSelectDrop, 140)
UIDropDownMenu_Initialize(mainSelectDrop,  InitMainSelectDropdown)

----------------------------------------------------------------
-- TOP BAR UPDATE
----------------------------------------------------------------
function UpdateTopBar()

	-- Prevent early calls before UI is created
	if not statusDrop or not mainSelectDrop or not topBar or not topBar.text then
		return
	end
	
    local player = GetPlayerName()
    local color  = GetClassColor(player)

    local isAlt  = IsAlt(player)
    local parent = GetMainOf(player)
    local isMain = IsMain(player)

    -- Base text: "You are on <name> who is a "
    topBar.text:SetText("You are on " .. color .. player .. "|r who is a")

    ----------------------------------------------------------------
    -- STATUS RESOLUTION: Main / Alt / Select / Pending Alt
    ----------------------------------------------------------------
    local statusText
    local showMainSelect = false

    if PendingAlt == player then
        -- User has chosen "Alt" but not yet picked a main
        statusText = "Alt"
        showMainSelect = true
    elseif isAlt then
        -- Already an alt with a stored parent
        statusText = "Alt"
        showMainSelect = true
    elseif isMain then
        statusText = "Main"
        showMainSelect = false
    else
        statusText = "Select"
        showMainSelect = false
    end

    UIDropDownMenu_SetText(statusDrop, statusText)

    if showMainSelect then
        UIDropDownMenu_SetText(mainSelectDrop, parent or "")
    else
        UIDropDownMenu_SetText(mainSelectDrop, "")
    end
	
    ----------------------------------------------------------------
    -- DROPDOWN 1: MAIN / ALT
    ----------------------------------------------------------------
    UIDropDownMenu_SetWidth(statusDrop, 80)
    UIDropDownMenu_Initialize(statusDrop, function(self, level)
        local info

        -- OPTION: MAIN
        info = UIDropDownMenu_CreateInfo()
        info.text = "Main"
        info.func = function()
            -- Clear any pending alt state
            PendingAlt = nil

            -- If currently an alt, promote to main (swap)
            if IsAlt(player) then
                PromoteToMain(player)
            end

            -- Ensure this character is recorded as a main
            RedGuild_Alts[player] = RedGuild_Alts[player] or {}
            RedGuild_AltParent[player] = nil

            mainSelectDrop:Hide()
            RefreshMainsList()
            rightPanel.update()
            UpdateTopBar()
        end
        UIDropDownMenu_AddButton(info)

        -- OPTION: ALT
		info = UIDropDownMenu_CreateInfo()
		info.text = "Alt"
		info.func = function()
		local altCount = (RedGuild_Alts[player] and #RedGuild_Alts[player]) or 0

		-- Only block if they are a main WITH alts
		if IsMain(player) and altCount > 0 then
			Msg("This character has alts, please first set one of those as your main (You will need to log that toon on).")
			return
		end

		-- Allow demotion if they are a main with zero alts
		PendingAlt = player

    UpdateTopBar()
end
UIDropDownMenu_AddButton(info)
    end)

    UIDropDownMenu_SetText(statusDrop, statusText)

    ----------------------------------------------------------------
    -- DROPDOWN 2: SELECT MAIN (ONLY WHEN ALT OR PENDING ALT)
    ----------------------------------------------------------------
    if showMainSelect then
		topBar.mainLabel:Show()
		mainSelectDrop:Show()
		UIDropDownMenu_SetText(mainSelectDrop, parent or "Select")
	else
		topBar.mainLabel:Hide()
		mainSelectDrop:Hide()
	end
end

    ----------------------------------------------------------------
    -- EDITOR TOOLS (ADD ALT / SET AS MAIN)
    ----------------------------------------------------------------
    rightPanel.addAltBtn = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate")
    rightPanel.addAltBtn:SetSize(100, 22)
    rightPanel.addAltBtn:SetPoint("BOTTOMLEFT", 30, -30)
    rightPanel.addAltBtn:SetText("Add Alt")
	
	rightPanel.addAltInput = CreateFrame("EditBox", nil, rightPanel, "InputBoxTemplate")
	rightPanel.addAltInput:SetSize(120, 22)
	rightPanel.addAltInput:SetPoint("LEFT", rightPanel.addAltBtn, "RIGHT", 10, 0)
	rightPanel.addAltInput:SetAutoFocus(false)
	rightPanel.addAltInput:SetMaxLetters(12)
	
	----------------------------------------------------------------
    -- HIDE EDITOR BUTTONS FOR NON‑EDITORS
    ----------------------------------------------------------------
local function UpdateEditorButtons()
    local isEditor = IsEditor(GetPlayerName())

    if isEditor then
        rightPanel.addAltBtn:Show()
        rightPanel.addAltInput:Show()
		rightPanel.deleteMainBtn:Show()
    else
        rightPanel.addAltBtn:Hide()
        rightPanel.addAltInput:Hide()
		rightPanel.deleteMainBtn:Hide()
    end
end
	
	-- Ensure editor buttons update every time the panel becomes visibleset
	altPanel:HookScript("OnShow", function()
		UpdateEditorButtons()
	end)

	rightPanel.addAltBtn:SetScript("OnClick", function()
		if not selectedMain then return end

		local name = rightPanel.addAltInput:GetText()
		if not name or name == "" then
			Msg("Please enter a character name.")
			return
		end

		name = Ambiguate(name, "none")

		-- Validate against guild roster
		local valid = false
		for _, gName in ipairs(GuildRosterCache) do
			if NormalizeName(gName) == NormalizeName(name) then
				valid = true
				break
			end
		end

		if not valid then
			Msg(name .. " is not a valid guild member.")
			return
		end

		-- Assign alt
		AssignAlt(name, selectedMain)
		rightPanel.addAltInput:SetText("")
		RefreshMainsList()
		rightPanel.update()
	end)
	
	rightPanel.deleteMainBtn:SetScript("OnClick", function()
		if not selectedMain then return end
			StaticPopup_Show("REDGUILD_DELETE_MAIN", selectedMain, nil, selectedMain)
	end)

	UpdateEditorButtons()
    ----------------------------------------------------------------
    -- FULL REFRESH
    ----------------------------------------------------------------
    local function FullRefresh()
        GuildRosterCache = BuildGuildRosterList()
        RefreshMainsList()
        rightPanel.update()
        UpdateTopBar()
    end

    altPanel:SetScript("OnShow", FullRefresh)
    ----------------------------------------------------------------
    -- INITIALISE ON LOAD (if panel is already visible)
    ----------------------------------------------------------------
    if altPanel:IsShown() then
        FullRefresh()
    end
end	
	

--------------------------------------------------------------------
-- GROUP BUILDER PANEL (INVITER)
--------------------------------------------------------------------
selectedState = selectedState or {}
do
    ------------------------------------------------------------
    -- TITLE
    ------------------------------------------------------------
    local title = groupPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 30, -30)
    title:SetText("")
	local RefreshGroupBuilder
	
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
    -- RIGHT SIDE: INFO BOX
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
			if row.checkbox:GetChecked() and row.name then
				table.insert(selected, row.name)

        ------------------------------------------------------------
        -- SAFE LOOKUP (DKP players have data, guild-only do not)
        ------------------------------------------------------------
        local d = RedGuild_Data[row.name]

        ------------------------------------------------------------
        -- CLASS COUNT (only DKP players have class data)
        ------------------------------------------------------------
        local class = d and d.class or nil
        if class then
            classCounts[class] = (classCounts[class] or 0) + 1
        end

        ------------------------------------------------------------
        -- ROLE COUNT (only DKP players have msRole)
        ------------------------------------------------------------
        local spec = d and d.msRole or nil
        local role = SPEC_ROLES[spec]

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
        table.insert(lines, "Roles (Main spec ONLY):")
        table.insert(lines, string.format("  Tanks: %d", roleCounts.tank))
        table.insert(lines, string.format("  Melee DPS: %d", roleCounts.melee))
        table.insert(lines, string.format("  Ranged DPS: %d", roleCounts.ranged))
        table.insert(lines, string.format("  Caster DPS: %d", roleCounts.caster))
        table.insert(lines, string.format("  Healers: %d", roleCounts.healer))
        table.insert(lines, string.format("  Unknown: %d", roleCounts.unknown))
		
		------------------------------------------------------------
		-- MAIN / ALT COUNTS (ALT TRACKER INTEGRATION)
		------------------------------------------------------------
		local mainCount = 0
		local altCount  = 0

		for _, name in ipairs(selected) do
			if IsAlt and IsAlt(name) then
				altCount = altCount + 1
			else
				-- treat unknowns as mains
				mainCount = mainCount + 1
			end
		end

		table.insert(lines, "")
		table.insert(lines, string.format("Mains: |cffffff00%d|r", mainCount))
		table.insert(lines, string.format("Alts:  |cffffff00%d|r", altCount))

        ------------------------------------------------------------
        -- GROUP MEMBERSHIP CHECK
        ------------------------------------------------------------
        local groupMembers = {}
		
		if not IsInRaid() and not IsInGroup() then
			local playerName = UnitName("player")
			if playerName then
				groupMembers[playerName] = true
			end
		end

        if IsInRaid() then
            for i = 1, GetNumGroupMembers() do
                local name = UnitName("raid"..i)
                if name then groupMembers[name] = true end
            end
        elseif IsInGroup() then
            for i = 1, GetNumSubgroupMembers() do
                local name = UnitName("party"..i)
                if name then groupMembers[name] = true end
            end
            groupMembers[UnitName("player")] = true
        end

        local missing = {}
        for _, name in ipairs(selected) do
            if not groupMembers[name] then
                table.insert(missing, name)
            end
        end

        table.insert(lines, "")
        
		------------------------------------------------------------
		-- SOLO MODE FIX: COUNT YOURSELF IF SELECTED
		------------------------------------------------------------
		local groupCount = GetNumGroupMembers()

		if groupCount == 0 then
			-- solo: check if the player is selected
			local playerName = Ambiguate(UnitName("player"), "short")
			for _, name in ipairs(selected) do
				if name == playerName then
					groupCount = 1
					break
				end
			end
		end

		table.insert(lines, string.format("In your group: |cffffff00%d|r", groupCount))
		
        table.insert(lines, "Missing from group:")

        if #missing == 0 then
            table.insert(lines, "  |cff00ff00None|r")
        else
            local row = {}
            for i, name in ipairs(missing) do
                local online = IsPlayerOnline(name)
				local offlineText = online and "" or " |cffaaaaaa(off)|r"
				local online = IsPlayerOnline(name)

				local colour = online and "|cffff3333" or "|cffaaaaaa"   -- red if online, grey if offline
				local display = colour .. name .. "|r"

				table.insert(row, display)
                if #row == 4 then
                    table.insert(lines, "  " .. table.concat(row, ", "))
                    row = {}
                end
            end
            if #row > 0 then
                table.insert(lines, "  " .. table.concat(row, ", "))
            end
        end

        infoText:SetText(table.concat(lines, "\n"))
        infoText:SetText(infoText:GetText() .. "\n\n|cffaaaaaaGrey names are not online.|r")
    end

    ------------------------------------------------------------
    -- SELECT ALL / DESELECT ALL CHECKBOX
    ------------------------------------------------------------
    local selectAllChk = CreateFrame("CheckButton", nil, groupPanel, "ChatConfigCheckButtonTemplate")
    selectAllChk:SetPoint("TOPLEFT", groupPanel, "TOPLEFT", 70, -35)
    selectAllChk:SetSize(18, 18)
	selectAllChk:SetHitRectInsets(4, 4, 4, 4)

    local selectAllLabel = groupPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    selectAllLabel:SetPoint("LEFT", selectAllChk, "RIGHT", 4, 0)
    selectAllLabel:SetText("Select all")

    selectAllChk:SetScript("OnClick", function(self)
        local checked = self:GetChecked()

        for _, row in ipairs(groupRows) do
            if row:IsShown() then
                row.checkbox:SetChecked(checked)
                selectedState[row.name] = checked
            end
        end

        UpdateGroupBuilderInfo()
    end)
	
	------------------------------------------------------------
	-- ADD ONLINE GUILD MEMBERS CHECKBOX
	------------------------------------------------------------
	local addGuildChk = CreateFrame("CheckButton", nil, groupPanel, "ChatConfigCheckButtonTemplate")
	addGuildChk:SetPoint("LEFT", selectAllLabel, "RIGHT", 40, 0)
	addGuildChk:SetSize(18, 18)
	addGuildChk:SetHitRectInsets(4, 4, 4, 4)

	local addGuildLabel = groupPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	addGuildLabel:SetPoint("LEFT", addGuildChk, "RIGHT", 4, 0)
	addGuildLabel:SetText("Add online guild members")

	addGuildChk:SetScript("OnClick", function()
		RefreshGroupBuilder()
	end)
	
	------------------------------------------------------------
	-- HIDE IN-GROUP MEMBERS CHECKBOX
	------------------------------------------------------------
	local hideGroupChk = CreateFrame("CheckButton", nil, groupPanel, "ChatConfigCheckButtonTemplate")
	hideGroupChk:SetPoint("LEFT", addGuildLabel, "RIGHT", 40, 0)
	hideGroupChk:SetSize(18, 18)
	hideGroupChk:SetHitRectInsets(4, 4, 4, 4)

	local hideGroupLabel = groupPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hideGroupLabel:SetPoint("LEFT", hideGroupChk, "RIGHT", 4, 0)
	hideGroupLabel:SetText("Hide users already in group")

	hideGroupChk:SetScript("OnClick", function()
		RefreshGroupBuilder()
	end)

    ------------------------------------------------------------
    -- REFRESH LIST
    ------------------------------------------------------------
    RefreshGroupBuilder = function()
        for _, row in ipairs(groupRows) do
            row:Hide()
        end
        wipe(groupRows)

        local names = {}

		-- 1. DKP table names
		for name in pairs(RedGuild_Data) do
			table.insert(names, name)
		end

		-- 2. Add online guild members if checkbox is ticked
		if addGuildChk:GetChecked() then
			local num = GetNumGuildMembers()
			for i = 1, num do
				local gName, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
				if gName then
					gName = Ambiguate(gName, "short")
					if online then
						-- Only add if not already in DKP table
						if not RedGuild_Data[gName] then
							table.insert(names, gName)
						end
					end
				end
			end
		end

		table.sort(names)

        local i = 0
        for _, name in ipairs(names) do
            local isInvalid = RuntimeInvalid(name)

				-- NEW: hide users already in group
				local hideThis = false
				if hideGroupChk:GetChecked() then
					if UnitInParty(name) or UnitInRaid(name) then
						hideThis = true
					end
				end

				if not isInvalid and not hideThis then
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

                local class = RedGuild_Data[name] and RedGuild_Data[name].class or nil
				local colour = CLASS_COLORS[class] or "|cffaaaaaa"   -- grey if unknown class

                local online = IsPlayerOnline(name)
				local offlineText = online and "" or " |cffaaaaaa(offline)|r"

				------------------------------------------------------------
				-- IN-GROUP CHECK (raid or party)
				------------------------------------------------------------
				local inGroup = false

				if IsInRaid() then
					for i = 1, GetNumGroupMembers() do
						if Ambiguate(UnitName("raid"..i), "short") == name then
							inGroup = true
							break
						end
					end
				elseif IsInGroup() then
					for i = 1, GetNumSubgroupMembers() do
						if Ambiguate(UnitName("party"..i), "short") == name then
							inGroup = true
							break
						end
					end

					-- Include the player themselves
					if Ambiguate(UnitName("player"), "short") == name then
						inGroup = true
					end
				end

				local inGroupText = inGroup and " |cff00ff00(in group)|r" or ""

				------------------------------------------------------------
				-- FINAL NAME STRING
				------------------------------------------------------------
				row.nameFS:SetText(colour .. name .. "|r" .. offlineText .. inGroupText)

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
-- ML SCORECARD PANEL
--------------------------------------------------------------------
local mlShowGroupOnly = false
do
    ----------------------------------------------------------------
    -- COLUMN HEADERS
    ----------------------------------------------------------------
    local headerFrame = CreateFrame("Frame", nil, mlPanel)
    headerFrame:SetPoint("TOPLEFT", mlPanel, "TOPLEFT", 60, -40)
    headerFrame:SetSize(600, 20)

local headers = {
    { text = "Name",      width = 120 },
    { text = "Main (MS)", width = 80  },
    { text = "Alt (MS)",  width = 80  },
    { text = "Main (OS)", width = 80  },
    { text = "Alt (OS)",  width = 80  },
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
local COL_ALT_MS   = 3
local COL_MAIN_OS  = 4
local COL_ALT_OS   = 5
local COL_NOTES    = 6

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
    [COL_NAME]     = 120,
    [COL_MAIN_MS]  = 80,
    [COL_ALT_MS]   = 80,
    [COL_MAIN_OS]  = 80,
    [COL_ALT_OS]   = 80,
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

        elseif col == COL_MAIN_MS or col == COL_ALT_MS or col == COL_MAIN_OS or col == COL_ALT_OS then
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
    local names = {}
    for name in pairs(RedGuild_ML or {}) do
        table.insert(names, name)
    end
    table.sort(names, function(a, b)
    local function weight(name)
        if IsMain(name) then
            return 0   -- mains first
        elseif IsAlt(name) then
            return 2   -- alts last
        else
            return 1   -- unknowns in the middle
        end
    end

    local wa = weight(a)
    local wb = weight(b)

    if wa ~= wb then
        return wa < wb
    end

    return a < b
end)
	
	-- Remove characters no longer in guild
	local filtered = {}
	for _, name in ipairs(names) do
		if IsNameInGuild(name) then
			table.insert(filtered, name)
		end
	end
	names = filtered

----------------------------------------------------------------
-- INSERT GROUP FILTER HERE
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
local altMSBtn  = row.cols[COL_ALT_MS]
local mainOSBtn = row.cols[COL_MAIN_OS]
local altOSBtn  = row.cols[COL_ALT_OS]
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
altMSBtn:SetText(tostring(mlData.mlAltMS or 0))
mainOSBtn:SetText(tostring(mlData.mlMainOS or 0))
altOSBtn:SetText(tostring(mlData.mlAltOS or 0))
    notesBtn:SetText(mlData.mlNotes or "")

------------------------------------------------------------
-- ALT TRACKER INTEGRATION: HIDE/SHOW COLUMNS
------------------------------------------------------------
if IsMain(name) then
    -- Mains: hide alt columns
    altMSBtn:Hide()
    altOSBtn:Hide()
    mainMSBtn:Show()
    mainOSBtn:Show()

elseif IsAlt(name) then
    -- Alts: hide main columns
    mainMSBtn:Hide()
    mainOSBtn:Hide()
    altMSBtn:Show()
    altOSBtn:Show()

else
    -- Unknown to alt tracker: show everything
    mainMSBtn:Show()
    mainOSBtn:Show()
    altMSBtn:Show()
    altOSBtn:Show()
end

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
altMSBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mainOSBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
altOSBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

mainMSBtn:SetScript("OnClick", makeMLHandler("mlMainMS"))
altMSBtn:SetScript("OnClick",  makeMLHandler("mlAltMS"))
mainOSBtn:SetScript("OnClick", makeMLHandler("mlMainOS"))
altOSBtn:SetScript("OnClick",  makeMLHandler("mlAltOS"))

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
            local oldAltMS   = tonumber(ml.mlAltMS or 0) or 0
			local oldMainOS   = tonumber(ml.mlMainOS or 0) or 0
			local oldAltOS   = tonumber(ml.mlAltOS or 0) or 0
            local oldNotes = ml.mlNotes or ""

            if oldMainMS ~= 0 then
                ml.mlMainMS = 0
            end

            if oldAltMS ~= 0 then
                ml.mlAltMS = 0
            end
			
            if oldMainOS ~= 0 then
                ml.mlMainOS = 0
            end

            if oldAltOS ~= 0 then
                ml.mlAltOS = 0
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

    --------------------------------------------------------------------
    -- EDITORS PANEL
    --------------------------------------------------------------------
	local versionLabel
	local addonOnlineFS
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
        removeNote:SetText("|cffaaaaaa* select name and click to remove|r")

        editorsPanel.selectedEditor = nil

addBtn:SetScript("OnClick", function()
    if not (IsGuildOfficer() or IsEditor(UnitName("player"))) then
        Print("Only guild leader or editors can add to the editor list.")
        return
    end

    local raw = addBox:GetText()
    if not raw or raw == "" then
        Print("|cffff0000RedGuild:|r No name entered.")
        return
    end

    local short = Ambiguate(raw, "short")
    local ok, proper = IsNameInGuild(short)
    if not ok then
        Print("|cffff0000RedGuild:|r Cannot add editor — player is not in your guild.")
        return
    end

    short = proper
    local key = NormalizeName(short)

    EnsureSaved()

    if RedGuild_Config.authorizedEditors[key] then
        Print("|cffffff00RedGuild:|r " .. short .. " is already an editor.")
        return
    end

    RedGuild_Config.authorizedEditors[key] = true
    RedGuild_Config.editorListVersion = (RedGuild_Config.editorListVersion or 0) + 1

    addBox:SetText("")
	UpdateTable()
	RefreshMLTools()
    RefreshEditorList()

    -- Broadcast to all addon users
    local me = NormalizeName(UnitName("player"))
    for name in pairs(RedGuild_Config.addonUsers) do
        if name ~= me and IsPlayerOnline(name) then
            BroadcastEditorListTo(name)
        end
    end
end)

        removeBtn:SetScript("OnClick", function()
            if not IsGuildOfficer() then
                Print("Only guild leader can remove from the editor list.")
                return
            end

            local selected = editorsPanel.selectedEditor
            if not selected or selected == "" then
                Print("|cffff0000RedGuild:|r No editor selected.")
                return
            end

            local key = NormalizeName(selected)
            if not key then
                Print("|cffff0000RedGuild:|r Invalid selected name.")
                return
            end

            EnsureSaved()

            -- Protected editor (guild leader) cannot be removed
            local protected = RedGuild_Config.protectedEditor
            if protected and key == protected then
                Print("|cffff0000RedGuild:|r You cannot remove the protected editor (guild leader).")
                return
            end

            if not RedGuild_Config.authorizedEditors[key] then
                Print("|cffff0000RedGuild:|r That name is not in the editor list.")
                return
            end

            RedGuild_Config.authorizedEditors[key] = nil
            RedGuild_Config.editorListVersion = (RedGuild_Config.editorListVersion or 0) + 1

            editorsPanel.selectedEditor = nil
            RefreshEditorList()

            -- Broadcast updated editor list to all known addon users
            EnsureConfig()
            local me = NormalizeName(UnitName("player"))
            for name in pairs(RedGuild_Config.addonUsers) do
                if name ~= me and IsPlayerOnline(name) then
                    BroadcastEditorListTo(name)
                end
            end
        end)

        editorsPanel:SetScript("OnShow", function()
            C_Timer.After(0.05, RefreshEditorList)
            dkpPanel:SetScript("OnShow", UpdateTable)
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

----------------------------------------------------------------
-- DKP VERSION EDIT BOX
----------------------------------------------------------------
versionLabel = editorsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
versionLabel:SetPoint("BOTTOMRIGHT", editorsPanel, "BOTTOMRIGHT", -100, 20)
versionLabel:SetText("Your DKP Table Version:")

local versionEdit = CreateFrame("EditBox", nil, editorsPanel, "InputBoxTemplate")
versionEdit:SetAutoFocus(false)
versionEdit:SetSize(60, 20)
versionEdit:SetPoint("LEFT", versionLabel, "RIGHT", 10, 0)

-- Load current version when panel is shown
editorsPanel:HookScript("OnShow", function()
    local online = CountOnlineAddonUsers()
    versionEdit:SetText(tostring(RedGuild_Config.dkpVersion or 0))
end)

-- Save on Enter
versionEdit:SetScript("OnEnterPressed", function(self)
    local newVal = tonumber(self:GetText())
    if newVal then
        RedGuild_Config.dkpVersion = newVal
		local me = NormalizeName(UnitName("player"))
		RedGuild_Config.EditorVersions[me] = newVal
        Print("|cff00ff00DKP version updated to " .. newVal .. ".|r")
        UpdateTable()
    else
        Print("|cffff5555Invalid version number.|r")
    end
    self:ClearFocus()
end)

-- Save on focus lost
versionEdit:SetScript("OnEditFocusLost", function(self)
    local newVal = tonumber(self:GetText())
    if newVal then
        RedGuild_Config.dkpVersion = newVal
		local me = NormalizeName(UnitName("player"))
		RedGuild_Config.EditorVersions[me] = newVal
        UpdateTable()
    end
end)

        local note = editorsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        note:SetPoint("BOTTOMLEFT", editorsPanel, "BOTTOMLEFT", 10, 10)
        note:SetJustifyH("LEFT")
        note:SetText("|cffaaaaaa* Guild leaders are editors by default.|r")
    end

----------------------------------------------------------------
-- REVERT DKP BACKUP BUTTON (Editors only)
----------------------------------------------------------------
local revertBtn = CreateFrame("Button", nil, editorsPanel, "UIPanelButtonTemplate")
revertBtn:SetSize(140, 22)
revertBtn:SetText("Revert DKP Backup")
revertBtn:SetPoint("BOTTOMRIGHT", editorsPanel, "BOTTOMRIGHT", -20, 50)

revertBtn:SetScript("OnClick", function()
    if not RedGuild_BackupData or not RedGuild_BackupData.data then
        Print("|cffff5555No DKP backup available.|r")
        return
    end

    StaticPopup_Show("REDGUILD_RESTORE_DKP_CONFIRM")
end)

-- Only show button to editors
editorsPanel:HookScript("OnShow", function()
    local canEditEditors = IsGuildOfficer() or IsEditor(UnitName("player"))
    if canEditEditors then
        revertBtn:Show()
    else
        revertBtn:Hide()
    end
end)

------------------------------------------------------------
-- HIDE ME FROM SYNC CHECKBOX
------------------------------------------------------------
local hideSyncChk = CreateFrame("CheckButton", nil, editorsPanel, "ChatConfigCheckButtonTemplate")
hideSyncChk:SetSize(18, 18)
hideSyncChk:ClearAllPoints()
hideSyncChk:SetPoint("RIGHT", versionLabel, "LEFT", -200, 0)


local hideSyncLabel = editorsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hideSyncLabel:SetPoint("LEFT", hideSyncChk, "RIGHT", 4, 0)
hideSyncLabel:SetText("Hide me from SYNC")

hideSyncChk:SetHitRectInsets(4, 4, 4, 4)

-- Load saved state
C_Timer.After(0.05, function()
    hideSyncChk:SetChecked(RedGuild_Config.hideMeFromSync)
end)

-- Save state when clicked
hideSyncChk:SetScript("OnClick", function(self)
    RedGuild_Config.hideMeFromSync = self:GetChecked() and true or false
end)


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
if IsEditor(UnitName("player")) then

-- SHOW HIDDEN RECORDS
local showHiddenChk = CreateFrame("CheckButton", nil, dkpPanel, "ChatConfigCheckButtonTemplate")
showHiddenChk:SetPoint("TOPLEFT", dkpPanel, "TOPLEFT", 80, -30)
showHiddenChk:SetSize(18, 18)

local showHiddenLabel = dkpPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
showHiddenLabel:SetPoint("LEFT", showHiddenChk, "RIGHT", 4, 0)
showHiddenLabel:SetText("Show hidden records")

-- Only editors see it
if not IsEditor(UnitName("player")) then
    showHiddenChk:Hide()
    showHiddenLabel:Hide()
end

showHiddenChk:SetScript("OnClick", function(self)
    showHiddenRecords = self:GetChecked() or false
    UpdateTable()
end)


----------------------------------------------------------------
-- SHOW GROUP/RAID ONLY
----------------------------------------------------------------
local showGroupChk = CreateFrame("CheckButton", nil, dkpPanel, "ChatConfigCheckButtonTemplate")
showGroupChk:SetPoint("LEFT", showHiddenLabel, "RIGHT", 40, 0)
showGroupChk:SetSize(18, 18)

local showGroupLabel = dkpPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
showGroupLabel:SetPoint("LEFT", showGroupChk, "RIGHT", 4, 0)
showGroupLabel:SetText("Show group/raid players only")

-- Only editors see it
if not IsEditor(UnitName("player")) then
    showGroupChk:Hide()
    showGroupLabel:Hide()
end

showGroupChk:SetScript("OnClick", function(self)
    C_Timer.After(0, function()
        dkpShowGroupOnly = self:GetChecked()
        UpdateTable()
    end)
end)

end

	----------------------------------
	-- DKP TABLE SCROLL
	----------------------------------

    dkpScroll = CreateFrame("ScrollFrame", nil, dkpPanel, "UIPanelScrollFrameTemplate")
    dkpScroll:SetPoint("TOPLEFT", dkpPanel, "TOPLEFT", 30, headerY - 20)
    dkpScroll:SetPoint("BOTTOMRIGHT", dkpPanel, "BOTTOMRIGHT", -30, 60)

    local sb = dkpScroll.ScrollBar
    if sb then
        sb:ClearAllPoints()
        sb:SetPoint("TOPRIGHT", dkpScroll, "TOPRIGHT", -5, -18)
        sb:SetPoint("BOTTOMRIGHT", dkpScroll, "BOTTOMRIGHT", -20, 16)
    end

    dkpScrollChild = CreateFrame("Frame", nil, dkpScroll)
    
    dkpScrollChild:SetPoint("TOPLEFT", 0, 0)
    dkpScrollChild:SetWidth(1)
    
    dkpScroll:SetScrollChild(dkpScrollChild)
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
		    if RedGuild_Config.hideMeFromSync then
				StaticPopup_Show("REDGUILD_FORCE_SYNC_BLOCKED")
				return
			end
			
            StaticPopup_Show("REDGUILD_FORCE_SYNC_CONFIRM")
        end)
    end

    --------------------------------------------------------------------
    -- FINALIZE
    --------------------------------------------------------------------
    RecalculateAllBalances()
	UpdateSyncStatus()
	dkpPanel:SetScript("OnShow", function()
    UpdateTable()
	end)

RedGuild_UIReady = true
ShowTab(TAB_DKP)
end

-----------------------------
-- Smart sync payload helpers
-----------------------------

-- [FORCE SYNC REWRITE] DKP‑only payload
local function BuildSyncPayload()
    return {
        sender = UnitName("player"),
        dkp = CopyTable(RedGuild_Data),  -- IMPORTANT: copy, don’t reference
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

function BroadcastAltFieldUpdate(field, value)
    RedGuild_Config.altsVersion = (RedGuild_Config.altsVersion or 0) + 1

    local update = {
        type    = "field",
        version = RedGuild_Config.altsVersion,
        field   = field,
        value   = value,
    }

    local encoded = EncodePayload(update)
    RedGuild_Send("ALTS_UPDATE", encoded)
end

local function ApplyAltFieldUpdate(update)
    if type(update) ~= "table" then return end

    local incoming = tonumber(update.version or 0)
    local localVer = tonumber(RedGuild_Config.altsVersion or 0)

    if incoming < localVer then return end
    RedGuild_Config.altsVersion = incoming

    local field = update.field
    local value = update.value

    if field == "AltParent" then
        local alt  = value.alt
        local main = value.main
        if alt and main and alt ~= main then
            RedGuild_AltParent[alt] = main
        end
        return
    end

    if field == "AddAltToMain" then
        local main = value.main
        local alt  = value.alt
        if main and alt then
            RedGuild_Alts[main] = RedGuild_Alts[main] or {}
            for _, a in ipairs(RedGuild_Alts[main]) do
                if a == alt then return end
            end
            table.insert(RedGuild_Alts[main], alt)
        end
        return
    end

    if field == "RemoveAltFromMain" then
        local main = value.main
        local alt  = value.alt
        if main and alt and RedGuild_Alts[main] then
            for i = #RedGuild_Alts[main], 1, -1 do
                if RedGuild_Alts[main][i] == alt then
                    table.remove(RedGuild_Alts[main], i)
                end
            end
        end
        return
    end
end

local function BuildAltSnapshot()
    return {
        type      = "snapshot",
        version   = tonumber(RedGuild_Config.altsVersion or 0),
        AltParent = RedGuild_AltParent or {},
        Alts      = RedGuild_Alts or {},
    }
end

local function ApplyAltSnapshot(snapshot)
    if type(snapshot) ~= "table" then return end

    local incoming = tonumber(snapshot.version or 0)
    local localVer = tonumber(RedGuild_Config.altsVersion or 0)

-- Alt tracker sync should always merge incoming data
-- Version is informational only, not authoritative
if incoming > localVer then
    RedGuild_Config.altsVersion = incoming
end

    for alt, main in pairs(snapshot.AltParent or {}) do
        if alt ~= main then
            RedGuild_AltParent[alt] = main
        end
    end

    for main, altList in pairs(snapshot.Alts or {}) do
        RedGuild_Alts[main] = RedGuild_Alts[main] or {}

        local existing = {}
        for _, a in ipairs(RedGuild_Alts[main]) do existing[a] = true end

        for _, alt in ipairs(altList) do
            if not existing[alt] then
                table.insert(RedGuild_Alts[main], alt)
                existing[alt] = true
            end
        end
    end
end

local function ApplyDKPSnapshot(snapshot)
    if type(snapshot) ~= "table" then return end

    local seen = {}

    for name, src in pairs(snapshot) do
        if type(name) == "string" and type(src) == "table" then
            local d = EnsurePlayer(name)

            -- DKP fields
            d.lastWeek   = tonumber(src.lastWeek)   or 0
            d.onTime     = tonumber(src.onTime)     or 0
            d.attendance = tonumber(src.attendance) or 0
            d.bench      = tonumber(src.bench)      or 0
            d.spent      = tonumber(src.spent)      or 0
            d.balance    = tonumber(src.balance)    or 0
            d.rotated    = tonumber(src.rotated)    or 0

            -- DKP‑table identity fields
            d.class  = src.class  or d.class
            d.msRole = src.msRole or d.msRole
            d.osRole = src.osRole or d.osRole

            RecalcBalance(d)
            seen[name] = true
        end
    end

    --Remove players not present in snapshot
    for name in pairs(RedGuild_Data) do
        if not seen[name] then
            RedGuild_Data[name] = nil
        end
    end
end

local function ApplySyncData(sender, encoded)
    D("ApplySyncData from "..tostring(sender))
    EnsureSaved()

    sender = Ambiguate(sender or "", "short")
    if not sender or sender == "" then return end
    if sender == UnitName("player") then return end
	
	-- Editors must NEVER accept normal DATA syncs
	if IsEditor(UnitName("player")) then
		SafeSetSyncWarning("Ignored DKP sync — editors only accept FORCE_REQ.")
		return
	end

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

    local snapshot = payload.dkp or payload
    if type(snapshot) ~= "table" then
        SafeSetSyncWarning("Invalid sync payload structure — ignored.")
        return
    end

	local incoming = tonumber(payload.dkpVersion or 0)
	local localVer = tonumber(RedGuild_Config.dkpVersion or 0)

	if not IsEditor(UnitName("player")) then
		if incoming <= localVer then
			SafeSetSyncWarning("DKP sync not required.")
			return
		end
	end
	
	RedGuild_Config.dkpVersion = incoming
    ApplyDKPSnapshot(snapshot)

    SafeSetSyncWarning("")
    UpdateTable()
    LogAudit(sender, "SYNC_APPLIED", "old data", "New DKP data applied")
    RedGuild_LastSyncTime = date("%Y-%m-%d %H:%M:%S")

	UpdateSyncStatus()

    D("Sync applied successfully")
end

local function HandleSyncRequest(requester, sender)
    EnsureSaved()

    requester = Ambiguate(requester or "", "short")
    sender    = Ambiguate(sender or "", "short")

    if not requester or requester == "" then return end
    if not sender or sender == "" then return end

    if RedGuild_SyncLocked then return end
    if not IsAuthorized() then return end
	
	-- Block all outbound sync if user opted out
    if RedGuild_Config.hideMeFromSync then
        return
    end

    local payload = BuildSyncPayload()
    local encoded = EncodePayload(payload)

	if not IsActiveGuildMember(requester) then
		D("SYNC REQUEST → requester not in guild, ignoring")
    return
	end

    D("SYNC REQUEST → Sending DATA to " .. requester)
    RedGuild_Send("DATA", encoded)
end

local function HandleSyncResponse(sender, msgType)
    sender = Ambiguate(sender, "short")
    local isEditor = IsEditor(sender)

    if msgType == "FORCE_ACCEPT" then
        LogAudit(sender, "FORCE_SYNC_ACCEPTED", "pending", "User accepted force sync")
        RedGuild_ForceSyncStatus.accepted = RedGuild_ForceSyncStatus.accepted + 1
        RedGuild_ForceSyncStatus.total    = RedGuild_ForceSyncStatus.total + 1

        if isEditor then
            table.insert(RedGuild_ForceSyncStatus.acceptedEditors, sender)
        else
            table.insert(RedGuild_ForceSyncStatus.autoAccepted, sender)
        end
        return
    end

    if msgType == "FORCE_DECLINE" then
        LogAudit(sender, "FORCE_SYNC_DECLINED", "pending", "User declined force sync")
        RedGuild_ForceSyncStatus.declined = RedGuild_ForceSyncStatus.declined + 1
        RedGuild_ForceSyncStatus.total    = RedGuild_ForceSyncStatus.total + 1

        if isEditor then
            table.insert(RedGuild_ForceSyncStatus.declinedEditors, sender)
        end
        return
    end
end

local function AttemptAutoSync()
    D("AttemptAutoSync called")

    if GetNumGuildMembers() == 0 then
        D("Guild roster not ready — delaying auto-sync")
        C_Timer.After(1, AttemptAutoSync)
        return
    end

    EnsureSaved()
    EnsureAddonUsers()
    UpdateOnlineEditors()

    local me = UnitName("player")
    if not me then
        SafeSetSyncWarning("Player name unavailable — sync aborted.")
        return
    end

    -- Editors never auto-sync
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

    local bestEditor = GetHighestVersionEditor()

	-- Fallback if no version info yet
	if not bestEditor then
		bestEditor = GetHighestRankEditor()
	end
	
    if not bestEditor then
        SafeSetSyncWarning("Correct editor not online — your DKP may be outdated.")
        return
    end

    if NormalizeName(bestEditor) == NormalizeName(me) then
        SafeSetSyncWarning("Editor detected as self — sync aborted.")
        return
    end

    D("Auto-sync → broadcasting EDITORREQ + REQUEST")

    local meReal = Ambiguate(me, "short")

    -- Broadcast via addon messages (GUILD)
    RedGuild_Send("EDITORREQ", meReal)
    RedGuild_Send("REQUEST",   meReal)
end

-- Popups
StaticPopupDialogs["REDGUILD_FORCE_SYNC_BLOCKED"] = {
    text = "You cannot initiate a force sync while 'Hide me from SYNC' is enabled.",
    button1 = "OK",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDGUILD_FORCE_SYNC_CONFIRM"] = {
    text = "Force sync will overwrite ALL guild DKP with YOUR data. Proceed?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        LogAudit(UnitName("player"), "FORCE_SYNC_INITIATED", "none", "Editor initiated force sync")

        EnsureAddonUsers()
        local me = UnitName("player")

        RedGuild_ForceSyncStatus.total          = 0
        RedGuild_ForceSyncStatus.accepted       = 0
        RedGuild_ForceSyncStatus.declined       = 0
        RedGuild_ForceSyncStatus.autoAccepted   = {}
        RedGuild_ForceSyncStatus.acceptedEditors = {}
        RedGuild_ForceSyncStatus.declinedEditors = {}

        local payloadTbl = BuildSyncPayload()
		
		-- Inject version + editor into the snapshot BEFORE encoding
		payloadTbl.dkp.dkpVersion = tonumber(RedGuild_Config.dkpVersion or 0)
		payloadTbl.editor  = UnitName("player")
		
        local encoded    = EncodePayload(payloadTbl)

        -- Broadcast FORCE_REQ with DKP snapshot via GUILD
        RedGuild_Send("FORCE_REQ", encoded)

        Print("Force sync request broadcast to addon users.")

        -- Show summary after a short window
        C_Timer.After(5, RedGuild_ShowForceSyncSummary)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDGUILD_REQUEST_SYNC_EDITOR_CONFIRM"] = {
    text = "Sync from another editor?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        RedGuild_DoRequestSync()
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
        if not RedGuild_PendingForceSync
            or RedGuild_PendingForceSync.editor ~= editor
            or not RedGuild_PendingForceSync.snapshot
        then
            return
        end

        RedGuild_CreateDKPBackup()
        
        -- Update DKP version and sync metadata
        local incomingdkpVersion = tonumber(RedGuild_PendingForceSync.snapshot.dkpVersion or 0) or 0
        RedGuild_Config.dkpVersion = incomingdkpVersion

        RedGuild_Config.lastDKPSync     = date("%Y-%m-%d %H:%M:%S")
        RedGuild_Config.lastDKPSyncFrom = editor
        
        -- Update editor version table
        local key = NormalizeName(editor)
        RedGuild_Config.EditorVersions[key] = incomingdkpVersion
        
        ApplyDKPSnapshot(RedGuild_PendingForceSync.snapshot)
        UpdateTable()
        SafeSetSyncWarning("")
        RedGuild_LastSyncTime = date("%Y-%m-%d %H:%M:%S")

        UpdateSyncStatus()

        RedGuild_Send("FORCE_ACCEPT", UnitName("player"), editor)
        RedGuild_PendingForceSync.editor   = nil
        RedGuild_PendingForceSync.snapshot = nil
    end,
    OnCancel = function(self, editor)
        RedGuild_Send("FORCE_DECLINE", UnitName("player"), editor)
        SafeSetSyncWarning("WARNING — You declined a sync so your dkp data may be out of date.")
        RedGuild_PendingForceSync.editor   = nil
        RedGuild_PendingForceSync.snapshot = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDGUILD_RESTORE_DKP_CONFIRM"] = {
    text = "Restore DKP table from last backup?\nThis will overwrite ALL current DKP data.",
    button1 = "Restore",
    button2 = "Cancel",
    OnAccept = function()
        if RedGuild_BackupData and RedGuild_BackupData.data then
            RedGuild_Data = CopyTable(RedGuild_BackupData.data)
            RedGuild_Config.dkpVersion = RedGuild_BackupData.dkpVersion or 0
            UpdateTable()
            Print("|cff00ff00DKP restored from backup (" ..
                (RedGuild_BackupData.timestamp or "unknown") .. ").|r")
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDGUILD_DELETE_MAIN"] = {
    text = "Delete all data for main %s and all related alts?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, main)
        if not main then return end

        -- Remove all alts of this main
        local alts = RedGuild_Alts[main] or {}
        for _, alt in ipairs(alts) do
            RedGuild_AltParent[alt] = nil
            BroadcastAltFieldUpdate("AltParent", { alt = alt, main = nil })
        end

        -- Remove the main itself
        RedGuild_Alts[main] = nil
        RedGuild_AltParent[main] = nil

        -- Version bump
        RedGuild_Config.altsVersion = (RedGuild_Config.altsVersion or 0) + 1

        -- Broadcast deletion
        BroadcastAltFieldUpdate("DeleteMain", { main = main })

        -- UI refresh
        RefreshMainsList()
        UpdateTopBar()
		ResetRightPanel()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["REDGUILD_CLEAR_RL_TICKS"] = {
    text = "Do you want to clear all selections ?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        wipe(RLSelected)
        for _, row in ipairs(RLRows) do
            if row.checkbox then
                row.checkbox:SetChecked(false)
            end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDGUILD_ON_TIME_CHECK"] = {
    text = "Allocate On-Time DKP to selected players?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()

        for name, selected in pairs(RLSelected) do
            if selected then
                local d = RedGuild_Data[name]
                if d then
                    local old = tonumber(d.onTime or 0) or 0
                    local new = old + 5
                    if new > 5 then
                        new = 5
                        Print("|cffff5555On-Time DKP cannot exceed 5 in a single DKP session. Value capped.|r")
                    end

                    d.onTime = new
                    RecalcBalance(d)
                    LogAudit(name, "onTime", old, d.onTime)
                end
            end
        end

        BumpDKPVersion()
        UpdateTable()
        Print("On-Time DKP allocated to selected players (up to a maximum of 5).")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDGUILD_ALLOCATE_ATTENDANCE"] = {
    text = "Allocate Attendance DKP to selected players?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()

        for name, selected in pairs(RLSelected) do
            if selected then
                local d = RedGuild_Data[name]
                if d then
                    local old = tonumber(d.attendance or 0) or 0
                    local new = old + 15
                    if new > 15 then
                        new = 15
                        Print("|cffff5555Attendance DKP cannot exceed 15 in a single DKP session. Value capped.|r")
                    end

                    d.attendance = new
                    RecalcBalance(d)
                    LogAudit(name, "attendance", old, d.attendance)
                end
            end
        end

        BumpDKPVersion()
        UpdateTable()
        Print("Attendance DKP allocated to selected players (up to a maximum of 15).")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDGUILD_ALLOCATE_BENCH"] = {
    text = "Allocate Bench DKP to all selected players?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        for _, row in ipairs(RLRows) do
            if row:IsShown() and row.checkbox:GetChecked() then
                local name = row.name
                local d = RedGuild_Data[name]

                if d then
                    local old = tonumber(d.bench or 0) or 0
                    local new = old + 20
                    if new > 20 then new = 20 end

                    if new ~= old then
                        d.bench = new
                        LogAudit(name, "bench", old, new)
                    end
                end
            end
        end

        BumpDKPVersion()
        UpdateTable()
        Print("Bench DKP allocated to selected players (up to a maximum of 20).")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDGUILD_MISSING_DKP_WARNING"] = {
    text = "The following players are in your group/raid but have no DKP record:\n\n%s\n\nProceed anyway?",
    button1 = "Proceed",
    button2 = "Cancel",
    OnAccept = function(self, nextPopup)
        StaticPopup_Show(nextPopup)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDGUILD_NEW_WEEK"] = {
    text = "Start a new DKP session? This will move all current values into Old Bal.",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        for name, d in pairs(RedGuild_Data) do
            local oldBalance = d.balance + d.attendance or 0

            d.lastWeek   = oldBalance
            d.onTime     = 0
            d.attendance = 0
            d.bench      = 0
            d.spent      = 0
            d.balance    = 0

            LogAudit(name, "DKP Session Change", "their previous balance of "..oldBalance, "prepare for new DKP session")
        end
		BumpDKPVersion()
        UpdateTable()
        Print("A new DKP session has begun.")
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

    SendChatMessage("Name (Current Balance)", "RAID")

    ------------------------------------------------------------
    -- BUILD LIST OF CURRENT GROUP/RAID MEMBERS
    ------------------------------------------------------------
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

    ------------------------------------------------------------
    -- FILTER DKP TABLE TO ONLY GROUP/RAID MEMBERS
    ------------------------------------------------------------
    local names = {}
    for name in pairs(RedGuild_Data) do
        if groupMembers[name] then
            table.insert(names, name)
        end
    end

    ------------------------------------------------------------
    -- SORT ALPHABETICALLY
    ------------------------------------------------------------
    table.sort(names, function(a, b)
        return a:lower() < b:lower()
    end)

    ------------------------------------------------------------
    -- BROADCAST ONLY GROUP MEMBERS
    ------------------------------------------------------------
    BroadcastNext(names, 1)
	
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["REDGUILD_INACTIVE_OR_DELETE"] = {
    text = "Do you wish to set this DKP record to inactive or delete it?",
    button1 = "Inactive",
    button2 = "Delete",
    button3 = "Cancel",
    OnAccept = function(self, player)
        -- INACTIVE OPTION
        if not player then return end
        local d = RedGuild_Data[player]
        if not d then return end

        d.inactive = true
        BumpDKPVersion()
        UpdateTable()
        Print("Set DKP record for " .. player .. " to inactive.")
    end,
    OnCancel = function(self, player)
        -- DELETE OPTION
        if not player then return end
        StaticPopup_Show("REDGUILD_DELETE_PLAYER", player, nil, player)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3
}

StaticPopupDialogs["REDGUILD_DELETE_PLAYER"] = {
    text = "Are you sure you want to delete DKP data for %s?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, player)
    if not player then return end
		RedGuild_Data[player] = nil
		wipe(dkpSortedNames)
		Print("Deleted DKP record for " .. player)
		BumpDKPVersion()
		UpdateTable()
	end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-------------------------------
-- LibDBIcon Minimap Button
-------------------------------
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
            ShowTab(TAB_ML)
        end
    end,

    OnTooltipShow = function(tt)
        tt:AddLine("RedGuild")
        tt:AddLine("|cff00ff00Left-click|r to open DKP")
		tt:AddLine("|cff00ff00Right-click|r to open ML")
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
eventFrame:RegisterEvent("CHAT_MSG_ADDON")

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5)

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
					local key = NormalizeName(name)
					if key then
						fixed[key] = true
					end
				end
			end
			RedGuild_Config.authorizedEditors = fixed
		end

        -- Populate class data if guild roster is already cached
        PopulateGuildClasses()

        -- Minimap icon
        icon:Register("RedGuild", LDB, RedGuild_Config.minimap)
		
		C_Timer.After(1, function()
			if IsEditor(UnitName("player")) then
				local me = NormalizeName(UnitName("player"))
				RedGuild_Config.EditorVersions = RedGuild_Config.EditorVersions or {}
				RedGuild_Config.EditorVersions[me] = tonumber(RedGuild_Config.dkpVersion or 0)
			end
		end)

		-- Patch Blizzard GuildUtil bug (formatString nil)
		hooksecurefunc("GuildNewsButton_SetText", function(button, text, formatString)
			if not formatString then
				-- Prevent Blizzard's nil-index crash
				return
			end
		end)
		
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
    -- removed to try improve lag on load
	--C_GuildInfo.GuildRoster()

    EnsureSaved()
    EnsureProtectedEditor()

    -- Version handshake: ask guild addon users for their version
    C_Timer.After(5, function()
        if IsInGuild() then
            RedGuild_Send("VERSIONREQ", UnitName("player"))  -- channel=GUILD
        end
    end)

    -- Small delay to let roster/chat settle, then auto-sync
    C_Timer.After(10, function()
        if not IsInGuild() then return end
        AttemptAutoSync()
    end)

    -- Small delay to let roster/chat settle, then sync Alt Tracker Data
    C_Timer.After(15, function()
        if not IsInGuild() then return end
		local me = UnitName("player")
		if me then
			RedGuild_Send("ALTS_REQ", Ambiguate(me, "short"))
		end
    end)

    -- Periodic editor list refresh for users (every 60s)
    C_Timer.NewTicker(60, function()
        UpdateOnlineEditors()
    end)
	
	-- Periodic sync status refresh (every 10 seconds)
	C_Timer.NewTicker(10, function()
		if mainFrame and mainFrame:IsShown() then
			UpdateSyncStatus()
		end	
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
					if IsInGuild() and GetNumGuildMembers() > 0 then
						PopulateGuildClasses()
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
-- 4. GROUP_ROSTER_UPDATE
---------------------------------------------------------

if event == "GROUP_ROSTER_UPDATE" then
    if mlPanel and mlPanel:IsShown() then
        if IsRaidLeaderOrMasterLooter() then
            mlPanel.broadcastBtn:Enable()
        else
            mlPanel.broadcastBtn:Disable()
        end
    end
    return
end

---------------------------------------------------------
-- 5. CHAT_MSG_ADDON (unified SYNC handler)
---------------------------------------------------------
if event == "CHAT_MSG_ADDON" then
    local prefix, raw, channel, sender = arg1, arg2, arg3, arg4
    local msg = raw
    if prefix ~= REDGUILD_CHAT_PREFIX or not msg or not sender then
        return
    end

    sender = Ambiguate(sender, "short")
    if sender == UnitName("player") then return end

    -- Track addon users
    local key = NormalizeName(sender)
    RedGuild_Config.addonUsers[key] = true

    ---------------------------------------------------------
    -- CHUNKED MESSAGES (DATA / EDITORSYNC / FORCE_REQ)
    ---------------------------------------------------------
    local pfx2, chunkType, seqStr, partStr, totalStr, chunk =
        msg:match("^([^:]+):([^:]+):(%d+):(%d+):(%d+):(.*)$")

    if pfx2 == REDGUILD_CHAT_PREFIX
       and (chunkType == "DATA" or chunkType == "EDITORSYNC" or chunkType == "FORCE_REQ" or chunkType == "ALTS")
    then
        local seq   = tonumber(seqStr)
        local part  = tonumber(partStr)
        local total = tonumber(totalStr)
        if not seq or not part or not total then return end

        D(string.format("ADDON IN %s seq=%d part=%d/%d from=%s len=%d",
            chunkType, seq, part, total, sender, #chunk))

        local bucket = REDGUILD_Inbound[chunkType]
        bucket[seq] = bucket[seq] or { parts = {}, total = total, from = sender }
        local entry = bucket[seq]
        entry.parts[part] = chunk

        local complete = true
        for i = 1, entry.total do
            if not entry.parts[i] then
                complete = false
                break
            end
        end

        if complete then
            D("CHUNK ASSEMBLY COMPLETE → " .. chunkType)
            local full = table.concat(entry.parts, "")
            bucket[seq] = nil

            -------------------------------------------------
            -- DATA SYNC
            -------------------------------------------------
            if chunkType == "DATA" then
                ApplySyncData(entry.from or sender, full)
				RedGuild_Config.lastDKPSync = date("%Y-%m-%d %H:%M:%S")
				RedGuild_Config.lastDKPSyncFrom = sender
				UpdateSyncStatus()
                return
            end
			
			-------------------------------------------------
			-- ALT SNAPSHOT (CHUNKED ALTS_DATA)
			-------------------------------------------------
			if chunkType == "ALTS" then
				local ok, snapshot = pcall(DecodePayload, full)
				if ok then
					ApplyAltSnapshot(snapshot)
					RefreshMainsList()
					UpdateTopBar()
				end

				RedGuild_Config.lastAltSync     = date("%Y-%m-%d %H:%M:%S")
				RedGuild_Config.lastAltSyncFrom = sender
				UpdateSyncStatus()
				return
			end

            -------------------------------------------------
            -- EDITOR LIST SYNC
            -------------------------------------------------
            if chunkType == "EDITORSYNC" then
                local decoded = LibDeflate:DecodeForPrint(full)
                if not decoded then return end
                local decompressed = LibDeflate:DecompressDeflate(decoded)
                if not decompressed then return end
                local ok, tbl = LibSerialize:Deserialize(decompressed)
                if not ok or type(tbl) ~= "table" then return end
                ApplyEditorList(tbl)
				RedGuild_Config.lastEditorSync = date("%Y-%m-%d %H:%M:%S")
				RedGuild_Config.lastEditorSyncFrom = sender
				UpdateSyncStatus()
                return
            end

            -------------------------------------------------
            -- FORCE SYNC
            -------------------------------------------------
            if chunkType == "FORCE_REQ" then
                local ok, payload = pcall(DecodePayload, full)
                if not ok or type(payload) ~= "table" then return end

                local snapshot = payload.dkp or payload
                if type(snapshot) ~= "table" then return end

                local editor = entry.from or sender
				local incoming = tonumber(payload.dkpVersion or 0) or 0

                -- NON‑EDITORS: auto‑apply, no version gating
                if not IsAuthorized() then

                    if not IsActiveGuildMember(sender) then
                        D("FORCE_REQ → ignoring for non‑guild member")
                        return
                    end

                    -- Always adopt sender's version
                    RedGuild_Config.dkpVersion = incoming

                    -- Always apply snapshot
                    ApplyDKPSnapshot(snapshot)
                    UpdateTable()
                    SafeSetSyncWarning("")
					RedGuild_Config.lastDKPSync = date("%Y-%m-%d %H:%M:%S")
					RedGuild_Config.lastDKPSyncFrom = editor
                    UpdateSyncStatus()

                    RedGuild_Send("FORCE_ACCEPT", UnitName("player"), editor)
                    return
                end

                -- EDITORS: show popup, no version gating
                RedGuild_PendingForceSync.editor   = editor
                RedGuild_PendingForceSync.snapshot = snapshot
                StaticPopup_Show("REDGUILD_FORCE_SYNC_RECEIVE", editor, nil, editor)
                return
            end

            return
        end
    end

    ---------------------------------------------------------
    -- ALT SYNC: SMALL MESSAGES (ALTS_REQ / ALTS_DATA / ALTS_UPDATE)
    ---------------------------------------------------------
    local pfx3, altType, altPayload =
        msg:match("^([^:]+):([^:]+):(.*)$")

    if pfx3 == REDGUILD_CHAT_PREFIX then
        -- ALT SYNC: REQUEST SNAPSHOT
if altType == "ALTS_REQ" then
    local requester = altPayload
    if not requester or requester == "" then
        requester = sender
    end

    local snapshot = BuildAltSnapshot()
    local encoded  = EncodePayload(snapshot)

    -- send via chunked path
    RedGuild_Send("ALTS", encoded, requester)
    return
end

        -- ALT SYNC: RECEIVE SNAPSHOT
        if altType == "ALTS_DATA" then
            local ok, snapshot = pcall(DecodePayload, altPayload)
            if ok then
                ApplyAltSnapshot(snapshot)
                RefreshMainsList()
                UpdateTopBar()
            end
			RedGuild_Config.lastAltSync     = date("%Y-%m-%d %H:%M:%S")
			RedGuild_Config.lastAltSyncFrom = sender
			UpdateSyncStatus()
            return
        end

        -- ALT SYNC: PER-FIELD UPDATE
        if altType == "ALTS_UPDATE" then
            local ok, update = pcall(DecodePayload, altPayload)
            if ok then
                ApplyAltFieldUpdate(update)
                RefreshMainsList()
                UpdateTopBar()
            end
            RedGuild_Config.lastAltSync     = date("%Y-%m-%d %H:%M:%S")
			RedGuild_Config.lastAltSyncFrom = sender
			UpdateSyncStatus()
			return
        end
    end

    ---------------------------------------------------------
    -- SIMPLE MESSAGES (EDITORREQ / REQUEST / VERSION / FORCE_* etc.)
    ---------------------------------------------------------
    local _, simpleType, simplePayload = msg:match("^([^:]+):([^:]+):?(.*)$")
    if not simpleType then return end

    -- EDITORREQ: payload = requester name
    if simpleType == "EDITORREQ" then
        local requester = simplePayload ~= "" and simplePayload or sender
        if IsAuthorized() or IsGuildOfficer() then
            BroadcastEditorListTo(requester)
        end
        return
    end

    -- REQUEST: payload = requester name
    if simpleType == "REQUEST" then
        HandleSyncRequest(simplePayload ~= "" and simplePayload or sender, sender)
        return
    end

    -- FORCE SYNC (handled above)
    if simpleType == "FORCE_REQ" then
        return
    end

    if simpleType == "FORCE_ACCEPT" then
        HandleSyncResponse(sender, "FORCE_ACCEPT")
        return
    end

    if simpleType == "FORCE_DECLINE" then
        HandleSyncResponse(sender, "FORCE_DECLINE")
        return
    end

    ---------------------------------------------------------
    -- VERSION HANDSHAKE
    ---------------------------------------------------------
    if simpleType == "VERSIONREQ" then
        RedGuild_Send("VERSIONREP", REDGUILD_VERSION)
		return
    end

if simpleType == "VERSIONREP" then

	-- Normalize sender name
    local key = NormalizeName(sender)
	
	-- Convert version to number
    local remoteVer = simplePayload or ""
	
	RedGuild_Config.AddonVersions = RedGuild_Config.AddonVersions or {}
    RedGuild_Config.AddonVersions[key] = remoteVer

    -- Track version sync for tooltip
    RedGuild_Config.lastVersionSync = date("%Y-%m-%d %H:%M:%S")
    RedGuild_Config.lastVersionSyncFrom = sender
    UpdateSyncStatus()
	
    -- Notify user if newer version exists
    if remoteVer ~= "" and CompareVersions(REDGUILD_VERSION, remoteVer) then
        if not RedGuild_Config.seenNewerVersion then
            RedGuild_Config.seenNewerVersion = true
            Print(string.format(
                "A newer RedGuild version is available: %s (you are on %s)",
                remoteVer, REDGUILD_VERSION
            ))
        end
    end

    return
end
end

---------------------------------------------------------
-- 6. CHAT_MSG_WHISPER (only DKP Q&A now)
---------------------------------------------------------
if event == "CHAT_MSG_WHISPER" then
    local text, sender = arg1, arg2
    if not text or not sender then return end

    sender = Ambiguate(sender, "short")

-- AUTO-REPLY: "What is my DKP?"
do
    local lower = text:lower()

	local hasMy  = lower:find("my", 1, true)
	local hasDKP = lower:find("dkp", 1, true)
	local hasQ   = lower:find("?", 1, true)

	if hasMy and hasDKP and hasQ then
        if IsAuthorized() then
            local d = RedGuild_Data[sender]
            if d then
                d.balance = (
                    (d.lastWeek or 0)
                    + (d.onTime or 0)
                    + (d.bench or 0)
                    - (d.spent or 0)
                )
				
				-- Ensure Hard cap at 300
				if d.balance > 300 then
					d.balance = 300
				end

                local balance = tonumber(d.balance or 0) or 0

                -- Easter egg: 69 → NICE!
                local suffix = ""
                if balance == 69 then
                    suffix = "  NICE!"
                end

                local reply = string.format("Your DKP: %d%s", balance, suffix)
                reply = reply:gsub("|", "||")
                SendChatMessage(reply, "WHISPER", nil, sender)
            else
                SendChatMessage(
                    "I don't have any DKP data recorded for you yet.",
                    "WHISPER", nil, sender
                )
                end
            end
            return
        end
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