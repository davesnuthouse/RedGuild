--------------------------------------------------
-- RedDKP - Core / Bootstrap / Audit / Undo
--------------------------------------------------

local ADDON_NAME = ...
local RedDKP = {}
_G.RedDKP = RedDKP

--------------------------------------------------
-- Saved variables
--------------------------------------------------

RedDKP_Data   = RedDKP_Data   or {}   -- per-player DKP rows
RedDKP_Config = RedDKP_Config or {}   -- settings, editors, etc.
RedDKP_Audit  = RedDKP_Audit  or {}   -- audit log entries

RedDKP_Config.authorizedEditors = RedDKP_Config.authorizedEditors or {}

--------------------------------------------------
-- Basic utilities
--------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff5555RedDKP:|r " .. tostring(msg))
end

local function Now()
    return date("%Y-%m-%d %H:%M:%S")
end

local function NewAuditId()
    return string.format("%08x", math.random(0, 0xFFFFFFFF))
end

--------------------------------------------------
-- Permissions
--------------------------------------------------

local function IsGuildOfficer()
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex == 0 or rankIndex == 1
end

local function IsAuthorized()
    if IsGuildOfficer() then
        return true
    end
    local name = UnitName("player")
    return RedDKP_Config.authorizedEditors[name] == true
end

--------------------------------------------------
-- Data helpers
--------------------------------------------------

local function EnsureSaved()
    RedDKP_Data   = RedDKP_Data   or {}
    RedDKP_Config = RedDKP_Config or {}
    RedDKP_Audit  = RedDKP_Audit  or {}
    RedDKP_Config.authorizedEditors = RedDKP_Config.authorizedEditors or {}
end

local function EnsurePlayer(name)
    EnsureSaved()
    RedDKP_Data[name] = RedDKP_Data[name] or {
        rotated    = false,
        lastWeek   = 0,
        onTime     = 0,
        attendance = 0,
        bench      = 0,
        spent      = 0,
        balance    = 0,
    }
    return RedDKP_Data[name]
end

--------------------------------------------------
-- Forward declaration (will be replaced later)
--------------------------------------------------

function UpdateTable()
    -- real implementation is defined later in the UI section
end

--------------------------------------------------
-- Audit core
--------------------------------------------------

local function AddAuditEntry(entry)
    EnsureSaved()
    entry.id     = entry.id     or NewAuditId()
    entry.time   = entry.time   or Now()
    entry.editor = entry.editor or UnitName("player")
    entry.source = entry.source or entry.editor

    table.insert(RedDKP_Audit, 1, entry)

    -- sync hook (implemented later)
    if RedDKP_SendAuditEntry then
        RedDKP_SendAuditEntry(entry)
    end
end

--------------------------------------------------
-- Audit logging helpers
--------------------------------------------------

local function LogFieldChange(player, field, oldValue, newValue)
    AddAuditEntry({
        action = "field",
        player = player,
        field  = field,
        old    = oldValue,
        new    = newValue,
    })
end

local function LogDeleteRow(player, data)
    AddAuditEntry({
        action = "delete",
        player = player,
        row = {
            rotated    = data.rotated,
            lastWeek   = data.lastWeek,
            onTime     = data.onTime,
            attendance = data.attendance,
            bench      = data.bench,
            spent      = data.spent,
            balance    = data.balance,
        },
    })
end

local function LogUndo(targetEntry, info)
    AddAuditEntry({
        action   = "undo",
        targetId = targetEntry.id,
        info     = info or "",
    })
end

--------------------------------------------------
-- Apply / revert helpers
--------------------------------------------------

local function ApplyFieldChange(entry, reverse)
    local p = entry.player
    local f = entry.field
    if not p or not f then return end
    local d = RedDKP_Data[p]
    if not d then return end

    local from = reverse and entry.new or entry.old
    local to   = reverse and entry.old or entry.new

    -- we don't strictly require matching "from", but you could enforce it
    d[f] = to
end

local function ApplyDelete(entry, reverse)
    local p = entry.player
    if not p then return end

    if reverse then
        -- undo delete: restore row
        local r = entry.row or {}
        RedDKP_Data[p] = {
            rotated    = r.rotated,
            lastWeek   = r.lastWeek   or 0,
            onTime     = r.onTime     or 0,
            attendance = r.attendance or 0,
            bench      = r.bench      or 0,
            spent      = r.spent      or 0,
            balance    = r.balance    or 0,
        }
    else
        -- apply delete
        RedDKP_Data[p] = nil
    end
end

--------------------------------------------------
-- Undo engine
--------------------------------------------------

