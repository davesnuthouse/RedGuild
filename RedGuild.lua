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
local REDGUILD_VERSION = "1.18.00"

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
local bidLogPanel

local TAB_DKP     = 1
local TAB_ALT     = 2
local TAB_GROUP   = 3
local TAB_ML      = 4
local TAB_BIDLOG  = 5
local TAB_RAID    = 6
local TAB_EDITORS = 7
local TAB_AUDIT   = 8

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

local function GetHighestAltVersionUser()
    local bestUser = nil
    local bestVer = -1

    for name, ver in pairs(RedGuild_Config.altsVersionByUser or {}) do
        if IsAddonUserOnlineForTooltip(name) then
            local nver = tonumber(ver) or 0

            if nver > bestVer then
                bestVer = nver
                bestUser = name

            elseif nver == bestVer then
                -- alphabetical tie-breaker (normalized)
                local normName     = NormalizeName(name)
                local normBestUser = NormalizeName(bestUser)

                if normBestUser == nil or normName < normBestUser then
                    bestUser = name
                end
            end
        end
    end

    return bestUser, bestVer
end

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

    local me = UnitName("player")

    -- Raw states
    local dkpState      = GetSyncAgeState(RedGuild_Config.lastDKPSync)
    local altState      = GetSyncAgeState(RedGuild_Config.lastAltSync)
    local editorState   = GetSyncAgeState(RedGuild_Config.lastEditorSync)

    ----------------------------------------------------------------
    -- EDITOR-SPECIFIC LOGIC (modify states BEFORE priority system)
    ----------------------------------------------------------------
    if IsEditor(me) then
        -- Editor Sync is ALWAYS green for editors
        editorState = "green"

        -- DKP Sync only red if NOT highest-version editor
        local getBest = _G.GetHighestVersionEditor
		local bestEditor, bestVersion = nil, 0

		if type(getBest) == "function" then
			bestEditor, bestVersion = getBest()
		end

        -- Your EditorVersions table already uses normalized keys
        local myVersion = 0
		if RedGuild_Config.EditorVersions then
			-- EditorVersions keys are already normalized
			for key, ver in pairs(RedGuild_Config.EditorVersions) do
				if IsEditor(key) and IsEditor(me) and key == key then
					-- But we actually want the version for THIS player:
					-- So we compare normalized names using your IsEditor logic
				end
			end

			-- The correct way: use IsEditor() to find the normalized key
			for key, ver in pairs(RedGuild_Config.EditorVersions) do
				if IsEditor(key) and IsEditor(me) then
					-- Compare normalized names by using IsEditor() on both
					if key == key then end -- ignore
				end
			end
		end

        if myVersion < bestVersion then
            dkpState = "red"
        else
            dkpState = "green"
        end

    else
        -- Normal users should IGNORE editor sync entirely
        editorState = "green"
    end

    ----------------------------------------------------------------
    -- PRIORITY SYSTEM
    ----------------------------------------------------------------

    if dkpState == "red" or altState == "red" or editorState == "red" then
        statusBox:SetColorTexture(1, 0, 0)
        return
    end

    if dkpState == "orange" or altState == "orange" or editorState == "orange" then
        statusBox:SetColorTexture(1, 0.65, 0)
        return
    end

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
    -- Live bidding traffic: bidder -> auctioneer
    if msgType == "BID_PLACE" then
        if not target or target == "" then return nil, nil end
        return "WHISPER", GetExactName(target)
    end

    -- Every other bidding message is editor -> group
    if msgType:sub(1, 4) == "BID_" then
        if IsInRaid() then return "RAID", nil end
        if IsInGroup() then return "PARTY", nil end
        return nil, nil
    end

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
	
-- DKP sync opt-out should NOT block Alt Tracker sync
if RedGuild_Config.hideMeFromSync then
    if msgType ~= "ALTS_REQ" and
       msgType ~= "ALTS_DATA" and
       msgType:sub(1, 4) ~= "BID_" and
       msgType ~= "ALTS_UPDATE" then
        return
    end
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

function EnsurePlayer(name)
    -- Normalize name
    name = Ambiguate(name, "short") or name

    -- If record exists, return it
    local d = RedGuild_Data[name]
    if d then return d end

    -- Create a safe, complete DKP record
    d = {
        class      = "UNKNOWN",
        msRole     = "UNKNOWN",
        osRole     = "UNKNOWN",
        lastWeek   = 0,
        onTime     = 0,
        attendance = 0,
        bench      = 0,
        spent      = 0,
        rotated    = 0,
    }

    RedGuild_Data[name] = d
    return d
end

