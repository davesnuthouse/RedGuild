--==================================================================
-- BID LOG TAB
--==================================================================
-- Editors see every bid that was placed. Everyone else sees the
-- outcome of each auction plus their own bid, because that is all
-- their client ever received.
--==================================================================

local bidLogRows    = {}
local bidLogDetail  = {}
local bidLogSelected

local function BidLogIsEditor()
    return IsEditor(UnitName("player")) and true or false
end

local function BidLogStripLink(link)
    if not link then return "unknown item" end
    local name = link:match("|h%[(.-)%]|h")
    return name or link
end

--------------------------------------------------
-- Rows
--------------------------------------------------

local function CreateLogRow(index, parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(700, 16)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * 16))

    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints(row)
    row.hl:SetColorTexture(0.3, 0.5, 0.9, 0.35)
    row.hl:Hide()

    local function mk(x, w, justify)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", row, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(justify or "LEFT")
        return fs
    end

    row.whenText   = mk(4,    85)
    row.itemText   = mk(95,  250)
    row.winnerText = mk(350, 110)
    row.costText   = mk(465,  55, "RIGHT")
    row.modeText   = mk(528,  55)
    row.countText  = mk(588, 100, "RIGHT")

    row:SetScript("OnClick", function(self)
        bidLogSelected = self.entryIndex
        RedGuild_BidLog_Refresh()
    end)

    row:SetScript("OnEnter", function(self)
        if not self.itemLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.itemLink)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

local function CreateDetailRow(index, parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(700, 14)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * 14))

    local function mk(x, w, justify)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", row, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(justify or "LEFT")
        return fs
    end

    row.nameText   = mk(4,   130)
    row.bidText    = mk(140,  55, "RIGHT")
    row.modeText   = mk(203,  50)
    row.rollText   = mk(258,  50, "RIGHT")
    row.srcText    = mk(316,  70)
    row.resultText = mk(392, 160)

    return row
end

--------------------------------------------------
-- Panel
--------------------------------------------------

