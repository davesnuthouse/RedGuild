local ADDON_NAME, RedDKP = ...

--------------------------------------------------
-- AUDIT SYSTEM
--------------------------------------------------

-- Add an audit entry to the log
function RedDKP.AddAuditEntry(entry)
    RedDKP.EnsureSaved()

    entry.id     = entry.id     or RedDKP.NewAuditId()
    entry.time   = entry.time   or RedDKP.Now()
    entry.editor = entry.editor or UnitName("player")
    entry.source = entry.source or entry.editor

    table.insert(RedDKP_Audit, 1, entry)

    -- Sync broadcast (Sync.lua overrides this)
    if RedDKP.SendAuditEntry then
        RedDKP.SendAuditEntry(entry)
    end
end

--------------------------------------------------
-- Logging helpers
--------------------------------------------------

-- Log a field change (e.g. attendance, spent, balance)
function RedDKP.LogFieldChange(player, field, oldValue, newValue)
    RedDKP.AddAuditEntry({
        action = "field",
        player = player,
        field  = field,
        old    = oldValue,
        new    = newValue,
    })
end

-- Log a row deletion (full snapshot)
function RedDKP.LogDeleteRow(player, data)
    RedDKP.AddAuditEntry({
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

-- Log an undo action
function RedDKP.LogUndo(targetEntry, info)
    RedDKP.AddAuditEntry({
        action   = "undo",
        targetId = targetEntry.id,
        info     = info or "",
    })
end

--------------------------------------------------
-- Apply / revert helpers
--------------------------------------------------

-- Apply or reverse a field change
function RedDKP.ApplyFieldChange(entry, reverse)
    local p = entry.player
    local f = entry.field
    if not p or not f then return end

    local d = RedDKP_Data[p]
    if not d then return end

    local from = reverse and entry.new or entry.old
    local to   = reverse and entry.old or entry.new

    d[f] = to
end

-- Apply or reverse a delete
function RedDKP.ApplyDelete(entry, reverse)
    local p = entry.player
    if not p then return end

    if reverse then
        -- Undo delete: restore row
        local r = entry.row or {}
        RedDKP_Data[p] = {
            rotated    = r.rotated,
            lastWeek   = r.lastWeek or 0,
            onTime     = r.onTime or 0,
            attendance = r.attendance or 0,
            bench      = r.bench or 0,
            spent      = r.spent or 0,
            balance    = r.balance or 0,
        }
    else
        -- Apply delete
        RedDKP_Data[p] = nil
    end
end