function CreateEditorsTab()
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
    local row = CreateFrame("Frame", nil, editorContent)
    row:SetSize(200, EDITOR_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * EDITOR_ROW_HEIGHT)

    -- Text label
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", 2, 0)
    fs:SetJustifyH("LEFT")
    row.text = fs

    -- Store row
    editorRows[i] = row
end

        editorContent:SetHeight(MAX_EDITOR_ROWS * EDITOR_ROW_HEIGHT)

        editorsPanel:SetScript("OnShow", function()
            C_Timer.After(0.05, RefreshEditorList)
            dkpPanel:SetScript("OnShow", UpdateTable)
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
        note:SetText("|cffaaaaaa* Celevius and Lunátic are the fixed editors.|r")
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

------------------------------------------------------------
-- AUTO-SYNC AFTER ALL ITEMS AWARDED CHECKBOX
------------------------------------------------------------
-- Controls RedGuild_Auction_PushSyncAfterClose: when you are running
-- an auction, handing out the last copy of the posted item broadcasts
-- a fresh DKP table to the guild, so everyone who just bid sees their
-- new balance without anyone having to remember to hit Force Sync.
-- Bidding merely closing does not trigger this - nothing has actually
-- changed until an award happens. Unchecking this turns it off on
-- this client when you are the one auctioneering.
local bidSyncChk = CreateFrame("CheckButton", nil, editorsPanel, "ChatConfigCheckButtonTemplate")
bidSyncChk:SetSize(18, 18)
bidSyncChk:ClearAllPoints()
bidSyncChk:SetPoint("BOTTOM", hideSyncChk, "TOP", 0, 8)

local bidSyncLabel = editorsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
bidSyncLabel:SetPoint("LEFT", bidSyncChk, "RIGHT", 4, 0)
bidSyncLabel:SetText("Auto-sync after all items awarded")

bidSyncChk:SetHitRectInsets(4, 4, 4, 4)

-- Load saved state
C_Timer.After(0.05, function()
    bidSyncChk:SetChecked(RedGuild_Config.bidSyncEnabled ~= false)
end)

-- Save state when clicked
bidSyncChk:SetScript("OnClick", function(self)
    RedGuild_Config.bidSyncEnabled = self:GetChecked() and true or false
end)


end
