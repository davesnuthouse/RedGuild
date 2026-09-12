-- RedGuild.lua
if ... ~= "RedGuild" then return end

RedGuild_Data   	= RedGuild_Data   or {}
RedGuild_BackupData = RedGuild_BackupData or {}
RedGuild_Alts   	= RedGuild_Alts   or {}
RedGuild_AltParent 	= RedGuild_AltParent or {}
RedGuild_ML 		= RedGuild_ML 	  or {}
RedGuild_Config 	= RedGuild_Config or {}
RedGuild_Audit  	= RedGuild_Audit  or {}
RedGuild_Usage  	= RedGuild_Usage  or {}

addonName      = ...
REDGUILD_VERSION = "3.0.69"

REDGUILD_CHAT_PREFIX = "REDGUILD"

RedGuild_Config.smartSync      		= (RedGuild_Config.smartSync ~= false)
RedGuild_Config.bidSyncEnabled 		= (RedGuild_Config.bidSyncEnabled ~= false)
RedGuild_Config.addonUsers     		= RedGuild_Config.addonUsers     or {}
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


RedGuild_Config.altsVersion = RedGuild_Config.altsVersion or 0

RedGuild_UIReady = false


TAB_DKP     = 1
TAB_ALT     = 2
TAB_GROUP   = 3
TAB_ML      = 4
TAB_BIDLOG  = 5
TAB_RAID    = 6
TAB_EDITORS = 7
TAB_AUDIT   = 8

activeTab = TAB_DKP
dkpLocked = true

SORT_COLOR   = "|cff3399ff"
NORMAL_COLOR = "|cffffffff"

AllDKPNames = AllDKPNames or {}
dkpShowGroupOnly = false

local protectedInitialized = false

suppressWarnings = false

local showHiddenRecords = false

LibSerialize = LibStub("LibSerialize")
LibDeflate   = LibStub("LibDeflate")

-- Ensure inbound chunk buffers exist
REDGUILD_Inbound = REDGUILD_Inbound or {
    DATA      = {},
    FORCE_REQ = {},
	ALTS_DATA  = {},
}

-- Payloads that already assembled, keyed the same way as the buckets.
-- A re-sent part can outrun its own repair request and arrive after the
-- payload was completed; without this it would open a brand new bucket
-- holding one chunk, which later times out and cries "incomplete sync"
-- about data the client already has.
REDGUILD_InboundDone = REDGUILD_InboundDone or {}
REDGUILD_DONE_TTL    = 120


--------------------------------------------------
-- DEBUGGING
--------------------------------------------------

RedGuild_Debug = false

function D(msg)
    if RedGuild_Debug then
        print("|cff00ff00[RedGuild DEBUG]|r " .. msg)
    end
end

function CountKeys(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end

function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RedGuild]|r " .. tostring(msg))
end

function NormalizeName(name)
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

-- Shared by ColourForSyncAge and GetSyncAgeState: parses a
-- "YYYY-MM-DD HH:MM:SS" timestamp and classifies its age into the
-- same red/orange/green tiers both use. `reason` is "missing" (nil or
-- "Never"), "invalid" (present but unparseable), or "ok" - only
-- ColourForSyncAge needs that distinction, to show "Never" vs
-- "Invalid" text; the color is red either way.
local function ClassifySyncAge(timestamp)
    if not timestamp or timestamp == "Never" then
        return "red", "missing"
    end

    local year, month, day, hour, min, sec =
        timestamp:match("(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)")

    if not year then
        return "red", "invalid"
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
        return "green", "ok"
    elseif ageDays < 7 then
        return "orange", "ok"
    else
        return "red", "ok"
    end
end

local SYNC_AGE_COLOR = {
    green  = "|cff00ff00",
    orange = "|cffffa500",
    red    = "|cffff0000",
}

function ColourForSyncAge(timestamp)
    local state, reason = ClassifySyncAge(timestamp)

    if reason == "missing" then
        return "|cffff0000Never|r"
    elseif reason == "invalid" then
        return "|cffff0000Invalid|r"
    end

    return SYNC_AGE_COLOR[state] .. timestamp .. "|r"
end

function GetExactName(name)
    -- Ambiguate("none") returns the full, exact name Blizzard expects
    local exact = Ambiguate(name, "none")
    return exact
