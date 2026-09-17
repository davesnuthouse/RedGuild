--==================================================================
-- AUDIT LOG TAB
--==================================================================
-- The log used to be one run-on sentence per line ("[timestamp] X
-- changed Y's field from A to B"), which was unreadable at any real
-- length: nothing lined up, so there was no way to scan down for one
-- player or one kind of change. It is a table now - fixed columns, a
-- filter box, and the change itself shown as old -> new.
--==================================================================

local AUDIT_ROW_HEIGHT = 16

-- Raw DKP record keys read badly in a log. Anything not listed here
-- (SYNC_APPLIED, "item won", and the other free-text actions) is
-- shown exactly as it was written.
local AUDIT_FIELD_LABELS = {
    lastWeek       = "Old Bal",
    onTime         = "On-Time",
    attendance     = "Post-Raid",
    bench          = "Bench",
    spent          = "Spent",
    balance        = "Balance",
    msRole         = "Main Spec",
    osRole         = "Off Spec",
    name           = "Name",
    raidsAttended  = "Raids",
    lastAttendance = "Last Raid",
    benched        = "Benched",
    lastBenched    = "Last Benched",
}

-- Sized to fill the panel rather than to the longest plausible value:
-- the widest entries here are free text ("moved 144 (from balance +
-- attendance)") and item links, which no sane column width fits. The
-- columns take the space that is actually there - roughly 180px of it
-- was sitting unused to the right of the table - and the row tooltip
-- (see CreateAuditRow) carries whatever still does not fit.
--
-- Everything is left-justified. From/To were right-justified, which
-- suits a column of numbers but reads badly for the sentences that
-- actually dominate this log.
local AUDIT_COLS = {
    { text = "When",    width = 72 },
    { text = "Editor",  width = 80 },
    { text = "Player",  width = 92 },
    { text = "Change",  width = 122 },
    { text = "From",    width = 160 },
    { text = "To",      width = 144 },
}

local AUDIT_COL_GAP   = 6
local AUDIT_ROW_WIDTH = 0
for i, c in ipairs(AUDIT_COLS) do
    AUDIT_ROW_WIDTH = AUDIT_ROW_WIDTH + c.width
    if i < #AUDIT_COLS then AUDIT_ROW_WIDTH = AUDIT_ROW_WIDTH + AUDIT_COL_GAP end
end

-- Exposed so a test can assert the table still fits the panel if
-- somebody widens a column or adds one.
REDGUILD_AUDIT_ROW_WIDTH = AUDIT_ROW_WIDTH

local auditContent
local auditFilterBox
local auditCountText
auditRows = {}

function RedGuild_Audit_FieldLabel(field)
    if not field then return "?" end
    return AUDIT_FIELD_LABELS[field] or field
end

-- The stored stamp is "YYYY-MM-DD HH:MM:SS"; the seconds and the
-- year are noise in a list, so the column shows "DD.MM HH:MM".
function RedGuild_Audit_ShortTime(stamp)
    if type(stamp) ~= "string" then return "?" end
    local _, month, day, hour, min = stamp:match("(%d+)%-(%d+)%-(%d+) (%d+):(%d+)")
    if not month then return stamp end
    return string.format("%s.%s %s:%s", day, month, hour, min)
end

-- Plain substring match against player, editor and change, so a name
-- containing a "-" searches for itself rather than being read as a
-- Lua pattern.
function RedGuild_Audit_Matches(entry, filter)
    if not filter or filter == "" then return true end
    if not entry then return false end
    local hay = strlower(table.concat({
        entry.name   or "",
        entry.editor or "",
        entry.field  or "",
        RedGuild_Audit_FieldLabel(entry.field),
    }, " "))
    return strfind(hay, filter, 1, true) ~= nil
end

-- Fields whose values are stored dates. The log records whatever was
-- written, which for these is the canonical YYYY-MM-DD - shown here
-- the same way the attendance table shows it, so the two tabs do not
-- disagree about what a date looks like.
local AUDIT_DATE_FIELDS = {
    lastAttendance = true,
    lastBenched    = true,
}

local function AuditValueText(v, field)
    if v == nil or v == "" then return "|cff666666-|r" end

    if field and AUDIT_DATE_FIELDS[field] and RedGuild_Attendance_FormatDate then
        return RedGuild_Attendance_FormatDate(v)
    end

    return tostring(v)
end

-- Hover handler, kept out of CreateAuditRow so it is one shared
-- function rather than a closure per row - there can be thousands.
function RedGuild_Audit_ShowRowTooltip(row)
    local e = row and row.entry
    if not e then return end

    GameTooltip:SetOwner(row, "ANCHOR_CURSOR")
    GameTooltip:AddLine(e.name or "?", 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("When",   e.time or "?",   0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine("Editor", e.editor or "?", 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine("Change", RedGuild_Audit_FieldLabel(e.field),
                                                         0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddLine(" ")
    -- Wrapped rather than double-lined: these are the two that
    -- overflow the table, and a tooltip that clipped them too would
    -- be no help at all.
    GameTooltip:AddLine("|cff888888From|r", 1, 1, 1)
    GameTooltip:AddLine(AuditValueText(e.old, e.field), 1, 0.5, 0.5, true)
    GameTooltip:AddLine("|cff888888To|r", 1, 1, 1)
    GameTooltip:AddLine(AuditValueText(e.new, e.field), 0.5, 1, 0.5, true)
    GameTooltip:Show()
end

local function CreateAuditRow(index)
    local row = CreateFrame("Frame", nil, auditContent)
    row:SetSize(AUDIT_ROW_WIDTH, AUDIT_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * AUDIT_ROW_HEIGHT)

    -- Banded backgrounds: with this many near-identical lines, the
    -- stripe is what keeps your eye on one row across the columns.
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    if index % 2 == 0 then
        bg:SetColorTexture(1, 1, 1, 0.03)
    else
        bg:SetColorTexture(0, 0, 0, 0.15)
    end

    -- No column is wide enough for the longest entries, so hovering a
    -- row shows it in full, one field per line, with nothing clipped.
    row:EnableMouse(true)
    row:SetScript("OnEnter", RedGuild_Audit_ShowRowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row.cols = {}
    local x = 0
    for i, c in ipairs(AUDIT_COLS) do
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", row, "LEFT", x, 0)
        fs:SetWidth(c.width)
        fs:SetJustifyH(c.justify or "LEFT")
        fs:SetWordWrap(false)
        row.cols[i] = fs
        x = x + c.width + AUDIT_COL_GAP
    end

    return row
end

function UpdateAuditLog()
    if not auditContent or not RedGuild_Audit then return end

    -- Remove entries older than 30 days
    local cutoff = time() - (30 * 24 * 60 * 60)

    for i = #RedGuild_Audit, 1, -1 do
        local entry = RedGuild_Audit[i]
        if entry and entry.time then
            local ts = ParseAuditTime(entry.time)
            if ts and ts < cutoff then
                table.remove(RedGuild_Audit, i)
            end
        end
    end

    -- Parse each stamp once rather than inside the comparator: the
    -- filter box re-runs this on every keystroke, and ParseAuditTime
    -- is a string match. A missing/unparsable stamp sorts to the
    -- bottom instead of returning false both ways, which Lua rejects
    -- as an invalid order function.
    local ts = {}
    for _, entry in ipairs(RedGuild_Audit) do
        ts[entry] = (entry.time and ParseAuditTime(entry.time)) or 0
    end

    table.sort(RedGuild_Audit, function(a, b)
        return ts[a] > ts[b]   -- newest first
    end)

    local raw = auditFilterBox and auditFilterBox:GetText()
    local filter = (type(raw) == "string") and strlower(strtrim(raw)) or ""

    local shown = {}
    for _, entry in ipairs(RedGuild_Audit) do
        if RedGuild_Audit_Matches(entry, filter) then
            table.insert(shown, entry)
        end
    end

    for i, entry in ipairs(shown) do
        local row = auditRows[i]
        if not row then
            row = CreateAuditRow(i)
            auditRows[i] = row
        end

        row.entry = entry
        row.cols[1]:SetText("|cff888888" .. RedGuild_Audit_ShortTime(entry.time) .. "|r")
        row.cols[2]:SetText("|cffaaaaff" .. (entry.editor or "?") .. "|r")
        row.cols[3]:SetText("|cffffffff" .. (entry.name or "?") .. "|r")
        row.cols[4]:SetText("|cffffd100" .. RedGuild_Audit_FieldLabel(entry.field) .. "|r")
        row.cols[5]:SetText("|cffff8080" .. AuditValueText(entry.old, entry.field) .. "|r")
        row.cols[6]:SetText("|cff80ff80" .. AuditValueText(entry.new, entry.field) .. "|r")

        row:Show()
    end

    for i = #shown + 1, #auditRows do
        auditRows[i].entry = nil
        auditRows[i]:Hide()
    end

    auditContent:SetHeight(math.max(1, #shown * AUDIT_ROW_HEIGHT))

    if auditCountText then
        if filter == "" then
            auditCountText:SetText(string.format("|cff888888%d entries|r", #shown))
        else
            auditCountText:SetText(string.format("|cff888888%d of %d entries|r",
                #shown, #RedGuild_Audit))
        end
    end
end

function CreateAuditTab()
    local title = auditPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", auditPanel, "TOPLEFT", 30, -30)
    title:SetText("Audit Log")

    ----------------------------------------------------------------
    -- FILTER
    ----------------------------------------------------------------
    local filterLabel = auditPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    filterLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    filterLabel:SetText("Filter:")

    auditFilterBox = CreateFrame("EditBox", nil, auditPanel, "InputBoxTemplate")
    auditFilterBox:SetSize(160, 18)
    auditFilterBox:SetPoint("LEFT", filterLabel, "RIGHT", 8, 0)
    auditFilterBox:SetAutoFocus(false)
    auditFilterBox:SetScript("OnTextChanged", UpdateAuditLog)
    auditFilterBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    auditFilterBox:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
        UpdateAuditLog()
    end)

    local clearBtn = CreateFrame("Button", nil, auditPanel, "UIPanelButtonTemplate")
    clearBtn:SetSize(50, 18)
    clearBtn:SetPoint("LEFT", auditFilterBox, "RIGHT", 8, 0)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        auditFilterBox:SetText("")
        auditFilterBox:ClearFocus()
        UpdateAuditLog()
    end)

    auditCountText = auditPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    auditCountText:SetPoint("LEFT", clearBtn, "RIGHT", 12, 0)

    ----------------------------------------------------------------
    -- HEADERS
    ----------------------------------------------------------------
    local headerY = -78
    local x = 30
    for _, c in ipairs(AUDIT_COLS) do
        local fs = auditPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", auditPanel, "TOPLEFT", x, headerY)
        fs:SetWidth(c.width)
        fs:SetJustifyH(c.justify or "LEFT")
        fs:SetText("|cffffd100" .. c.text .. "|r")
        x = x + c.width + AUDIT_COL_GAP
    end

    ----------------------------------------------------------------
    -- LIST
    ----------------------------------------------------------------
    local scroll = CreateFrame("ScrollFrame", nil, auditPanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", auditPanel, "TOPLEFT", 30, headerY - 18)
    scroll:SetPoint("BOTTOMRIGHT", auditPanel, "BOTTOMRIGHT", -40, 25)

    auditContent = CreateFrame("Frame", nil, scroll)
    auditContent:SetSize(AUDIT_ROW_WIDTH, 1)
    scroll:SetScrollChild(auditContent)

    auditPanel:SetScript("OnShow", UpdateAuditLog)
end