local function UndoAuditEntry(entry)
    if not IsAuthorized() then
        Print("Only editors can undo audit actions.")
        return
    end

    if not entry or not entry.action then
        Print("Invalid audit entry.")
        return
    end

    if entry.action == "field" then
        ApplyFieldChange(entry, true)
    elseif entry.action == "delete" then
        ApplyDelete(entry, true)
    else
        Print("This audit entry type cannot be undone yet.")
        return
    end

    UpdateTable()

    local info = string.format("Undo of %s on %s", entry.action, entry.player or "?")
    LogUndo(entry, info)

    Print("Undid audit action " .. (entry.id or "?"))
end

RedDKP.UndoAuditEntry = UndoAuditEntry

--------------------------------------------------
-- Sync hooks (to be wired later)
--------------------------------------------------

function RedDKP_SendAuditEntry(entry)
    -- placeholder: will be wired to SendAddonMessage later
    -- e.g. serialize 'entry' and SendAddonMessage("REDDKP_AUDIT", payload, "GUILD")
end

function RedDKP_ReceiveAuditEntry(entry)
    EnsureSaved()
    if not entry or not entry.id then return end

    -- avoid duplicates
    for _, e in ipairs(RedDKP_Audit) do
        if e.id == entry.id then
            return
        end
    end

    -- mark source (your comm handler should set this too)
    entry.source = entry.source or "remote"

    -- insert into audit log (this will also re‑broadcast if we’re not careful,
    -- so you may want a flag later to suppress re‑send on receive)
    local oldSend = RedDKP_SendAuditEntry
    RedDKP_SendAuditEntry = nil
    AddAuditEntry(entry)
    RedDKP_SendAuditEntry = oldSend

    -- apply the action
    if entry.action == "field" then
        ApplyFieldChange(entry, false)
    elseif entry.action == "delete" then
        ApplyDelete(entry, false)
    elseif entry.action == "undo" then
        -- find target and apply reverse
        for _, e in ipairs(RedDKP_Audit) do
            if e.id == entry.targetId then
                UndoAuditEntry(e)
                break
            end
        end
    end

    UpdateTable()
end

--------------------------------------------------
-- End of Part 1
--------------------------------------------------

--------------------------------------------------
-- Part 2 — DKP Mutation Helpers
--------------------------------------------------

-- These helpers ensure ALL DKP changes are logged
-- and therefore undoable + syncable.

--------------------------------------------------
-- Set a DKP field (with audit logging)
--------------------------------------------------

function RedDKP.SetDKPField(player, field, newValue)
    EnsureSaved()
    local d = EnsurePlayer(player)
    local oldValue = d[field]

    if oldValue == newValue then
        return -- no change
    end

    d[field] = newValue

    -- audit entry
    AddAuditEntry({
        action = "field",
        player = player,
        field  = field,
        old    = oldValue,
        new    = newValue,
    })

    UpdateTable()
end

--------------------------------------------------
-- Add to a DKP field (e.g. +5 attendance)
--------------------------------------------------

function RedDKP.AddDKP(player, field, amount)
    EnsureSaved()
    local d = EnsurePlayer(player)
    local oldValue = d[field]
    local newValue = oldValue + amount

    d[field] = newValue

    AddAuditEntry({
        action = "field",
        player = player,
        field  = field,
        old    = oldValue,
        new    = newValue,
    })

    UpdateTable()
end

--------------------------------------------------
-- Delete a DKP row (with audit logging)
--------------------------------------------------

function RedDKP.DeletePlayerRow(player)
    EnsureSaved()

    local d = RedDKP_Data[player]
    if not d then
        Print("No DKP row exists for " .. player)
        return
    end

    -- log full row before deletion
    AddAuditEntry({
        action = "delete",
        player = player,
        row = {
            rotated    = d.rotated,
            lastWeek   = d.lastWeek,
            onTime     = d.onTime,
            attendance = d.attendance,
            bench      = d.bench,
            spent      = d.spent,
            balance    = d.balance,
        },
    })

    -- delete the row
    RedDKP_Data[player] = nil

    UpdateTable()
    Print("Deleted DKP record for " .. player)
end

--------------------------------------------------
-- Delete confirmation popup
--------------------------------------------------