local function EnsureML(name)
    if not RedGuild_ML[name] then
        RedGuild_ML[name] = {
            mlMainMS = 0,   -- Main (MS)
            mlMainOS = 0,   -- Main (OS)
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

local function GetNewestVersion()
    local addonVersions = RedGuild_Config.AddonVersions or {}
    local newest = nil

    for name, ver in pairs(addonVersions) do
        if not newest or CompareVersions(newest, ver) then
            newest = ver
        end
    end

    return newest
end

local function CountOutdatedUsers()
    local addonVersions = RedGuild_Config.AddonVersions or {}
    local newest = GetNewestVersion()
    local accountVersions = {}
    local count = 0

    -- Collapse alts → mains and track highest version per account
    for main, altList in pairs(RedGuild_Alts or {}) do
        local normMain = NormalizeName(main)

        -- Start with main's version
        local best = addonVersions[normMain]

        -- Check alts for higher version
        for _, alt in ipairs(altList) do
            local normAlt = NormalizeName(alt)
            local altVer = addonVersions[normAlt]

            if altVer and best then
                if CompareVersions(best, altVer) then
                    best = altVer
                end
            elseif altVer then
                best = altVer
            end
        end

        -- Store highest version for this account
        if best then
            accountVersions[normMain] = best
        end
    end

    -- Count outdated accounts
    for main, ver in pairs(accountVersions) do
        if ver ~= newest then
            count = count + 1
        end
    end

    return count
end

local function CountAddonMains()
    local addonUsers = RedGuild_Config.addonUsers or {}
    local total = 0
    local online = 0

    for main, altList in pairs(RedGuild_Alts or {}) do
        local norm = NormalizeName(main)

        -- Only count mains that actually have the addon
        if addonUsers[norm] then
            total = total + 1

            -- Check if main is online
            local isOnline = IsAddonUserOnlineForTooltip(main)

            -- If not, check alts
            if not isOnline then
                for _, alt in ipairs(altList) do
                    if IsAddonUserOnlineForTooltip(alt) then
                        isOnline = true
                        break
                    end
                end
            end

            if isOnline then
                online = online + 1
            end
        end
    end

    return online, total
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

local function UpdateAuditLog()
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

local online, total = CountAddonMains()
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
GameTooltip:AddLine("|cffffff00DKP Data|r")
GameTooltip:AddLine("|cffffffffLast: |r" .. ColourForSyncAge(RedGuild_Config.lastDKPSync or "Never"))
GameTooltip:AddLine("|cffffffffFrom: |r" .. (RedGuild_Config.lastDKPSyncFrom or "?"))
local bestEditor, bestVersion = GetHighestVersionEditor()
	if bestEditor and bestVersion then
		GameTooltip:AddLine("|cffffffffHighest version: |r" .. bestVersion .. " (" .. bestEditor .. ")")
	else
		GameTooltip:AddLine("|cffffffffHighest version: |r?")
	end
GameTooltip:AddLine("|cffffffffYour version: |r" .. (RedGuild_Config.dkpVersion or "?"))
GameTooltip:AddLine(" ")

-- Alt sync
GameTooltip:AddLine("|cffffff00Alt Tracker Sync|r")
GameTooltip:AddLine("|cffffffffLast: |r" .. ColourForSyncAge(RedGuild_Config.lastAltSync or "Never"))
GameTooltip:AddLine("|cffffffffFrom: |r" .. (RedGuild_Config.lastAltSyncFrom or "?"))
GameTooltip:AddLine("|cffffffffVersion: |r" .. (RedGuild_Config.altsVersion or "?"))
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
    CreateTab(TAB_BIDLOG, "Bid Log")
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
    bidLogPanel  = CreateFrame("Frame", nil, mainFrame); LayoutPanel(bidLogPanel)
	
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
			local balance    = tonumber(d.balance)    or 0
			local attendance = tonumber(d.attendance) or 0

			-- Original functionality: add attendance into lastWeek
			local rawTransfer = balance + attendance

			-- New rule: cap lastWeek at 300
			local transfer = math.min(rawTransfer, 300)

			-- Apply the transfer
			d.lastWeek = transfer

			-- Reduce balance ONLY by the amount actually moved
			-- (attendance is not subtracted from balance)
			d.balance = balance - transfer
			if d.balance < 0 then
				d.balance = 0
			end

			-- Reset weekly fields
			d.onTime     = 0
			d.attendance = 0
			d.bench      = 0
			d.spent      = 0

			LogAudit(
				name,
				"DKP Session Change",
				"moved "..transfer.." (from balance + attendance)",
				"new session start"
			)
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

        ----------------------------------------------------------------
        -- COMBAT LOCKDOWN: Block opening the addon while in combat
        ----------------------------------------------------------------
        if InCombatLockdown() then
            print("|cffff5555RedGuild: Cannot open the DKP window while in combat.|r")
            return
        end

        ----------------------------------------------------------------
        -- NORMAL CLICK HANDLING
        ----------------------------------------------------------------
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
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")

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
    RedGuild_Auction_AttachUI()
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

			local requesterVer = tonumber(RedGuild_Config.altsVersionByUser and RedGuild_Config.altsVersionByUser[NormalizeName(requester)] or 0)

			-- Determine the highest-version alt-data user
			local bestUser, bestVer = GetHighestAltVersionUser()

			-- Only the highest-version user responds, and only if newer than requester
			if bestUser and NormalizeName(bestUser) == NormalizeName(UnitName("player")) then
				if bestVer > requesterVer then
					local snapshot = BuildAltSnapshot()
					local encoded  = EncodePayload(snapshot)
					RedGuild_Send("ALTS_DATA", encoded, requester)
				end
			end
			return
		end

        -- ALT SYNC: RECEIVE SNAPSHOT
		if altType == "ALTS_DATA" then
			local ok, snapshot = pcall(DecodePayload, altPayload)
			if ok and type(snapshot) == "table" then
				local incoming = tonumber(snapshot.version or 0)
				local localVer = tonumber(RedGuild_Config.altsVersion or 0)
				
				RedGuild_Config.altsVersionByUser = RedGuild_Config.altsVersionByUser or {}
				RedGuild_Config.altsVersionByUser[NormalizeName(sender)] = incoming

				if incoming > localVer then
					ApplyAltSnapshot(snapshot)
					RedGuild_Config.altsVersion = incoming
					RefreshMainsList()
					UpdateTopBar()
				end
			end
		end


        -- ALT SYNC: PER-FIELD UPDATE
		if altType == "ALTS_UPDATE" then
			local ok, update = pcall(DecodePayload, altPayload)
			if ok and type(update) == "table" then
				local incoming = tonumber(update.version or 0)
				local localVer = tonumber(RedGuild_Config.altsVersion or 0)
				
				RedGuild_Config.altsVersionByUser = RedGuild_Config.altsVersionByUser or {}
				RedGuild_Config.altsVersionByUser[NormalizeName(sender)] = incoming

				if incoming > localVer then
					ApplyAltFieldUpdate(update)
					RefreshMainsList()
					UpdateTopBar()
				end
			end
		end
	end

    ---------------------------------------------------------
    -- SIMPLE MESSAGES (EDITORREQ / REQUEST / VERSION / FORCE_* etc.)
    ---------------------------------------------------------
    local _, simpleType, simplePayload = msg:match("^([^:]+):([^:]+):?(.*)$")
    if not simpleType then return end

    -- BIDDING: BID_START / BID_PLACE / BID_STOP / BID_CANCEL / BID_AWARD
    if simpleType:sub(1, 4) == "BID_" then
        RedGuild_Auction_OnAddonMessage(simpleType, simplePayload, sender)
        return
    end

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
	
	-- Store Version
	RedGuild_Config.AddonVersions = RedGuild_Config.AddonVersions or {}
    RedGuild_Config.AddonVersions[key] = remoteVer

    -- Track version sync for tooltip
    RedGuild_Config.lastVersionSync = date("%Y-%m-%d %H:%M:%S")
    RedGuild_Config.lastVersionSyncFrom = sender
    UpdateSyncStatus()
	
	-- NEW: Global version check (you vs newest in guild)

    local newest = GetNewestVersion()
    if newest and newest ~= "" and CompareVersions(REDGUILD_VERSION, newest) then
        if not RedGuild_Config.seenNewerVersion then
            RedGuild_Config.seenNewerVersion = true
            Print(string.format(
                "Your RedGuild addon is out of date. Latest version: %s (you are on %s)",
                newest, REDGUILD_VERSION
            ))
        end
    end
	
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
-- 5b. CHAT_MSG_SYSTEM (off-spec roll capture during bidding)
---------------------------------------------------------
if event == "CHAT_MSG_SYSTEM" then
    RedGuild_Auction_OnSystemMessage(arg1)
    return
end

---------------------------------------------------------
-- 6. CHAT_MSG_WHISPER (DKP Q&A + bidding commands)
---------------------------------------------------------
if event == "CHAT_MSG_WHISPER" then
    local text, sender = arg1, arg2
    if not text or not sender then return end

    sender = Ambiguate(sender, "short")

-- BIDDING COMMANDS: !bid / !pass / !os / !dkp
-- Lets players without the addon take part in an auction.
if RedGuild_Auction_OnWhisper(text, sender) then
    return
end

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

    ----------------------------------------------------------------
    -- COMBAT LOCKDOWN: Block opening the addon while in combat
    ----------------------------------------------------------------
    if InCombatLockdown() then
        -- Allowed in combat: hide, debug, minimap, help
        if msg == "hide" then
            mainFrame:Hide()
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

        if msg == "minimap" then
            RedGuild_ResetMinimapButton()
            return
        end

        if msg == "help" or msg == "" then
            print("|cffffd100RedGuild Commands:|r")
            print("|cff00ff00/redguild show|r   - Open the DKP window")
            print("|cff00ff00/redguild hide|r   - Hide the DKP window")
            print("|cff00ff00/redguild toggle|r - Toggle the DKP window")
            print("|cff00ff00/redguild minimap|r - Reset minimap icon position")
            print("|cff00ff00/redguild bid|r    - Open the item bidding window (editors)")
            print("|cff00ff00/redguild help|r   - Show this help list")
            return
        end

        -- Anything else that tries to open UI is blocked
        print("|cffff5555RedGuild: Cannot open the DKP window while in combat.|r")
        return
    end

    ----------------------------------------------------------------
    -- NORMAL (OUT OF COMBAT) COMMANDS
    ----------------------------------------------------------------
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

    if msg == "bid" or msg == "bids" or msg == "auction" then
        RedGuild_Auction_ShowMaster()
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
        print("|cff00ff00/redguild bid|r    - Open the item bidding window (editors)")
        print("|cff00ff00/redguild help|r   - Show this help list")
        return
    end

    print("|cffff5555Unknown command. Use /redguild help|r")
end


--==================================================================
-- DKP BIDDING / AUCTION
--==================================================================
-- Editor posts an item -> raid members get a prompt showing their
-- current DKP where they can bid, roll off-spec, or pass.
-- Players without the addon can whisper the auctioneer:
--     !bid 50        place a main-spec bid of 50
--     !os            declare off-spec, then /roll 69 (flat 5 DKP if won)
--     !pass          pass on the item
--     !dkp           check balance
-- The editor sees every bid and awards the item MANUALLY.
--==================================================================

local AUCTION_DEFAULT_DURATION = 30
-- Smallest main-spec bid the addon will accept.
local AUCTION_MIN_BID          = 10
local AUCTION_MAX_ROWS         = 60

-- Runtime only. Deliberately not a SavedVariable: an auction should
-- never survive a /reload or a disconnect.
RedGuild_Auction = {
    open       = false,   -- accepting bids right now
    posted     = false,   -- an item is posted (may be closed but not yet awarded)
    id         = nil,
    itemLink   = nil,
    itemID     = nil,
    ml         = nil,     -- auctioneer (short name)
    duration   = AUCTION_DEFAULT_DURATION,
    endTime    = nil,
    paused     = false,
    myBid      = nil,     -- what this client submitted, for the log
    remaining  = nil,   -- seconds frozen on the clock while paused
    ticker     = nil,
    bids       = {},      -- [character] = { name, key, amount, mode, src, roll, at }
    selected   = nil,
}

local auctionMaster      -- editor window
local auctionButton      -- Bidding button on the DKP tab
local auctionLogButton   -- Bidding button on the Bid Log tab
local AUCTION_LOG_MAX    = 250

--------------------------------------------------
-- Bid log
--------------------------------------------------
-- Kept inside RedGuild_Config, which is already a SavedVariable and
-- is never serialised into a sync payload, so the .toc needs no new
-- entry and the log never inflates addon messages.
--
-- Each client records only what it legitimately saw. The auctioneer
-- receives every bid, so an editor logs the full book. Everyone else
-- only ever sees the award broadcast plus whatever they sent
-- themselves, so that is exactly what their log holds.
local function EnsureBidLog()
    RedGuild_Config.bidLog = RedGuild_Config.bidLog or {}
    return RedGuild_Config.bidLog
end

function RedGuild_BidLog_Add(entry)
    local log = EnsureBidLog()
    table.insert(log, 1, entry)      -- newest first
    while #log > AUCTION_LOG_MAX do
        table.remove(log)
    end
    if RedGuild_BidLog_Refresh then RedGuild_BidLog_Refresh() end
end

-- Snapshot of the current auction, from the point of view of
-- whoever is running this client.
local function BuildLogEntry(winner, cost, mode, cancelled)
    local bids = {}

    if RedGuild_Auction_IsAuctioneer() then
        for _, b in ipairs(RedGuild_Auction_SortedBids()) do
            table.insert(bids, {
                name   = b.name,
                amount = b.amount,
                mode   = b.mode,
                roll   = b.roll,
                src    = b.src,
            })
        end
    elseif RedGuild_Auction.myBid then
        table.insert(bids, RedGuild_Auction.myBid)
    end

    return {
        t         = time(),
        when      = date("%d.%m %H:%M"),
        item      = RedGuild_Auction.itemLink,
        ml        = RedGuild_Auction.ml,
        winner    = winner,
        cost      = cost or 0,
        mode      = mode,
        cancelled = cancelled or nil,
        full      = RedGuild_Auction_IsAuctioneer() or nil,
        bids      = bids,
    }
end
local auctionPrompt      -- bidder popup
local auctionMasterRows = {}

--------------------------------------------------
-- Roll pattern (locale safe)
--------------------------------------------------
local RedGuild_RollPattern
do
    local p = RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
    -- escape the literal magic characters first
    p = p:gsub("%(", "%%(")
    p = p:gsub("%)", "%%)")
    p = p:gsub("%-", "%%-")
    p = p:gsub("%.", "%%.")
    -- then turn the format specifiers into captures
    p = p:gsub("%%s", "(.+)")
    p = p:gsub("%%d", "(%%d+)")
    RedGuild_RollPattern = p
end

--------------------------------------------------
-- Small helpers
--------------------------------------------------

local function AuctionPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff8800[RedGuild Bid]|r " .. tostring(msg))
end

-- The character who bids is the character who pays. Alt/main linking
-- is deliberately NOT applied here: an alt bids with the alt's own DKP
-- and the alt's own record is charged.
function RedGuild_Auction_Bidder(name)
    if not name then return nil end
    return Ambiguate(name, "short")
end

-- Returns balance, character. The balance belongs to the character
-- that is bidding, not to any linked main. Recalculated so it is
-- never stale.
function RedGuild_Auction_GetBalance(name)
    local who = RedGuild_Auction_Bidder(name)
    if not who then return 0, nil end

    local d = RedGuild_Data and RedGuild_Data[who]
    if not d then return 0, who end

    local bal = (d.lastWeek or 0) + (d.onTime or 0) + (d.bench or 0) - (d.spent or 0)
    if bal > 300 then bal = 300 end
    return bal, who
end

function RedGuild_Auction_TimeLeft()
    if RedGuild_Auction.paused then
        return math.max(0, math.ceil(RedGuild_Auction.remaining or 0))
    end
    return math.max(0, math.ceil((RedGuild_Auction.endTime or 0) - GetTime()))
end

function RedGuild_Auction_IsOpen()
    return RedGuild_Auction.open == true
end

-- True when we are the person running the current auction.
function RedGuild_Auction_IsAuctioneer()
    if not RedGuild_Auction.ml then return false end
    return NormalizeName(RedGuild_Auction.ml) == NormalizeName(UnitName("player"))
end

local function AuctionChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function AuctionAnnounce(msg)
    local chan = AuctionChannel()
    if not chan then return end
    SendChatMessage(msg, chan)
end

-- Raid warning for the things people must not miss. RAID_WARNING is
-- silently dropped for anyone who is not lead or assist, so fall
-- back to plain raid chat rather than losing the message.
local function AuctionWarn(msg)
    if IsInRaid() and (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then
        SendChatMessage(msg, "RAID_WARNING")
        return
    end
    AuctionAnnounce(msg)
end

local function AuctionWhisper(target, msg)
    if not target or target == "" then return end
    SendChatMessage(msg, "WHISPER", nil, Ambiguate(target, "none"))
end

local function ClassColour(name)
    local who = RedGuild_Auction_Bidder(name)
    local d = RedGuild_Data and RedGuild_Data[who]
    local class = d and d.class
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
    return "|cffffffff"
end

--------------------------------------------------
-- Bid book
--------------------------------------------------

-- Push the current DKP table so nobody bids against a stale balance,
-- and so everyone sees the new balance right after an award.
-- This is a normal DATA sync, not FORCE_REQ: recipients apply it only
-- if their dkpVersion is behind, and it raises no prompt. FORCE_REQ
-- would ask every guild member to accept an overwrite, which is far
-- too heavy to fire once per item.
-- The DKP table is far bigger than one addon message, so a push is
-- dozens of chunks. RedGuild_Send fires them in a tight loop, which is
-- fine for an occasional manual sync but risks tripping the server
-- addon-message throttle when it happens automatically on every item.
-- These pushes are background traffic, so space them out instead.
local AUCTION_SYNC_CHUNK_DELAY = 0.15

local function AuctionSendThrottled(msgType, payload)
    RedGuild_OutboundSeq = RedGuild_OutboundSeq + 1
    local seq   = RedGuild_OutboundSeq
    local total = math.ceil(#payload / REDGUILD_MAX_CHUNK)
    if total == 0 then total = 1 end

    for i = 1, total do
        local startIdx = (i - 1) * REDGUILD_MAX_CHUNK + 1
        local chunk    = payload:sub(startIdx, startIdx + REDGUILD_MAX_CHUNK - 1)
        local msg      = string.format("%s:%s:%d:%d:%d:%s",
            REDGUILD_CHAT_PREFIX, msgType, seq, i, total, chunk)

        C_Timer.After((i - 1) * AUCTION_SYNC_CHUNK_DELAY, function()
            C_ChatInfo.SendAddonMessage(REDGUILD_CHAT_PREFIX, msg, "GUILD")
        end)
    end

    return total
end

local lastPushedVersion, lastPushTime = nil, 0

function RedGuild_Auction_PushSync(reason)
    if not IsAuthorized() then return end
    if RedGuild_SyncLocked then return end
    if RedGuild_Config.hideMeFromSync then
        AuctionPrint("DKP not synced - 'Hide me from SYNC' is enabled.")
        return
    end

    -- Recipients discard a push whose dkpVersion is not ahead of
    -- their own, so resending an unchanged table is pure traffic.
    -- An award bumps the version, so the post-award push always goes.
    local ver = tonumber(RedGuild_Config.dkpVersion or 0)
    if lastPushedVersion == ver and (GetTime() - lastPushTime) < 300 then
        D("Auction sync skipped - nothing changed since the last push")
        return
    end
    lastPushedVersion, lastPushTime = ver, GetTime()

    local payload = BuildSyncPayload()
    -- ApplySyncData reads dkpVersion from the top level of the
    -- payload, so it has to be set here or every recipient will
    -- read version 0 and discard the update.
    payload.dkpVersion = tonumber(RedGuild_Config.dkpVersion or 0)

    local chunks = AuctionSendThrottled("DATA", EncodePayload(payload))
    D(string.format("Auction sync pushed (%s) in %d chunks",
        tostring(reason), chunks))
end

local function AuctionResetBook()
    RedGuild_Auction.bids     = {}
    RedGuild_Auction.selected = nil
end

-- Sorted view of the bid book: main-spec bids by DKP desc, then
-- off-spec rollers by roll desc, then passes. Sorting is purely
-- cosmetic; awarding is always manual.
function RedGuild_Auction_SortedBids()
    local list = {}
    for _, b in pairs(RedGuild_Auction.bids) do
        table.insert(list, b)
    end

    local rank = { MS = 1, OS = 2, PASS = 3 }
    table.sort(list, function(a, b)
        local ra, rb = rank[a.mode] or 9, rank[b.mode] or 9
        if ra ~= rb then return ra < rb end
        if a.mode == "OS" and b.mode == "OS" then
            if (a.roll or 0) ~= (b.roll or 0) then
                return (a.roll or 0) > (b.roll or 0)
            end
        end
        if (a.amount or 0) ~= (b.amount or 0) then
            return (a.amount or 0) > (b.amount or 0)
        end
        return (a.at or 0) < (b.at or 0)
    end)

    return list
end

-- Editor side. Records or replaces a bid. src is "addon" or "whisper".
function RedGuild_Auction_RecordBid(player, amount, mode, src, roll)
    if not RedGuild_Auction.posted then return false, "No item is posted." end
    if not RedGuild_Auction.open   then return false, "Bidding is closed." end
    if not player then return false, "No player." end

    player = Ambiguate(player, "short")
    local bal, who = RedGuild_Auction_GetBalance(player)
    if not who then return false, "Could not resolve name." end

    mode   = mode or "MS"
    amount = tonumber(amount) or 0

    -- Off spec is decided purely by the roll and costs nothing, so
    -- neither off spec nor a pass ever carries a DKP amount.
    if mode ~= "MS" then amount = 0 end

    if mode == "MS" then
        if amount < AUCTION_MIN_BID then
            return false, string.format(
                "Main-spec bids must be at least %d DKP.", AUCTION_MIN_BID)
        end
        if amount > bal then
            return false, string.format("Bid of %d exceeds your balance of %d DKP.", amount, bal)
        end
    end

    local existing = RedGuild_Auction.bids[who]

    -- Keep a previous roll only if the bidder has not switched
    -- between main-spec and off-spec since rolling.
    local keptRoll = nil
    if existing and existing.mode == mode then
        keptRoll = existing.roll
    end

    RedGuild_Auction.bids[who] = {
        name   = player,
        key    = who,
        amount = amount,
        mode   = mode,
        src    = src or "addon",
        roll   = roll or keptRoll or nil,
        bal    = bal,
        at     = existing and existing.at or GetTime(),
    }

    RedGuild_Auction_RefreshMaster()
    return true
end

--------------------------------------------------
-- Editor: start / stop / cancel / award
--------------------------------------------------

-- Loads an item into the slot. Never starts an auction.
function RedGuild_Auction_ApplyItem(link)
    if not link then return end
    local name, itemLink, _, _, _, _, _, _, _, icon = GetItemInfo(link)
    itemLink = itemLink or link

    RedGuild_Auction.itemLink = itemLink
    RedGuild_Auction.itemID   = tonumber(itemLink:match("item:(%d+)"))

    if auctionMaster then
        auctionMaster.itemText:SetText(itemLink)
        auctionMaster.itemIcon:SetTexture(icon or (RedGuild_Auction.itemID and GetItemIcon(RedGuild_Auction.itemID)) or "Interface\\Icons\\INV_Misc_QuestionMark")
    end
end

-- Public entry point used by the drop slot, the link box and the
-- shift-click hook. While an item is already posted, swapping is
-- confirmed first so a stray drag cannot silently replace the item
-- the raid is bidding on. Swapping never starts a new auction.
function RedGuild_Auction_SetItem(link)
    if not link then return end

    if RedGuild_Auction.posted then
        RedGuild_Auction.pendingSwap = link
        StaticPopup_Show("REDGUILD_BID_SWAP_ITEM")
        return
    end

    RedGuild_Auction_ApplyItem(link)
end

StaticPopupDialogs["REDGUILD_BID_SWAP_ITEM"] = {
    text = "Bidding is already running on this item.\n\nReplace it? The current auction is cancelled and all bids are discarded.\n\nThis does NOT start a new auction - press Post when you are ready.",
    button1 = "Replace item",
    button2 = "Keep bidding",
    OnAccept = function()
        local link = RedGuild_Auction.pendingSwap
        RedGuild_Auction.pendingSwap = nil
        RedGuild_Auction_Cancel()
        if link then RedGuild_Auction_ApplyItem(link) end
    end,
    OnCancel = function()
        RedGuild_Auction.pendingSwap = nil
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function RedGuild_Auction_Start()
    if not IsAuthorized() then
        AuctionPrint("Only editors can post items for bidding.")
        return
    end
    if not AuctionChannel() then
        AuctionPrint("You must be in a group or raid to post an item.")
        return
    end
    if not RedGuild_Auction.itemLink then
        AuctionPrint("Drag an item onto the window, or shift-click one into the box, first.")
        return
    end
    if RedGuild_Auction.open then
        AuctionPrint("Bidding is already open. Close it first.")
        return
    end

    local dur = AUCTION_DEFAULT_DURATION
    if auctionMaster and auctionMaster.durBox then
        dur = tonumber(auctionMaster.durBox:GetText()) or AUCTION_DEFAULT_DURATION
    end
    if dur < 5   then dur = 5   end
    if dur > 300 then dur = 300 end

    AuctionResetBook()

    RedGuild_Auction.id       = tostring(time()) .. "-" .. math.random(1000, 9999)
    RedGuild_Auction.ml       = Ambiguate(UnitName("player"), "short")
    RedGuild_Auction.duration = dur
    RedGuild_Auction.endTime  = GetTime() + dur
    RedGuild_Auction.paused   = false
    RedGuild_Auction.remaining = nil
    RedGuild_Auction.myBid    = nil
    RedGuild_Auction.open     = true
    RedGuild_Auction.posted   = true

    RedGuild_Send("BID_START", EncodePayload({
        id       = RedGuild_Auction.id,
        itemLink = RedGuild_Auction.itemLink,
        itemID   = RedGuild_Auction.itemID,
        ml       = RedGuild_Auction.ml,
        duration = dur,
    }))

    AuctionWarn(string.format(
        "Bidding OPEN on %s - %d seconds.", RedGuild_Auction.itemLink, dur))
    AuctionWarn(string.format(
        "MAIN SPEC: bid DKP, minimum %d.   OFF SPEC: /roll 69 only, costs no DKP.",
        AUCTION_MIN_BID))
    AuctionAnnounce(string.format(
        "No addon? Whisper %s:  !bid <amount>  for main spec,  or just /roll 69 for off spec.  !pass to skip.",
        RedGuild_Auction.ml))

    RedGuild_Auction_PushSync("auction start")

    -- The auctioneer never receives their own BID_START, so open the
    -- prompt for them directly. They bid on the same terms as anyone
    -- else, including the minimum and their own balance.
    RedGuild_Auction_ShowPrompt()

    if RedGuild_Auction.ticker then RedGuild_Auction.ticker:Cancel() end
    RedGuild_Auction.ticker = C_Timer.NewTicker(1, function()
        if not RedGuild_Auction.open then return end

        -- A paused auction keeps its clock frozen and announces
        -- nothing, but the window still redraws so the editor can
        -- see the held time.
        if RedGuild_Auction.paused then
            RedGuild_Auction_RefreshMaster()
            return
        end

        local left = math.ceil((RedGuild_Auction.endTime or 0) - GetTime())

        if left == 30 or left == 20 or left == 10 or left == 5 then
            AuctionWarn(string.format("%d seconds left to bid on %s",
                left, RedGuild_Auction.itemLink or "the item"))
        end

        if left <= 0 then
            RedGuild_Auction_Stop(true)
        end
        RedGuild_Auction_RefreshMaster()
    end)

    RedGuild_Auction_RefreshMaster()
end

function RedGuild_Auction_Pause()
    if not RedGuild_Auction_IsAuctioneer() then return end
    if not RedGuild_Auction.open then
        AuctionPrint("No bidding is running.")
        return
    end
    if RedGuild_Auction.paused then return end

    RedGuild_Auction.remaining = math.max(0, (RedGuild_Auction.endTime or 0) - GetTime())
    RedGuild_Auction.paused    = true

    RedGuild_Send("BID_PAUSE", EncodePayload({
        id        = RedGuild_Auction.id,
        remaining = RedGuild_Auction.remaining,
    }))

    AuctionWarn(string.format(
        "Bidding PAUSED on %s with %d seconds left. You can still bid.",
        RedGuild_Auction.itemLink or "the item", RedGuild_Auction_TimeLeft()))

    RedGuild_Auction_RefreshMaster()
end

function RedGuild_Auction_Resume()
    if not RedGuild_Auction_IsAuctioneer() then return end
    if not RedGuild_Auction.open then return end
    if not RedGuild_Auction.paused then return end

    local left = math.max(1, RedGuild_Auction.remaining or 0)
    RedGuild_Auction.endTime   = GetTime() + left
    RedGuild_Auction.paused    = false
    RedGuild_Auction.remaining = nil

    RedGuild_Send("BID_RESUME", EncodePayload({
        id        = RedGuild_Auction.id,
        remaining = left,
    }))

    AuctionWarn(string.format("Bidding RESUMED on %s - %d seconds left.",
        RedGuild_Auction.itemLink or "the item", math.ceil(left)))

    RedGuild_Auction_RefreshMaster()
end

function RedGuild_Auction_TogglePause()
    if RedGuild_Auction.paused then
        RedGuild_Auction_Resume()
    else
        RedGuild_Auction_Pause()
    end
end

function RedGuild_Auction_Stop(auto)
    if not RedGuild_Auction.open then return end

    RedGuild_Auction.open      = false
    RedGuild_Auction.paused    = false
    RedGuild_Auction.remaining = nil
    if RedGuild_Auction.ticker then
        RedGuild_Auction.ticker:Cancel()
        RedGuild_Auction.ticker = nil
    end

    if RedGuild_Auction_IsAuctioneer() then
        RedGuild_Send("BID_STOP", EncodePayload({ id = RedGuild_Auction.id }))

        local count = 0
        for _, b in pairs(RedGuild_Auction.bids) do
            if b.mode ~= "PASS" then count = count + 1 end
        end

        AuctionWarn(string.format(
            "Bidding CLOSED on %s. %d bid%s received.",
            RedGuild_Auction.itemLink or "the item",
            count, count == 1 and "" or "s"))
    end

    RedGuild_Auction_RefreshMaster()
    if auctionPrompt then auctionPrompt:Hide() end
    StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")
end

function RedGuild_Auction_Cancel()
    if not RedGuild_Auction.posted then return end

    if RedGuild_Auction_IsAuctioneer() then
        RedGuild_BidLog_Add(BuildLogEntry(nil, 0, nil, true))
        RedGuild_Send("BID_CANCEL", EncodePayload({ id = RedGuild_Auction.id }))
        AuctionWarn(string.format(
            "Bidding CANCELLED on %s. No DKP has been charged.",
            RedGuild_Auction.itemLink or "the item"))
    end

    if RedGuild_Auction.ticker then
        RedGuild_Auction.ticker:Cancel()
        RedGuild_Auction.ticker = nil
    end

    RedGuild_Auction.open      = false
    RedGuild_Auction.posted    = false
    RedGuild_Auction.paused    = false
    RedGuild_Auction.remaining = nil
    AuctionResetBook()

    RedGuild_Auction_RefreshMaster()
    if auctionPrompt then auctionPrompt:Hide() end
    StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")
end

-- Manual award. Nothing here picks a winner automatically.
function RedGuild_Auction_Award(winner, cost)
    if not IsAuthorized() then
        AuctionPrint("Only editors can award items.")
        return
    end
    if not winner then
        AuctionPrint("Select a bidder in the list first.")
        return
    end

    cost = tonumber(cost) or 0
    if cost < 0 then cost = 0 end

    local who  = RedGuild_Auction_Bidder(winner)
    local link = RedGuild_Auction.itemLink or "item"

    if cost > 0 then
        local inGuild = IsNameInGuild(who)
        if not inGuild and not (RedGuild_Data and RedGuild_Data[who]) then
            AuctionPrint(string.format(
                "%s is not on the DKP table and not in the guild - no DKP charged. Award recorded in chat only.", who))
            cost = 0
        else
            local d   = EnsurePlayer(who)
            local old = d.spent or 0
            d.spent   = old + cost
            RecalcBalance(d)

            LogAudit(who, "spent", old, d.spent)
            LogAudit(who, "item won", "", string.format("%s (%d DKP)", link, cost))

            BumpDKPVersion()
            if UpdateTable then UpdateTable() end
            if UpdateSyncStatus then UpdateSyncStatus() end
            RedGuild_Auction_PushSync("item awarded")
        end
    end

    local bid  = RedGuild_Auction.bids[who]
    local mode = bid and bid.mode or "MS"
    local roll = bid and bid.roll

    RedGuild_BidLog_Add(BuildLogEntry(who, cost, mode, false))

    RedGuild_Send("BID_AWARD", EncodePayload({
        id     = RedGuild_Auction.id,
        winner = who,
        cost   = cost,
        mode   = mode,
    }))

    if mode == "OS" then
        if roll then
            AuctionWarn(string.format(
                "%s awarded to %s on an off-spec roll of %d. No DKP charged.", link, winner, roll))
        else
            AuctionWarn(string.format(
                "%s awarded to %s for off spec. No DKP charged.", link, winner))
        end
    elseif cost > 0 then
        AuctionWarn(string.format("%s awarded to %s for %d DKP (main spec).", link, winner, cost))
    else
        AuctionWarn(string.format("%s awarded to %s. No DKP charged.", link, winner))
    end

    if RedGuild_Auction.ticker then
        RedGuild_Auction.ticker:Cancel()
        RedGuild_Auction.ticker = nil
    end

    RedGuild_Auction.open   = false
    RedGuild_Auction.posted = false
    AuctionResetBook()

    RedGuild_Auction_RefreshMaster()
    if auctionPrompt then auctionPrompt:Hide() end
    StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")

    AuctionPrint(string.format(
        "Awarded %s to %s for %d DKP. Remember to broadcast/sync so everyone gets the new balances.",
        link, winner, cost))
end

--------------------------------------------------
-- Bidder side
--------------------------------------------------

function RedGuild_Auction_SendBid(amount, mode)
    if not RedGuild_Auction.posted or not RedGuild_Auction.ml then
        AuctionPrint("There is no item up for bidding.")
        return
    end
    if not RedGuild_Auction.open then
        AuctionPrint("Bidding has already closed.")
        return
    end

    mode   = mode or "MS"
    amount = tonumber(amount) or 0
    if mode ~= "MS" then amount = 0 end

    local bal = RedGuild_Auction_GetBalance(UnitName("player"))

    if mode == "MS" then
        if amount < AUCTION_MIN_BID then
            AuctionPrint(string.format(
                "Minimum bid is %d DKP. Off spec is the roll button, not a bid.",
                AUCTION_MIN_BID))
            return
        end
        if amount > bal then
            AuctionPrint(string.format("You only have %d DKP.", bal))
            return
        end
    end

    if RedGuild_Auction_IsAuctioneer() then
        -- Addon messages whispered to yourself are dropped by the
        -- inbound handler, so write straight into the book instead.
        local good, err = RedGuild_Auction_RecordBid(
            UnitName("player"), amount, mode, "addon")
        if not good then
            AuctionPrint(err or "Bid rejected.")
            return
        end
    else
        RedGuild_Send("BID_PLACE", EncodePayload({
            id     = RedGuild_Auction.id,
            amount = amount,
            mode   = mode,
        }), RedGuild_Auction.ml)
    end

    -- Kept so this client can write its own entry in the Bid Log
    -- when the award is announced.
    RedGuild_Auction.myBid = {
        name   = Ambiguate(UnitName("player"), "short"),
        amount = amount,
        mode   = mode,
        src    = "addon",
    }

    if mode == "OS" then
        -- A real Blizzard roll so the whole raid can see it and the
        -- auctioneer can verify it. The system message is picked up
        -- on the editor's client and attached to this bid.
        RandomRoll(1, 69)
        AuctionPrint("Off spec roll sent. It costs no DKP if you win it.")
    elseif mode == "PASS" then
        AuctionPrint("You passed.")
    else
        AuctionPrint(string.format("Bid of %d DKP sent to %s.", amount, RedGuild_Auction.ml))
    end

    if auctionPrompt then auctionPrompt:Hide() end
    StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")
end

--------------------------------------------------
-- Incoming addon messages
--------------------------------------------------

function RedGuild_Auction_OnAddonMessage(msgType, payload, sender)
    local ok, data = pcall(DecodePayload, payload)
    if not ok or type(data) ~= "table" then return end

    sender = Ambiguate(sender or "", "short")

    ----------------------------------------------------------------
    if msgType == "BID_START" then
        -- Only trust an editor, and only for the group we are in.
        if not IsEditor(sender) then return end

        RedGuild_Auction.id       = data.id
        RedGuild_Auction.itemLink = data.itemLink
        RedGuild_Auction.itemID   = data.itemID
        RedGuild_Auction.ml       = data.ml or sender
        RedGuild_Auction.duration = tonumber(data.duration) or AUCTION_DEFAULT_DURATION
        RedGuild_Auction.endTime  = GetTime() + RedGuild_Auction.duration
        RedGuild_Auction.paused   = false
        RedGuild_Auction.remaining = nil
        RedGuild_Auction.myBid    = nil
        RedGuild_Auction.open     = true
        RedGuild_Auction.posted   = true
        AuctionResetBook()

        RedGuild_Auction_ShowPrompt()
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_PLACE" then
        -- Only the auctioneer cares about incoming bids.
        if not RedGuild_Auction_IsAuctioneer() then return end
        if data.id ~= RedGuild_Auction.id then return end

        local good, err = RedGuild_Auction_RecordBid(sender, data.amount, data.mode, "addon")
        if not good and err then
            AuctionWhisper(sender, "RedGuild: " .. err)
        end
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_PAUSE" then
        if data.id ~= RedGuild_Auction.id then return end
        RedGuild_Auction.remaining = tonumber(data.remaining) or 0
        RedGuild_Auction.paused    = true
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_RESUME" then
        if data.id ~= RedGuild_Auction.id then return end
        RedGuild_Auction.endTime   = GetTime() + (tonumber(data.remaining) or 0)
        RedGuild_Auction.paused    = false
        RedGuild_Auction.remaining = nil
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_STOP" then
        if data.id ~= RedGuild_Auction.id then return end
        RedGuild_Auction.open = false
        if auctionPrompt then auctionPrompt:Hide() end
        StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_CANCEL" then
        if data.id ~= RedGuild_Auction.id then return end
        RedGuild_BidLog_Add(BuildLogEntry(nil, 0, nil, true))
        RedGuild_Auction.open   = false
        RedGuild_Auction.posted = false
        AuctionResetBook()
        if auctionPrompt then auctionPrompt:Hide() end
        StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_AWARD" then
        if data.id ~= RedGuild_Auction.id then return end

        RedGuild_BidLog_Add(BuildLogEntry(
            data.winner, tonumber(data.cost) or 0, data.mode, false))
        RedGuild_Auction.open   = false
        RedGuild_Auction.posted = false
        AuctionResetBook()
        if auctionPrompt then auctionPrompt:Hide() end
        StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")

        -- Non-editors update their own copy so their displayed balance
        -- is right immediately instead of waiting for the next sync.
        if not IsAuthorized() and data.winner and (tonumber(data.cost) or 0) > 0 then
            local d = RedGuild_Data and RedGuild_Data[data.winner]
            if d then
                d.spent = (d.spent or 0) + tonumber(data.cost)
                RecalcBalance(d)
                if UpdateTable then UpdateTable() end
            end
        end
        return
    end
end

--------------------------------------------------
-- Whisper commands for players without the addon
-- Returns true when the whisper was a bid command.
--------------------------------------------------

function RedGuild_Auction_OnWhisper(text, sender)
    if not text or not sender then return false end

    local lower = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if lower:sub(1, 1) ~= "!" then return false end

    sender = Ambiguate(sender, "short")

    ----------------------------------------------------------------
    -- !dkp  (works any time, editors only)
    ----------------------------------------------------------------
    if lower == "!dkp" then
        if not IsAuthorized() then return false end
        local bal, main = RedGuild_Auction_GetBalance(sender)
        if RedGuild_Data and RedGuild_Data[main] then
            AuctionWhisper(sender, string.format("Your DKP: %d", bal))
        else
            AuctionWhisper(sender, "You are not on the DKP table yet.")
        end
        return true
    end

    -- Everything below needs to be the auctioneer with bidding open.
    if not RedGuild_Auction_IsAuctioneer() then return false end

    if not RedGuild_Auction.open then
        if lower:match("^!bid") or lower == "!pass" or lower == "!os" then
            AuctionWhisper(sender, "RedGuild: bidding is not open right now.")
            return true
        end
        return false
    end

    ----------------------------------------------------------------
    -- !pass
    ----------------------------------------------------------------
    if lower == "!pass" then
        RedGuild_Auction_RecordBid(sender, 0, "PASS", "whisper")
        AuctionWhisper(sender, "RedGuild: passed.")
        return true
    end

    ----------------------------------------------------------------
    -- !os
    ----------------------------------------------------------------
    if lower == "!os" then
        RedGuild_Auction_RecordBid(sender, 0, "OS", "whisper")
        AuctionWhisper(sender,
            "RedGuild: off spec noted, it costs no DKP. Now /roll 69 and I will pick it up.")
        return true
    end

    ----------------------------------------------------------------
    -- !bid <amount>   (main spec only)
    ----------------------------------------------------------------
    local amount, tail = lower:match("^!bid%s+(%d+)%s*(.*)$")
    if amount then
        -- Someone trying to bid DKP for off-spec. Register the
        -- off-spec roll instead and explain the rule.
        if tail and (tail:find("os", 1, true) or tail:find("off", 1, true)) then
            RedGuild_Auction_RecordBid(sender, 0, "OS", "whisper")
            AuctionWhisper(sender,
                "RedGuild: off spec is roll only and costs no DKP. Noted as off spec - now /roll 69.")
            return true
        end

        local good, err = RedGuild_Auction_RecordBid(sender, amount, "MS", "whisper")
        if good then
            AuctionWhisper(sender, string.format("RedGuild: main-spec bid of %d DKP recorded on %s.",
                tonumber(amount), RedGuild_Auction.itemLink or "the item"))
        else
            AuctionWhisper(sender, "RedGuild: " .. (err or "bid rejected."))
        end
        return true
    end

    if lower:match("^!bid") then
        AuctionWhisper(sender, string.format(
            "RedGuild: use  !bid <amount>  for main spec, minimum %d, for example  !bid 50. Off spec is /roll 69 only and costs no DKP.",
            AUCTION_MIN_BID))
        return true
    end

    return false
end

--------------------------------------------------
-- /roll capture (off-spec), auctioneer only
--------------------------------------------------

function RedGuild_Auction_OnSystemMessage(text)
    if not text then return end
    if not RedGuild_Auction.open then return end
    if not RedGuild_Auction_IsAuctioneer() then return end

    local who, roll, low, high = text:match(RedGuild_RollPattern)
    if not who or not roll then return end
    if tonumber(low) ~= 1 or tonumber(high) ~= 69 then
        AuctionWhisper(who, "RedGuild: only /roll 69 (1-69) counts. Please roll again.")
        return
    end

    who = RedGuild_Auction_Bidder(who)
    local bid = RedGuild_Auction.bids[who]

    if bid then
        -- Main-spec bidders are not converted by rolling.
        if bid.mode ~= "OS" then return end

        -- Only the first roll counts. Later ones are ignored, and
        -- the roller is told once so they are not left thinking a
        -- reroll replaced their result.
        if bid.roll then
            if not bid.rollWarned then
                bid.rollWarned = true
                AuctionWhisper(who, string.format(
                    "RedGuild: only your first roll counts. Your %d stands, later rolls are ignored.",
                    bid.roll))
                AuctionPrint(string.format(
                    "%s rolled again (%d) - ignored, first roll of %d stands.",
                    who, tonumber(roll), bid.roll))
            end
            return
        end

        bid.roll = tonumber(roll)
        RedGuild_Auction_RefreshMaster()
    else
        -- Someone rolled without registering. Treat as an off-spec roll
        -- so people who just /roll are not silently dropped.
        RedGuild_Auction_RecordBid(who, 0, "OS", "roll", tonumber(roll))
    end
end

--------------------------------------------------
-- BIDDER PROMPT
--------------------------------------------------

local function BidItemName(link)
    if not link then return "this item" end
    return link:match("|h%[(.-)%]|h") or link
end

StaticPopupDialogs["REDGUILD_BID_CONFIRM_PASS"] = {
    text = "Pass on %s?\n\nClosing the bidding window counts as a pass, and you will not be able to bid on it.",
    button1 = "Pass",
    button2 = "Keep bidding",
    OnAccept = function()
        RedGuild_Auction.passConfirm = nil
        if RedGuild_Auction.open and not RedGuild_Auction.myBid then
            RedGuild_Auction_SendBid(0, "PASS")
        end
    end,
    OnCancel = function()
        RedGuild_Auction.passConfirm = nil
        -- Not a pass after all, so put the window back.
        if RedGuild_Auction.open and not RedGuild_Auction.myBid then
            RedGuild_Auction_ShowPrompt()
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = false, preferredIndex = 3,
}

local function CreatePrompt()
    if auctionPrompt then return auctionPrompt end

    local f = CreateFrame("Frame", "RedGuildBidPrompt", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(300, 225)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    table.insert(UISpecialFrames, "RedGuildBidPrompt")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("CENTER", f.TitleBg, "CENTER", 0, 0)
    f.title:SetText("RedGuild - Bid")

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(34, 34)
    f.icon:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)

    f.itemBtn = CreateFrame("Button", nil, f)
    f.itemBtn:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 8, 0)
    f.itemBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -34)
    f.itemBtn:SetHeight(34)

    f.itemText = f.itemBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.itemText:SetAllPoints(f.itemBtn)
    f.itemText:SetJustifyH("LEFT")
    f.itemText:SetWordWrap(true)

    f.itemBtn:SetScript("OnEnter", function(self)
        if not RedGuild_Auction.itemLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(RedGuild_Auction.itemLink)
        GameTooltip:Show()
    end)
    f.itemBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.balText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.balText:SetPoint("TOPLEFT", f.icon, "BOTTOMLEFT", 0, -10)

    f.timerText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.timerText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -80)

    local bidLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bidLabel:SetPoint("TOPLEFT", f.balText, "BOTTOMLEFT", 0, -12)
    bidLabel:SetText(string.format("Main spec bid (min %d):", AUCTION_MIN_BID))

    f.ruleText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.ruleText:SetPoint("TOPLEFT", bidLabel, "BOTTOMLEFT", 0, -14)
    f.ruleText:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.ruleText:SetJustifyH("LEFT")
    f.ruleText:SetWordWrap(true)
    f.ruleText:SetText(string.format(
        "Minimum bid %d DKP. Off spec is a roll, not a bid, and costs no DKP.\nClosing this window or pressing Escape counts as a pass.",
        AUCTION_MIN_BID))

    f.amountBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.amountBox:SetSize(70, 20)
    f.amountBox:SetPoint("LEFT", bidLabel, "RIGHT", 10, 0)
    f.amountBox:SetAutoFocus(false)
    f.amountBox:SetNumeric(true)
    f.amountBox:SetScript("OnEnterPressed", function(self)
        RedGuild_Auction_SendBid(self:GetNumber(), "MS")
        self:ClearFocus()
    end)
    f.amountBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Bid sits far left and Roll OS far right, so the two cannot be
    -- confused for one another under raid pressure.
    f.bidBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.bidBtn:SetSize(92, 24)
    f.bidBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 14)
    f.bidBtn:SetText("|TInterface\\Icons\\INV_Misc_Coin_01:14:14:0:0|t Bid")
    f.bidBtn:SetScript("OnClick", function()
        RedGuild_Auction_SendBid(f.amountBox:GetNumber(), "MS")
    end)

    f.osBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.osBtn:SetSize(102, 24)
    f.osBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
    f.osBtn:SetText("|TInterface\\Buttons\\UI-GroupLoot-Dice-Up:16:16:0:0|t Roll OS")
    f.osBtn:SetScript("OnClick", function()
        RedGuild_Auction_SendBid(0, "OS")
    end)

    -- There is no Pass button. Dismissing the window is the pass, so
    -- the close box and Escape both go through here. Every deliberate
    -- hide from the addon happens after the auction is closed or after
    -- a bid was recorded, and both are covered by the guards below, so
    -- only a genuine dismissal reaches SendBid.
    f:SetScript("OnHide", function()
        if not RedGuild_Auction.open then return end
        if RedGuild_Auction.myBid then return end
        if RedGuild_Auction.passConfirm then return end

        -- Escape is easy to hit by reflex while clearing other UI, so
        -- ask before turning that into a pass that cannot be undone.
        RedGuild_Auction.passConfirm = true
        StaticPopup_Show("REDGUILD_BID_CONFIRM_PASS",
            BidItemName(RedGuild_Auction.itemLink))
    end)

    f:SetScript("OnUpdate", function(self, elapsed)
        self.acc = (self.acc or 0) + elapsed
        if self.acc < 0.2 then return end
        self.acc = 0

        if not RedGuild_Auction.open then
            self.timerText:SetText("|cffff5555Closed|r")
            return
        end

        local left = RedGuild_Auction_TimeLeft()
        if RedGuild_Auction.paused then
            self.timerText:SetText(string.format("|cffffff00PAUSED %ds|r", left))
            return
        end

        local colour = left <= 5 and "|cffff5555" or "|cffffff00"
        self.timerText:SetText(string.format("%s%ds|r", colour, left))
    end)

    auctionPrompt = f
    return f
