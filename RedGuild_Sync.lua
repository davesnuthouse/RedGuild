
-----------------------------
-- Smart sync payload helpers
-----------------------------

-- [FORCE SYNC REWRITE] DKP‑only payload
function BuildSyncPayload()
    return {
        sender = UnitName("player"),
        dkp = CopyTable(RedGuild_Data),  -- IMPORTANT: copy, don’t reference
    }
end

function EncodePayload(tbl)
    local serialized  = LibSerialize:Serialize(tbl)
    local compressed  = LibDeflate:CompressDeflate(serialized)
    return LibDeflate:EncodeForPrint(compressed)   -- TEXT SAFE
end

function DecodePayload(data)
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

function ApplyAltFieldUpdate(update)
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

function BuildAltSnapshot()
    return {
        type      = "snapshot",
        version   = tonumber(RedGuild_Config.altsVersion or 0),
        AltParent = RedGuild_AltParent or {},
        Alts      = RedGuild_Alts or {},
    }
end

function ApplyAltSnapshot(snapshot)
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

function ApplyDKPSnapshot(snapshot)
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

function ApplySyncData(sender, encoded)
    D("ApplySyncData from "..tostring(sender))
    EnsureSaved()

    sender = Ambiguate(sender or "", "short")
    if not sender or sender == "" then return end
    if sender == UnitName("player") then return end
	
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

	-- Editors must NEVER accept ordinary DATA syncs: their own table is
	-- the authority and a stray broadcast could undo their edits.
	-- The push that opens bidding is the one exception. Everyone has to
	-- be bidding against the same numbers, and an editor sitting on a
	-- stale table sees wrong balances in the auction window just like
	-- anyone else. It is still gated on the version below, so an editor
	-- who is AHEAD keeps what they have - only a genuinely newer table
	-- is taken.
	if IsEditor(UnitName("player")) and not payload.auctionSync then
		SafeSetSyncWarning("Ignored DKP sync — editors only accept FORCE_REQ.")
		return
	end

	if incoming <= localVer then
		SafeSetSyncWarning("DKP sync not required.")
		return
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

------------------------------------------------------------
-- Sync request batching
------------------------------------------------------------
-- See REDGUILD_SYNC_BATCH_* in RedGuild_Core.lua for the tuning
-- constants and the reasoning. A lone requester still just gets a
-- whisper; once enough people are asking around the same time this
-- switches to one shared guild broadcast that answers all of them
-- (and, incidentally, anyone else who happens to be behind too) in a
-- single transfer instead of one queued up after another.
RedGuild_PendingSyncRequesters = RedGuild_PendingSyncRequesters or {}
local syncBatchStart        = nil
local syncBatchLastSeen     = nil
local syncBatchTimerRunning = false

local function RedGuild_FlushSyncBatch()
    local requesters = RedGuild_PendingSyncRequesters
    RedGuild_PendingSyncRequesters = {}
    syncBatchStart    = nil
    syncBatchLastSeen = nil

    if #requesters == 0 then return end

    local payload = BuildSyncPayload()
    local encoded = EncodePayload(payload)

    if #requesters < REDGUILD_SYNC_BATCH_THRESHOLD then
        for _, name in ipairs(requesters) do
            D("SYNC REQUEST → Sending DATA to " .. name)
            RedGuild_Send("DATA", encoded, name)
        end
        return
    end

    D(string.format(
        "SYNC REQUEST → %d requesters in this window, broadcasting DATA once instead of %d separate whispers",
        #requesters, #requesters))
    RedGuild_Send("DATA", encoded, "GUILD")
end

local function RedGuild_SyncBatchTick()
    local now = GetTime()

    if #RedGuild_PendingSyncRequesters == 0 then
        syncBatchTimerRunning = false
        return
    end

    if (now - (syncBatchLastSeen or now)) >= REDGUILD_SYNC_BATCH_WINDOW
       or (now - (syncBatchStart or now)) >= REDGUILD_SYNC_BATCH_MAX_WAIT
    then
        syncBatchTimerRunning = false
        RedGuild_FlushSyncBatch()
        return
    end

    C_Timer.After(0.5, RedGuild_SyncBatchTick)
end

local function RedGuild_QueueSyncRequester(name)
    for _, existing in ipairs(RedGuild_PendingSyncRequesters) do
        if existing == name then return end
    end
    table.insert(RedGuild_PendingSyncRequesters, name)

    local now = GetTime()
    if not syncBatchStart then syncBatchStart = now end
    syncBatchLastSeen = now

    if not syncBatchTimerRunning then
        syncBatchTimerRunning = true
        C_Timer.After(REDGUILD_SYNC_BATCH_WINDOW, RedGuild_SyncBatchTick)
    end
end

function HandleSyncRequest(requester, sender, requesterVersion)
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

	if not IsActiveGuildMember(requester) then
		D("SYNC REQUEST → requester not in guild, ignoring")
    return
	end

    -- Requester already reported being at or ahead of our version -
    -- no need to send the full table again. This is the common case
    -- when several people request in quick succession right after one
    -- of them just got synced.
    requesterVersion = tonumber(requesterVersion)
    if requesterVersion and requesterVersion >= (RedGuild_Config.dkpVersion or 0) then
        D("SYNC REQUEST → " .. requester .. " already at version " .. requesterVersion .. ", skipping")
        return
    end

    RedGuild_QueueSyncRequester(requester)
end

function HandleSyncResponse(sender, msgType)
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

function AttemptAutoSync()
    D("AttemptAutoSync called")

    if GetNumGuildMembers() == 0 then
        D("Guild roster not ready — delaying auto-sync")
        C_Timer.After(1, AttemptAutoSync)
        return
    end

    EnsureSaved()
    EnsureAddonUsers()

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

    local bestEditor = GetPreferredEditor()

    if not bestEditor then
        SafeSetSyncWarning("Correct editor not online — your DKP may be outdated.")
        return
    end

    if NormalizeName(bestEditor) == NormalizeName(me) then
        SafeSetSyncWarning("Editor detected as self — sync aborted.")
        return
    end

    D("Auto-sync → asking " .. tostring(bestEditor) .. " for REQUEST")

    local meReal = Ambiguate(me, "short")

    -- Asking just the one editor whose reply is actually needed, rather
    -- than every online editor, so a raid full of people logging in at
    -- once doesn't turn into several editors each whispering back a
    -- full DKP table to the same person at the same time.
    RedGuild_Send("REQUEST", meReal .. "|" .. tostring(RedGuild_Config.dkpVersion or 0), bestEditor)
end

