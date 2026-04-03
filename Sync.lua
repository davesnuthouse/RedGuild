local ADDON_NAME, RedDKP = ...

--------------------------------------------------
-- SYNC SYSTEM
--------------------------------------------------

-- Register addon message prefix
C_ChatInfo.RegisterAddonMessagePrefix("REDDKP_AUDIT")
C_ChatInfo.RegisterAddonMessagePrefix("REDDKP_VERSION")

--------------------------------------------------
-- Log sync events (optional but recommended)
--------------------------------------------------

local function LogSyncEvent(entry, sender)
    RedDKP.AddAuditEntry({
        action = "sync",
        source = sender,
        info = "Received audit entry " .. (entry.id or "?") .. " from " .. sender,
    })
end

--------------------------------------------------
-- Outgoing sync
--------------------------------------------------

function RedDKP.SendAuditEntry(entry)
    local payload = RedDKP.Serialize(entry)
    if not payload then
        RedDKP.Print("Failed to serialize audit entry.")
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
    local oldSend = RedDKP.SendAuditEntry
    RedDKP.SendAuditEntry = nil

    RedDKP.AddAuditEntry(entry)

    -- Restore sync
    RedDKP.SendAuditEntry = oldSend

    --------------------------------------------------
    -- Apply the action immediately
    --------------------------------------------------

    if entry.action == "field" then
        RedDKP.ApplyFieldChange(entry, false)

    elseif entry.action == "delete" then
        RedDKP.ApplyDelete(entry, false)

    elseif entry.action == "undo" then
        -- Find the target entry and undo it
        for _, t in ipairs(RedDKP_Audit) do
            if t.id == entry.targetId then
                RedDKP.UndoAuditEntry(t)
                break
            end
        end
    end

    RedDKP.UpdateTable()
end

--------------------------------------------------
-- CHAT_MSG_ADDON listener
--------------------------------------------------

local syncFrame = CreateFrame("Frame")
syncFrame:RegisterEvent("CHAT_MSG_ADDON")

syncFrame:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if sender == UnitName("player") then return end

    if prefix == "REDDKP_AUDIT" then
        local entry = RedDKP.Deserialize(msg)
        if entry then
            ProcessIncomingAudit(entry, sender)
        end
        return
    end

    --------------------------------------------------
    -- Version check
    --------------------------------------------------
    if prefix == "REDDKP_VERSION" then
        if msg ~= RedDKP.VERSION then
            RedDKP.Print("User " .. sender .. " is running RedDKP version " .. msg)
        end
    end
end)