function RedGuild_BidLog_Build()
    if not bidLogPanel or bidLogPanel.built then return end
    local p = bidLogPanel

    ----------------------------------------------------------------
    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", p, "TOPLEFT", 25, -42)
    title:SetText("Bid Log")

    p.subText = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.subText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)

    ----------------------------------------------------------------
    -- Bidding button, editors only
    ----------------------------------------------------------------
    local bidBtn = CreateFrame("Button", "RedGuildBidLogBiddingButton", p, "UIPanelButtonTemplate")
    bidBtn:SetSize(80, 20)
    bidBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -45, -42)
    bidBtn:SetText("Bidding")
    bidBtn:SetScript("OnClick", RedGuild_Auction_ShowMaster)
    bidBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("|cffffff00Item Bidding|r")
        GameTooltip:AddLine("Post an item and collect DKP bids from the raid.", 1, 1, 1)
        GameTooltip:Show()
    end)
    bidBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    auctionLogButton = bidBtn

    local clearBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    clearBtn:SetSize(80, 20)
    clearBtn:SetPoint("RIGHT", bidBtn, "LEFT", -6, 0)
    clearBtn:SetText("Clear log")
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Show("REDGUILD_CLEAR_BIDLOG")
    end)
    p.clearBtn = clearBtn

    ----------------------------------------------------------------
    -- Column headers
    ----------------------------------------------------------------
    local head = CreateFrame("Frame", nil, p)
    head:SetPoint("TOPLEFT", p, "TOPLEFT", 25, -88)
    head:SetSize(700, 14)

    local function hdr(parent, x, w, text, justify)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", parent, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(justify or "LEFT")
        fs:SetText(text)
        return fs
    end
    hdr(head, 4,    85, "When")
    hdr(head, 95,  250, "Item")
    hdr(head, 350, 110, "Awarded to")
    hdr(head, 465,  55, "Cost", "RIGHT")
    hdr(head, 528,  55, "Type")
    hdr(head, 588, 100, "Bids", "RIGHT")

    ----------------------------------------------------------------
    -- Auction list
    ----------------------------------------------------------------
    local scroll = CreateFrame("ScrollFrame", "RedGuildBidLogScroll", p, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -45, 205)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(700, 16)
    scroll:SetScrollChild(child)
    p.listChild = child

    p.emptyText = p:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    p.emptyText:SetPoint("CENTER", scroll, "CENTER", 0, 0)
    p.emptyText:SetText("No bidding recorded yet.")
    p.emptyText:Hide()

    ----------------------------------------------------------------
    -- Detail pane
    ----------------------------------------------------------------
    p.detailTitle = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.detailTitle:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, -10)
    p.detailTitle:SetText("Select an auction above")

    local dhead = CreateFrame("Frame", nil, p)
    dhead:SetPoint("TOPLEFT", p.detailTitle, "BOTTOMLEFT", 0, -4)
    dhead:SetSize(700, 14)
    hdr(dhead, 4,   130, "Bidder")
    hdr(dhead, 140,  55, "Bid", "RIGHT")
    hdr(dhead, 203,  50, "Type")
    hdr(dhead, 258,  50, "Roll", "RIGHT")
    hdr(dhead, 316,  70, "Via")
    hdr(dhead, 392, 160, "Result")
    p.detailHead = dhead

    local dscroll = CreateFrame("ScrollFrame", "RedGuildBidLogDetailScroll", p, "UIPanelScrollFrameTemplate")
    dscroll:SetPoint("TOPLEFT", dhead, "BOTTOMLEFT", 0, -4)
    dscroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -45, 40)

    local dchild = CreateFrame("Frame", nil, dscroll)
    dchild:SetSize(700, 14)
    dscroll:SetScrollChild(dchild)
    p.detailChild = dchild

    p.built = true
end

--------------------------------------------------
-- Refresh
--------------------------------------------------