end

function RedGuild_Auction_ShowPrompt()
    if not RedGuild_Auction.posted then return end

    -- A confirmation left over from a previous item must not suppress
    -- the next one, or a later Escape would silently do nothing.
    RedGuild_Auction.passConfirm = nil

    local f = CreatePrompt()
    local bal = RedGuild_Auction_GetBalance(UnitName("player"))

    f.itemText:SetText(RedGuild_Auction.itemLink or "Unknown item")
    f.icon:SetTexture(
        (RedGuild_Auction.itemID and GetItemIcon(RedGuild_Auction.itemID))
        or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.balText:SetText(string.format("Your DKP: |cff00ff00%d|r", bal))
    f.amountBox:SetText("")
    f:Show()
end

--------------------------------------------------
-- AUCTIONEER WINDOW
--------------------------------------------------

local function CreateMasterRow(index, parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(400, 16)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * 16))

    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints(row)
    row.hl:SetColorTexture(0.3, 0.5, 0.9, 0.35)
    row.hl:Hide()

    local function mk(x, w, justify)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", row, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(justify or "LEFT")
        return fs
    end

    row.nameText = mk(4,   120)
    row.bidText  = mk(128,  50, "RIGHT")
    row.modeText = mk(186,  40)
    row.balText  = mk(230,  50, "RIGHT")
    row.rollText = mk(288,  40, "RIGHT")
    row.srcText  = mk(336,  60)

    row:SetScript("OnClick", function(self)
        RedGuild_Auction.selected = self.bidder
        RedGuild_Auction_RefreshMaster()
    end)

    return row