StaticPopupDialogs["REDDKP_DELETE_PLAYER"] = {
    text = "Delete DKP record for %s?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, player)
        if not IsAuthorized() then
            Print("Only editors can delete DKP rows.")
            return
        end
        RedDKP.DeletePlayerRow(player)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

--------------------------------------------------
-- Helper for UI to request deletion
--------------------------------------------------

function RedDKP.RequestDeletePlayer(player)
    StaticPopup_Show("REDDKP_DELETE_PLAYER", player, nil, player)
end

--------------------------------------------------
-- End of Part 2
--------------------------------------------------

--------------------------------------------------
-- Part 3 — DKP Table UI
--------------------------------------------------

local mainFrame
local dkpPanel
local dkpRows = {}
local selectedPlayer = nil

--------------------------------------------------
-- Create main addon frame (tabs added later)
--------------------------------------------------

mainFrame = CreateFrame("Frame", "RedDKP_MainFrame", UIParent, "BasicFrameTemplateWithInset")
mainFrame:SetSize(900, 600)
mainFrame:SetPoint("CENTER")
mainFrame:Hide()

mainFrame.title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
mainFrame.title:SetPoint("TOP", 0, -10)
mainFrame.title:SetText("RedDKP")

--------------------------------------------------
-- DKP Panel (Tab 1)
--------------------------------------------------

dkpPanel = CreateFrame("Frame", nil, mainFrame)
dkpPanel:SetAllPoints()
dkpPanel:Hide()

--------------------------------------------------
-- ScrollFrame for DKP table
--------------------------------------------------

local scroll = CreateFrame("ScrollFrame", nil, dkpPanel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 10, -40)
scroll:SetPoint("BOTTOMRIGHT", -30, 50)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(1, 1)
scroll:SetScrollChild(content)

--------------------------------------------------
-- Column headers
--------------------------------------------------

local headers = {
    { name = "Player",     width = 140 },
    { name = "Rot",        width = 40  },
    { name = "LW",         width = 40  },
    { name = "OT",         width = 40  },
    { name = "AT",         width = 40  },
    { name = "Bench",      width = 50  },
    { name = "Spent",      width = 60  },
    { name = "Balance",    width = 60  },
}

local x = 10
for _, h in ipairs(headers) do
    local fs = dkpPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", x, -15)
    fs:SetText(h.name)
    x = x + h.width + 10
end

--------------------------------------------------
-- Row creation
--------------------------------------------------

local function CreateDKPRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(800, 20)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * 22)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(0, 0, 0, 0.2)
    row.bg:Hide()

    local cols = {}
    local x = 0

    for i, h in ipairs(headers) do
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", x, 0)
        fs:SetWidth(h.width)
        fs:SetJustifyH("LEFT")
        cols[i] = fs
        x = x + h.width + 10
    end

    row.cols = cols

    row:SetScript("OnClick", function(self)
        selectedPlayer = self.player
        for _, r in ipairs(dkpRows) do
            r.bg:Hide()
        end
        self.bg:Show()
    end)

    return row
end

--------------------------------------------------
-- UpdateTable() — refresh DKP table
--------------------------------------------------

function UpdateTable()
    EnsureSaved()

    for _, r in ipairs(dkpRows) do
        r:Hide()
    end
    wipe(dkpRows)

    local names = {}
    for name in pairs(RedDKP_Data) do
        table.insert(names, name)
    end
    table.sort(names)

    local y = 0
    for i, name in ipairs(names) do
        local d = RedDKP_Data[name]
        local row = CreateDKPRow(content, i)
        row.player = name

        row.cols[1]:SetText(name)
        row.cols[2]:SetText(d.rotated and "Y" or "N")
        row.cols[3]:SetText(d.lastWeek)
        row.cols[4]:SetText(d.onTime)
        row.cols[5]:SetText(d.attendance)
        row.cols[6]:SetText(d.bench)
        row.cols[7]:SetText(d.spent)
        row.cols[8]:SetText(d.balance)

        row:Show()
        dkpRows[i] = row
        y = y + 22
    end

    content:SetHeight(y)
end

--------------------------------------------------
-- Edit box for modifying fields
--------------------------------------------------

local editBox = CreateFrame("EditBox", nil, dkpPanel, "InputBoxTemplate")
editBox:SetSize(120, 25)
editBox:SetPoint("BOTTOMLEFT", 10, 10)
editBox:SetAutoFocus(false)
editBox:Hide()

local fieldDropdown = CreateFrame("Frame", "RedDKP_FieldDropdown", dkpPanel, "UIDropDownMenuTemplate")
fieldDropdown:SetPoint("LEFT", editBox, "RIGHT", 10, 0)

local fields = {
    { text = "lastWeek",   value = "lastWeek" },
    { text = "onTime",     value = "onTime" },
    { text = "attendance", value = "attendance" },
    { text = "bench",      value = "bench" },
    { text = "spent",      value = "spent" },
    { text = "balance",    value = "balance" },
}

