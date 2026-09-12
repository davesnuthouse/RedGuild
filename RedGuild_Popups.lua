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
LDB = LibStub("LibDataBroker-1.1"):NewDataObject("RedGuild", {
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

icon = LibStub("LibDBIcon-1.0")

function EnsureMinimapConfig()
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