end

local function CreateMaster()
    if auctionMaster then return auctionMaster end

    local f = CreateFrame("Frame", "RedGuildAuctionFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(430, 430)
    f:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    table.insert(UISpecialFrames, "RedGuildAuctionFrame")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("CENTER", f.TitleBg, "CENTER", 0, 0)
    f.title:SetText("RedGuild - Item Bidding")

    ----------------------------------------------------------------
    -- Item drop slot
    ----------------------------------------------------------------
    local slot = CreateFrame("Button", nil, f)
    slot:SetSize(36, 36)
    slot:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
    slot:RegisterForDrag("LeftButton")

    slot.bg = slot:CreateTexture(nil, "BACKGROUND")
    slot.bg:SetAllPoints(slot)
    slot.bg:SetColorTexture(0, 0, 0, 0.5)

    f.itemIcon = slot:CreateTexture(nil, "ARTWORK")
    f.itemIcon:SetAllPoints(slot)
    f.itemIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

    local function TakeCursorItem()
        local cursorType, _, itemLink = GetCursorInfo()
        if cursorType == "item" and itemLink then
            ClearCursor()
            RedGuild_Auction_SetItem(itemLink)
        end
    end
    slot:SetScript("OnReceiveDrag", TakeCursorItem)
    slot:SetScript("OnMouseUp", TakeCursorItem)
    slot:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if RedGuild_Auction.itemLink then
            GameTooltip:SetHyperlink(RedGuild_Auction.itemLink)
        else
            GameTooltip:SetText("Drag an item here, or shift-click one into the box.")
        end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.itemText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.itemText:SetPoint("TOPLEFT", slot, "TOPRIGHT", 8, -2)
    f.itemText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -36)
    f.itemText:SetJustifyH("LEFT")
    f.itemText:SetText("|cff888888No item selected|r")

    ----------------------------------------------------------------
    -- Item link box (shift-click target)
    ----------------------------------------------------------------
    f.itemBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.itemBox:SetSize(230, 20)
    f.itemBox:SetPoint("TOPLEFT", slot, "BOTTOMLEFT", 6, -8)
    f.itemBox:SetAutoFocus(false)
    f.itemBox:SetScript("OnEnterPressed", function(self)
        local txt = self:GetText()
        if txt and txt:find("item:") then
            RedGuild_Auction_SetItem(txt)
        end
        self:ClearFocus()
    end)
    f.itemBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    hooksecurefunc("ChatEdit_InsertLink", function(link)
        if link and auctionMaster and auctionMaster:IsShown()
            and auctionMaster.itemBox and auctionMaster.itemBox:HasFocus() then
            auctionMaster.itemBox:SetText(link)
            RedGuild_Auction_SetItem(link)
        end
    end)

    ----------------------------------------------------------------
    -- Duration + controls
    ----------------------------------------------------------------
    local durLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    durLabel:SetPoint("LEFT", f.itemBox, "RIGHT", 10, 0)
    durLabel:SetText("Secs:")

    f.durBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.durBox:SetSize(36, 20)
    f.durBox:SetPoint("LEFT", durLabel, "RIGHT", 8, 0)
    f.durBox:SetAutoFocus(false)
    f.durBox:SetNumeric(true)
    f.durBox:SetText(tostring(AUCTION_DEFAULT_DURATION))
    f.durBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    f.startBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.startBtn:SetSize(68, 22)
    f.startBtn:SetPoint("TOPLEFT", f.itemBox, "BOTTOMLEFT", -6, -8)
    f.startBtn:SetText("Post")
    f.startBtn:SetScript("OnClick", RedGuild_Auction_Start)

    f.pauseBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.pauseBtn:SetSize(68, 22)
    f.pauseBtn:SetPoint("LEFT", f.startBtn, "RIGHT", 6, 0)
    f.pauseBtn:SetText("Pause")
    f.pauseBtn:SetScript("OnClick", RedGuild_Auction_TogglePause)

    f.stopBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.stopBtn:SetSize(68, 22)
    f.stopBtn:SetPoint("LEFT", f.pauseBtn, "RIGHT", 6, 0)
    f.stopBtn:SetText("Close")
    f.stopBtn:SetScript("OnClick", function() RedGuild_Auction_Stop(false) end)

    f.cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.cancelBtn:SetSize(68, 22)
    f.cancelBtn:SetPoint("LEFT", f.stopBtn, "RIGHT", 6, 0)
    f.cancelBtn:SetText("Cancel")
    f.cancelBtn:SetScript("OnClick", RedGuild_Auction_Cancel)

    f.timerText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.timerText:SetPoint("LEFT", f.cancelBtn, "RIGHT", 10, 0)

    ----------------------------------------------------------------
    -- Column headers
    ----------------------------------------------------------------
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", f.startBtn, "BOTTOMLEFT", 6, -10)
    header:SetSize(400, 14)

    local function hdr(x, w, text, justify)
        local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", header, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(justify or "LEFT")
        fs:SetText(text)
        return fs
    end
    hdr(4,   120, "Bidder")
    hdr(128,  50, "Bid", "RIGHT")
    hdr(186,  40, "Type")
    hdr(230,  50, "Bal", "RIGHT")
    hdr(288,  40, "Roll", "RIGHT")
    hdr(336,  60, "Via")

    ----------------------------------------------------------------
    -- Bid list
    ----------------------------------------------------------------
    local scroll = CreateFrame("ScrollFrame", "RedGuildAuctionScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 46)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(400, 16)
    scroll:SetScrollChild(child)
    f.scrollChild = child

    ----------------------------------------------------------------
    -- Award controls
    ----------------------------------------------------------------
    local costLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    costLabel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 22)
    costLabel:SetText("Cost:")

    f.costBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.costBox:SetSize(50, 20)
    f.costBox:SetPoint("LEFT", costLabel, "RIGHT", 10, 0)
    f.costBox:SetAutoFocus(false)
    f.costBox:SetNumeric(true)
    f.costBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    f.awardBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.awardBtn:SetSize(160, 24)
    f.awardBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 16)
    f.awardBtn:SetText("Award to selected")
    f.awardBtn:SetScript("OnClick", function()
        if not RedGuild_Auction.selected then
            AuctionPrint("Click a bidder in the list first.")
            return
        end
        RedGuild_Auction_Award(RedGuild_Auction.selected, f.costBox:GetNumber())
    end)

    f.hintText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hintText:SetPoint("BOTTOMLEFT", costLabel, "TOPLEFT", 0, 4)
    f.hintText:SetText(
        "Off spec = roll, no DKP. Winner is never picked automatically: click a row, check the cost, award.")

    auctionMaster = f
    return f
