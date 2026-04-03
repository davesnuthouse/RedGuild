local ADDON_NAME, RedDKP = ...
RedDKP = RedDKP or {}
_G.RedDKP = RedDKP

--------------------------------------------------
-- Saved variables
--------------------------------------------------

RedDKP_Data   = RedDKP_Data   or {}
RedDKP_Config = RedDKP_Config or {}
RedDKP_Audit  = RedDKP_Audit  or {}

RedDKP_Config.authorizedEditors = RedDKP_Config.authorizedEditors or {}

--------------------------------------------------
-- Utilities
--------------------------------------------------

function RedDKP.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff5555RedDKP:|r " .. tostring(msg))
end

function RedDKP.Now()
    return date("%Y-%m-%d %H:%M:%S")
end

function RedDKP.NewAuditId()
    return string.format("%08x", math.random(0, 0xFFFFFFFF))
end

--------------------------------------------------
-- Permissions
--------------------------------------------------

function RedDKP.IsGuildOfficer()
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex == 0 or rankIndex == 1
end

function RedDKP.IsAuthorized()
    if RedDKP.IsGuildOfficer() then
        return true
    end
    local name = UnitName("player")
    return RedDKP_Config.authorizedEditors[name] == true
end

--------------------------------------------------
-- Data helpers
--------------------------------------------------

function RedDKP.EnsureSaved()
    RedDKP_Data   = RedDKP_Data   or {}
    RedDKP_Config = RedDKP_Config or {}
    RedDKP_Audit  = RedDKP_Audit  or {}
    RedDKP_Config.authorizedEditors = RedDKP_Config.authorizedEditors or {}
end

function RedDKP.EnsurePlayer(name)
    RedDKP.EnsureSaved()
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
-- Serialization (shared by Sync + Import/Export)
--------------------------------------------------

local AceSerializer = LibStub and LibStub("AceSerializer-3.0", true)

function RedDKP.Serialize(tbl)
    if not AceSerializer then return nil end
    local ok, result = pcall(function()
        return AceSerializer:Serialize(tbl)
    end)
    if ok then return result end
    return nil
end

function RedDKP.Deserialize(str)
    if not AceSerializer then return nil end
    local ok, success, data = pcall(function()
        return AceSerializer:Deserialize(str)
    end)
    if ok and success then return data end
    return nil
end

--------------------------------------------------
-- UpdateTable stub (real one in UI_DKP.lua)
--------------------------------------------------

function RedDKP.UpdateTable()
    -- replaced by UI_DKP.lua
end