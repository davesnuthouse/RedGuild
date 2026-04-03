local ADDON_NAME, RedDKP = ...

--------------------------------------------------
-- IMPORT / EXPORT PANEL (TAB 3)
--------------------------------------------------

local mainFrame = RedDKP.MainFrame

local importPanel = CreateFrame("Frame", nil, mainFrame)
importPanel:SetAllPoints()
importPanel:Hide()
RedDKP.ImportPanel = importPanel

--------------------------------------------------
-- TITLE
--------------------------------------------------

local title = importPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
title:SetPoint("TOPLEFT", 10, -10)
title:SetText("Import / Export")

--------------------------------------------------
-- EXPORT BOX
--------------------------------------------------

local exportScroll = CreateFrame("ScrollFrame", nil, importPanel, "UIPanelScrollFrameTemplate")
exportScroll:SetPoint("TOPLEFT", 10, -50)
exportScroll:SetSize(400, 400)

local exportEdit = CreateFrame("EditBox", nil, exportScroll)
exportEdit:SetMultiLine(true)
exportEdit:SetFontObject(ChatFontNormal)
exportEdit:SetWidth(380)
exportEdit:SetAutoFocus(false)
exportScroll:SetScrollChild(exportEdit)

local exportBtn = CreateFrame("Button", nil, importPanel, "UIPanelButtonTemplate")
exportBtn:SetSize(120, 25)
exportBtn:SetPoint("TOPLEFT", exportScroll, "BOTTOMLEFT", 0, -10)
exportBtn:SetText("Export Data")

exportBtn:SetScript("OnClick", function()
    RedDKP.EnsureSaved()

    local payload = {
        dkp   = RedDKP_Data,
        audit = RedDKP_Audit,
    }

    local text = RedDKP.Serialize(payload)
    if not text then
        RedDKP.Print("Export failed: serialization error.")
        return
    end

    exportEdit:SetText(text)
    RedDKP.Print("Exported DKP + audit log.")
end)

--------------------------------------------------
-- IMPORT BOX
--------------------------------------------------

local importScroll = CreateFrame("ScrollFrame", nil, importPanel, "UIPanelScrollFrameTemplate")
importScroll:SetPoint("TOPLEFT", exportScroll, "TOPRIGHT", 20, 0)
importScroll:SetSize(400, 400)

local importEdit = CreateFrame("EditBox", nil, importScroll)
importEdit:SetMultiLine(true)
importEdit:SetFontObject(ChatFontNormal)
importEdit:SetWidth(380)
importEdit:SetAutoFocus(false)
importScroll:SetScrollChild(importEdit)

local importBtn = CreateFrame("Button", nil, importPanel, "UIPanelButtonTemplate")
importBtn:SetSize(120, 25)
importBtn:SetPoint("TOPLEFT", importScroll, "BOTTOMLEFT", 0, -10)
importBtn:SetText("Import Data")

importBtn:SetScript("OnClick", function()
    if not RedDKP.IsAuthorized() then
        RedDKP.Print("Only editors can import data.")
        return
    end

    local text = importEdit:GetText()
    if text == "" then
        RedDKP.Print("Nothing to import.")
        return
    end

    local data = RedDKP.Deserialize(text)
    if not data then
        RedDKP.Print("Import failed: invalid data.")
        return
    end

    --------------------------------------------------
    -- Merge DKP
    --------------------------------------------------
    for name, row in pairs(data.dkp or {}) do
        RedDKP_Data[name] = row
    end

    --------------------------------------------------
    -- Merge audit log (sync-safe)
    --------------------------------------------------
    for _, entry in ipairs(data.audit or {}) do
        -- Use the sync-safe receive function
        if RedDKP.ReceiveAuditEntry then
            RedDKP.ReceiveAuditEntry(entry)
        else
            -- fallback: insert directly
            RedDKP.AddAuditEntry(entry)
        end
    end

    RedDKP.UpdateTable()
    RedDKP.Print("Import complete.")
end)

--------------------------------------------------
-- PANEL SHOW HANDLER
--------------------------------------------------

importPanel:SetScript("OnShow", function()
    -- Nothing special needed here, but this hook is useful
end)