end

function RedGuild_Auction_RefreshMaster()
    if not auctionMaster or not auctionMaster:IsShown() then return end
    local f = auctionMaster

    ----------------------------------------------------------------
    -- Header state
    ----------------------------------------------------------------
    f.itemText:SetText(RedGuild_Auction.itemLink or "|cff888888No item selected|r")

    if RedGuild_Auction.open then
        local left = RedGuild_Auction_TimeLeft()
        if RedGuild_Auction.paused then
            f.timerText:SetText(string.format("|cffffff00PAUSED %ds|r", left))
            f.pauseBtn:SetText("Resume")
        else
            local colour = left <= 5 and "|cffff5555" or "|cffffff00"
            f.timerText:SetText(string.format("%s%ds|r", colour, left))
            f.pauseBtn:SetText("Pause")
        end
        f.startBtn:Disable()
        f.stopBtn:Enable()
        f.pauseBtn:Enable()
    else
        f.timerText:SetText(RedGuild_Auction.posted and "|cffff5555closed|r" or "")
        f.pauseBtn:SetText("Pause")
        f.startBtn:Enable()
        f.stopBtn:Disable()
        f.pauseBtn:Disable()
    end

    ----------------------------------------------------------------
    -- Rows
    ----------------------------------------------------------------
    local list  = RedGuild_Auction_SortedBids()
    local shown = math.min(#list, AUCTION_MAX_ROWS)

    for i = 1, shown do
        local b = list[i]
        local row = auctionMasterRows[i]
        if not row then
            row = CreateMasterRow(i, f.scrollChild)
            auctionMasterRows[i] = row
        end

        row.bidder = b.key

        row.nameText:SetText(ClassColour(b.name) .. b.name .. "|r")

        if b.mode == "MS" then
            row.bidText:SetText(tostring(b.amount or 0))
        else
            -- Off spec and passes cost nothing, so there is no figure.
            row.bidText:SetText("|cff888888-|r")
        end

        local modeColour = "|cffffffff"
        if b.mode == "OS"   then modeColour = "|cff55ccff" end
        if b.mode == "PASS" then modeColour = "|cff888888" end
        row.modeText:SetText(modeColour .. (b.mode or "?") .. "|r")

        -- Balance is looked up live from the editor's own table, not
        -- from whatever the bidder claimed.
        local bal = RedGuild_Auction_GetBalance(b.name)
        if b.mode == "MS" and (b.amount or 0) > bal then
            row.balText:SetText("|cffff0000" .. bal .. "|r")
        else
            row.balText:SetText(tostring(bal))
        end

        row.rollText:SetText(b.roll and tostring(b.roll) or "")
        row.srcText:SetText("|cff888888" .. (b.src or "") .. "|r")

        if RedGuild_Auction.selected == b.key then
            row.hl:Show()
        else
            row.hl:Hide()
        end

        row:Show()
    end

    for i = shown + 1, #auctionMasterRows do
        auctionMasterRows[i]:Hide()
    end

    f.scrollChild:SetHeight(math.max(1, shown * 16))

    ----------------------------------------------------------------
    -- Pre-fill the cost box from the selection
    ----------------------------------------------------------------
    if RedGuild_Auction.selected then
        local b = RedGuild_Auction.bids[RedGuild_Auction.selected]
        if b and not f.costBox:HasFocus() then
            -- Main spec suggests the bid; off spec is always free.
            f.costBox:SetText(tostring(b.amount or 0))
        end
    end
end

function RedGuild_Auction_ShowMaster()
    if not IsAuthorized() then
        AuctionPrint("Only editors can run bidding.")
        return
    end
    local f = CreateMaster()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        RedGuild_Auction_RefreshMaster()
    end
end

--------------------------------------------------
-- Hook a button onto the ML Scorecard tab
--------------------------------------------------

function RedGuild_Auction_AttachUI()
    if not mainFrame or not dkpPanel then return end
    if auctionButton then return end

    -- Parented to the DKP panel, so it is present on the DKP tab and
    -- hides with it. Visibility is still gated on being an editor.
    local btn = CreateFrame("Button", "RedGuildBiddingButton", dkpPanel, "UIPanelButtonTemplate")
    btn:SetSize(70, 18)
    btn:SetText("Bidding")
    btn:SetFrameStrata("HIGH")
    btn:SetScript("OnClick", RedGuild_Auction_ShowMaster)

    -- Sits just left of the Sync indicator. statusText is created by
    -- CreateUI; fall back to the frame corner if it is missing.
    local syncWidget = statusText and statusText:GetParent()
    if syncWidget then
        btn:SetPoint("RIGHT", syncWidget, "LEFT", -10, 0)
    else
        btn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -130, -4)
    end

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("|cffffff00Item Bidding|r")
        GameTooltip:AddLine("Post an item and collect DKP bids from the raid.", 1, 1, 1)
        GameTooltip:AddLine("Also available as /redguild bid", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    auctionButton = btn

    -- Editors only. Re-checked whenever the window opens or the DKP
    -- tab is shown, so the button appears as soon as an editor list
    -- sync arrives rather than needing a reload.
    local function UpdateBidButton()
        if IsEditor(UnitName("player")) then btn:Show() else btn:Hide() end
    end
    UpdateBidButton()
    mainFrame:HookScript("OnShow", UpdateBidButton)
    dkpPanel:HookScript("OnShow", UpdateBidButton)
end


--==================================================================
-- BID LOG TAB
--==================================================================
-- Editors see every bid that was placed. Everyone else sees the
-- outcome of each auction plus their own bid, because that is all
-- their client ever received.
--==================================================================

local bidLogRows    = {}
local bidLogDetail  = {}
local bidLogSelected

local function BidLogIsEditor()
    return IsEditor(UnitName("player")) and true or false
end

local function BidLogStripLink(link)
    if not link then return "unknown item" end
    local name = link:match("|h%[(.-)%]|h")
    return name or link
end

--------------------------------------------------
-- Rows
--------------------------------------------------

local function CreateLogRow(index, parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(700, 16)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * 16))

    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints(row)
    row.hl:SetColorTexture(0.3, 0.5, 0.9, 0.35)
    row.hl:Hide()

    local function mk(x, w, justify)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", row, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(justify or "LEFT")
        return fs
    end

    row.whenText   = mk(4,    85)
    row.itemText   = mk(95,  250)
    row.winnerText = mk(350, 110)
    row.costText   = mk(465,  55, "RIGHT")
    row.modeText   = mk(528,  55)
    row.countText  = mk(588, 100, "RIGHT")

    row:SetScript("OnClick", function(self)
        bidLogSelected = self.entryIndex
        RedGuild_BidLog_Refresh()
    end)

    row:SetScript("OnEnter", function(self)
        if not self.itemLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.itemLink)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

