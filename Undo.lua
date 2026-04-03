local ADDON_NAME, RedDKP = ...

--------------------------------------------------
-- UNDO ENGINE
--------------------------------------------------

-- Undo a single audit entry
function RedDKP.UndoAuditEntry(entry)
    if not RedDKP.IsAuthorized() then
        RedDKP.Print("Only editors can undo audit actions.")
        return
    end

    if not entry or not entry.action then
        RedDKP.Print("Invalid audit entry.")
        return
    end

    if entry.action == "field" then
        RedDKP.ApplyFieldChange(entry, true)

    elseif entry.action == "delete" then
        RedDKP.ApplyDelete(entry, true)

    else
        RedDKP.Print("This audit entry type cannot be undone.")
        return
    end

    -- Update UI
    RedDKP.UpdateTable()

    -- Log the undo action
    local info = string.format("Undo of %s on %s", entry.action, entry.player or "?")
    RedDKP.LogUndo(entry, info)

    RedDKP.Print("Undid audit action " .. (entry.id or "?"))
end

--------------------------------------------------
-- Rebuild DKP from audit log (optional)
--------------------------------------------------

function RedDKP.RebuildFromAudit()
    RedDKP.Print("Rebuilding DKP table from audit log...")

    -- wipe DKP
    RedDKP_Data = {}

    -- apply all audit entries oldest → newest
    for i = #RedDKP_Audit, 1, -1 do
        local e = RedDKP_Audit[i]

        if e.action == "field" then
            RedDKP.EnsurePlayer(e.player)[e.field] = e.new

        elseif e.action == "delete" then
            RedDKP_Data[e.player] = nil

        elseif e.action == "undo" then
            -- reverse the target entry
            for _, t in ipairs(RedDKP_Audit) do
                if t.id == e.targetId then
                    if t.action == "field" then
                        RedDKP.EnsurePlayer(t.player)[t.field] = t.old

                    elseif t.action == "delete" then
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

    RedDKP.UpdateTable()
    RedDKP.Print("Rebuild complete.")
end