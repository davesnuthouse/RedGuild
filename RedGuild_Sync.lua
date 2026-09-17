
-----------------------------
-- Smart sync payload helpers
-----------------------------

-- Fields that belong to an editor's own bookkeeping rather than to
-- the guild's DKP, and are deliberately kept out of the DKP payload:
-- everybody in the guild would otherwise carry them in every sync for
-- no reason. They travel separately, editor to editor, through
-- RedGuild_SendAttendanceSync.
local ATTENDANCE_FIELDS = {
    "raidsAttended", "lastAttendance", "benched", "lastBenched",
}

-- The DKP tab's old "Rotated" column counted the same thing the
-- attendance tab's Benched counter does, so it is gone. Records saved
-- before that still carry the key: drop it on the way out rather than
-- paying for a dead field in every sync, and clear it from this
-- client's own saved data while we are walking every record anyway.
local DEAD_FIELDS = { "rotated" }

-- [FORCE SYNC REWRITE] DKP‑only payload
function BuildSyncPayload()
    local dkp = CopyTable(RedGuild_Data)  -- IMPORTANT: copy, don’t reference

    for name, rec in pairs(dkp) do
        if type(rec) == "table" then
            for _, field in ipairs(ATTENDANCE_FIELDS) do
                rec[field] = nil
            end

            local own = RedGuild_Data[name]
            for _, field in ipairs(DEAD_FIELDS) do
                rec[field] = nil
                if type(own) == "table" then own[field] = nil end
            end
        end
    end

    return {
        sender = UnitName("player"),
        dkp = dkp,
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

-- Applies an incoming DKP table over the local one.
--
-- Two rules here exist because this function is the only thing in the
-- addon that can destroy DKP wholesale, and it runs unattended on
-- whatever arrives over the wire:
--
--  1. A missing field means "no information", never zero. The wire
--     format is a reassembled chunk stream; a record that arrives
--     short used to silently set that player's DKP to 0, which is
--     indistinguishable from an editor having zeroed them on purpose.
--     Keep what we already had instead.
--
--  2. A snapshot with no usable records is refused outright. The
--     delete pass below removes everybody the snapshot does not
--     mention, so an empty or unparsable-but-still-a-table payload
--     used to wipe the entire roster in one go, with nothing said.
function ApplyDKPSnapshot(snapshot)
    if type(snapshot) ~= "table" then return end

    local incoming = 0
    for name, src in pairs(snapshot) do
        if type(name) == "string" and type(src) == "table" then
            incoming = incoming + 1
        end
    end

    if incoming == 0 then
        Print("|cffff5555Ignored a DKP sync containing no players - "
            .. "your table has been left alone.|r")
        return
    end

    local seen = {}

    for name, src in pairs(snapshot) do
        if type(name) == "string" and type(src) == "table" then
            local d = EnsurePlayer(name)

            -- DKP fields. Falling back to the value already held, not
            -- to 0: see rule 1 above.
            d.lastWeek   = tonumber(src.lastWeek)   or tonumber(d.lastWeek)   or 0
            d.onTime     = tonumber(src.onTime)     or tonumber(d.onTime)     or 0
            d.attendance = tonumber(src.attendance) or tonumber(d.attendance) or 0
            d.bench      = tonumber(src.bench)      or tonumber(d.bench)      or 0
            d.spent      = tonumber(src.spent)      or tonumber(d.spent)      or 0
            d.balance    = tonumber(src.balance)    or tonumber(d.balance)    or 0

            -- Attendance/bench counters are deliberately NOT touched
            -- here. They are editor-only bookkeeping that never rides
            -- along with a DKP sync, so an incoming snapshot - which
            -- no longer carries them at all - must leave this client's
            -- own values exactly as they are.

            -- DKP‑table identity fields
            d.class  = src.class  or d.class
            d.msRole = src.msRole or d.msRole
            d.osRole = src.osRole or d.osRole

            RecalcBalance(d)
            seen[name] = true
        end
    end

    -- Remove players not present in the snapshot. This is intended -
    -- a sync is an authoritative full-table replace - but it is also
    -- the one place DKP records disappear without anybody asking, so
    -- say how many went rather than doing it silently.
    local removed = {}
    for name in pairs(RedGuild_Data) do
        if not seen[name] then
            table.insert(removed, name)
        end
    end

    for _, name in ipairs(removed) do
        RedGuild_Data[name] = nil
    end

    if #removed > 0 then
        table.sort(removed)
        Print(string.format(
            "|cffffff00DKP sync removed %d player(s) not in the sender's table: %s|r",
            #removed, table.concat(removed, ", ")))
    end
end

--------------------------------------------------
-- Attendance sync (editor to editor, manual)
--------------------------------------------------
-- Separate from the DKP sync on purpose. Attendance and bench
-- counters are the editors' own bookkeeping, so they are pushed by
-- hand from the Attendance tab to the other editors instead of riding
-- along in the table every guild member receives.

function BuildAttendancePayload()
    local snapshot = {}

    for name, d in pairs(RedGuild_Data) do
        if type(name) == "string" and type(d) == "table" then
            local raids = tonumber(d.raidsAttended) or 0
            local bench = tonumber(d.benched) or 0

            -- Only players with something actually recorded, so the
            -- payload stays proportional to the attendance history
            -- rather than to the size of the guild.
            if raids > 0 or bench > 0 or d.lastAttendance or d.lastBenched then
                snapshot[name] = {
                    raidsAttended  = raids,
                    lastAttendance = d.lastAttendance,
                    benched        = bench,
                    lastBenched    = d.lastBenched,
                }
            end
        end
    end

    return { sender = UnitName("player"), attendance = snapshot }
end

-- Returns how many records were taken. Players the receiver does not
-- already have a DKP record for are skipped rather than created: this
-- sync carries attendance, not roster, and inventing blank DKP rows
-- from it is exactly the sort of mess it exists to avoid.
function ApplyAttendanceSnapshot(snapshot)
    if type(snapshot) ~= "table" then return 0 end

    local applied = 0
    for name, src in pairs(snapshot) do
        if type(name) == "string" and type(src) == "table" then
            local d = RedGuild_Data[name]
            if d then
                d.raidsAttended  = tonumber(src.raidsAttended) or 0
                d.lastAttendance = src.lastAttendance
                d.benched        = tonumber(src.benched) or 0
                d.lastBenched    = src.lastBenched
                applied = applied + 1
            end
        end
    end

    return applied
end

-- Pushes this client's attendance table to every other editor who is
-- online. Returns the number of editors it went to.
function RedGuild_SendAttendanceSync()
    if not IsAuthorized() then
        Print("|cffff5555Only editors can sync attendance.|r")
        return 0
    end

    local me      = NormalizeName(UnitName("player"))
    local encoded = EncodePayload(BuildAttendancePayload())
    local sent    = 0

    for _, editorName in ipairs(EDITOR_PRIORITY) do
        if NormalizeName(editorName) ~= me
           and IsAddonUserOnlineForTooltip(editorName)
        then
            RedGuild_Send("ATTEND_DATA", encoded, editorName)
            sent = sent + 1
        end
    end

    if sent == 0 then
        Print("|cffff5555No other editor is online - attendance not sent.|r")
    else
        Print("Attendance sent to " .. sent .. " editor(s).")
    end

    return sent
end

function ApplyAttendanceSync(sender, encoded)
    sender = Ambiguate(sender or "", "short")
    if sender == "" then return end

    -- Only an editor sends this, and only an editor has any use for
    -- it; anyone else drops it on the floor.
    if not IsEditor(sender) then
        D("ATTEND_DATA from non-editor " .. sender .. " - ignored")
        return
    end
    if not IsAuthorized() then
        D("ATTEND_DATA received but this client is not an editor - ignored")
        return
    end

    local ok, payload = pcall(DecodePayload, encoded)
    if not ok or type(payload) ~= "table" then
        Print("|cffff5555Attendance sync from " .. sender .. " could not be read.|r")
        return
    end

    local applied = ApplyAttendanceSnapshot(payload.attendance)

    RedGuild_Config.lastAttendSync     = date("%Y-%m-%d %H:%M:%S")
    RedGuild_Config.lastAttendSyncFrom = sender

    Print("Attendance updated from " .. sender .. " (" .. applied .. " players).")

    if RedGuild_RefreshAttendanceTable then
        RedGuild_RefreshAttendanceTable()
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

