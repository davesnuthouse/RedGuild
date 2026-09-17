--==================================================================
-- ATTENDANCE TAB (editors only)
--==================================================================
-- Kept off the DKP tab on purpose: these are lifetime counters, not
-- part of the running DKP session, and mixing them into that table
-- made it noisy. Both counters move only when a new DKP session is
-- started (RedGuild_BumpAttendance / RedGuild_BumpBenched, from the
-- New Week popup), so everything here is hand-editable too - an
-- editor still needs to correct a miscount or backfill somebody.
--==================================================================

local ATTEND_ROW_HEIGHT = 18

-- field = the RedGuild_Data key, kind = how the value is edited.
local ATTEND_COLS = {
    { text = "Name",          width = 120, field = "name",           kind = "name" },
    { text = "Raids",         width = 55,  field = "raidsAttended",  kind = "count" },
    { text = "Last Raid",     width = 100, field = "lastAttendance", kind = "date" },
    { text = "Benched",       width = 65,  field = "benched",        kind = "count" },
    { text = "Last Benched",  width = 100, field = "lastBenched",    kind = "date" },
}

local attendanceRows = {}
local attendContent
local attendInlineEdit
local attendStatusText

-- Dates are shown and typed as DD.MM.YYYY but stored as YYYY-MM-DD.
-- The stored form is what the day-based de-duplication in
-- RedGuild_BumpAttendance compares against (it builds today's stamp
-- with date("%Y-%m-%d")), what the attendance sync puts on the wire,
-- and what sorts correctly as a plain string - so the display format
-- stops at the edge, and nothing downstream has to care.
function RedGuild_Attendance_FormatDate(stored)
    if type(stored) ~= "string" then return "Never" end

    local y, m, dd = stored:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return stored end   -- unrecognised: show it as-is

    return string.format("%s.%s.%s", dd, m, y)
end

