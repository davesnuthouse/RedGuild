local ADDON_NAME, RedDKP = ...

--------------------------------------------------
-- MAIN FRAME
--------------------------------------------------

local mainFrame = CreateFrame("Frame", "RedDKP_MainFrame", UIParent, "BasicFrameTemplateWithInset")
mainFrame:SetSize(900, 600)
mainFrame:SetPoint("CENTER")
mainFrame:Hide()
RedDKP.MainFrame = mainFrame

mainFrame.title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
mainFrame.title:SetPoint("TOP", 0, -10)
mainFrame.title:SetText("RedDKP")

--------------------------------------------------
-- DKP PANEL (TAB 1)
--------------------------------------------------

local dkpPanel = CreateFrame("Frame", nil, mainFrame)
dkpPanel:SetAllPoints()
RedDKP.DKPPanel = dkpPanel

--------------------------------------------------
-- SCROLL FRAME FOR DKP TABLE
--------------------------------------------------

local scroll = CreateFrame("ScrollFrame", nil, dkpPanel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 10, -40)
scroll:SetPoint("BOTTOMRIGHT", -30, 50)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(1, 1)
scroll:SetScrollChild(content)

--------------------------------------------------
-- COLUMN HEADERS
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
-- ROW CREATION
--------------------------------------------------

local dkpRows = {}
local selectedPlayer = nil

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
-- UPDATE TABLE (OVERRIDES STUB IN Core.lua)
--------------------------------------------------

function RedDKP.UpdateTable()
    RedDKP.EnsureSaved()

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
-- EDIT BOX FOR MODIFYING FIELDS
--------------------------------------------------

local editBox = CreateFrame("EditBox", nil, dkpPanel, "InputBoxTemplate")
editBox:SetSize(120, 25)
editBox:SetPoint("BOTTOMLEFT", 10, 10)
editBox:SetAutoFocus(false)

--------------------------------------------------
-- FIELD DROPDOWN
--------------------------------------------------

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
-- APPLY EDIT BUTTON
--------------------------------------------------

local applyBtn = CreateFrame("Button", nil, dkpPanel, "UIPanelButtonTemplate")
applyBtn:SetSize(80, 25)
applyBtn:SetPoint("LEFT", fieldDropdown, "RIGHT", 10, 0)
applyBtn:SetText("Apply")

applyBtn:SetScript("OnClick", function()
    if not selectedPlayer then
        RedDKP.Print("No player selected.")
        return
    end
    if not RedDKP.IsAuthorized() then
        RedDKP.Print("Only editors can modify DKP.")
        return
    end

    local val = tonumber(editBox:GetText())
    if not val then
        RedDKP.Print("Enter a number.")
        return
    end

    RedDKP.SetDKPField(selectedPlayer, selectedField, val)
    editBox:SetText("")
end)

--------------------------------------------------
-- DELETE BUTTON
--------------------------------------------------

local deleteBtn = CreateFrame("Button", nil, dkpPanel, "UIPanelButtonTemplate")
deleteBtn:SetSize(80, 25)
deleteBtn:SetPoint("LEFT", applyBtn, "RIGHT", 10, 0)
deleteBtn:SetText("Delete")

deleteBtn:SetScript("OnClick", function()
    if not selectedPlayer then
        RedDKP.Print("No player selected.")
        return
    end
    RedDKP.RequestDeletePlayer(selectedPlayer)
end)