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

		-- Patch Blizzard's GuildUtil.lua bug: GuildNewsButton_SetText
		-- indexes a nil formatString for certain guild news entries and
		-- throws "attempt to index local 'formatString' (a nil value)",
		-- spamming a Lua warning every time the Guild News list scrolls
		-- or refreshes. hooksecurefunc can't prevent this - it only
		-- runs AFTER the original, which has already errored by then -
		-- so replace the function outright and swallow the error
		-- instead of letting it propagate.
		if type(GuildNewsButton_SetText) == "function" then
			local original_GuildNewsButton_SetText = GuildNewsButton_SetText
			GuildNewsButton_SetText = function(...)
				pcall(original_GuildNewsButton_SetText, ...)
			end
		end
		
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
    -- removed to try improve lag on load
	--C_GuildInfo.GuildRoster()

    EnsureSaved()
    RedGuild_UpdateEditorTabVisibility()

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

    -- Periodic sync status refresh (every 10 seconds)
	C_Timer.NewTicker(10, function()
		if mainFrame and mainFrame:IsShown() then
			UpdateSyncStatus()
		end	
	end)

	-- Discard abandoned inbound chunk buffers (every 15 seconds)
	C_Timer.NewTicker(15, RedGuild_SweepInboundChunks)
	C_Timer.NewTicker(2,  RedGuild_RepairInboundChunks)

    return