-- Blank, "never" or "-" all clear the field; anything else has to be
-- a full date, so a typo cannot quietly become the value that the
-- day-based de-duplication then compares against. Returns the
-- canonical YYYY-MM-DD form.
--
-- DD.MM.YYYY is what the table shows, so it is what an editor will
-- type back. YYYY-MM-DD is still accepted: it is what the field held
-- before this and what an editor used to typing it will reach for.
local function ParseDateInput(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if text == "" or text:lower() == "never" or text == "-" then
        return true, nil
    end

    local y, m, dd

    local dd2, m2, y4 = text:match("^(%d%d)%.(%d%d)%.(%d%d%d%d)$")
    if dd2 then
        y, m, dd = y4, m2, dd2
    else
        y, m, dd = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    end
    if not y then return false end

    if tonumber(m) < 1 or tonumber(m) > 12
    or tonumber(dd) < 1 or tonumber(dd) > 31 then
        return false
    end

    return true, string.format("%s-%s-%s", y, m, dd)
end

-- kind is "count" (a whole number, floored at 0) or "date"
-- (YYYY-MM-DD, or empty/never/- to clear). Rejects anything else
-- rather than writing a value the automatic counters would then
-- compare against.
function RedGuild_Attendance_SetValue(playerName, field, kind, raw)
    local d = playerName and RedGuild_Data[playerName]
    if not d then return end

    local old = d[field]
    local new

    if kind == "count" then
        new = tonumber(raw)
        if not new then
            Print("|cffff5555Enter a number.|r")
            return
        end
        new = math.max(0, math.floor(new))
    else
        local ok, parsed = ParseDateInput(raw)
        if not ok then
            Print("|cffff5555Dates must be DD.MM.YYYY (or empty to clear).|r")
            return
        end
        new = parsed
    end

    if old == new then return end

    d[field] = new
    LogAudit(playerName, field, old == nil and "none" or tostring(old),
        new == nil and "none" or tostring(new))
    BumpDKPVersion()
    RedGuild_RefreshAttendanceTable()
end

local function CreateAttendanceRow(index)
    local row = CreateFrame("Frame", nil, attendContent)
    row:SetSize(460, ATTEND_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ATTEND_ROW_HEIGHT)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.15)
    row.bg = bg

    row.cols = {}
    local x = 0

    for i, c in ipairs(ATTEND_COLS) do
        local col

        if c.kind == "name" then
            col = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            col:SetPoint("LEFT", row, "LEFT", x, 0)
            col:SetWidth(c.width)
            col:SetJustifyH("LEFT")
        else
            -- A button rather than a bare font string so the value can
            -- be clicked to edit, the same way the DKP table works.
            col = CreateFrame("Button", nil, row)
            col:SetPoint("LEFT", row, "LEFT", x, 0)
            col:SetSize(c.width, ATTEND_ROW_HEIGHT)

            local fs = col:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetAllPoints(col)
            fs:SetJustifyH("LEFT")
            col:SetFontString(fs)

            col:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            col:GetHighlightTexture():SetAlpha(0.3)

            col:SetScript("OnClick", function(self)
                if not IsAuthorized() then
                    Print("Only editors can modify attendance.")
                    return
                end

                local playerName = row.name
                if not playerName then return end

                attendInlineEdit:Hide()

                attendInlineEdit.currentBtn = self
                attendInlineEdit:ClearAllPoints()
                attendInlineEdit:SetPoint("LEFT", self, "LEFT", 0, 0)
                attendInlineEdit:SetWidth(c.width - 4)

                local d = RedGuild_Data[playerName]
                local value = d and d[c.field]
                if c.kind == "count" then
                    attendInlineEdit:SetText(tostring(tonumber(value) or 0))
                else
                    -- Pre-filled in the format the cell shows, so the
                    -- editor edits what they were looking at.
                    attendInlineEdit:SetText(
                        value and RedGuild_Attendance_FormatDate(value) or "")
                end

                attendInlineEdit.saveFunc = function(text)
                    RedGuild_Attendance_SetValue(playerName, c.field, c.kind, text)
                end

                attendInlineEdit:Show()
                attendInlineEdit:HighlightText()
            end)
        end

        row.cols[i] = col
        x = x + c.width + 5
    end

    return row
end

function RedGuild_RefreshAttendanceStatus()
    if not attendStatusText then return end

    local when = RedGuild_Config.lastAttendSync
    if not when then
        attendStatusText:SetText("|cff888888Last sync: never|r")
        return
    end

    attendStatusText:SetText(string.format("|cff888888Last sync: %s from %s|r",
        when, RedGuild_Config.lastAttendSyncFrom or "?"))
end

