local ADDON_NAME, RedDKP = ...

--------------------------------------------------
-- VERSION
--------------------------------------------------

RedDKP.VERSION = "1.0.0"

--------------------------------------------------
-- TAB BUTTONS
--------------------------------------------------

local mainFrame = RedDKP.MainFrame

local tabs = {
    { name = "DKP",        panel = RedDKP.DKPPanel },
    { name = "Editors",    panel = RedDKP.EditorsPanel },
    { name = "Import/Export", panel = RedDKP.ImportPanel },
    { name = "Audit Log",  panel = RedDKP.AuditPanel },
}

local function CreateTabButton(index, text)
    local btn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    btn:SetSize(120, 24)
    btn:SetPoint("TOPLEFT", 10 + (index - 1) * 130, -30)
    btn:SetText(text)
    return btn
end

local function HideAllPanels()
    for _, t in ipairs(tabs) do
        t.panel:Hide()
    end
end

for i, t in ipairs(tabs) do
    local btn = CreateTabButton(i, t.name)
    t.button = btn

    btn:SetScript("OnClick", function()
        HideAllPanels()
        t.panel:Show()
    end)
end

-- Default tab
HideAllPanels()
RedDKP.DKPPanel:Show()

--------------------------------------------------
-- SLASH COMMANDS
--------------------------------------------------

SLASH_REDDKP1 = "/reddkp"
SLASH_REDDKP2 = "/dkp"

SlashCmdList["REDDKP"] = function(msg)
    msg = msg:lower():trim()

    if msg == "" or msg == "show" then
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

    RedDKP.Print("Commands:")
    RedDKP.Print("/reddkp show     - open DKP window")
    RedDKP.Print("/reddkp hide     - close DKP window")
    RedDKP.Print("/reddkp rebuild  - rebuild DKP from audit log")
end

--------------------------------------------------
-- MINIMAP BUTTON
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
-- VERSION BROADCAST
--------------------------------------------------

local function SendVersion()
    C_ChatInfo.SendAddonMessage("REDDKP_VERSION", RedDKP.VERSION, "GUILD")
end

local versionFrame = CreateFrame("Frame")
versionFrame:RegisterEvent("PLAYER_LOGIN")
versionFrame:RegisterEvent("CHAT_MSG_ADDON")

versionFrame:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(5, SendVersion)
        return
    end

    if prefix == "REDDKP_VERSION" and sender ~= UnitName("player") then
        if msg ~= RedDKP.VERSION then
            RedDKP.Print("User " .. sender .. " is running RedDKP version " .. msg)
        end
    end
end)

--------------------------------------------------
-- ADDON INITIALIZATION
--------------------------------------------------

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")

initFrame:SetScript("OnEvent", function(self, event, addon)
    if addon ~= ADDON_NAME then return end

    RedDKP.EnsureSaved()
    RedDKP.UpdateTable()

    RedDKP.Print("RedDKP loaded. Type /reddkp to open.")
end)