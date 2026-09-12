function CreateGroupTab()
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

end