local selectedField = "lastWeek"

UIDropDownMenu_Initialize(fieldDropdown, function(self, level)
    for _, f in ipairs(fields) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = f.text
        info.value = f.value
        info.func = function()
            selectedField = f.value
            UIDropDownMenu_SetText(fieldDropdown, f.text)
        end
        UIDropDownMenu_AddButton(info)
    end
end)

UIDropDownMenu_SetText(fieldDropdown, "lastWeek")

--------------------------------------------------
-- Apply edit button
--------------------------------------------------

local applyBtn = CreateFrame("Button", nil, dkpPanel, "UIPanelButtonTemplate")
applyBtn:SetSize(80, 25)
applyBtn:SetPoint("LEFT", fieldDropdown, "RIGHT", 10, 0)
applyBtn:SetText("Apply")

applyBtn:SetScript("OnClick", function()
    if not selectedPlayer then
        Print("No player selected.")
        return
    end
    if not IsAuthorized() then
        Print("Only editors can modify DKP.")
        return
    end

    local val = tonumber(editBox:GetText())
    if not val then
        Print("Enter a number.")
        return
    end

    RedDKP.SetDKPField(selectedPlayer, selectedField, val)
    editBox:SetText("")
end)

--------------------------------------------------
-- Delete button
--------------------------------------------------

local deleteBtn = CreateFrame("Button", nil, dkpPanel, "UIPanelButtonTemplate")
deleteBtn:SetSize(80, 25)
deleteBtn:SetPoint("LEFT", applyBtn, "RIGHT", 10, 0)
deleteBtn:SetText("Delete")

deleteBtn:SetScript("OnClick", function()
    if not selectedPlayer then
        Print("No player selected.")
        return
    end
    RedDKP.RequestDeletePlayer(selectedPlayer)
end)

--------------------------------------------------
-- End of Part 3
--------------------------------------------------

--------------------------------------------------
-- Part 4 — Tabs, Editors Tab, Import/Export Tab
--------------------------------------------------

--------------------------------------------------
-- Tab Buttons
--------------------------------------------------

local tabs = {}
local function CreateTab(id, text)
    local tab = CreateFrame("Button", nil, mainFrame, "OptionsFrameTabButtonTemplate")
    tab:SetID(id)
    tab:SetText(text)
    tab:SetScript("OnClick", function(self)
        PanelTemplates_SetTab(mainFrame, self:GetID())
        dkpPanel:Hide()
        editorsPanel:Hide()
        importPanel:Hide()

        if self:GetID() == 1 then dkpPanel:Show()
        elseif self:GetID() == 2 then editorsPanel:Show()
        elseif self:GetID() == 3 then importPanel:Show()
        end
    end)
    return tab
end

tabs[1] = CreateTab(1, "DKP")
tabs[2] = CreateTab(2, "Editors")
tabs[3] = CreateTab(3, "Import/Export")

tabs[1]:SetPoint("TOPLEFT", mainFrame, "BOTTOMLEFT", 10, 7)
tabs[2]:SetPoint("LEFT", tabs[1], "RIGHT", 10, 0)
tabs[3]:SetPoint("LEFT", tabs[2], "RIGHT", 10, 0)

PanelTemplates_SetNumTabs(mainFrame, 3)
PanelTemplates_SetTab(mainFrame, 1)

--------------------------------------------------
-- Editors Panel (Tab 2)
--------------------------------------------------

editorsPanel = CreateFrame("Frame", nil, mainFrame)
editorsPanel:SetAllPoints()
editorsPanel:Hide()

local title = editorsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
title:SetPoint("TOPLEFT", 10, -10)
title:SetText("Authorized Editors")

--------------------------------------------------
-- Scrollable list of editors
--------------------------------------------------

local editorScroll = CreateFrame("ScrollFrame", nil, editorsPanel, "UIPanelScrollFrameTemplate")
editorScroll:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
editorScroll:SetSize(200, 350)

local editorListFrame = CreateFrame("Frame", nil, editorScroll)
editorListFrame:SetSize(200, 1)
editorScroll:SetScrollChild(editorListFrame)

editorsPanel.editorRows = {}
editorsPanel.selectedEditor = nil

