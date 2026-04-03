local ADDON_NAME, RedDKP = ...

--------------------------------------------------
-- EDITORS PANEL (TAB 2)
--------------------------------------------------

local mainFrame = RedDKP.MainFrame

local editorsPanel = CreateFrame("Frame", nil, mainFrame)
editorsPanel:SetAllPoints()
editorsPanel:Hide()
RedDKP.EditorsPanel = editorsPanel

--------------------------------------------------
-- TITLE
--------------------------------------------------

local title = editorsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
title:SetPoint("TOPLEFT", 10, -10)
title:SetText("Authorized Editors")

--------------------------------------------------
-- SCROLLABLE LIST OF EDITORS
--------------------------------------------------

local scroll = CreateFrame("ScrollFrame", nil, editorsPanel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
scroll:SetSize(200, 350)

local listFrame = CreateFrame("Frame", nil, scroll)
listFrame:SetSize(200, 1)
scroll:SetScrollChild(listFrame)

editorsPanel.rows = {}
editorsPanel.selectedEditor = nil

local function RefreshEditorList()
    RedDKP.EnsureSaved()

    for _, r in ipairs(editorsPanel.rows) do
        r:Hide()
    end
    wipe(editorsPanel.rows)

    local names = {}
    for name in pairs(RedDKP_Config.authorizedEditors) do
        table.insert(names, name)
    end
    table.sort(names)

    local y = 0
    for i, name in ipairs(names) do
        local row = CreateFrame("Button", nil, listFrame)
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetSize(200, 18)

        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", 2, 0)
        fs:SetText(name)
        row.text = fs

        row:SetScript("OnClick", function()
            editorsPanel.selectedEditor = name
            for _, r in ipairs(editorsPanel.rows) do
                r.text:SetTextColor(1, 1, 1)
            end
            row.text:SetTextColor(0, 0.6, 1)
        end)

        table.insert(editorsPanel.rows, row)
        y = y + 18
    end

    listFrame:SetHeight(y)
end

editorsPanel.RefreshEditorList = RefreshEditorList

--------------------------------------------------
-- ADD EDITOR CONTROLS
--------------------------------------------------

local addBox = CreateFrame("EditBox", nil, editorsPanel, "InputBoxTemplate")
addBox:SetSize(150, 25)
addBox:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 20, 0)
addBox:SetAutoFocus(false)

local addBtn = CreateFrame("Button", nil, editorsPanel, "UIPanelButtonTemplate")
addBtn:SetSize(80, 25)
addBtn:SetPoint("LEFT", addBox, "RIGHT", 10, 0)
addBtn:SetText("Add")

addBtn:SetScript("OnClick", function()
    if not RedDKP.IsGuildOfficer() then
        RedDKP.Print("Only officers can modify editors.")
        return
    end

    local name = addBox:GetText():gsub("%s+", "")
    if name == "" then return end

    RedDKP.EnsureSaved()
    RedDKP_Config.authorizedEditors[name] = true
    addBox:SetText("")
    RefreshEditorList()
end)

--------------------------------------------------
-- REMOVE EDITOR BUTTON
--------------------------------------------------

local removeBtn = CreateFrame("Button", nil, editorsPanel, "UIPanelButtonTemplate")
removeBtn:SetSize(80, 25)
removeBtn:SetPoint("TOPLEFT", addBox, "BOTTOMLEFT", 0, -10)
removeBtn:SetText("Remove")

removeBtn:SetScript("OnClick", function()
    if not RedDKP.IsGuildOfficer() then
        RedDKP.Print("Only officers can modify editors.")
        return
    end

    local name = editorsPanel.selectedEditor
    if not name then return end

    RedDKP_Config.authorizedEditors[name] = nil
    editorsPanel.selectedEditor = nil
    RefreshEditorList()
end)

--------------------------------------------------
-- PERMISSION‑BASED VISIBILITY
--------------------------------------------------

editorsPanel:SetScript("OnShow", function()
    RefreshEditorList()

    if not RedDKP.IsGuildOfficer() then
        addBox:Hide()
        addBtn:Hide()
        removeBtn:Hide()
    else
        addBox:Show()
        addBtn:Show()
        removeBtn:Show()
    end
end)