local ADDON_NAME, RedDKP = ...

--------------------------------------------------
-- DKP Mutation Helpers
--------------------------------------------------

-- Set a DKP field (audit-logged)
function RedDKP.SetDKPField(player, field, newValue)
    RedDKP.EnsureSaved()
    local d = RedDKP.EnsurePlayer(player)
    local oldValue = d[field]

    if oldValue == newValue then
        return
    end

    d[field] = newValue

    -- audit entry
    RedDKP.AddAuditEntry({
        action = "field",
        player = player,
        field  = field,
        old    = oldValue,
        new    = newValue,
    })

    RedDKP.UpdateTable()
end

--------------------------------------------------
-- Add to a DKP field (e.g. +5 attendance)
--------------------------------------------------

function RedDKP.AddDKP(player, field, amount)
    RedDKP.EnsureSaved()
    local d = RedDKP.EnsurePlayer(player)
    local oldValue = d[field]
    local newValue = oldValue + amount

    d[field] = newValue

    RedDKP.AddAuditEntry({
        action = "field",
        player = player,
        field  = field,
        old    = oldValue,
        new    = newValue,
    })

    RedDKP.UpdateTable()
end

--------------------------------------------------
-- Delete a DKP row (audit-logged)
--------------------------------------------------

function RedDKP.DeletePlayerRow(player)
    RedDKP.EnsureSaved()

    local d = RedDKP_Data[player]
    if not d then
        RedDKP.Print("No DKP row exists for " .. player)
        return
    end

    -- log full row before deletion
    RedDKP.AddAuditEntry({
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

    RedDKP_Data[player] = nil

    RedDKP.UpdateTable()
    RedDKP.Print("Deleted DKP record for " .. player)
end

--------------------------------------------------
-- Delete confirmation popup
--------------------------------------------------

StaticPopupDialogs["REDDKP_DELETE_PLAYER"] = {
    text = "Delete DKP record for %s?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, player)
        if not RedDKP.IsAuthorized() then
            RedDKP.Print("Only editors can delete DKP rows.")
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