local function RefreshEditorList()
    EnsureSaved()

    for _, row in ipairs(editorsPanel.editorRows) do
        row:Hide()
    end
    wipe(editorsPanel.editorRows)

    local names = {}
    for name in pairs(RedDKP_Config.authorizedEditors) do
        table.insert(names, name)
    end
    table.sort(names)

    local y = 0
    for i, name in ipairs(names) do
        local row = CreateFrame("Button", nil, editorListFrame)
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetSize(200, 18)

        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", 2, 0)
        fs:SetText(name)
        row.text = fs

        row:SetScript("OnClick", function()
            editorsPanel.selectedEditor = name
            for _, r in ipairs(editorsPanel.editorRows) do
                r.text:SetTextColor(1, 1, 1)
            end
            row.text:SetTextColor(0, 0.6, 1)
        end)

        table.insert(editorsPanel.editorRows, row)
        y = y + 18
    end

    editorListFrame:SetHeight(y)
end

editorsPanel.RefreshEditorList = RefreshEditorList

--------------------------------------------------
-- Add editor controls
--------------------------------------------------

local addBox = CreateFrame("EditBox", nil, editorsPanel, "InputBoxTemplate")
addBox:SetSize(150, 25)
addBox:SetPoint("TOPLEFT", editorScroll, "TOPRIGHT", 20, 0)
addBox:SetAutoFocus(false)

local addBtn = CreateFrame("Button", nil, editorsPanel, "UIPanelButtonTemplate")
addBtn:SetSize(80, 25)
addBtn:SetPoint("LEFT", addBox, "RIGHT", 10, 0)
addBtn:SetText("Add")

addBtn:SetScript("OnClick", function()
    if not IsGuildOfficer() then
        Print("Only officers can modify editors.")
        return
    end

    local name = addBox:GetText():gsub("%s+", "")
    if name == "" then return end

    EnsureSaved()
    RedDKP_Config.authorizedEditors[name] = true
    addBox:SetText("")
    RefreshEditorList()
end)

--------------------------------------------------
-- Remove editor button
--------------------------------------------------

local removeBtn = CreateFrame("Button", nil, editorsPanel, "UIPanelButtonTemplate")
removeBtn:SetSize(80, 25)
removeBtn:SetPoint("TOPLEFT", addBox, "BOTTOMLEFT", 0, -10)
removeBtn:SetText("Remove")

removeBtn:SetScript("OnClick", function()
    if not IsGuildOfficer() then
        Print("Only officers can modify editors.")
        return
    end

    local name = editorsPanel.selectedEditor
    if not name then return end

    EnsureSaved()
    RedDKP_Config.authorizedEditors[name] = nil
    editorsPanel.selectedEditor = nil
    RefreshEditorList()
end)

--------------------------------------------------
-- Show/hide controls based on permissions
--------------------------------------------------

editorsPanel:SetScript("OnShow", function()
    RefreshEditorList()

    if not IsGuildOfficer() then
        addBox:Hide()
        addBtn:Hide()
        removeBtn:Hide()
    else
        addBox:Show()
        addBtn:Show()
        removeBtn:Show()
    end
end)

--------------------------------------------------
-- Import/Export Panel (Tab 3)
--------------------------------------------------

importPanel = CreateFrame("Frame", nil, mainFrame)
importPanel:SetAllPoints()
importPanel:Hide()

local ieTitle = importPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
ieTitle:SetPoint("TOPLEFT", 10, -10)
ieTitle:SetText("Import / Export")

--------------------------------------------------
-- Export box
--------------------------------------------------

local exportBox = CreateFrame("ScrollFrame", nil, importPanel, "UIPanelScrollFrameTemplate")
exportBox:SetPoint("TOPLEFT", 10, -50)
exportBox:SetSize(400, 400)

local exportEdit = CreateFrame("EditBox", nil, exportBox)
exportEdit:SetMultiLine(true)
exportEdit:SetFontObject(ChatFontNormal)
exportEdit:SetWidth(380)
exportEdit:SetAutoFocus(false)
exportBox:SetScrollChild(exportEdit)

local exportBtn = CreateFrame("Button", nil, importPanel, "UIPanelButtonTemplate")
exportBtn:SetSize(120, 25)
exportBtn:SetPoint("TOPLEFT", exportBox, "BOTTOMLEFT", 0, -10)
exportBtn:SetText("Export Data")

exportBtn:SetScript("OnClick", function()
    EnsureSaved()

    local payload = {
        dkp   = RedDKP_Data,
        audit = RedDKP_Audit,
    }

    exportEdit:SetText(SerializeTable(payload))
    Print("Exported DKP + audit log.")
end)

--------------------------------------------------
-- Import box
--------------------------------------------------