end

function GenerateAuditID()
    return tostring(time()) .. "-" .. math.random(100000, 999999)
end

function ColorizeBalance(d)
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

function CompareVersions(localVer, remoteVer)
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

function ParseAuditTime(t)
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

function GetHighestAltVersionUser()
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
    return (ClassifySyncAge(timestamp))
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
    local dkpState = GetSyncAgeState(RedGuild_Config.lastDKPSync)
    local altState = GetSyncAgeState(RedGuild_Config.lastAltSync)

    ----------------------------------------------------------------
    -- EDITOR-SPECIFIC LOGIC (modify dkpState before the priority system)
    ----------------------------------------------------------------
    if IsEditor(me) then
        -- DKP Sync only red if behind the preferred (authoritative) editor
        local bestEditor, bestVersion = GetPreferredEditor()
        local myVersion = tonumber(RedGuild_Config.dkpVersion or 0)

        if myVersion < bestVersion then
            dkpState = "red"
        else
            dkpState = "green"
        end
    end

    ----------------------------------------------------------------
    -- PRIORITY SYSTEM
    ----------------------------------------------------------------

    if dkpState == "red" or altState == "red" then
        statusBox:SetColorTexture(1, 0, 0)
        return
    end

    if dkpState == "orange" or altState == "orange" then
        statusBox:SetColorTexture(1, 0.65, 0)
        return
    end

    statusBox:SetColorTexture(0, 1, 0)
end


-- Addon messages top out around 255 bytes. The worst case line is
-- "REDGUILD:FORCE_REQ:######:###:###:" (prefix + longest msgType +
-- a 6-digit seq + 3-digit part/total, all colon separated) at 34
-- bytes, so 220 bytes of chunk data leaves a safe margin without
-- risking truncation. Bigger than the old 200 means fewer chunks -
-- and fewer addon messages - for every sync.
REDGUILD_MAX_CHUNK = 220
RedGuild_OutboundSeq = 0
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

RedGuild_PendingForceSync = {
    editor = nil,
    snapshot = nil,
}

function RedGuild_ShowForceSyncSummary()
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

--------------------------------------------------
-- Outbound chunk pacing and re-send cache
--------------------------------------------------
-- A DKP table is dozens of addon messages. Firing them in a tight
-- loop is what makes parts go missing: the server side addon message
-- throttle silently drops whatever overflows the burst allowance, and
-- the receiver is left holding half a payload. So every chunk now
-- goes through one paced queue, shared by all senders in this client
-- (manual sync, editor list, auction push), and each send is kept for
-- a while so a receiver can ask for the parts it never got.
REDGUILD_CHUNK_DELAY     = 0.15   -- seconds between outbound chunks
REDGUILD_OUT_CACHE_MAX   = 10     -- payloads kept for re-sending
REDGUILD_OUT_CACHE_TTL   = 300    -- seconds a cached payload lives
REDGUILD_CHUNK_RETRY_MAX = 6      -- throttled attempts before a chunk is given up on

-- Sync request batching: every chunked send an editor makes shares
-- the one paced queue above, so several people requesting a sync
-- within moments of each other (a raid all logging in at once) used
-- to queue up as separate full-table whispers, one after another -
-- the last person in line could be waiting the better part of a
-- minute. HandleSyncRequest now holds a request open for a short
-- window to see if others are about to ask too; if enough do, it
-- answers everyone with a single guild-wide broadcast instead of one
-- transfer per person.
REDGUILD_SYNC_BATCH_WINDOW    = 2   -- seconds of quiet before answering
REDGUILD_SYNC_BATCH_MAX_WAIT  = 6   -- longest the first asker is made to wait
REDGUILD_SYNC_BATCH_THRESHOLD = 3   -- requesters needed to switch to a broadcast

RedGuild_OutboundCache = RedGuild_OutboundCache or {}
RedGuild_OutboundQueue = RedGuild_OutboundQueue or {}
RedGuild_OutboundBusy  = false