function RedGuild_RefreshAttendanceTable()
    RedGuild_RefreshAttendanceStatus()

    if not attendContent then return end

    local names = {}
    for name in pairs(RedGuild_Data) do
        if type(name) == "string" and strtrim(name) ~= "" then
            table.insert(names, name)
        end
    end
    table.sort(names)

    for i, name in ipairs(names) do
        local row = attendanceRows[i]
        if not row then
            row = CreateAttendanceRow(i)
            attendanceRows[i] = row
        end

        local d = RedGuild_Data[name] or {}
        row.name = name

        local classColor = "|cffffffff"
        local c = d.class and RAID_CLASS_COLORS[d.class]
        if c then
            classColor = string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
        end

        row.cols[1]:SetText(classColor .. name .. "|r")
        row.cols[2]:SetText(tostring(tonumber(d.raidsAttended) or 0))
        row.cols[3]:SetText(RedGuild_Attendance_FormatDate(d.lastAttendance))
        row.cols[4]:SetText(tostring(tonumber(d.benched) or 0))
        row.cols[5]:SetText(RedGuild_Attendance_FormatDate(d.lastBenched))

        row:Show()
    end

    for i = #names + 1, #attendanceRows do
        attendanceRows[i]:Hide()
        attendanceRows[i].name = nil
    end

    attendContent:SetHeight(math.max(1, #names * ATTEND_ROW_HEIGHT))
end

function CreateAttendanceTab()
    local title = attendancePanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", attendancePanel, "TOPLEFT", 30, -30)
    title:SetText("Raid Attendance")

    local note = attendancePanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    note:SetText("Counted automatically; click any value to correct it. Dates are YYYY-MM-DD.")

    ----------------------------------------------------------------
    -- SYNC (editors only, and deliberately manual)
    ----------------------------------------------------------------
    -- These numbers ride on their own channel rather than the DKP
    -- sync, so they need pushing by hand once an editor is happy with
    -- them - see RedGuild_SendAttendanceSync.
    local syncBtn = CreateFrame("Button", nil, attendancePanel, "UIPanelButtonTemplate")
    syncBtn:SetSize(140, 22)
    syncBtn:SetPoint("TOPRIGHT", attendancePanel, "TOPRIGHT", -40, -32)
    syncBtn:SetText("Sync Attendance")
    syncBtn:SetScript("OnClick", function()
        RedGuild_SendAttendanceSync()
        RedGuild_RefreshAttendanceStatus()
    end)
    syncBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Sync Attendance")
        GameTooltip:AddLine("Sends these counters to the other editors.", 1, 1, 1)
        GameTooltip:AddLine("Attendance is not part of the DKP sync, so", 0.6, 0.6, 0.6)
        GameTooltip:AddLine("it only moves when you press this.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    syncBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    attendStatusText = attendancePanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    attendStatusText:SetPoint("TOPRIGHT", syncBtn, "BOTTOMRIGHT", 0, -4)
    attendStatusText:SetJustifyH("RIGHT")

    ----------------------------------------------------------------
    -- HEADERS
    ----------------------------------------------------------------
    local headerY = -70
    local x = 30

    for _, c in ipairs(ATTEND_COLS) do
        local fs = attendancePanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", attendancePanel, "TOPLEFT", x, headerY)
        fs:SetWidth(c.width)
        fs:SetJustifyH("LEFT")
        fs:SetText("|cffffd100" .. c.text .. "|r")
        x = x + c.width + 5
    end

    ----------------------------------------------------------------
    -- SCROLLING LIST
    ----------------------------------------------------------------
    local scroll = CreateFrame("ScrollFrame", nil, attendancePanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", attendancePanel, "TOPLEFT", 30, headerY - 20)
    scroll:SetPoint("BOTTOMRIGHT", attendancePanel, "BOTTOMRIGHT", -40, 30)

    attendContent = CreateFrame("Frame", nil, scroll)
    attendContent:SetSize(460, 1)
    scroll:SetScrollChild(attendContent)

    ----------------------------------------------------------------
    -- INLINE EDIT BOX
    ----------------------------------------------------------------
    attendInlineEdit = CreateFrame("EditBox", nil, attendContent, "InputBoxTemplate")
    attendInlineEdit:SetAutoFocus(true)
    attendInlineEdit:SetHeight(ATTEND_ROW_HEIGHT)
    attendInlineEdit:SetFrameStrata("HIGH")
    attendInlineEdit:Hide()

    attendInlineEdit:SetScript("OnEscapePressed", function(self)
        self.saveFunc = nil
        self:Hide()
    end)

    attendInlineEdit:SetScript("OnEnterPressed", function(self)
        local save = self.saveFunc
        self.saveFunc = nil
        self:Hide()
        if save then save(self:GetText()) end
    end)

    -- Clicking away is a cancel, not a save: a half-typed date left
    -- behind by a stray click should not overwrite a real one.
    attendInlineEdit:SetScript("OnEditFocusLost", function(self)
        self.saveFunc = nil
        self:Hide()
    end)

    attendancePanel:SetScript("OnShow", RedGuild_RefreshAttendanceTable)
end