local importBox = CreateFrame("ScrollFrame", nil, importPanel, "UIPanelScrollFrameTemplate")
importBox:SetPoint("TOPLEFT", exportBox, "TOPRIGHT", 20, 0)
importBox:SetSize(400, 400)

local importEdit = CreateFrame("EditBox", nil, importBox)
importEdit:SetMultiLine(true)
importEdit:SetFontObject(ChatFontNormal)
importEdit:SetWidth(380)
importEdit:SetAutoFocus(false)
importBox:SetScrollChild(importEdit)

local importBtn = CreateFrame("Button", nil, importPanel, "UIPanelButtonTemplate")
importBtn:SetSize(120, 25)
importBtn:SetPoint("TOPLEFT", importBox, "BOTTOMLEFT", 0, -10)
importBtn:SetText("Import Data")

importBtn:SetScript("OnClick", function()
    if not IsAuthorized() then
        Print("Only editors can import data.")
        return
    end

    local text = importEdit:GetText()
    if text == "" then return end

    local ok, data = DeserializeTable(text)
    if not ok then
        Print("Import failed: invalid data.")
        return
    end

    -- Merge DKP
    for name, row in pairs(data.dkp or {}) do
        RedDKP_Data[name] = row
    end

    -- Merge audit log
    for _, entry in ipairs(data.audit or {}) do
        RedDKP_ReceiveAuditEntry(entry)
    end

    UpdateTable()
    Print("Import complete.")
end)

--------------------------------------------------
-- End of Part 4
--------------------------------------------------

--------------------------------------------------
-- Part 5 — Audit Log Tab (with Undo hyperlink)
--------------------------------------------------

auditPanel = CreateFrame("Frame", nil, mainFrame)
auditPanel:SetAllPoints()
auditPanel:Hide()

local auditTitle = auditPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
auditTitle:SetPoint("TOPLEFT", 10, -10)
auditTitle:SetText("Audit Log")

--------------------------------------------------
-- ScrollFrame for audit log
--------------------------------------------------

local auditScroll = CreateFrame("ScrollFrame", nil, auditPanel, "UIPanelScrollFrameTemplate")
auditScroll:SetPoint("TOPLEFT", 10, -50)
auditScroll:SetPoint("BOTTOMRIGHT", -30, 10)

local auditContent = CreateFrame("Frame", nil, auditScroll)
auditContent:SetSize(1, 1)
auditScroll:SetScrollChild(auditContent)

auditPanel.rows = {}

--------------------------------------------------
-- Create a single audit row
--------------------------------------------------

local function CreateAuditRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(820, 20)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * 22)

    -- Main text
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row.text:SetJustifyH("LEFT")

    -- Undo hyperlink
    row.undo = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.undo:SetPoint("RIGHT", -4, 0)
    row.undo:SetTextColor(1, 0.2, 0.2)
    row.undo:SetText("Undo")
    row.undo:Hide()

    -- Clicking the row triggers undo
    row:SetScript("OnClick", function(self)
        if self.entry and self.entry.action ~= "undo" then
            RedDKP.UndoAuditEntry(self.entry)
        end
    end)

    return row
end

--------------------------------------------------
-- Format audit entry into readable text
--------------------------------------------------

local function FormatAuditEntry(entry)
    if entry.action == "field" then
        return string.format(
            "[%s] %s changed %s.%s from %s to %s",
            entry.time or "?",
            entry.editor or "?",
            entry.player or "?",
            entry.field or "?",
            tostring(entry.old),
            tostring(entry.new)
        )

    elseif entry.action == "delete" then
        local r = entry.row or {}
        return string.format(
            "[%s] %s deleted %s (rot=%s LW=%d OT=%d AT=%d Bench=%d Spent=%d Bal=%d)",
            entry.time or "?",
            entry.editor or "?",
            entry.player or "?",
            tostring(r.rotated),
            r.lastWeek or 0,
            r.onTime or 0,
            r.attendance or 0,
            r.bench or 0,
            r.spent or 0,
            r.balance or 0
        )

    elseif entry.action == "undo" then
        return string.format(
            "[%s] %s undid action %s (%s)",
            entry.time or "?",
            entry.editor or "?",
            entry.targetId or "?",
            entry.info or ""
        )

    else
        return string.format("[%s] Unknown audit entry", entry.time or "?")
    end
end

--------------------------------------------------
-- Refresh audit log UI
--------------------------------------------------