local function CreateDetailRow(index, parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(700, 14)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * 14))

    local function mk(x, w, justify)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", row, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(justify or "LEFT")
        return fs
    end

    row.nameText   = mk(4,   130)
    row.bidText    = mk(140,  55, "RIGHT")
    row.modeText   = mk(203,  50)
    row.rollText   = mk(258,  50, "RIGHT")
    row.srcText    = mk(316,  70)
    row.resultText = mk(392, 160)

    return row
end

--------------------------------------------------
-- Panel
--------------------------------------------------

function RedGuild_BidLog_Build()
    if not bidLogPanel or bidLogPanel.built then return end
    local p = bidLogPanel

    ----------------------------------------------------------------
    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", p, "TOPLEFT", 25, -42)
    title:SetText("Bid Log")

    p.subText = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.subText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)

    ----------------------------------------------------------------
    -- Bidding button, editors only
    ----------------------------------------------------------------
    local bidBtn = CreateFrame("Button", "RedGuildBidLogBiddingButton", p, "UIPanelButtonTemplate")
    bidBtn:SetSize(80, 20)
    bidBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -45, -42)
    bidBtn:SetText("Bidding")
    bidBtn:SetScript("OnClick", RedGuild_Auction_ShowMaster)
    bidBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("|cffffff00Item Bidding|r")
        GameTooltip:AddLine("Post an item and collect DKP bids from the raid.", 1, 1, 1)
        GameTooltip:Show()
    end)
    bidBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    auctionLogButton = bidBtn

    local clearBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    clearBtn:SetSize(80, 20)
    clearBtn:SetPoint("RIGHT", bidBtn, "LEFT", -6, 0)
    clearBtn:SetText("Clear log")
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Show("REDGUILD_CLEAR_BIDLOG")
    end)
    p.clearBtn = clearBtn

    ----------------------------------------------------------------
    -- Column headers
    ----------------------------------------------------------------
    local head = CreateFrame("Frame", nil, p)
    head:SetPoint("TOPLEFT", p, "TOPLEFT", 25, -88)
    head:SetSize(700, 14)

    local function hdr(parent, x, w, text, justify)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", parent, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(justify or "LEFT")
        fs:SetText(text)
        return fs
    end
    hdr(head, 4,    85, "When")
    hdr(head, 95,  250, "Item")
    hdr(head, 350, 110, "Awarded to")
    hdr(head, 465,  55, "Cost", "RIGHT")
    hdr(head, 528,  55, "Type")
    hdr(head, 588, 100, "Bids", "RIGHT")

    ----------------------------------------------------------------
    -- Auction list
    ----------------------------------------------------------------
    local scroll = CreateFrame("ScrollFrame", "RedGuildBidLogScroll", p, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -45, 205)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(700, 16)
    scroll:SetScrollChild(child)
    p.listChild = child

    p.emptyText = p:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    p.emptyText:SetPoint("CENTER", scroll, "CENTER", 0, 0)
    p.emptyText:SetText("No bidding recorded yet.")
    p.emptyText:Hide()

    ----------------------------------------------------------------
    -- Detail pane
    ----------------------------------------------------------------
    p.detailTitle = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.detailTitle:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, -10)
    p.detailTitle:SetText("Select an auction above")

    local dhead = CreateFrame("Frame", nil, p)
    dhead:SetPoint("TOPLEFT", p.detailTitle, "BOTTOMLEFT", 0, -4)
    dhead:SetSize(700, 14)
    hdr(dhead, 4,   130, "Bidder")
    hdr(dhead, 140,  55, "Bid", "RIGHT")
    hdr(dhead, 203,  50, "Type")
    hdr(dhead, 258,  50, "Roll", "RIGHT")
    hdr(dhead, 316,  70, "Via")
    hdr(dhead, 392, 160, "Result")
    p.detailHead = dhead

    local dscroll = CreateFrame("ScrollFrame", "RedGuildBidLogDetailScroll", p, "UIPanelScrollFrameTemplate")
    dscroll:SetPoint("TOPLEFT", dhead, "BOTTOMLEFT", 0, -4)
    dscroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -45, 40)

    local dchild = CreateFrame("Frame", nil, dscroll)
    dchild:SetSize(700, 14)
    dscroll:SetScrollChild(dchild)
    p.detailChild = dchild

    p.built = true