-- The client silently used to be trusted to have sent whatever was
-- handed to it. It does not: C_ChatInfo.SendAddonMessage reports back
-- whether the send actually went out or was throttled, on any client
-- that exposes Enum.SendAddonMessageResult. Older clients without
-- that enum fall back to the old blind-trust behavior - there is
-- nothing to check on those.
function RedGuild_SendRaw(msg, channel, target)
    local result = C_ChatInfo.SendAddonMessage(REDGUILD_CHAT_PREFIX, msg, channel, target)
    if type(result) == "number" and Enum and Enum.SendAddonMessageResult then
        return result == Enum.SendAddonMessageResult.Success
    end
    return true
end

-- Peeks rather than pops: a throttled chunk stays at the front of the
-- queue and is retried, with a growing backoff, instead of being
-- blindly treated as delivered and left for the receiver to notice
-- missing minutes later. A chunk that keeps failing gives up after
-- REDGUILD_CHUNK_RETRY_MAX tries rather than stalling the whole queue
-- behind it forever - anything actually lost is still caught by the
-- existing chunk repair/resend path on the receiving end.
local function RedGuild_OutboundPump()
    local item = RedGuild_OutboundQueue[1]
    if not item then
        RedGuild_OutboundBusy = false
        return
    end

    local sent = RedGuild_SendRaw(item.msg, item.channel, item.target)

    if sent then
        table.remove(RedGuild_OutboundQueue, 1)
        C_Timer.After(REDGUILD_CHUNK_DELAY, RedGuild_OutboundPump)
        return
    end

    item.retries = (item.retries or 0) + 1
    if item.retries > REDGUILD_CHUNK_RETRY_MAX then
        D("OUTBOUND DROP - throttled " .. item.retries .. " times in a row, giving up on one chunk")
        table.remove(RedGuild_OutboundQueue, 1)
        C_Timer.After(REDGUILD_CHUNK_DELAY, RedGuild_OutboundPump)
        return
    end

    C_Timer.After(REDGUILD_CHUNK_DELAY * (1 + item.retries * 0.5), RedGuild_OutboundPump)
end

function RedGuild_QueueChunk(msg, channel, target)
    table.insert(RedGuild_OutboundQueue,
        { msg = msg, channel = channel, target = target })

    if RedGuild_OutboundBusy then return end
    RedGuild_OutboundBusy = true
    C_Timer.After(0, RedGuild_OutboundPump)
end

