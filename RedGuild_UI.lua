function CreateUI()
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
    mainFrame.title:SetText("Redemption Guild UI - brought to you by two clueless idiots called Lunátic and Celery Guy")

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
local bestEditor, bestVersion = GetPreferredEditor()
	if bestEditor then
		GameTooltip:AddLine("|cffffffffSyncing from: |r" .. bestEditor .. " (v" .. bestVersion .. ")")
	else
		GameTooltip:AddLine("|cffffffffSyncing from: |r no editor online")
	end
GameTooltip:AddLine("|cffffffffYour version: |r" .. (RedGuild_Config.dkpVersion or "?"))
GameTooltip:AddLine(" ")

-- Alt sync
GameTooltip:AddLine("|cffffff00Alt Tracker Sync|r")
GameTooltip:AddLine("|cffffffffLast: |r" .. ColourForSyncAge(RedGuild_Config.lastAltSync or "Never"))
GameTooltip:AddLine("|cffffffffFrom: |r" .. (RedGuild_Config.lastAltSyncFrom or "?"))
GameTooltip:AddLine("|cffffffffVersion: |r" .. (RedGuild_Config.altsVersion or "?"))

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
	
    -- Always created, not just for players who already pass IsEditor()
    -- here: that status can still resolve after this point (protected
    -- editor grant, or an editor-list sync still in flight), and these
    -- tabs are never rebuilt afterward. RedGuild_UpdateEditorTabVisibility
    -- decides which of them actually show, now and whenever editor
    -- status changes.
    CreateTab(TAB_BIDLOG, "Bid Log")
    CreateTab(TAB_RAID, "RL Tools")
    CreateTab(TAB_EDITORS, "Editors")
    CreateTab(TAB_AUDIT,   "Audit Log")
    RedGuild_UpdateEditorTabVisibility()   -- also calls RealignTabs()
    --------------------------------------------------------------------
    -- PANELS
    --------------------------------------------------------------------
    dkpPanel     = CreateFrame("Frame", nil, mainFrame); LayoutPanel(dkpPanel)
	
    CreateDKPLockButton()
    altPanel = CreateFrame("Frame", nil, mainFrame); LayoutPanel(altPanel)
	groupPanel   = CreateFrame("Frame", nil, mainFrame); LayoutPanel(groupPanel)
	mlPanel      = CreateFrame("Frame", nil, mainFrame); LayoutPanel(mlPanel)
    raidPanel    = CreateFrame("Frame", nil, mainFrame); LayoutPanel(raidPanel)
    editorsPanel = CreateFrame("Frame", nil, mainFrame); LayoutPanel(editorsPanel)
    auditPanel   = CreateFrame("Frame", nil, mainFrame); LayoutPanel(auditPanel)
    bidLogPanel  = CreateFrame("Frame", nil, mainFrame); LayoutPanel(bidLogPanel)
	
    CreateAltTab()
    CreateGroupTab()
    CreateMLTab()
    CreateRaidTab()
    CreateEditorsTab()
    CreateAuditTab()
    CreateDKPTab()
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