function auditPanel.Refresh()
    EnsureSaved()

    for _, r in ipairs(auditPanel.rows) do
        r:Hide()
    end
    wipe(auditPanel.rows)

    local y = 0
    for i, entry in ipairs(RedDKP_Audit) do
        local row = CreateAuditRow(auditContent, i)
        row.entry = entry

        row.text:SetText(FormatAuditEntry(entry))

        -- Show undo link only for undo‑able entries
        if entry.action == "field" or entry.action == "delete" then
            row.undo:Show()
        else
            row.undo:Hide()
        end

        row:Show()
        auditPanel.rows[i] = row
        y = y + 22
    end

    auditContent:SetHeight(y)
end

auditPanel:SetScript("OnShow", auditPanel.Refresh)

--------------------------------------------------
-- Add Audit Log as Tab 4
--------------------------------------------------

tabs[4] = CreateFrame("Button", nil, mainFrame, "OptionsFrameTabButtonTemplate")
tabs[4]:SetID(4)
tabs[4]:SetText("Audit Log")
tabs[4]:SetPoint("LEFT", tabs[3], "RIGHT", 10, 0)

PanelTemplates_SetNumTabs(mainFrame, 4)

tabs[4]:SetScript("OnClick", function(self)
    PanelTemplates_SetTab(mainFrame, 4)
    dkpPanel:Hide()
    editorsPanel:Hide()
    importPanel:Hide()
    auditPanel:Show()
end)

--------------------------------------------------
-- End of Part 5
--------------------------------------------------

--------------------------------------------------
-- PART 6 - SYNC SYSTEM (Send/Receive, Serialization, Logging)
--------------------------------------------------

-- Requires AceSerializer-3.0
local AceSerializer = LibStub("AceSerializer-3.0")

--------------------------------------------------
-- Serialization helpers
--------------------------------------------------

local function Serialize(tbl)
    local ok, result = pcall(function()
        return AceSerializer:Serialize(tbl)
    end)
    if ok then return result end
    return nil
end

local function Deserialize(str)
    local ok, success, data = pcall(function()
        return AceSerializer:Deserialize(str)
    end)
    if ok and success then return data end
    return nil
end

--------------------------------------------------
-- Register addon prefix
--------------------------------------------------

C_ChatInfo.RegisterAddonMessagePrefix("REDDKP_AUDIT")

--------------------------------------------------
-- Log sync events (optional but recommended)
--------------------------------------------------

local function LogSyncEvent(entry, sender)
    AddAuditEntry({
        action = "sync",
        source = sender,
        info = "Received audit entry " .. (entry.id or "?") .. " from " .. sender,
    })
end

--------------------------------------------------
-- Outgoing sync
--------------------------------------------------

function RedDKP_SendAuditEntry(entry)
    local payload = Serialize(entry)
    if not payload then
        Print("Failed to serialize audit entry.")
        return
    end

    -- Broadcast to guild + raid
    C_ChatInfo.SendAddonMessage("REDDKP_AUDIT", payload, "GUILD")
    C_ChatInfo.SendAddonMessage("REDDKP_AUDIT", payload, "RAID")
end

--------------------------------------------------
-- Incoming sync processor
--------------------------------------------------

local function ProcessIncomingAudit(entry, sender)
    -- Prevent duplicates
    for _, e in ipairs(RedDKP_Audit) do
        if e.id == entry.id then
            return
        end
    end

    entry.source = sender

    -- Log sync event
    LogSyncEvent(entry, sender)

    -- Temporarily disable outgoing sync to avoid loops
    local oldSend = RedDKP_SendAuditEntry
    RedDKP_SendAuditEntry = nil

    AddAuditEntry(entry)

    -- Restore sync
    RedDKP_SendAuditEntry = oldSend

    --------------------------------------------------
    -- Apply the action (Option 1: apply immediately)
    --------------------------------------------------

    if entry.action == "field" then
        ApplyFieldChange(entry, false)

    elseif entry.action == "delete" then
        ApplyDelete(entry, false)

    elseif entry.action == "undo" then
        -- Find the target entry and undo it
        for _, e in ipairs(RedDKP_Audit) do
            if e.id == entry.targetId then
                RedDKP.UndoAuditEntry(e)
                break
            end
        end
    end

    UpdateTable()
end

--------------------------------------------------
-- CHAT_MSG_ADDON listener
--------------------------------------------------

local syncFrame = CreateFrame("Frame")
syncFrame:RegisterEvent("CHAT_MSG_ADDON")

syncFrame:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if prefix ~= "REDDKP_AUDIT" then return end
    if sender == UnitName("player") then return end

    local entry = Deserialize(msg)
    if not entry then return end

    ProcessIncomingAudit(entry, sender)
end)

--------------------------------------------------
-- Add formatting for sync entries in the audit log
--------------------------------------------------