-- Runs fn once everything queued so far has actually gone out, so a
-- small announcement can be made to arrive *after* a big paced payload
-- instead of overtaking it. Falls through immediately when there is
-- nothing in flight, and gives up after timeout so a stuck queue can
-- never wedge the caller.
function RedGuild_AfterOutbound(timeout, fn)
    local deadline = GetTime() + (tonumber(timeout) or 10)

    local function check()
        if (#RedGuild_OutboundQueue == 0 and not RedGuild_OutboundBusy)
           or GetTime() >= deadline
        then
            fn()
            return
        end
        C_Timer.After(0.1, check)
    end

    check()
end

function RedGuild_BuildChunkMsg(msgType, seq, part, total, chunk)
    return string.format("%s:%s:%d:%d:%d:%s",
        REDGUILD_CHAT_PREFIX, msgType, seq, part, total, chunk)
end

-- Remembers the pieces of one push so missing parts can be re-sent
-- without rebuilding (and re-broadcasting) the whole table.
function RedGuild_CacheOutbound(seq, msgType, chunks)
    RedGuild_OutboundCache[seq] = {
        msgType = msgType,
        chunks  = chunks,
        total   = #chunks,
        t       = GetTime(),
    }

    local now, keys = GetTime(), {}
    for k, v in pairs(RedGuild_OutboundCache) do
        if (now - (v.t or 0)) > REDGUILD_OUT_CACHE_TTL then
            RedGuild_OutboundCache[k] = nil
        else
            table.insert(keys, k)
        end
    end

    -- Sequence numbers only ever grow, so the lowest keys are oldest.
    table.sort(keys)
    for i = 1, #keys - REDGUILD_OUT_CACHE_MAX do
        RedGuild_OutboundCache[keys[i]] = nil
    end
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
        or msgType == "RESEND"
    then
        if not target then return nil, nil end
        return "WHISPER", GetExactName(target)
    end

    -- DATA is the per-requester sync response (HandleSyncRequest): one
    -- person asked, so only they need the table. Broadcasting it to the
    -- whole guild instead - as this used to - means every online editor
    -- answers every request to everyone, and a raid full of people
    -- logging in at once turns into a pile of simultaneous guild-wide
    -- chunk floods that blow through the outbound cache and the addon
    -- message throttle, which is exactly what was showing up as nonstop
    -- RESEND spam and "no longer cached" in a 25-person raid.
    if msgType == "DATA" then
        -- "GUILD" is the explicit broadcast sentinel HandleSyncRequest's
        -- batching uses when enough people asked at once that one
        -- shared broadcast is cheaper than answering each individually.
        if target == "GUILD" then return "GUILD", nil end
        if not target or target == "" then return nil, nil end
        return "WHISPER", GetExactName(target)
    end

    -- FORCE_REQ is a deliberate one-to-many broadcast (the editor's
    -- manual "Force Sync" action), so it stays guild-wide.
    if msgType == "FORCE_REQ" then
        return "GUILD", nil
    end

    -- REQUEST is small (never chunked) so a guild-wide send would be
    -- cheap on its own, but the manual "Request SYNC" button and
    -- AttemptAutoSync already pick one specific bestEditor to ask -
    -- broadcasting anyway meant every online editor, not just the
    -- intended one, whispered back a full DKP table (via the DATA fix
    -- above), multiplying traffic by the number of online editors for
    -- no reason. Whisper whenever a target was actually given; fall
    -- through to the guild-wide default below for the rare case where
    -- one wasn't (e.g. no bestEditor could be determined yet).
    if msgType == "REQUEST" and target and target ~= "" then
        return "WHISPER", GetExactName(target)
    end

    -- VERSIONREP is the per-requester reply to one login's VERSIONREQ;
    -- it has no reason to go to anyone but whoever asked.
    if msgType == "VERSIONREP" and target and target ~= "" then
        return "WHISPER", GetExactName(target)
    end

    -- ALTS_DATA is the alt-tracker snapshot sent to one requester
    -- (only the single highest-version alt holder ever replies, so
    -- this isn't a fan-out risk like DATA was, but there
    -- is still no reason for the whole guild to receive one person's
    -- answer to another person's request).
    if msgType == "ALTS_DATA" and target and target ~= "" then
        return "WHISPER", GetExactName(target)
    end

    -- Everything else → guild
    return "GUILD", nil
end

REDGUILD_SMALL_RETRY_MAX   = 3     -- throttled attempts before a small message is dropped
REDGUILD_SMALL_RETRY_DELAY = 0.2   -- seconds before the first retry, growing each attempt

-- Small (unchunked) messages skip the paced outbound queue - a bid or
-- a pause/resume needs to land immediately, not queue up behind
-- whatever big chunked transfer happens to be running - but they
-- still deserve to know if the client actually managed to send them.
-- On a throttle, retry a few times with a short, growing backoff
-- instead of just assuming it went out.
local function RedGuild_SendSmall(msg, channel, target, attempt)
    attempt = attempt or 1
    if RedGuild_SendRaw(msg, channel, target) then return end

    if attempt >= REDGUILD_SMALL_RETRY_MAX then
        D("SMALL SEND DROP - throttled " .. attempt .. " times: " .. msg)
        return
    end

    C_Timer.After(REDGUILD_SMALL_RETRY_DELAY * attempt, function()
        RedGuild_SendSmall(msg, channel, target, attempt + 1)
    end)
end

function RedGuild_Send(msgType, payload, target)
    if not msgType then return end
	
-- DKP sync opt-out should NOT block Alt Tracker sync
if RedGuild_Config.hideMeFromSync then
    -- RESEND only asks for parts of a payload this client was already
    -- sent, so opting out of broadcasting must not leave it stuck with
    -- a half-received table.
    if msgType ~= "ALTS_REQ" and
       msgType ~= "ALTS_DATA" and
       msgType ~= "RESEND" and
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

	-- Small messages (everything except the chunked types below).
	-- ALTS_DATA is the alt-tracker snapshot: same as DATA, it can
	-- exceed one addon message once a guild has enough tracked alts,
	-- so it needs the same chunk/repair path. ALTS_REQ and
	-- ALTS_UPDATE stay small - a name and a single field edit never
	-- get close to the size limit.
	local isChunked =
		msgType == "DATA" or
		msgType == "FORCE_REQ" or
		msgType == "ALTS_DATA"

	if not isChunked then
		local msg = string.format("%s:%s:%s", REDGUILD_CHAT_PREFIX, msgType, payload)
		RedGuild_SendSmall(msg, channel, actualTarget)
		return
	end

    -- Chunked messages (DATA, FORCE_REQ, ALTS_DATA)
    RedGuild_OutboundSeq = RedGuild_OutboundSeq + 1
    local seq = RedGuild_OutboundSeq

    local total = math.ceil(#payload / REDGUILD_MAX_CHUNK)
    if total == 0 then total = 1 end

    local chunks = {}
    for i = 1, total do
        local startIdx = (i - 1) * REDGUILD_MAX_CHUNK + 1
        chunks[i] = payload:sub(startIdx, startIdx + REDGUILD_MAX_CHUNK - 1)
    end

    RedGuild_CacheOutbound(seq, msgType, chunks)

    for i = 1, total do
        RedGuild_QueueChunk(
            RedGuild_BuildChunkMsg(msgType, seq, i, total, chunks[i]),
            channel, actualTarget)
    end
end

function RedGuild_CreateDKPBackup()
    RedGuild_BackupData.data      = CopyTable(RedGuild_Data)
    RedGuild_BackupData.dkpVersion   = tonumber(RedGuild_Config.dkpVersion or 0)
    RedGuild_BackupData.timestamp = date("%Y-%m-%d %H:%M:%S")
    RedGuild_BackupData.from      = RedGuild_PendingForceSync and RedGuild_PendingForceSync.editor or "unknown"

    D("DKP backup created (version " .. tostring(RedGuild_BackupData.dkpVersion) .. ")")
end

--------------------------------------------------
-- Basic Helpers
--------------------------------------------------

-- No-op: used to seed the old fixed editor list, which editor status
-- no longer depends on (it's derived live from guild rank). Kept as a
-- harmless call target rather than touching its many call sites.
function EnsureSaved()
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

function EnsureML(name)
    if not RedGuild_ML[name] then
        RedGuild_ML[name] = {
            mlMainMS = 0,   -- Main (MS)
            mlMainOS = 0,   -- Main (OS)
            mlNotes  = "",
        }
    end

    return RedGuild_ML[name]
end

function BumpDKPVersion()
    RedGuild_Config.dkpVersion = (RedGuild_Config.dkpVersion or 0) + 1
end

function PopulateGuildClasses()
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

function RLTools_HasSelections()
    for _, row in ipairs(RLRows) do
        if row:IsShown() and row.checkbox:GetChecked() then
            return true
        end
    end
    return false
end

function CountOnlineAddonUsers()
    local count = 0
    for name in pairs(RedGuild_Config.addonUsers) do
        if IsPlayerOnline(name) then
            count = count + 1
        end
    end
    return count
end

function GetMissingDKPGroupMembers()
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

function CheckGuildRestriction()
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

function IsGuildOfficer()
	-- Note to myself... I changed this to only look for guild leader because it has the editors to fall back on
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex == 0
end

function RecalcBalance(d)
    d.balance = (d.lastWeek or 0)
              + (d.onTime or 0)
              + (d.bench or 0)
              - (d.spent or 0)

    -- Hard cap at 300
    if d.balance > 300 then
        d.balance = 300
    end
end

function RuntimeInvalid(name)
    if IsInGuild() and GetNumGuildMembers() > 0 then
        return not IsNameInGuild(name)
    end
    return false
end

function RecalculateAllBalances()
    for _, d in pairs(RedGuild_Data) do
        RecalcBalance(d)
    end
end

function EnsureAddonUsers()
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

function IsActiveGuildMember(name)
    local ok = IsNameInGuild(name)
    return ok == true
end	

function SafeSetSyncWarning(text)
    if syncWarning then
        syncWarning:SetText(text or "")
    end
end

--------------------------------------------------
-- Inbound chunk buffer maintenance
--------------------------------------------------
-- A chunked sync (DATA / FORCE_REQ / ALTS_DATA) is only
-- applied once every part has arrived. If a part is lost - a
-- loading screen mid raid, a server side addon message drop - the
-- half filled bucket used to sit here untouched forever, so the
-- client stayed silently out of date until someone ran a full
-- force sync. Buckets now carry a timestamp and are swept, and the
-- user is told instead of being left to guess.
REDGUILD_CHUNK_TIMEOUT = 60   -- seconds before a bucket is given up on

-- Before giving up, ask the sender for the parts that never arrived.
-- A dropped chunk is nearly always a throttle casualty, so the payload
-- is still sitting in the sender's cache and a targeted whisper gets it
-- back in a second or two - no full table re-broadcast, no user action.
REDGUILD_CHUNK_REPAIR_IDLE = 4    -- seconds of silence before asking
REDGUILD_CHUNK_REPAIR_MAX  = 3    -- how many times to ask
REDGUILD_AUTOREQ_COOLDOWN  = 300  -- seconds between automatic full syncs

RedGuild_LastAutoRequest = 0

function RedGuild_RepairInboundChunks()
    local now = GetTime()

    for chunkType, bucket in pairs(REDGUILD_Inbound or {}) do
        for _, entry in pairs(bucket) do
            if type(entry) == "table" and entry.total and entry.from and entry.seq then
                local idle       = now - (entry.t or now)
                local sinceAsked = now - (entry.lastRepair or 0)

                if idle >= REDGUILD_CHUNK_REPAIR_IDLE
                   and sinceAsked >= REDGUILD_CHUNK_REPAIR_IDLE
                   and (entry.repairs or 0) < REDGUILD_CHUNK_REPAIR_MAX
                then
                    local missing = {}
                    for i = 1, entry.total do
                        -- One request has to fit in one addon message,
                        -- so ask for a batch and let the next pass take
                        -- the rest if a payload lost a lot of parts.
                        if not entry.parts[i] and #missing < 40 then
                            table.insert(missing, i)
                        end
                    end

                    if #missing > 0 then
                        entry.repairs    = (entry.repairs or 0) + 1
                        entry.lastRepair = now

                        D(string.format(
                            "CHUNK REPAIR %s seq=%d - asking %s for %d missing part(s), try %d",
                            tostring(chunkType), entry.seq, tostring(entry.from),
                            #missing, entry.repairs))

                        RedGuild_Send("RESEND", string.format(
                            "%d|%s", entry.seq, table.concat(missing, ",")),
                            entry.from)
                    end
                end
            end
        end
    end
end

-- Last resort once the repair whispers went unanswered: ask for a
-- fresh sync instead of leaving the player to notice a chat line and
-- press a button. Jittered and rate limited, because a raid-wide
-- hiccup would otherwise have everyone request at the same instant.
--
-- Always asks the SAME editor whose transfer just failed, never a
-- different one: that editor is who actually has this client's gap,
-- and asking someone else instead (as this used to, via whichever
-- editor looked "best" by version/rank) just starts a second,
-- unrelated transfer from a second editor while the first is still
-- the one this client is actually behind on.
function RedGuild_AutoRequestSync(target)
    if not target or target == "" then return false end

    local now = GetTime()
    if (now - (RedGuild_LastAutoRequest or 0)) < REDGUILD_AUTOREQ_COOLDOWN then
        return false
    end
    if not IsInGuild() or GetNumGuildMembers() == 0 then return false end
    if RedGuild_SyncLocked then return false end

    RedGuild_LastAutoRequest = now

    C_Timer.After(2 + math.random() * 8, function()
        local me = Ambiguate(UnitName("player"), "short")
        if me and me ~= "" then
            D("AUTO SYNC REQUEST after failed chunk repair, asking " .. tostring(target))
            RedGuild_Send("REQUEST", me .. "|" .. tostring(RedGuild_Config.dkpVersion or 0), target)
        end
    end)

    return true
end

function RedGuild_SweepInboundChunks()
    local now = GetTime()
    local dropped, lastFrom, dataFrom = 0, nil, nil

    for chunkType, bucket in pairs(REDGUILD_Inbound or {}) do
        for bucketKey, entry in pairs(bucket) do
            if type(entry) == "table" then
                -- buckets created before this fix have no timestamp
                if not entry.t then entry.t = now end

                if (now - entry.t) > REDGUILD_CHUNK_TIMEOUT then
                    local total = tonumber(entry.total) or 0
                    local have  = 0
                    for i = 1, total do
                        if entry.parts and entry.parts[i] then
                            have = have + 1
                        end
                    end

                    D(string.format(
                        "CHUNK TIMEOUT %s from %s - %d/%d parts after %d repair attempt(s), discarded",
                        tostring(chunkType), tostring(entry.from), have, total,
                        entry.repairs or 0))

                    bucket[bucketKey] = nil
                    dropped  = dropped + 1
                    lastFrom = entry.from or lastFrom
                    -- The auto-resync below only re-requests the DKP
                    -- DATA sync, so it needs specifically the sender of
                    -- the dropped DATA transfer, not just whichever
                    -- bucket (DATA/FORCE_REQ/ALTS_DATA) happened
                    -- to be discarded last.
                    if chunkType == "DATA" then
                        dataFrom = entry.from or dataFrom
                    end
                end
            end
        end
    end

    if dropped > 0 then
        -- Only reaches here after the repair whispers were ignored or
        -- the sender went offline, so retrying by hand is pointless
        -- until something changes - fetch a fresh copy instead, from
        -- the same editor whose transfer this actually was.
        local requested = dataFrom and RedGuild_AutoRequestSync(dataFrom)

        if requested then
            SafeSetSyncWarning(string.format(
                "Incomplete sync from %s - requesting a fresh sync.",
                tostring(lastFrom)))
            if RedGuild_Debug then
                Print(string.format(
                    "|cffff8800Incomplete sync|r from %s - %d transfer%s could not be "
                    .. "repaired. Requesting a fresh sync automatically; no action needed.",
                    tostring(lastFrom), dropped, dropped == 1 and "" or "s"))
            end
        else
            SafeSetSyncWarning(string.format(
                "Incomplete sync from %s - press Request SYNC.",
                tostring(lastFrom)))
            if RedGuild_Debug then
                Print(string.format(
                    "|cffff8800Incomplete sync|r from %s - %d transfer%s lost parts and "
                    .. "were discarded. Your DKP table may be out of date; press "
                    .. "Request SYNC on the DKP tab.",
                    tostring(lastFrom), dropped, dropped == 1 and "" or "s"))
            end
        end
    end
end


function IsAuthorized()
    return IsEditor(UnitName("player"))
end

-- Fixed editors. Celevius is authoritative for sync whenever online;
-- Lunátic is only the backup, used when Celevius is not - see
-- GetPreferredEditor below.
EDITOR_PRIORITY = { "Celevius", "Lunátic" }

function IsEditor(name)
    if not name then
        name = UnitName("player")
    end

    local key = NormalizeName(name)
    if not key then return false end

    for _, editorName in ipairs(EDITOR_PRIORITY) do
        if NormalizeName(editorName) == key then
            return true
        end
    end

    return false
end

function LogAudit(player, field, old, new)
    if not RedGuild_Enabled then
        return
    end

    if not IsEditor(UnitName("player")) then
        return
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

function IsNameInGuild(name)
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

function IsRaidLeaderOrMasterLooter()

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

function NameExists(newName, oldName)
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


function GetNewestVersion()
    local addonVersions = RedGuild_Config.AddonVersions or {}
    local newest = nil

    for name, ver in pairs(addonVersions) do
        if not newest or CompareVersions(newest, ver) then
            newest = ver
        end
    end

    return newest
end

function CountOutdatedUsers()
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

function CountAddonMains()
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


function BroadcastNext(names, index)
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


-- Who to sync from: Celevius whenever he's online, Lunátic only when
-- Celevius is not. Also returns that editor's last-known DKP version
-- (from EditorVersions), same shape the old highest-version lookup
-- returned, so callers that check a version still work.
function GetPreferredEditor()
    for _, editorName in ipairs(EDITOR_PRIORITY) do
        if IsAddonUserOnlineForTooltip(editorName) then
            local key = NormalizeName(editorName)
            local ver = RedGuild_Config.EditorVersions and RedGuild_Config.EditorVersions[key]
            return editorName, tonumber(ver) or 0
        end
    end

    return nil, 0
end

local function RedGuild_ChatFilter(self, event, msg, sender, ...)
    if type(msg) == "string" and msg:find("^" .. REDGUILD_CHAT_PREFIX .. ":") then
        return true -- suppress from all visible chat frames
    end
    return false
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", RedGuild_ChatFilter)
ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", RedGuild_ChatFilter)