function RedGuild_BidLog_Refresh()
    if not bidLogPanel then return end
    RedGuild_BidLog_Build()
    if not bidLogPanel:IsShown() then return end

    local p        = bidLogPanel
    local log      = (RedGuild_Config and RedGuild_Config.bidLog) or {}
    local isEditor = BidLogIsEditor()

    ----------------------------------------------------------------
    -- Editor-only controls
    ----------------------------------------------------------------
    if isEditor then
        auctionLogButton:Show()
        p.clearBtn:Show()
        p.subText:SetText("Every bid placed in each auction.")
    else
        auctionLogButton:Hide()
        p.clearBtn:Hide()
        p.subText:SetText("Items awarded, and the bids you placed yourself.")
    end

    ----------------------------------------------------------------
    -- Auction list
    ----------------------------------------------------------------
    local shown = math.min(#log, 250)
    p.emptyText:SetShown(shown == 0)

    for i = 1, shown do
        local e   = log[i]
        local row = bidLogRows[i]
        if not row then
            row = CreateLogRow(i, p.listChild)
            bidLogRows[i] = row
        end

        row.entryIndex = i
        row.itemLink   = e.item

        row.whenText:SetText("|cff888888" .. (e.when or "") .. "|r")

        -- A multi-copy item writes one row per copy, so each says
        -- which one it was.
        local itemLabel = e.item or "unknown item"
        if e.qty and e.copy then
            itemLabel = string.format("%s |cff888888(%d/%d)|r", itemLabel, e.copy, e.qty)
        elseif e.qty then
            itemLabel = string.format("%s |cff888888(x%d)|r", itemLabel, e.qty)
        end
        row.itemText:SetText(itemLabel)

        if e.cancelled then
            row.winnerText:SetText("|cffff5555cancelled|r")
            row.costText:SetText("|cff888888-|r")
            row.modeText:SetText("")
        else
            row.winnerText:SetText(e.winner or "|cff888888-|r")
            row.costText:SetText(tostring(e.cost or 0))
            local modeColour = (e.mode == "OS") and "|cff55ccff" or "|cffffffff"
            row.modeText:SetText(modeColour ..
                (e.rollOnly and "ROLL" or (e.mode or "")) .. "|r")
        end

        -- An editor's entry holds the whole book, so the count is real.
        -- A player's entry only ever holds their own bid, so showing a
        -- number there would be misleading.
        if e.full then
            row.countText:SetText("|cff888888" .. #(e.bids or {}) .. "|r")
        elseif e.bids and #e.bids > 0 then
            row.countText:SetText("|cff888888you bid|r")
        else
            row.countText:SetText("")
        end

        row.hl:SetShown(bidLogSelected == i)
        row:Show()
    end

    for i = shown + 1, #bidLogRows do
        bidLogRows[i]:Hide()
    end
    p.listChild:SetHeight(math.max(1, shown * 16))

    ----------------------------------------------------------------
    -- Detail pane
    ----------------------------------------------------------------
    local entry = bidLogSelected and log[bidLogSelected] or nil

    if not entry then
        p.detailTitle:SetText("Select an auction above")
        for _, r in ipairs(bidLogDetail) do r:Hide() end
        p.detailChild:SetHeight(1)
        return
    end

    if entry.cancelled then
        p.detailTitle:SetText(string.format("%s  |cffff5555cancelled|r",
            BidLogStripLink(entry.item)))
    else
        p.detailTitle:SetText(string.format(
            "%s%s  won by |cffffff00%s|r for |cffffff00%d|r DKP  (%s, run by %s)",
            BidLogStripLink(entry.item),
            (entry.qty and entry.copy)
                and string.format(" |cff888888copy %d of %d|r", entry.copy, entry.qty)
                or "",
            entry.winner or "nobody", entry.cost or 0,
            entry.rollOnly and "roll only" or (entry.mode or "?"), entry.ml or "?"))
    end

    local bids = entry.bids or {}
    for i = 1, #bids do
        local b   = bids[i]
        local row = bidLogDetail[i]
        if not row then
            row = CreateDetailRow(i, p.detailChild)
            bidLogDetail[i] = row
        end

        row.nameText:SetText(b.name or "?")
        row.bidText:SetText((b.mode == "PASS") and "|cff888888-|r" or tostring(b.amount or 0))

        local modeColour = "|cffffffff"
        if b.mode == "OS"   then modeColour = "|cff55ccff" end
        if b.mode == "PASS" then modeColour = "|cff888888" end
        row.modeText:SetText(modeColour .. (b.mode or "") .. "|r")

        row.rollText:SetText(b.roll and tostring(b.roll) or "")
        row.srcText:SetText("|cff888888" .. (b.src or "") .. "|r")

        if entry.winner and b.name == entry.winner then
            row.resultText:SetText("|cff00ff00won the item|r")
        elseif b.won then
            -- Took one of the other copies of the same item.
            row.resultText:SetText("|cff888888won another copy|r")
        else
            row.resultText:SetText("")
        end

        row:Show()
    end

    for i = #bids + 1, #bidLogDetail do
        bidLogDetail[i]:Hide()
    end
    p.detailChild:SetHeight(math.max(1, #bids * 14))

    if #bids == 0 and not entry.cancelled and not entry.full then
        p.detailTitle:SetText(p.detailTitle:GetText() .. "   |cff888888(you did not bid)|r")
    end
end

StaticPopupDialogs["REDGUILD_CLEAR_BIDLOG"] = {
    text = "Clear your entire bid log?\n\nThis only clears your own copy.",
    button1 = "Clear",
    button2 = "Cancel",
    OnAccept = function()
        RedGuild_Config.bidLog = {}
        bidLogSelected = nil
        RedGuild_BidLog_Refresh()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