-- Add this inside your FormatAuditEntry() function:
-- (If you already added it, ignore this part)

--[[
elseif entry.action == "sync" then
    return string.format(
        "[%s] Sync from %s: %s",
        entry.time or "?",
        entry.source or "?",
        entry.info or ""
    )
]]

--------------------------------------------------
-- End of Part 6
--------------------------------------------------

--------------------------------------------------
-- Part 7 — Final Polish (Slash Commands, UI Open, Versioning, Rebuild)
--------------------------------------------------

--------------------------------------------------
-- Slash Commands
--------------------------------------------------

SLASH_REDDKP1 = "/reddkp"
SLASH_REDDKP2 = "/dkp"

SlashCmdList["REDDKP"] = function(msg)
    msg = msg:lower():trim()

    if msg == "show" or msg == "" then
        mainFrame:Show()
        return
    end

    if msg == "hide" then
        mainFrame:Hide()
        return
    end

    if msg == "rebuild" then
        RedDKP.RebuildFromAudit()
        return
    end

    Print("Commands:")
    Print("/reddkp show   - open DKP window")
    Print("/reddkp hide   - close DKP window")
    Print("/reddkp rebuild - rebuild DKP from audit log")
end

--------------------------------------------------
-- Rebuild DKP from audit log
-- (Optional but extremely useful for debugging)
--------------------------------------------------

function RedDKP.RebuildFromAudit()
    Print("Rebuilding DKP table from audit log...")

    -- wipe DKP
    RedDKP_Data = {}

    -- apply all audit entries in reverse order (oldest first)
    for i = #RedDKP_Audit, 1, -1 do
        local e = RedDKP_Audit[i]

        if e.action == "field" then
            EnsurePlayer(e.player)[e.field] = e.new

        elseif e.action == "delete" then
            -- delete means: row was removed at that time
            -- but earlier entries may recreate it
            RedDKP_Data[e.player] = nil

        elseif e.action == "undo" then
            -- undo means: reverse the target entry
            for _, t in ipairs(RedDKP_Audit) do
                if t.id == e.targetId then
                    if t.action == "field" then
                        EnsurePlayer(t.player)[t.field] = t.old
                    elseif t.action == "delete" then
                        EnsurePlayer(t.player)
                        local r = t.row or {}
                        RedDKP_Data[t.player] = {
                            rotated    = r.rotated,
                            lastWeek   = r.lastWeek or 0,
                            onTime     = r.onTime or 0,
                            attendance = r.attendance or 0,
                            bench      = r.bench or 0,
                            spent      = r.spent or 0,
                            balance    = r.balance or 0,
                        }
                    end
                end
            end
        end
    end

    UpdateTable()
    Print("Rebuild complete.")
end

--------------------------------------------------
-- Minimap Button (optional)
--------------------------------------------------

local mini = CreateFrame("Button", "RedDKP_MinimapButton", Minimap)
mini:SetSize(32, 32)
mini:SetFrameStrata("MEDIUM")
mini:SetNormalTexture("Interface\\AddOns\\RedDKP\\icon")
mini:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 0, 0)

mini:SetScript("OnClick", function()
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        mainFrame:Show()
    end
end)

mini:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("RedDKP")
    GameTooltip:AddLine("Click to toggle window", 1, 1, 1)
    GameTooltip:Show()
end)

mini:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

--------------------------------------------------
-- Version Broadcast
--------------------------------------------------

local REDDKP_VERSION = "1.0.0"

local function SendVersion()
    C_ChatInfo.SendAddonMessage("REDDKP_VERSION", REDDKP_VERSION, "GUILD")
end

C_ChatInfo.RegisterAddonMessagePrefix("REDDKP_VERSION")

local versionFrame = CreateFrame("Frame")
versionFrame:RegisterEvent("CHAT_MSG_ADDON")
versionFrame:RegisterEvent("PLAYER_LOGIN")

versionFrame:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(5, SendVersion)
        return
    end

    if prefix == "REDDKP_VERSION" then
        if sender ~= UnitName("player") then
            if msg ~= REDDKP_VERSION then
                Print("User " .. sender .. " is running RedDKP version " .. msg)
            end
        end
    end
end)

--------------------------------------------------
-- Initialization
--------------------------------------------------

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")

initFrame:SetScript("OnEvent", function(self, event, addon)
    if addon ~= ADDON_NAME then return end

    EnsureSaved()
    UpdateTable()

    Print("RedDKP loaded. Type /reddkp to open.")
end)

--------------------------------------------------
-- End of Part 7
--------------------------------------------------