end

    ---------------------------------------------------------
    -- 3. GUILD_ROSTER_UPDATE / PLAYER_GUILD_UPDATE
    ---------------------------------------------------------
    if event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        CheckGuildRestriction()

        if not firstRosterReady then
            if IsInGuild() and GetNumGuildMembers() > 0 then
                local anyName = select(1, GetGuildRosterInfo(1))
                if anyName then
                    firstRosterReady = true
                    RedGuild_UpdateEditorTabVisibility()
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
    -- CHUNKED MESSAGES (DATA / FORCE_REQ / ALTS_DATA)
    ---------------------------------------------------------
    local pfx2, chunkType, seqStr, partStr, totalStr, chunk =
        msg:match("^([^:]+):([^:]+):(%d+):(%d+):(%d+):(.*)$")

    if pfx2 == REDGUILD_CHAT_PREFIX
       and (chunkType == "DATA" or chunkType == "FORCE_REQ" or chunkType == "ALTS_DATA")
    then
        local seq   = tonumber(seqStr)
        local part  = tonumber(partStr)
        local total = tonumber(totalStr)
        if not seq or not part or not total then return end

        D(string.format("ADDON IN %s seq=%d part=%d/%d from=%s len=%d",
            chunkType, seq, part, total, sender, #chunk))

        local bucket = REDGUILD_Inbound[chunkType]

        -- One bucket per SENDER and sequence, not per sequence alone.
        -- RedGuild_OutboundSeq restarts at 0 on every login, so two
        -- editors pushing during the same raid both start at seq 1 and
        -- used to interleave their chunks into a single bucket. The
        -- bucket then hit its part count, was concatenated out of two
        -- different payloads, and failed to decode - silently.
        local bucketKey = tostring(sender) .. "\001" .. tostring(seq)

        -- Already assembled and applied: nothing to do with stragglers.
        local doneAt = REDGUILD_InboundDone[bucketKey]
        if doneAt and (GetTime() - doneAt) < REDGUILD_DONE_TTL then
            D("CHUNK IGNORED - " .. chunkType .. " seq " .. seq ..
              " from " .. tostring(sender) .. " already complete")
            return
        end

        local entry = bucket[bucketKey]

        -- No bucket yet, or the sender restarted a push under the same
        -- seq with a different size: start clean rather than mixing.
        if not entry or entry.total ~= total then
            entry = { parts = {}, total = total, from = sender, seq = seq }
            bucket[bucketKey] = entry
        end

        entry.t = GetTime()   -- last activity, used by the sweep
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

            -- Built in index order rather than by concatenating the
            -- table: repaired parts arrive out of order, and the order
            -- of the payload is the payload.
            local ordered = {}
            for i = 1, entry.total do
                ordered[i] = entry.parts[i]
            end
            local full = table.concat(ordered, "")

            bucket[bucketKey] = nil

            local now = GetTime()
            REDGUILD_InboundDone[bucketKey] = now
            for k, t in pairs(REDGUILD_InboundDone) do
                if (now - t) > REDGUILD_DONE_TTL then
                    REDGUILD_InboundDone[k] = nil
                end
            end

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
			-- ALT SNAPSHOT
			-------------------------------------------------
			if chunkType == "ALTS_DATA" then
				local ok, snapshot = pcall(DecodePayload, full)
				if ok and type(snapshot) == "table" then
					local incoming = tonumber(snapshot.version or 0)
					local localVer = tonumber(RedGuild_Config.altsVersion or 0)

					RedGuild_Config.altsVersionByUser = RedGuild_Config.altsVersionByUser or {}
					RedGuild_Config.altsVersionByUser[NormalizeName(entry.from or sender)] = incoming

					if incoming > localVer then
						ApplyAltSnapshot(snapshot)
						RefreshMainsList()
						UpdateTopBar()
					end
				end

				RedGuild_Config.lastAltSync     = date("%Y-%m-%d %H:%M:%S")
				RedGuild_Config.lastAltSyncFrom = sender
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
    -- ALT SYNC: SMALL MESSAGES (ALTS_REQ / ALTS_UPDATE)
    -- ALTS_DATA is handled above with DATA/FORCE_REQ - it's
    -- the alt-tracker snapshot, chunked the same way for the same
    -- reason (it can exceed one addon message).
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
    -- SIMPLE MESSAGES (REQUEST / VERSION / FORCE_* etc.)
    ---------------------------------------------------------
    local _, simpleType, simplePayload = msg:match("^([^:]+):([^:]+):?(.*)$")
    if not simpleType then return end

    -- BIDDING: BID_START / BID_PLACE / BID_PAUSE / BID_RESUME / BID_STOP /
    -- BID_REOPEN / BID_CANCEL / BID_AWARD
    if simpleType:sub(1, 4) == "BID_" then
        RedGuild_Auction_OnAddonMessage(simpleType, simplePayload, sender)
        return
    end

    -- RESEND: payload = "<seq>|<part>,<part>,..." - someone is missing
    -- parts of a payload this client sent. Re-send just those parts,
    -- whispered, instead of making the whole guild eat the table again.
    if simpleType == "RESEND" then
        local seqStr, partList = simplePayload:match("^(%d+)|(.*)$")
        local seq   = tonumber(seqStr or "")
        local entry = seq and RedGuild_OutboundCache[seq]

        if not entry then
            D("RESEND from " .. tostring(sender) ..
              " - seq " .. tostring(seqStr) .. " no longer cached")
            return
        end

        local sent = 0
        for p in tostring(partList):gmatch("%d+") do
            local idx = tonumber(p)
            -- Capped so a malformed or hostile request cannot turn one
            -- message into an unbounded flood of whispers.
            if idx and entry.chunks[idx] and sent < 40 then
                sent = sent + 1
                RedGuild_QueueChunk(
                    RedGuild_BuildChunkMsg(entry.msgType, seq, idx,
                        entry.total, entry.chunks[idx]),
                    "WHISPER", GetExactName(sender))
            end
        end

        D(string.format("RESEND → %d part(s) of seq %d back to %s",
            sent, seq, tostring(sender)))
        return
    end

    -- REQUEST: payload = "requesterName|requesterDkpVersion" (version is
    -- optional for backward compatibility with older clients)
    if simpleType == "REQUEST" then
        local reqName, reqVersion = simplePayload:match("^(.-)|(%d+)$")
        reqName = reqName or (simplePayload ~= "" and simplePayload or sender)
        HandleSyncRequest(reqName, sender, reqVersion)
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
        -- Whispered back to whoever actually asked: broadcasting this
        -- to the guild meant every addon user online replied to every
        -- other addon user's login-time VERSIONREQ, an O(n^2) burst of
        -- unpaced addon messages in a big raid.
        RedGuild_Send("VERSIONREP", REDGUILD_VERSION, sender)
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


