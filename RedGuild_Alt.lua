function CreateAltTab()
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
	

end