end

--------------------------------------------------
-- Refresh
--------------------------------------------------

function RedGuild_BidLog_Refresh()
    if not bidLogPanel then return end
    RedGuild_BidLog_Build()
    if not bidLogPanel:IsShown() then return end

    local p        = bidLogPanel
    local log      = (RedGuild_Config and RedGuild_Config.bidLog) or {}
    local isEditor = BidLogIsEditor()

    ----------------------------------------------------------------
    -- Editor-only controls
    ----------------------------------------------------------------
    if isEditor then
        auctionLogButton:Show()
        p.clearBtn:Show()
        p.subText:SetText("Every bid placed in each auction.")
    else
        auctionLogButton:Hide()
        p.clearBtn:Hide()
        p.subText:SetText("Items awarded, and the bids you placed yourself.")
    end

    ----------------------------------------------------------------
    -- Auction list
    ----------------------------------------------------------------
    local shown = math.min(#log, 250)
    p.emptyText:SetShown(shown == 0)

    for i = 1, shown do
        local e   = log[i]
        local row = bidLogRows[i]
        if not row then
            row = CreateLogRow(i, p.listChild)
            bidLogRows[i] = row
        end

        row.entryIndex = i
        row.itemLink   = e.item

        row.whenText:SetText("|cff888888" .. (e.when or "") .. "|r")
        row.itemText:SetText(e.item or "unknown item")

        if e.cancelled then
            row.winnerText:SetText("|cffff5555cancelled|r")
            row.costText:SetText("|cff888888-|r")
            row.modeText:SetText("")
        else
            row.winnerText:SetText(e.winner or "|cff888888-|r")
            row.costText:SetText(tostring(e.cost or 0))
            local modeColour = (e.mode == "OS") and "|cff55ccff" or "|cffffffff"
            row.modeText:SetText(modeColour .. (e.mode or "") .. "|r")
        end

        -- An editor's entry holds the whole book, so the count is real.
        -- A player's entry only ever holds their own bid, so showing a
        -- number there would be misleading.
        if e.full then
            row.countText:SetText("|cff888888" .. #(e.bids or {}) .. "|r")
        elseif e.bids and #e.bids > 0 then
            row.countText:SetText("|cff888888you bid|r")
        else
            row.countText:SetText("")
        end

        row.hl:SetShown(bidLogSelected == i)
        row:Show()
    end

    for i = shown + 1, #bidLogRows do
        bidLogRows[i]:Hide()
    end
    p.listChild:SetHeight(math.max(1, shown * 16))

    ----------------------------------------------------------------
    -- Detail pane
    ----------------------------------------------------------------
    local entry = bidLogSelected and log[bidLogSelected] or nil

    if not entry then
        p.detailTitle:SetText("Select an auction above")
        for _, r in ipairs(bidLogDetail) do r:Hide() end
        p.detailChild:SetHeight(1)
        return
    end

    if entry.cancelled then
        p.detailTitle:SetText(string.format("%s  |cffff5555cancelled|r",
            BidLogStripLink(entry.item)))
    else
        p.detailTitle:SetText(string.format(
            "%s  won by |cffffff00%s|r for |cffffff00%d|r DKP  (%s, run by %s)",
            BidLogStripLink(entry.item),
            entry.winner or "nobody", entry.cost or 0,
            entry.mode or "?", entry.ml or "?"))
    end

    local bids = entry.bids or {}
    for i = 1, #bids do
        local b   = bids[i]
        local row = bidLogDetail[i]
        if not row then
            row = CreateDetailRow(i, p.detailChild)
            bidLogDetail[i] = row
        end

        row.nameText:SetText(b.name or "?")
        row.bidText:SetText((b.mode == "PASS") and "|cff888888-|r" or tostring(b.amount or 0))

        local modeColour = "|cffffffff"
        if b.mode == "OS"   then modeColour = "|cff55ccff" end
        if b.mode == "PASS" then modeColour = "|cff888888" end
        row.modeText:SetText(modeColour .. (b.mode or "") .. "|r")

        row.rollText:SetText(b.roll and tostring(b.roll) or "")
        row.srcText:SetText("|cff888888" .. (b.src or "") .. "|r")

        if entry.winner and b.name == entry.winner then
            row.resultText:SetText("|cff00ff00won the item|r")
        else
            row.resultText:SetText("")
        end

        row:Show()
    end

    for i = #bids + 1, #bidLogDetail do
        bidLogDetail[i]:Hide()
    end
    p.detailChild:SetHeight(math.max(1, #bids * 14))

    if #bids == 0 and not entry.cancelled and not entry.full then
        p.detailTitle:SetText(p.detailTitle:GetText() .. "   |cff888888(you did not bid)|r")
    end
end

StaticPopupDialogs["REDGUILD_CLEAR_BIDLOG"] = {
    text = "Clear your entire bid log?\n\nThis only clears your own copy.",
    button1 = "Clear",
    button2 = "Cancel",
    OnAccept = function()
        RedGuild_Config.bidLog = {}
        bidLogSelected = nil
        RedGuild_BidLog_Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
