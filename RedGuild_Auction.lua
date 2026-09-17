--==================================================================
-- DKP BIDDING / AUCTION
--==================================================================
-- Editor posts an item -> raid members get a prompt showing their
-- current DKP where they can bid, roll off-spec, or pass.
-- Players without the addon can whisper the auctioneer:
--     !bid 50        place a main-spec bid of 50
--     !os            declare off-spec, then /roll 69 (flat 5 DKP if won)
--     !pass          pass on the item
--     !dkp           check balance
-- The editor sees every bid and awards the item MANUALLY.
--
-- Two shapes of auction beyond the plain one:
--   * COPIES - the same item dropped more than once (two tier tokens
--     off one boss). One auction is posted for all of them, everybody
--     sees "2x <item>", and the editor awards it once per copy. The
--     book is kept between awards, and a winner is flagged so they
--     cannot be handed a second copy by accident.
--   * ROLL ONLY - recipes and the like, where DKP is not spent at all.
--     The bid box is not even offered, whispered bids are taken as
--     roll declarations, and the award always costs 0 DKP.
--==================================================================

local AUCTION_DEFAULT_DURATION = 30
-- Smallest main-spec bid the addon will accept.
local AUCTION_MIN_BID          = 10
local AUCTION_MAX_ROWS         = 60

-- Runtime only. Deliberately not a SavedVariable: an auction should
-- never survive a /reload or a disconnect.
RedGuild_Auction = {
    open       = false,   -- accepting bids right now
    preparing  = false,   -- syncing DKP, bidding opens once that is out
    posted     = false,   -- an item is posted (may be closed but not yet awarded)
    dkpVersion = nil,     -- DKP version the auctioneer posted with
    id         = nil,
    itemLink   = nil,
    itemID     = nil,
    ml         = nil,     -- auctioneer (short name)
    duration   = AUCTION_DEFAULT_DURATION,
    endTime    = nil,
    qty        = 1,       -- copies of the item up in this auction
    awarded    = 0,       -- copies already handed out
    rollOnly   = false,   -- roll-only item: no DKP bids at all
    paused     = false,
    myBid      = nil,     -- what this client submitted, for the log
    remaining  = nil,   -- seconds frozen on the clock while paused
    ticker     = nil,
    bids       = {},      -- [character] = { name, key, amount, mode, src, roll, at }
    selected   = nil,
}

local auctionMaster      -- editor window
local auctionButton      -- Bidding button on the DKP tab
local AUCTION_LOG_MAX    = 250

--------------------------------------------------
-- Bid log
--------------------------------------------------
-- Kept inside RedGuild_Config, which is already a SavedVariable and
-- is never serialised into a sync payload, so the .toc needs no new
-- entry and the log never inflates addon messages.
--
-- Each client records only what it legitimately saw. The auctioneer
-- receives every bid, so an editor logs the full book. Everyone else
-- only ever sees the award broadcast plus whatever they sent
-- themselves, so that is exactly what their log holds.
local function EnsureBidLog()
    RedGuild_Config.bidLog = RedGuild_Config.bidLog or {}
    return RedGuild_Config.bidLog
end

function RedGuild_BidLog_Add(entry)
    local log = EnsureBidLog()
    table.insert(log, 1, entry)      -- newest first
    while #log > AUCTION_LOG_MAX do
        table.remove(log)
    end
    if RedGuild_BidLog_Refresh then RedGuild_BidLog_Refresh() end
end

-- Snapshot of the current auction, from the point of view of
-- whoever is running this client.
local function BuildLogEntry(winner, cost, mode, cancelled, copy)
    local bids = {}

    if RedGuild_Auction_IsAuctioneer() then
        for _, b in ipairs(RedGuild_Auction_SortedBids()) do
            table.insert(bids, {
                name    = b.name,
                amount  = b.amount,
                mode    = b.mode,
                roll    = b.roll,
                tieRoll = b.tieRoll,
                src     = b.src,
                -- Set on a multi-copy item once this bidder has taken
                -- one, so the detail pane can say so.
                won     = b.won or nil,
            })
        end
    elseif RedGuild_Auction.myBid then
        table.insert(bids, RedGuild_Auction.myBid)
    end

    return {
        t         = time(),
        when      = date("%d.%m %H:%M"),
        item      = RedGuild_Auction.itemLink,
        ml        = RedGuild_Auction.ml,
        winner    = winner,
        cost      = cost or 0,
        mode      = mode,
        cancelled = cancelled or nil,
        -- A multi-copy item writes one entry per copy, so each row can
        -- say which of them it was.
        qty       = ((tonumber(RedGuild_Auction.qty) or 1) > 1)
                    and (tonumber(RedGuild_Auction.qty) or 1) or nil,
        copy      = copy,
        rollOnly  = RedGuild_Auction.rollOnly or nil,
        full      = RedGuild_Auction_IsAuctioneer() or nil,
        bids      = bids,
    }
end
local auctionPrompt      -- bidder popup
local auctionTiePrompt   -- tie-roll popup
local auctionMasterRows = {}

--------------------------------------------------
-- Roll pattern (locale safe)
--------------------------------------------------
local RedGuild_RollPattern
do
    local p = RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
    -- escape the literal magic characters first
    p = p:gsub("%(", "%%(")
    p = p:gsub("%)", "%%)")
    p = p:gsub("%-", "%%-")
    p = p:gsub("%.", "%%.")
    -- then turn the format specifiers into captures
    p = p:gsub("%%s", "(.+)")
    p = p:gsub("%%d", "(%%d+)")
    RedGuild_RollPattern = p
end

--------------------------------------------------
-- Small helpers
--------------------------------------------------

local function AuctionPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff8800[RedGuild Bid]|r " .. tostring(msg))
end

-- The character who bids is the character who pays. Alt/main linking
-- is deliberately NOT applied here: an alt bids with the alt's own DKP
-- and the alt's own record is charged.
function RedGuild_Auction_Bidder(name)
    if not name then return nil end
    return Ambiguate(name, "short")
end

-- Returns balance, character. The balance belongs to the character
-- that is bidding, not to any linked main. Recalculated so it is
-- never stale.
function RedGuild_Auction_GetBalance(name)
    local who = RedGuild_Auction_Bidder(name)
    if not who then return 0, nil end

    local d = RedGuild_Data and RedGuild_Data[who]
    if not d then return 0, who end

    local bal = (d.lastWeek or 0) + (d.onTime or 0) + (d.bench or 0) - (d.spent or 0)
    if bal > 300 then bal = 300 end
    return bal, who
end

function RedGuild_Auction_TimeLeft()
    if RedGuild_Auction.paused then
        return math.max(0, math.ceil(RedGuild_Auction.remaining or 0))
    end
    return math.max(0, math.ceil((RedGuild_Auction.endTime or 0) - GetTime()))
end

--------------------------------------------------
-- Class/armor usability
--------------------------------------------------
-- Which armor subclass IDs (under itemClassID 4, Armor) each class can
-- wear. IDs rather than itemSubType strings, since the latter comes
-- back localized from GetItemInfo and would silently misbehave on a
-- non-English client. 1=Cloth 2=Leather 3=Mail 4=Plate 6=Shields -
-- Blizzard's own Enum.ItemArmorSubclass values, stable across clients.
local function ArmorSet(...)
    local s = {}
    for _, v in ipairs({...}) do s[v] = true end
    return s
end

local ARMOR_PROFICIENCY = {
    WARRIOR     = ArmorSet(1, 2, 3, 4, 6),
    PALADIN     = ArmorSet(1, 2, 3, 4, 6),
    DEATHKNIGHT = ArmorSet(1, 2, 3, 4),
    HUNTER      = ArmorSet(1, 2, 3),
    SHAMAN      = ArmorSet(1, 2, 3, 6),
    ROGUE       = ArmorSet(1, 2),
    DRUID       = ArmorSet(1, 2),
    PRIEST      = ArmorSet(1),
    MAGE        = ArmorSet(1),
    WARLOCK     = ArmorSet(1),
}

-- Only these slots are actually gated by armor-type proficiency.
-- Notably NOT here: INVTYPE_CLOAK - back-slot items carry itemSubType
-- "Cloth" too, but every class can wear any cloak regardless, so
-- checking it here would wrongly flag a warrior's own cloak as
-- unusable. Rings, necks, trinkets, weapons, and relics aren't
-- proficiency-gated this way either, so they are left alone too.
local ARMOR_PROFICIENCY_SLOTS = ArmorSet(
    "INVTYPE_HEAD", "INVTYPE_SHOULDER", "INVTYPE_CHEST", "INVTYPE_ROBE",
    "INVTYPE_WAIST", "INVTYPE_LEGS", "INVTYPE_FEET", "INVTYPE_WRIST",
    "INVTYPE_HAND", "INVTYPE_SHIELD"
)

-- True unless the posted item is armor of a type the bidder's class
-- cannot wear (a priest looking at plate, a mage looking at a
-- shield). Weapon proficiency is deliberately not covered - unlike
-- armor type, it has enough class/talent/quest exceptions that a
-- hardcoded table would risk wrongly blocking a valid roll, which is
-- worse than not checking at all. Fails open (usable) whenever the
-- item info isn't cached yet or the slot isn't proficiency-gated, so
-- this only ever narrows bidding, never blocks something it shouldn't.
function RedGuild_Auction_ItemUsableByMe()
    local link = RedGuild_Auction.itemLink
    if not link then return true end

    local _, _, _, _, _, _, _, _, equipLoc, _, _, classID, subClassID = GetItemInfo(link)
    if not equipLoc then return true end
    if not ARMOR_PROFICIENCY_SLOTS[equipLoc] then return true end
    if classID ~= 4 then return true end

    local _, classToken = UnitClass("player")
    local allowed = ARMOR_PROFICIENCY[classToken]
    if not allowed then return true end

    return allowed[subClassID] == true
end

-- The auctioneer stamps every BID_START with the DKP version it was
-- posted under. Anything lower locally means the balance on screen is
-- not the one being bid against yet.
function RedGuild_Auction_DKPStale()
    local want = tonumber(RedGuild_Auction.dkpVersion or 0) or 0
    if want <= 0 then return false end
    return (tonumber(RedGuild_Config.dkpVersion or 0) or 0) < want
end

-- True while a DKP DATA transfer is actually being received right
-- now - not just "our version happens to be behind", but chunks
-- genuinely arriving. The one that matters here is the broadcast
-- RedGuild_Auction_PushSyncAfterClose sends the moment the previous
-- item's bidding closes; this only reports whether it (or any other
-- DATA sync) is currently in flight.
function RedGuild_Auction_SyncInProgress()
    local bucket = REDGUILD_Inbound and REDGUILD_Inbound.DATA
    if not bucket then return false end
    return next(bucket) ~= nil
end

-- What the bid prompt's balance line should show: "syncing..." only
-- while the table is genuinely stale AND a sync is actually incoming
-- (from the previous item's close), for at most 10 seconds - past
-- that, or once nothing is really coming, the real balance is shown
-- even if it may still be out of date, rather than leaving the
-- prompt stuck reading "syncing..." for the whole auction.
function RedGuild_Auction_ShowSyncingBalance()
    if not RedGuild_Auction_DKPStale() then return false end

    local elapsed = GetTime() - (RedGuild_Auction.staleSince or GetTime())
    if elapsed >= 10 then return false end

    return RedGuild_Auction_SyncInProgress()
end

function RedGuild_Auction_IsOpen()
    return RedGuild_Auction.open == true
end

-- True when we are the person running the current auction.
function RedGuild_Auction_IsAuctioneer()
    if not RedGuild_Auction.ml then return false end
    return NormalizeName(RedGuild_Auction.ml) == NormalizeName(UnitName("player"))
end

-- "2x [Item]" while more than one copy is up, the plain link
-- otherwise. Used everywhere the item is named so the raid always
-- sees how many are going out.
function RedGuild_Auction_ItemLabel()
    local link = RedGuild_Auction.itemLink or "the item"
    local qty  = tonumber(RedGuild_Auction.qty) or 1
    if qty > 1 then
        return string.format("%dx %s", qty, link)
    end
    return link
end

-- Copies still to hand out on the item that is posted.
function RedGuild_Auction_Remaining()
    local qty = tonumber(RedGuild_Auction.qty) or 1
    return math.max(0, qty - (RedGuild_Auction.awarded or 0))
end

function RedGuild_Auction_IsRollOnly()
    return RedGuild_Auction.rollOnly == true
end

local function AuctionChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function AuctionAnnounce(msg)
    local chan = AuctionChannel()
    if not chan then return end
    SendChatMessage(msg, chan)
end

-- Raid warning for the things people must not miss. RAID_WARNING is
-- silently dropped for anyone who is not lead or assist, so fall
-- back to plain raid chat rather than losing the message.
local function AuctionWarn(msg)
    if IsInRaid() and (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then
        SendChatMessage(msg, "RAID_WARNING")
        return
    end
    AuctionAnnounce(msg)
end

local function AuctionWhisper(target, msg)
    if not target or target == "" then return end
    SendChatMessage(msg, "WHISPER", nil, Ambiguate(target, "none"))
end

--------------------------------------------------
-- EASTER EGGS
--------------------------------------------------
-- Whispered to whoever earned them. Each one lands at most once per
-- person per item - the same joke eleven times in a row stops being
-- one - but a player who rolls a 1 and later a 69 gets both, so the
-- de-duplication is per quip rather than per person.
AUCTION_NICE_NUMBER = REDGUILD_NICE_NUMBER or 69

-- The answer to the Ultimate Question of Life, the Universe, and
-- Everything (Adams), which people do notice when it comes up.
local AUCTION_ANSWER_NUMBER = 42

-- Picks the line for a roll, or nil for the overwhelming majority of
-- rolls that are just numbers. Returns the quip and a stable kind,
-- which is what the once-per-item check keys off.
--
-- Pure, and deliberately separate from the whispering, so the rules
-- can be tested without a chat channel.
function RedGuild_Auction_RollQuip(roll, low, high)
    roll, low, high = tonumber(roll), tonumber(low), tonumber(high)
    if not roll then return nil end

    if roll == AUCTION_NICE_NUMBER then
        return string.format("%d, nice!", AUCTION_NICE_NUMBER), "nice"
    end

    -- Checked before the max-roll line so a 1-1 roll reads as the joke
    -- it is rather than as a triumph.
    if low and roll == low and high and high > low then
        return string.format("A %d. Are you even trying?", roll), "min"
    end

    if high and roll == high and low and high > low then
        return string.format("%d. Max roll - that is the best it gets.", roll), "max"
    end

    if roll == AUCTION_ANSWER_NUMBER then
        return string.format(
            "%d. The answer to life, the universe, and everything.",
            AUCTION_ANSWER_NUMBER), "answer"
    end

    return nil
end

-- Sends one, at most once per person per item.
function RedGuild_Auction_Quip(who, msg, kind)
    if not who or not msg then return end

    RedGuild_Auction.niced = RedGuild_Auction.niced or {}

    local key = NormalizeName(who)
    if not key then return end

    local seen = key .. "\001" .. tostring(kind or msg)
    if RedGuild_Auction.niced[seen] then return end
    RedGuild_Auction.niced[seen] = true

    -- Whispering yourself goes nowhere, so the auctioneer gets it in
    -- their own chat frame instead.
    if key == NormalizeName(UnitName("player")) then
        AuctionPrint(msg)
    else
        AuctionWhisper(who, msg)
    end
end

local function ClassColour(name)
    local who = RedGuild_Auction_Bidder(name)
    local d = RedGuild_Data and RedGuild_Data[who]
    local class = d and d.class
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
    return "|cffffffff"
end

--------------------------------------------------
-- Bid book
--------------------------------------------------

-- Pushes a fresh full DKP broadcast once every copy of the posted
-- item has been awarded - called only from RedGuild_Auction_Award's
-- final copy. Bidding merely closing (RedGuild_Auction_Stop) no
-- longer triggers this: nothing has actually changed yet at that
-- point, since DKP is only spent on award, so a push there was just
-- traffic for no new data.
function RedGuild_Auction_PushSyncAfterClose()
    if RedGuild_SyncLocked then return end
    if RedGuild_Config.bidSyncEnabled == false then return end
    if not RedGuild_Auction_IsAuctioneer() then return end

    D("AUCTION SYNC (all copies awarded) - broadcasting current DKP table")
    local payload = BuildSyncPayload()
    local encoded = EncodePayload(payload)
    RedGuild_Send("DATA", encoded, "GUILD")
end

-- Wipes the book and everything that describes the item that was up.
-- Start and BID_START both call this before setting the new item's
-- copy count and roll-only flag, so a fresh auction never inherits
-- them from the last one.
local function AuctionResetBook()
    RedGuild_Auction.bids        = {}
    RedGuild_Auction.selected    = nil
    RedGuild_Auction.tieSelected = {}
    RedGuild_Auction.awarded     = 0
    RedGuild_Auction.qty         = 1
    RedGuild_Auction.rollOnly    = false
    RedGuild_Auction.niced       = {}
end

-- Sorted view of the bid book: main-spec bids by DKP desc, then
-- off-spec rollers by roll desc, then passes. Sorting is purely
-- cosmetic; awarding is always manual.
function RedGuild_Auction_SortedBids()
    local list = {}
    for _, b in pairs(RedGuild_Auction.bids) do
        table.insert(list, b)
    end

    local rank = { MS = 1, OS = 2, PASS = 3 }
    table.sort(list, function(a, b)
        -- On a multi-copy item, whoever already took one sits at the
        -- top of the list, clear of the bidders still in the running.
        local wa, wb = a.won and 0 or 1, b.won and 0 or 1
        if wa ~= wb then return wa < wb end

        local ra, rb = rank[a.mode] or 9, rank[b.mode] or 9
        if ra ~= rb then return ra < rb end

        -- A tie roll is the whole point of being in one, so once both
        -- sides have rolled it settles the order between them before
        -- anything else does.
        if a.tieRoll and b.tieRoll and a.tieRoll ~= b.tieRoll then
            return a.tieRoll > b.tieRoll
        end

        if a.mode == "OS" and b.mode == "OS" then
            if (a.roll or 0) ~= (b.roll or 0) then
                return (a.roll or 0) > (b.roll or 0)
            end
        end
        -- On a roll-only item, main-spec is a "need" roll too, not a
        -- DKP amount - amount is always 0 for every bidder, so the
        -- tiebreaker that actually matters is the roll itself.
        if RedGuild_Auction.rollOnly and a.mode == "MS" and b.mode == "MS" then
            if (a.roll or 0) ~= (b.roll or 0) then
                return (a.roll or 0) > (b.roll or 0)
            end
        end
        if (a.amount or 0) ~= (b.amount or 0) then
            return (a.amount or 0) > (b.amount or 0)
        end
        return (a.at or 0) < (b.at or 0)
    end)

    return list
end

-- Tie rolls are picked by hand: the auctioneer ticks whoever should
-- roll off in the bid list and presses Tie Roll. Nothing here is
-- automatic, and nothing here disturbs the bids already on the book -
-- a tie roll is recorded alongside the original bid or roll, never
-- over the top of it, so the editor can still see what everybody
-- actually bid when deciding.
AUCTION_TIE_ROLL_MAX = 100

-- Sends the selected bidders a roll prompt. Returns how many were
-- asked, so the caller can report it.
function RedGuild_Auction_TriggerTieRoll()
    if not RedGuild_Auction_IsAuctioneer() then
        AuctionPrint("Only the auctioneer running this auction can trigger a tie roll.")
        return 0
    end
    if not RedGuild_Auction.posted then
        AuctionPrint("No item is posted.")
        return 0
    end

    local names = {}
    for key, selected in pairs(RedGuild_Auction.tieSelected or {}) do
        local bid = selected and RedGuild_Auction.bids[key]
        if bid then
            table.insert(names, bid.name or key)

            -- Only the tie-roll fields are touched. bid.roll and
            -- bid.amount stay exactly as they were.
            bid.tieRoll       = nil
            bid.tieRollWarned = nil
            bid.tiePassed     = nil
            bid.tieRollWant   = AUCTION_TIE_ROLL_MAX
        end
    end

    if #names < 1 then
        AuctionPrint("Tick the bidders who should roll off first.")
        return 0
    end

    table.sort(names)

    RedGuild_Send("BID_TIEROLL", EncodePayload({
        id    = RedGuild_Auction.id,
        names = names,
        range = AUCTION_TIE_ROLL_MAX,
    }))

    -- The auctioneer never receives their own addon messages - the
    -- CHAT_MSG_ADDON handler drops anything it sent itself - so an
    -- auctioneer who is in the tie has to be prompted directly, the
    -- same way BID_START and BID_REOPEN open their own prompt. It
    -- also means the tie roll works when testing outside a group,
    -- where there is no RAID or PARTY channel to send on at all.
    local me = NormalizeName(UnitName("player"))
    for _, n in ipairs(names) do
        if NormalizeName(n) == me then
            RedGuild_Auction_ShowTieRollPrompt(AUCTION_TIE_ROLL_MAX)
            break
        end
    end

    AuctionWarn(string.format(
        "TIE ROLL on %s - %s, roll off now (1-%d).",
        RedGuild_Auction_ItemLabel(), table.concat(names, ", "),
        AUCTION_TIE_ROLL_MAX))

    RedGuild_Auction_RefreshMaster()
    return #names
end

-- Editor side. Records or replaces a bid. src is "addon" or "whisper".
-- Once bidding has closed but the item has not yet been awarded, a
-- bid is still accepted rather than rejected outright - it is just
-- flagged as late so the editor can see it missed the window and can
-- decide whether it still counts.
-- Returns true, isLate on success; false, errorMessage on failure.
function RedGuild_Auction_RecordBid(player, amount, mode, src, roll)
    if not RedGuild_Auction.posted then return false, "No item is posted." end
    if not player then return false, "No player." end

    player = Ambiguate(player, "short")
    local bal, who = RedGuild_Auction_GetBalance(player)
    if not who then return false, "Could not resolve name." end

    mode   = mode or "MS"
    amount = tonumber(amount) or 0

    -- A roll-only item has no DKP side at all: main spec ("need") and
    -- off spec ("greed") are both dice rolls there, never a DKP bid,
    -- so mode is kept as given (not coerced to OS) and no amount ever
    -- survives. Off spec elsewhere is decided purely by the roll too.
    if RedGuild_Auction.rollOnly then
        amount = 0
    elseif mode ~= "MS" then
        amount = 0
    end

    if mode == "MS" and not RedGuild_Auction.rollOnly then
        if amount < AUCTION_MIN_BID then
            return false, string.format(
                "Main-spec bids must be at least %d DKP.", AUCTION_MIN_BID)
        end
        if amount > bal then
            return false, string.format("Bid of %d exceeds your balance of %d DKP.", amount, bal)
        end
    end

    local existing = RedGuild_Auction.bids[who]

    -- Somebody who already took a copy of a multi-copy item is out of
    -- the running for the rest, and their award record must not be
    -- overwritten by a later bid.
    if existing and existing.won then
        return false, "You already received a copy of this item."
    end

    -- Keep a previous roll only if the bidder has not switched
    -- between main-spec and off-spec since rolling.
    local keptRoll = nil
    if existing and existing.mode == mode then
        keptRoll = existing.roll
    end

    local isLate = not RedGuild_Auction.open

    RedGuild_Auction.bids[who] = {
        name   = player,
        key    = who,
        amount = amount,
        mode   = mode,
        src    = src or "addon",
        roll   = roll or keptRoll or nil,
        bal    = bal,
        late   = isLate or nil,
        at     = existing and existing.at or GetTime(),
    }

    if amount == AUCTION_NICE_NUMBER then
        RedGuild_Auction_Quip(player,
            string.format("%d, nice!", AUCTION_NICE_NUMBER), "nice")
    elseif amount > 0 and amount == bal then
        RedGuild_Auction_Quip(player,
            "That is every point you have. No pressure.", "allin")
    end

    RedGuild_Auction_RefreshMaster()
    return true, isLate
end

--------------------------------------------------
-- Editor: start / stop / cancel / award
--------------------------------------------------

-- Loads an item into the slot. Never starts an auction.
function RedGuild_Auction_ApplyItem(link, qty)
    if not link then return end
    local name, itemLink, _, _, _, _, _, _, _, icon = GetItemInfo(link)
    itemLink = itemLink or link

    RedGuild_Auction.itemLink = itemLink
    RedGuild_Auction.itemID   = tonumber(itemLink:match("item:(%d+)"))

    if auctionMaster then
        -- The loot window knows when the same item is sitting in more
        -- than one slot, so the copy count is pre-filled from there.
        -- It is only a suggestion; the editor can still change it.
        if qty and auctionMaster.qtyBox then
            auctionMaster.qtyBox:SetText(tostring(math.max(1, tonumber(qty) or 1)))
        end
        auctionMaster.itemText:SetText(itemLink)
        auctionMaster.itemIcon:SetTexture(icon or (RedGuild_Auction.itemID and GetItemIcon(RedGuild_Auction.itemID)) or "Interface\\Icons\\INV_Misc_QuestionMark")
    end
end

-- Public entry point used by the drop slot, the link box and the
-- shift-click hook. While an item is already posted, swapping is
-- confirmed first so a stray drag cannot silently replace the item
-- the raid is bidding on. Swapping never starts a new auction.
function RedGuild_Auction_SetItem(link, qty)
    if not link then return end

    if RedGuild_Auction.posted then
        RedGuild_Auction.pendingSwap    = link
        RedGuild_Auction.pendingSwapQty = qty
        StaticPopup_Show("REDGUILD_BID_SWAP_ITEM")
        return
    end

    RedGuild_Auction_ApplyItem(link, qty)
end

StaticPopupDialogs["REDGUILD_BID_SWAP_ITEM"] = {
    text = "Bidding is already running on this item.\n\nReplace it? The current auction is cancelled and all bids are discarded.\n\nThis does NOT start a new auction - press Post when you are ready.",
    button1 = "Replace item",
    button2 = "Keep bidding",
    OnAccept = function()
        local link = RedGuild_Auction.pendingSwap
        local qty  = RedGuild_Auction.pendingSwapQty
        RedGuild_Auction.pendingSwap    = nil
        RedGuild_Auction.pendingSwapQty = nil
        RedGuild_Auction_Cancel()
        if link then RedGuild_Auction_ApplyItem(link, qty) end
    end,
    OnCancel = function()
        RedGuild_Auction.pendingSwap    = nil
        RedGuild_Auction.pendingSwapQty = nil
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Shared ticker used by both a fresh Start and a Reopen: announces
-- the standard countdown warnings and auto-closes at zero.
local function AuctionStartTicker()
    if RedGuild_Auction.ticker then RedGuild_Auction.ticker:Cancel() end
    RedGuild_Auction.ticker = C_Timer.NewTicker(1, function()
        if not RedGuild_Auction.open then return end

        -- A paused auction keeps its clock frozen and announces
        -- nothing, but the window still redraws so the editor can
        -- see the held time.
        if RedGuild_Auction.paused then
            RedGuild_Auction_RefreshMaster()
            return
        end

        local left = math.ceil((RedGuild_Auction.endTime or 0) - GetTime())

        if left == 30 or left == 20 or left == 10 or left == 5 then
            AuctionWarn(string.format("%d seconds left %s %s",
                left,
                RedGuild_Auction.rollOnly and "to roll on" or "to bid on",
                RedGuild_Auction_ItemLabel()))
        end

        if left <= 0 then
            RedGuild_Auction_Stop(true)
        end
        RedGuild_Auction_RefreshMaster()
    end)
end

function RedGuild_Auction_Start()
    if not IsAuthorized() then
        AuctionPrint("Only editors can post items for bidding.")
        return
    end
    if not AuctionChannel() then
        AuctionPrint("You must be in a group or raid to post an item.")
        return
    end
    if not RedGuild_Auction.itemLink then
        AuctionPrint("Drag an item onto the window, or shift-click one into the box, first.")
        return
    end
    if RedGuild_Auction.open then
        AuctionPrint("Bidding is already open. Close it first.")
        return
    end
    if RedGuild_Auction.preparing then
        AuctionPrint("Bidding is already being prepared.")
        return
    end
    if RedGuild_Auction_SyncInProgress() then
        AuctionPrint("A DKP sync from the last item is still coming in - wait for it to finish before starting a new bid.")
        return
    end

    local dur = AUCTION_DEFAULT_DURATION
    if auctionMaster and auctionMaster.durBox then
        dur = tonumber(auctionMaster.durBox:GetText()) or AUCTION_DEFAULT_DURATION
    end
    if dur < 5   then dur = 5   end
    if dur > 300 then dur = 300 end

    -- How many of this item are going out. Two tier tokens off one
    -- boss are a single auction with two winners, not two auctions:
    -- everybody bids once and the editor awards twice.
    local qty = 1
    if auctionMaster and auctionMaster.qtyBox then
        qty = tonumber(auctionMaster.qtyBox:GetText()) or 1
    end
    if qty < 1  then qty = 1  end
    if qty > 40 then qty = 40 end

    -- Roll-only items (recipes, patterns) are decided purely on the
    -- roll and never touch DKP, so the bid box is never even offered.
    local rollOnly = false
    if auctionMaster and auctionMaster.rollOnlyCheck then
        rollOnly = auctionMaster.rollOnlyCheck:GetChecked() and true or false
    end

    RedGuild_Auction.preparing = false

    AuctionResetBook()

        RedGuild_Auction.id       = tostring(time()) .. "-" .. math.random(1000, 9999)
        RedGuild_Auction.ml       = Ambiguate(UnitName("player"), "short")
        RedGuild_Auction.duration = dur
        RedGuild_Auction.endTime  = GetTime() + dur
        RedGuild_Auction.paused   = false
        RedGuild_Auction.remaining = nil
        RedGuild_Auction.myBid    = nil
        RedGuild_Auction.open     = true
        RedGuild_Auction.posted   = true
        RedGuild_Auction.qty      = qty
        RedGuild_Auction.awarded  = 0
        RedGuild_Auction.rollOnly = rollOnly
        -- A roll-only item is not bid against any balance, so there is
        -- no version to be behind and the prompt never shows "syncing".
        RedGuild_Auction.dkpVersion = rollOnly and 0
            or (tonumber(RedGuild_Config.dkpVersion or 0) or 0)
        RedGuild_Auction.staleSince = GetTime()

        RedGuild_Send("BID_START", EncodePayload({
            id         = RedGuild_Auction.id,
            itemLink   = RedGuild_Auction.itemLink,
            itemID     = RedGuild_Auction.itemID,
            ml         = RedGuild_Auction.ml,
            duration   = dur,
            qty        = qty,
            rollOnly   = rollOnly or nil,
            -- Lets a client that still missed the push notice it is
            -- behind instead of bidding against a stale number.
            dkpVersion = RedGuild_Auction.dkpVersion,
        }))

        if rollOnly then
            AuctionWarn(string.format(
                "ROLL ONLY on %s - %d seconds. /roll 69, no DKP is charged.",
                RedGuild_Auction_ItemLabel(), dur))
            AuctionAnnounce(string.format(
                "No addon? Just /roll 69 - or whisper %s !os. There are no DKP bids on this one.",
                RedGuild_Auction.ml))
        else
            AuctionWarn(string.format(
                "Bidding OPEN on %s - %d seconds.", RedGuild_Auction_ItemLabel(), dur))
            AuctionAnnounce(string.format(
                "No addon? Whisper %s:  !bid <amount>  for main spec,  or just /roll 69 for off spec.  !pass to skip.",
                RedGuild_Auction.ml))
        end

        if qty > 1 then
            AuctionWarn(string.format(
                "%d copies are up - %d of you will be awarded one each. Bid once.",
                qty, qty))
        end

        -- The auctioneer never receives their own BID_START, so open
        -- the prompt for them directly. They bid on the same terms as
        -- anyone else, including the minimum and their own balance.
        RedGuild_Auction_ShowPrompt()

        AuctionStartTicker()

        RedGuild_Auction_RefreshMaster()
end

function RedGuild_Auction_Pause()
    if not RedGuild_Auction_IsAuctioneer() then return end
    if not RedGuild_Auction.open then
        AuctionPrint("No bidding is running.")
        return
    end
    if RedGuild_Auction.paused then return end

    RedGuild_Auction.remaining = math.max(0, (RedGuild_Auction.endTime or 0) - GetTime())
    RedGuild_Auction.paused    = true

    RedGuild_Send("BID_PAUSE", EncodePayload({
        id        = RedGuild_Auction.id,
        remaining = RedGuild_Auction.remaining,
    }))

    AuctionWarn(string.format(
        "Bidding PAUSED on %s with %d seconds left. You can still bid.",
        RedGuild_Auction.itemLink or "the item", RedGuild_Auction_TimeLeft()))

    RedGuild_Auction_RefreshMaster()
end

function RedGuild_Auction_Resume()
    if not RedGuild_Auction_IsAuctioneer() then return end
    if not RedGuild_Auction.open then return end
    if not RedGuild_Auction.paused then return end

    local left = math.max(1, RedGuild_Auction.remaining or 0)
    RedGuild_Auction.endTime   = GetTime() + left
    RedGuild_Auction.paused    = false
    RedGuild_Auction.remaining = nil

    RedGuild_Send("BID_RESUME", EncodePayload({
        id        = RedGuild_Auction.id,
        remaining = left,
    }))

    AuctionWarn(string.format("Bidding RESUMED on %s - %d seconds left.",
        RedGuild_Auction.itemLink or "the item", math.ceil(left)))

    RedGuild_Auction_RefreshMaster()
end

function RedGuild_Auction_TogglePause()
    if RedGuild_Auction.paused then
        RedGuild_Auction_Resume()
    else
        RedGuild_Auction_Pause()
    end
end

function RedGuild_Auction_Stop(auto)
    if not RedGuild_Auction.open then return end

    RedGuild_Auction.open      = false
    RedGuild_Auction.paused    = false
    RedGuild_Auction.remaining = nil
    if RedGuild_Auction.ticker then
        RedGuild_Auction.ticker:Cancel()
        RedGuild_Auction.ticker = nil
    end

    if RedGuild_Auction_IsAuctioneer() then
        RedGuild_Send("BID_STOP", EncodePayload({ id = RedGuild_Auction.id }))

        local count = 0
        for _, b in pairs(RedGuild_Auction.bids) do
            if b.mode ~= "PASS" then count = count + 1 end
        end

        local left = RedGuild_Auction_Remaining()
        AuctionWarn(string.format(
            "Bidding CLOSED on %s. %d bid%s received.%s Late bids are still accepted (and flagged LATE) until it is awarded.",
            RedGuild_Auction_ItemLabel(),
            count, count == 1 and "" or "s",
            ((tonumber(RedGuild_Auction.qty) or 1) > 1)
                and string.format(" %d copies still to award.", left) or ""))
    end

    RedGuild_Auction_RefreshMaster()
    -- The bidder window is deliberately left open (it now shows
    -- "Closed") rather than hidden, so a bid placed here after the
    -- close is still possible - RedGuild_Auction_SendBid records and
    -- reports it as late instead of rejecting it.
    StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")
end

-- Reopens bidding on the item that is currently posted but closed
-- (not yet cancelled or awarded), keeping every bid already on the
-- book. Late-flags on existing bids are cleared, since they are back
-- inside an open window.
function RedGuild_Auction_Reopen()
    if not IsAuthorized() then
        AuctionPrint("Only editors can reopen bidding.")
        return
    end
    if not RedGuild_Auction_IsAuctioneer() then
        AuctionPrint("Only the auctioneer running this auction can reopen it.")
        return
    end
    if not RedGuild_Auction.posted then
        AuctionPrint("No item is posted.")
        return
    end
    if RedGuild_Auction.open then
        AuctionPrint("Bidding is already open.")
        return
    end

    local dur = AUCTION_DEFAULT_DURATION
    if auctionMaster and auctionMaster.durBox then
        dur = tonumber(auctionMaster.durBox:GetText()) or AUCTION_DEFAULT_DURATION
    end
    if dur < 5   then dur = 5   end
    if dur > 300 then dur = 300 end

    for _, b in pairs(RedGuild_Auction.bids) do
        b.late = nil
    end

    RedGuild_Auction.duration  = dur
    RedGuild_Auction.endTime   = GetTime() + dur
    RedGuild_Auction.paused    = false
    RedGuild_Auction.remaining = nil
    RedGuild_Auction.open      = true

    RedGuild_Send("BID_REOPEN", EncodePayload({
        id       = RedGuild_Auction.id,
        duration = dur,
    }))

    AuctionWarn(string.format(
        "%s REOPENED on %s - %d seconds. Existing bids are kept.%s",
        RedGuild_Auction.rollOnly and "Rolling" or "Bidding",
        RedGuild_Auction_ItemLabel(), dur,
        ((tonumber(RedGuild_Auction.qty) or 1) > 1)
            and string.format(" %d copies left.", RedGuild_Auction_Remaining()) or ""))

    -- The auctioneer never receives their own BID_REOPEN, so refresh
    -- their own prompt directly, same as on a fresh Start.
    RedGuild_Auction_ShowPrompt()

    AuctionStartTicker()

    RedGuild_Auction_RefreshMaster()
end

function RedGuild_Auction_Cancel()
    RedGuild_Auction.preparing = false
    if not RedGuild_Auction.posted then return end

    if RedGuild_Auction_IsAuctioneer() then
        RedGuild_BidLog_Add(BuildLogEntry(nil, 0, nil, true))
        RedGuild_Send("BID_CANCEL", EncodePayload({ id = RedGuild_Auction.id }))
        AuctionWarn(string.format(
            "Bidding CANCELLED on %s. No DKP has been charged.",
            RedGuild_Auction_ItemLabel()))
    end

    if RedGuild_Auction.ticker then
        RedGuild_Auction.ticker:Cancel()
        RedGuild_Auction.ticker = nil
    end

    RedGuild_Auction.open      = false
    RedGuild_Auction.posted    = false
    RedGuild_Auction.paused    = false
    RedGuild_Auction.remaining = nil
    AuctionResetBook()

    RedGuild_Auction_RefreshMaster()
    if auctionPrompt then auctionPrompt:Hide() end
    RedGuild_Auction_HideTieRollPrompt()
    StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")
end

-- Manual award. Nothing here picks a winner automatically.
--
-- An item posted with more than one copy stays posted after an award:
-- the book keeps every other bid, the winner is flagged so they cannot
-- be handed a second copy, and the auction only closes for good once
-- the last copy has gone out.
function RedGuild_Auction_Award(winner, cost)
    if not IsAuthorized() then
        AuctionPrint("Only editors can award items.")
        return
    end
    if not winner then
        AuctionPrint("Select a bidder in the list first.")
        return
    end
    if not RedGuild_Auction.posted then
        AuctionPrint("No item is posted.")
        return
    end

    cost = tonumber(cost) or 0
    if cost < 0 then cost = 0 end
    -- A roll-only item never costs DKP, whatever is in the cost box.
    if RedGuild_Auction.rollOnly then cost = 0 end

    local who  = RedGuild_Auction_Bidder(winner)
    local link = RedGuild_Auction.itemLink or "item"

    local held = RedGuild_Auction.bids[who]
    if held and held.won then
        AuctionPrint(string.format(
            "%s already has a copy of this item. Pick somebody else.", who))
        return
    end

    if cost > 0 then
        local inGuild = IsNameInGuild(who)
        if not inGuild and not (RedGuild_Data and RedGuild_Data[who]) then
            AuctionPrint(string.format(
                "%s is not on the DKP table and not in the guild - no DKP charged. Award recorded in chat only.", who))
            cost = 0
        else
            local d   = EnsurePlayer(who)
            local old = d.spent or 0
            d.spent   = old + cost
            RecalcBalance(d)

            LogAudit(who, "spent", old, d.spent)
            LogAudit(who, "item won", "", string.format("%s (%d DKP)", link, cost))

            BumpDKPVersion()
            if UpdateTable then UpdateTable() end
            if UpdateSyncStatus then UpdateSyncStatus() end
        end
    end

    local bid  = RedGuild_Auction.bids[who]
    local mode = bid and bid.mode or "MS"
    local roll = bid and bid.roll

    local copies  = tonumber(RedGuild_Auction.qty) or 1
    RedGuild_Auction.awarded = (RedGuild_Auction.awarded or 0) + 1
    local copyIdx = math.min(RedGuild_Auction.awarded, copies)
    local left    = math.max(0, copies - RedGuild_Auction.awarded)

    -- Flagged rather than removed from the book, so the editor keeps
    -- seeing who took which copy for as long as the auction runs.
    if bid then
        bid.won     = true
        bid.wonCost = cost
        bid.wonCopy = copyIdx
    end

    RedGuild_BidLog_Add(BuildLogEntry(
        who, cost, mode, false, (copies > 1) and copyIdx or nil))

    RedGuild_Send("BID_AWARD", EncodePayload({
        id        = RedGuild_Auction.id,
        winner    = who,
        cost      = cost,
        mode      = mode,
        copy      = copyIdx,
        qty       = copies,
        -- Copies still to come. Everyone else uses this to decide
        -- whether the auction is over or simply between winners.
        remaining = left,
    }))

    local suffix = (copies > 1)
        and string.format(" (%d of %d)", copyIdx, copies) or ""

    if mode == "OS" then
        if roll then
            AuctionWarn(string.format(
                "%s%s awarded to %s on %s roll of %d. No DKP charged.",
                link, suffix, winner,
                RedGuild_Auction.rollOnly and "a" or "an off-spec", roll))
        else
            AuctionWarn(string.format(
                "%s%s awarded to %s. No DKP charged.", link, suffix, winner))
        end
    elseif RedGuild_Auction.rollOnly and mode == "MS" and roll then
        AuctionWarn(string.format(
            "%s%s awarded to %s on a roll of %d. No DKP charged.",
            link, suffix, winner, roll))
    elseif cost > 0 then
        AuctionWarn(string.format("%s%s awarded to %s for %d DKP (main spec).",
            link, suffix, winner, cost))
    else
        AuctionWarn(string.format("%s%s awarded to %s. No DKP charged.",
            link, suffix, winner))
    end

    RedGuild_Auction.selected = nil
    if auctionMaster and auctionMaster.costBox then
        auctionMaster.costBox:SetText("")
    end

    -- Still copies to go: the auction is left exactly as it stands,
    -- timer included. Every remaining bid keeps counting, and a clock
    -- that is still running is not cut short by an early award.
    if left > 0 then
        AuctionWarn(string.format(
            "%d of %d copies of %s still to award.", left, copies, link))
        RedGuild_Auction_RefreshMaster()
        AuctionPrint(string.format(
            "Awarded copy %d of %d to %s for %d DKP. %d left - pick the next winner.",
            copyIdx, copies, winner, cost, left))
        return
    end

    if RedGuild_Auction.ticker then
        RedGuild_Auction.ticker:Cancel()
        RedGuild_Auction.ticker = nil
    end

    RedGuild_Auction.open   = false
    RedGuild_Auction.posted = false
    AuctionResetBook()

    RedGuild_Auction_RefreshMaster()
    if auctionPrompt then auctionPrompt:Hide() end
    RedGuild_Auction_HideTieRollPrompt()
    StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")

    RedGuild_Auction_PushSyncAfterClose()

    AuctionPrint(string.format(
        "Awarded %s to %s for %d DKP.", link, winner, cost))
end

--------------------------------------------------
-- Bidder side
--------------------------------------------------

function RedGuild_Auction_SendBid(amount, mode)
    if not RedGuild_Auction.posted or not RedGuild_Auction.ml then
        AuctionPrint("There is no item up for bidding.")
        return
    end

    -- Bidding closed but not yet awarded still accepts bids - they
    -- are just recorded (and reported back here) as late.
    local late = not RedGuild_Auction.open

    mode   = mode or "MS"
    amount = tonumber(amount) or 0

    -- A roll-only item has no DKP side at all: both Roll MS ("need")
    -- and Roll OS ("greed") are dice rolls, not bids, so mode is kept
    -- as given rather than blocked or coerced.
    if RedGuild_Auction.rollOnly then
        amount = 0
    elseif mode ~= "MS" then
        amount = 0
    end

    local bal = RedGuild_Auction_GetBalance(UnitName("player"))

    if mode == "MS" and not RedGuild_Auction.rollOnly then
        if amount < AUCTION_MIN_BID then
            AuctionPrint(string.format(
                "Minimum bid is %d DKP. Off spec is the roll button, not a bid.",
                AUCTION_MIN_BID))
            return
        end
        if amount > bal then
            AuctionPrint(string.format("You only have %d DKP.", bal))
            return
        end
    end

    if RedGuild_Auction_IsAuctioneer() then
        -- Addon messages whispered to yourself are dropped by the
        -- inbound handler, so write straight into the book instead.
        local good, err = RedGuild_Auction_RecordBid(
            UnitName("player"), amount, mode, "addon")
        if not good then
            AuctionPrint(err or "Bid rejected.")
            return
        end
    else
        RedGuild_Send("BID_PLACE", EncodePayload({
            id     = RedGuild_Auction.id,
            amount = amount,
            mode   = mode,
        }), RedGuild_Auction.ml)
    end

    -- Kept so this client can write its own entry in the Bid Log
    -- when the award is announced.
    RedGuild_Auction.myBid = {
        name   = Ambiguate(UnitName("player"), "short"),
        amount = amount,
        mode   = mode,
        src    = "addon",
    }

    if mode == "PASS" then
        AuctionPrint("You passed.")
    elseif RedGuild_Auction.rollOnly then
        -- A real Blizzard roll so the whole raid can see it and the
        -- auctioneer can verify it. The system message is picked up
        -- on the editor's client and attached to this bid. Roll MS is
        -- a normal 1-100 "need" roll; Roll OS stays the usual 1-69.
        RandomRoll(1, mode == "MS" and 100 or 69)
        if late then
            AuctionPrint("Bidding has closed - your roll was sent as LATE and may not be considered.")
        else
            AuctionPrint(string.format("%s roll sent. This item costs no DKP.",
                mode == "MS" and "Need (1-100)" or "Offspec (1-69)"))
        end
    elseif mode == "OS" then
        RandomRoll(1, 69)
        if late then
            AuctionPrint("Bidding has closed - your roll was sent as LATE and may not be considered.")
        else
            AuctionPrint("Off spec roll sent. It costs no DKP if you win it.")
        end
    else
        if late then
            AuctionPrint(string.format(
                "Bidding has closed - your bid of %d DKP was sent to %s as LATE and may not be considered.",
                amount, RedGuild_Auction.ml))
        else
            AuctionPrint(string.format("Bid of %d DKP sent to %s.", amount, RedGuild_Auction.ml))
        end
    end

    if auctionPrompt then auctionPrompt:Hide() end
    StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")
end

--------------------------------------------------
-- Incoming addon messages
--------------------------------------------------

function RedGuild_Auction_OnAddonMessage(msgType, payload, sender)
    local ok, data = pcall(DecodePayload, payload)
    if not ok or type(data) ~= "table" then return end

    sender = Ambiguate(sender or "", "short")

    ----------------------------------------------------------------
    if msgType == "BID_START" then
        -- Only trust an editor, and only for the group we are in.
        if not IsEditor(sender) then return end

        RedGuild_Auction.id       = data.id
        RedGuild_Auction.itemLink = data.itemLink
        RedGuild_Auction.itemID   = data.itemID
        RedGuild_Auction.ml       = data.ml or sender
        RedGuild_Auction.duration = tonumber(data.duration) or AUCTION_DEFAULT_DURATION
        RedGuild_Auction.endTime  = GetTime() + RedGuild_Auction.duration
        RedGuild_Auction.paused   = false
        RedGuild_Auction.remaining = nil
        RedGuild_Auction.myBid    = nil
        RedGuild_Auction.open     = true
        RedGuild_Auction.posted   = true
        RedGuild_Auction.dkpVersion = tonumber(data.dkpVersion or 0) or 0
        RedGuild_Auction.staleSince = GetTime()
        AuctionResetBook()
        -- Set after the reset, which clears the award counter.
        RedGuild_Auction.qty      = math.max(1, tonumber(data.qty) or 1)
        RedGuild_Auction.rollOnly = data.rollOnly and true or false

        RedGuild_Auction_ShowPrompt()

        -- No proactive sync here anymore: a bidder behind the version
        -- this item was posted under just shows "syncing..." on their
        -- balance and lives with it for this one bid. Pinging the
        -- auctioneer mid-bid for a fresh table added avoidable traffic
        -- right when a raid is busiest; RedGuild_Auction_PushSyncAfterClose
        -- (called once this item's bidding is actually done, from
        -- RedGuild_Auction_Stop and RedGuild_Auction_Award) is what
        -- catches everyone up now.
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_PLACE" then
        -- Only the auctioneer cares about incoming bids.
        if not RedGuild_Auction_IsAuctioneer() then return end
        if data.id ~= RedGuild_Auction.id then return end

        local good, info = RedGuild_Auction_RecordBid(sender, data.amount, data.mode, "addon")
        if not good then
            if info then AuctionWhisper(sender, "RedGuild: " .. info) end
        elseif info then
            -- info is the isLate flag on a successful record.
            AuctionWhisper(sender,
                "RedGuild: bidding has already closed - your bid was recorded as LATE and may not be considered.")
        end
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_PAUSE" then
        if data.id ~= RedGuild_Auction.id then return end
        RedGuild_Auction.remaining = tonumber(data.remaining) or 0
        RedGuild_Auction.paused    = true
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_RESUME" then
        if data.id ~= RedGuild_Auction.id then return end
        RedGuild_Auction.endTime   = GetTime() + (tonumber(data.remaining) or 0)
        RedGuild_Auction.paused    = false
        RedGuild_Auction.remaining = nil
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_TIEROLL" then
        if not IsEditor(sender) then return end
        if data.id ~= RedGuild_Auction.id then return end

        -- Sent to the whole group; only the people named in it are
        -- being asked to roll off.
        local me = NormalizeName(UnitName("player"))
        for _, n in ipairs(data.names or {}) do
            if NormalizeName(n) == me then
                RedGuild_Auction_ShowTieRollPrompt(
                    tonumber(data.range) or AUCTION_TIE_ROLL_MAX)
                return
            end
        end
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_TIEPASS" then
        if not RedGuild_Auction_IsAuctioneer() then return end
        if data.id ~= RedGuild_Auction.id then return end

        RedGuild_Auction_RecordTieRollPass(sender)
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_STOP" then
        if data.id ~= RedGuild_Auction.id then return end
        RedGuild_Auction.open = false
        -- The window is deliberately left open (it now shows
        -- "Closed") rather than hidden, so a bid placed here after
        -- the close is still possible - RedGuild_Auction_SendBid
        -- records and reports it as late instead of rejecting it.
        StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_REOPEN" then
        if data.id ~= RedGuild_Auction.id then return end

        RedGuild_Auction.duration  = tonumber(data.duration) or RedGuild_Auction.duration
        RedGuild_Auction.endTime   = GetTime() + (tonumber(data.duration) or AUCTION_DEFAULT_DURATION)
        RedGuild_Auction.paused    = false
        RedGuild_Auction.remaining = nil
        RedGuild_Auction.open      = true

        -- Late-flags only meant "arrived after the close that just
        -- ended" - clear them now that the window is open again.
        for _, b in pairs(RedGuild_Auction.bids) do
            b.late = nil
        end

        RedGuild_Auction_ShowPrompt()
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_CANCEL" then
        if data.id ~= RedGuild_Auction.id then return end
        RedGuild_BidLog_Add(BuildLogEntry(nil, 0, nil, true))
        RedGuild_Auction.open   = false
        RedGuild_Auction.posted = false
        AuctionResetBook()
        if auctionPrompt then auctionPrompt:Hide() end
        RedGuild_Auction_HideTieRollPrompt()
        StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")
        return
    end

    ----------------------------------------------------------------
    if msgType == "BID_AWARD" then
        if data.id ~= RedGuild_Auction.id then return end

        local cost      = tonumber(data.cost) or 0
        local copies    = math.max(1, tonumber(data.qty) or 1)
        local remaining = tonumber(data.remaining) or 0

        RedGuild_BidLog_Add(BuildLogEntry(
            data.winner, cost, data.mode, false,
            (copies > 1) and tonumber(data.copy) or nil))

        -- Non-editors update their own copy so their displayed balance
        -- is right immediately instead of waiting for the next sync.
        if not IsAuthorized() and data.winner and cost > 0 then
            local d = RedGuild_Data and RedGuild_Data[data.winner]
            if d then
                d.spent = (d.spent or 0) + cost
                RecalcBalance(d)
                if UpdateTable then UpdateTable() end
            end
        end

        -- Another copy of the same item is still going out, so the
        -- auction is not over: every bid already placed still counts
        -- for it and nothing here is torn down.
        if remaining > 0 then
            RedGuild_Auction.awarded = tonumber(data.copy)
                or ((RedGuild_Auction.awarded or 0) + 1)
            local b = data.winner and RedGuild_Auction.bids[data.winner]
            if b then b.won = true end
            return
        end

        RedGuild_Auction.open   = false
        RedGuild_Auction.posted = false
        AuctionResetBook()
        if auctionPrompt then auctionPrompt:Hide() end
        RedGuild_Auction_HideTieRollPrompt()
        StaticPopup_Hide("REDGUILD_BID_CONFIRM_PASS")
        return
    end
end

--------------------------------------------------
-- Whisper commands for players without the addon
-- Returns true when the whisper was a bid command.
--------------------------------------------------

function RedGuild_Auction_OnWhisper(text, sender)
    if not text or not sender then return false end

    local lower = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if lower:sub(1, 1) ~= "!" then return false end

    sender = Ambiguate(sender, "short")

    ----------------------------------------------------------------
    -- !dkp  (works any time, editors only)
    ----------------------------------------------------------------
    if lower == "!dkp" then
        if not IsAuthorized() then return false end
        local bal, main = RedGuild_Auction_GetBalance(sender)
        if RedGuild_Data and RedGuild_Data[main] then
            AuctionWhisper(sender, string.format("Your DKP: %d", bal))
        else
            AuctionWhisper(sender, "You are not on the DKP table yet.")
        end
        return true
    end

    -- Everything below needs an auctioneer with an item posted. Note
    -- this is gated on "posted", not "open" - once bidding is closed
    -- but the item has not been awarded yet, whispered commands are
    -- still accepted, just recorded (and reported back) as late.
    if not RedGuild_Auction_IsAuctioneer() then return false end

    if not RedGuild_Auction.posted then
        if lower:match("^!bid") or lower == "!pass" or lower == "!os" then
            AuctionWhisper(sender, "RedGuild: bidding is not open right now.")
            return true
        end
        return false
    end

    -- Bidding is a raid/group activity: a whisper from someone who
    -- isn't actually in it has no legitimate claim on its loot.
    if lower:match("^!bid") or lower == "!pass" or lower == "!os" then
        if not (UnitInParty(sender) or UnitInRaid(sender)) then
            AuctionWhisper(sender, "RedGuild: you must be in the raid or group to bid.")
            return true
        end
    end

    ----------------------------------------------------------------
    -- !pass
    ----------------------------------------------------------------
    if lower == "!pass" then
        RedGuild_Auction_RecordBid(sender, 0, "PASS", "whisper")
        AuctionWhisper(sender, "RedGuild: passed.")
        return true
    end

    ----------------------------------------------------------------
    -- !os
    ----------------------------------------------------------------
    if lower == "!os" then
        local ok, isLate = RedGuild_Auction_RecordBid(sender, 0, "OS", "whisper")
        if not ok then
            AuctionWhisper(sender, "RedGuild: " .. (isLate or "not recorded."))
        elseif isLate then
            AuctionWhisper(sender,
                "RedGuild: bidding has already closed - noted as LATE and may not be considered. Now /roll 69 and I will pick it up.")
        elseif RedGuild_Auction.rollOnly then
            AuctionWhisper(sender,
                "RedGuild: noted. This item is roll only and costs no DKP - now /roll 69 and I will pick it up.")
        else
            AuctionWhisper(sender,
                "RedGuild: off spec noted, it costs no DKP. Now /roll 69 and I will pick it up.")
        end
        return true
    end

    ----------------------------------------------------------------
    -- !bid <amount>   (main spec only)
    ----------------------------------------------------------------
    local amount, tail = lower:match("^!bid%s+(%d+)%s*(.*)$")
    if amount then
        -- Nothing is bid on a roll-only item, so the whisper is taken
        -- as a roll declaration rather than rejected outright.
        if RedGuild_Auction.rollOnly then
            local ok, isLate = RedGuild_Auction_RecordBid(sender, 0, "OS", "whisper")
            if not ok then
                AuctionWhisper(sender, "RedGuild: " .. (isLate or "not recorded."))
            elseif isLate then
                AuctionWhisper(sender,
                    "RedGuild: this item is ROLL ONLY and costs no DKP. Bidding has already closed - noted as LATE. Now /roll 69.")
            else
                AuctionWhisper(sender,
                    "RedGuild: this item is ROLL ONLY and costs no DKP. Noted - now /roll 69.")
            end
            return true
        end

        -- Someone trying to bid DKP for off-spec. Register the
        -- off-spec roll instead and explain the rule.
        if tail and (tail:find("os", 1, true) or tail:find("off", 1, true)) then
            local ok, isLate = RedGuild_Auction_RecordBid(sender, 0, "OS", "whisper")
            if ok and isLate then
                AuctionWhisper(sender,
                    "RedGuild: off spec is roll only and costs no DKP. Bidding has already closed - noted as off spec but LATE and may not be considered. Now /roll 69.")
            else
                AuctionWhisper(sender,
                    "RedGuild: off spec is roll only and costs no DKP. Noted as off spec - now /roll 69.")
            end
            return true
        end

        local good, info = RedGuild_Auction_RecordBid(sender, amount, "MS", "whisper")
        if good then
            if info then
                AuctionWhisper(sender, string.format(
                    "RedGuild: bidding has already closed - your main-spec bid of %d DKP on %s was recorded as LATE and may not be considered.",
                    tonumber(amount), RedGuild_Auction.itemLink or "the item"))
            else
                AuctionWhisper(sender, string.format("RedGuild: main-spec bid of %d DKP recorded on %s.",
                    tonumber(amount), RedGuild_Auction.itemLink or "the item"))
            end
        else
            AuctionWhisper(sender, "RedGuild: " .. (info or "bid rejected."))
        end
        return true
    end

    if lower:match("^!bid") then
        if RedGuild_Auction.rollOnly then
            AuctionWhisper(sender,
                "RedGuild: this item is ROLL ONLY - there are no DKP bids. Whisper !os and then /roll 69.")
        else
            AuctionWhisper(sender, string.format(
                "RedGuild: use  !bid <amount>  for main spec, minimum %d, for example  !bid 50. Off spec is /roll 69 only and costs no DKP.",
                AUCTION_MIN_BID))
        end
        return true
    end

    return false
end

--------------------------------------------------
-- /roll capture (off-spec), auctioneer only
--------------------------------------------------

function RedGuild_Auction_OnSystemMessage(text)
    if not text then return end
    -- Gated on "posted", not "open", so a roll for a late off-spec
    -- bid is still picked up after bidding has closed.
    if not RedGuild_Auction.posted then return end
    if not RedGuild_Auction_IsAuctioneer() then return end

    local who, roll, low, high = text:match(RedGuild_RollPattern)
    if not who or not roll then return end

    local lowNum, highNum = tonumber(low), tonumber(high)
    local bidderKey        = RedGuild_Auction_Bidder(who)
    local bid              = RedGuild_Auction.bids[bidderKey]

    -- Before any of the gating below, so a roll gets its due whatever
    -- the range - need roll, off-spec roll, tie roll, or a roll that
    -- counts for nothing at all.
    local quip, quipKind = RedGuild_Auction_RollQuip(roll, lowNum, highNum)
    if quip then
        RedGuild_Auction_Quip(who, quip, quipKind)
    end

    -- A pending tie-roll (RedGuild_Auction_TriggerTieRoll) overrides
    -- the normal mode rules: whoever is in one must roll the exact
    -- range they were asked for, whatever kind of bid or roll got
    -- them into the tie in the first place. The result is kept in its
    -- own field - the bid or roll that got them here is left intact,
    -- so the editor can still see both side by side.
    if bid and (bid.tieRollWant or bid.tiePassed) then
        -- Someone who passed stays in this branch rather than falling
        -- through to the normal listener below, where a later roll
        -- could overwrite the bid or roll they are tied on. They said
        -- no; a stray /roll afterwards does not change that.
        if bid.tiePassed then return end

        if lowNum ~= 1 or highNum ~= bid.tieRollWant then
            AuctionWhisper(who, string.format(
                "RedGuild: this is a tie-break - please /roll %d.", bid.tieRollWant))
            return
        end

        if bid.tieRoll then
            if not bid.tieRollWarned then
                bid.tieRollWarned = true
                AuctionWhisper(who, string.format(
                    "RedGuild: only your first tie roll counts. Your %d stands.",
                    bid.tieRoll))
            end
            return
        end

        -- tieRollWant deliberately stays set: it is what keeps every
        -- later roll from this player inside this branch. Clearing it
        -- would drop them back into the normal listener below, where a
        -- reroll could overwrite the bid they are tied on.
        bid.tieRoll = tonumber(roll)
        RedGuild_Auction_RefreshMaster()
        return
    end

    -- On a roll-only item, either a 1-100 "need" roll (mode MS) or the
    -- usual 1-69 "offspec" roll (mode OS) counts. Everywhere else,
    -- only the 1-69 off-spec roll does - main spec is a DKP bid there,
    -- never a dice roll.
    local expectMode
    if lowNum == 1 and highNum == 69 then
        expectMode = "OS"
    elseif RedGuild_Auction.rollOnly and lowNum == 1 and highNum == 100 then
        expectMode = "MS"
    else
        AuctionWhisper(who, RedGuild_Auction.rollOnly
            and "RedGuild: only /roll 100 (need) or /roll 69 (offspec) count. Please roll again."
            or "RedGuild: only /roll 69 (1-69) counts. Please roll again.")
        return
    end

    if bid then
        -- A registered bid only accepts a roll matching the mode it
        -- was placed under - a DKP main-spec bidder is never converted
        -- by rolling, and an off-spec roller's number never counts
        -- for a need roll or vice versa.
        if bid.mode ~= expectMode then return end

        -- Only the first roll counts. Later ones are ignored, and
        -- the roller is told once so they are not left thinking a
        -- reroll replaced their result.
        if bid.roll then
            if not bid.rollWarned then
                bid.rollWarned = true
                AuctionWhisper(bidderKey, string.format(
                    "RedGuild: only your first roll counts. Your %d stands, later rolls are ignored.",
                    bid.roll))
                AuctionPrint(string.format(
                    "%s rolled again (%d) - ignored, first roll of %d stands.",
                    bidderKey, tonumber(roll), bid.roll))
            end
            return
        end

        bid.roll = tonumber(roll)
        RedGuild_Auction_RefreshMaster()
    else
        -- Someone rolled without registering. Treat it as a bid under
        -- whichever mode its roll range matches, so people who just
        -- /roll are not silently dropped.
        RedGuild_Auction_RecordBid(bidderKey, 0, expectMode, "roll", tonumber(roll))
    end
end

--------------------------------------------------
-- BIDDER PROMPT
--------------------------------------------------

local function BidItemName(link)
    if not link then return "this item" end
    return link:match("|h%[(.-)%]|h") or link
end

StaticPopupDialogs["REDGUILD_BID_CONFIRM_PASS"] = {
    text = "Pass on %s?\n\nClosing the bidding window counts as a pass, and you will not be able to bid on it.",
    button1 = "Pass",
    button2 = "Keep bidding",
    OnAccept = function()
        RedGuild_Auction.passConfirm = nil
        if RedGuild_Auction.open and not RedGuild_Auction.myBid then
            RedGuild_Auction_SendBid(0, "PASS")
        end
    end,
    OnCancel = function()
        RedGuild_Auction.passConfirm = nil
        -- Not a pass after all, so put the window back.
        if RedGuild_Auction.open and not RedGuild_Auction.myBid then
            RedGuild_Auction_ShowPrompt()
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = false, preferredIndex = 3,
}

-- The line under the bid box. It has to be rebuilt rather than set
-- once, because the OnUpdate below rewrites it every tick and the
-- wording depends on what kind of item is up.
local function PromptRuleText()
    local parts = {}

    if not RedGuild_Auction_ItemUsableByMe() then
        table.insert(parts, "|cffff2020This item is not usable by your class - bidding disabled.|r")
    end

    if RedGuild_Auction.rollOnly then
        table.insert(parts, "|cff55ccffRoll only|r - no DKP is charged. Roll MS is a normal 1-100 roll, Roll OS is 1-69.")
    end

    local qty = tonumber(RedGuild_Auction.qty) or 1
    if qty > 1 then
        table.insert(parts, string.format(
            "%d copies are being handed out - one bid or roll is enough.", qty))
    end

    table.insert(parts, "Closing this window or pressing Escape counts as a pass.")
    return table.concat(parts, " ")
end

local function CreatePrompt()
    if auctionPrompt then return auctionPrompt end

    local f = CreateFrame("Frame", "RedGuildBidPrompt", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(300, 255)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    table.insert(UISpecialFrames, "RedGuildBidPrompt")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("CENTER", f.TitleBg, "CENTER", 0, 0)
    f.title:SetText("RedGuild - Bid")

    -- Both the icon and the name are hover targets: people reach for
    -- whichever one their eye lands on first, and a tooltip that only
    -- works on half the item is worse than none at all.
    local function ItemTooltipOn(self)
        if not RedGuild_Auction.itemLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(RedGuild_Auction.itemLink)
        GameTooltip:Show()
    end
    local function ItemTooltipOff() GameTooltip:Hide() end

    f.iconBtn = CreateFrame("Button", nil, f)
    f.iconBtn:SetSize(34, 34)
    f.iconBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
    f.iconBtn:EnableMouse(true)
    -- The template's inset sits over the body of the frame, so both
    -- hover targets are lifted above it or they never see the mouse.
    f.iconBtn:SetFrameLevel(f:GetFrameLevel() + 5)
    f.iconBtn:SetScript("OnEnter", ItemTooltipOn)
    f.iconBtn:SetScript("OnLeave", ItemTooltipOff)

    f.icon = f.iconBtn:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints(f.iconBtn)

    f.itemBtn = CreateFrame("Button", nil, f)
    f.itemBtn:SetPoint("TOPLEFT", f.iconBtn, "TOPRIGHT", 8, 0)
    f.itemBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -34)
    f.itemBtn:SetHeight(34)
    f.itemBtn:EnableMouse(true)
    f.itemBtn:SetFrameLevel(f:GetFrameLevel() + 5)

    f.itemText = f.itemBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.itemText:SetAllPoints(f.itemBtn)
    f.itemText:SetJustifyH("LEFT")
    f.itemText:SetWordWrap(true)

    f.itemBtn:SetScript("OnEnter", ItemTooltipOn)
    f.itemBtn:SetScript("OnLeave", ItemTooltipOff)

    f.balText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.balText:SetPoint("TOPLEFT", f.iconBtn, "BOTTOMLEFT", 0, -10)

    f.timerText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.timerText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -80)

    local bidLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bidLabel:SetPoint("TOPLEFT", f.balText, "BOTTOMLEFT", 0, -12)
    bidLabel:SetText(string.format("Main spec bid (min %d):", AUCTION_MIN_BID))
    -- Kept on the frame so a roll-only item can hide the whole bid row.
    f.bidLabel = bidLabel

    f.ruleText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.ruleText:SetPoint("TOPLEFT", bidLabel, "BOTTOMLEFT", 0, -14)
    f.ruleText:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.ruleText:SetJustifyH("LEFT")
    f.ruleText:SetWordWrap(true)
    f.ruleText:SetText(PromptRuleText())

    f.amountBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.amountBox:SetSize(70, 20)
    f.amountBox:SetPoint("LEFT", bidLabel, "RIGHT", 10, 0)
    f.amountBox:SetAutoFocus(false)
    f.amountBox:SetNumeric(true)
    f.amountBox:SetScript("OnEnterPressed", function(self)
        RedGuild_Auction_SendBid(self:GetNumber(), "MS")
        self:ClearFocus()
    end)
    f.amountBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Bid sits far left and Roll OS far right, so the two cannot be
    -- confused for one another under raid pressure.
    f.bidBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.bidBtn:SetSize(92, 24)
    f.bidBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 44)
    f.bidBtn:SetText("|TInterface\\Icons\\INV_Misc_Coin_01:14:14:0:0|t Bid")
    f.bidBtn:SetScript("OnClick", function()
        -- Doubles as "Roll MS" (a 1-100 need roll) on a roll-only
        -- item, where there is no amount to read from the bid box.
        if RedGuild_Auction.rollOnly then
            RedGuild_Auction_SendBid(0, "MS")
        else
            RedGuild_Auction_SendBid(f.amountBox:GetNumber(), "MS")
        end
    end)

    f.osBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.osBtn:SetSize(102, 24)
    f.osBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 44)
    f.osBtn:SetText("|TInterface\\Buttons\\UI-GroupLoot-Dice-Up:16:16:0:0|t Roll OS")
    f.osBtn:SetScript("OnClick", function()
        RedGuild_Auction_SendBid(0, "OS")
    end)

    -- Passing on purpose is a deliberate click on its own row, well
    -- clear of Bid and Roll OS, so it cannot be hit by accident while
    -- reaching for either of them. Because it is deliberate, it does
    -- not ask for confirmation - it just passes.
    f.passBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.passBtn:SetSize(110, 22)
    f.passBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    f.passBtn:SetText("|TInterface\\Buttons\\UI-GroupLoot-Pass-Up:16:16:0:0|t Pass")
    f.passBtn:SetScript("OnClick", function()
        -- SendBid records the pass and hides the window; the OnHide
        -- guard below sees myBid and stays quiet, so no popup appears.
        RedGuild_Auction_SendBid(0, "PASS")
    end)

    -- Dismissing the window is also a pass, so the close box and
    -- Escape both go through here. Every deliberate hide from the
    -- addon happens after the auction is closed or after a bid was
    -- recorded, and both are covered by the guards below, so only a
    -- genuine dismissal reaches the confirmation.
    f:SetScript("OnHide", function()
        if not RedGuild_Auction.open then return end
        if RedGuild_Auction.myBid then return end
        if RedGuild_Auction.passConfirm then return end

        -- Escape is easy to hit by reflex while clearing other UI, so
        -- ask before turning that into a pass that cannot be undone.
        RedGuild_Auction.passConfirm = true
        StaticPopup_Show("REDGUILD_BID_CONFIRM_PASS",
            BidItemName(RedGuild_Auction.itemLink))
    end)

    f:SetScript("OnUpdate", function(self, elapsed)
        self.acc = (self.acc or 0) + elapsed
        if self.acc < 0.2 then return end
        self.acc = 0

        -- Read the balance every tick rather than once at open.
        -- "syncing..." only while a table is genuinely stale AND a
        -- sync is actually incoming, and only for the first 10
        -- seconds - see RedGuild_Auction_ShowSyncingBalance. Past
        -- that, or with nothing coming, showing the real (possibly
        -- outdated) number beats leaving the prompt stuck forever.
        if RedGuild_Auction_ShowSyncingBalance() then
            self.balText:SetText("Your DKP: |cffffff00syncing...|r")
        else
            self.balText:SetText(string.format("Your DKP: |cff00ff00%d|r",
                RedGuild_Auction_GetBalance(UnitName("player"))))
        end

        -- Checked every tick, independent of open/closed, so a class
        -- that simply cannot use the item never gets to Bid or Roll -
        -- Pass is untouched either way.
        if RedGuild_Auction_ItemUsableByMe() then
            self.bidBtn:Enable()
            self.osBtn:Enable()
        else
            self.bidBtn:Disable()
            self.osBtn:Disable()
        end

        if not RedGuild_Auction.open then
            self.timerText:SetText("|cffff5555Closed|r")
            self.ruleText:SetText(
                "|cffff5555Bidding is closed.|r A bid placed now is accepted as LATE and may not be considered.")
            return
        end

        self.ruleText:SetText(PromptRuleText())

        local left = RedGuild_Auction_TimeLeft()
        if RedGuild_Auction.paused then
            self.timerText:SetText(string.format("|cffffff00PAUSED %ds|r", left))
            return
        end

        local colour = left <= 5 and "|cffff5555" or "|cffffff00"
        self.timerText:SetText(string.format("%s%ds|r", colour, left))
    end)

    auctionPrompt = f
    return f
end

--------------------------------------------------
-- TIE ROLL PROMPT
--------------------------------------------------
-- Deliberately nothing but a roll button. The bid is already placed
-- and is not being replaced - this is only the roll-off that settles
-- who wins among people who are level on it.
local function CreateTiePrompt()
    if auctionTiePrompt then return auctionTiePrompt end

    local f = CreateFrame("Frame", "RedGuildTieRollPrompt", UIParent,
        "BasicFrameTemplateWithInset")
    f:SetSize(260, 150)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    table.insert(UISpecialFrames, "RedGuildTieRollPrompt")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("CENTER", f.TitleBg, "CENTER", 0, 0)
    f.title:SetText("RedGuild - Tie Roll")

    f.itemText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.itemText:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
    f.itemText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -34)
    f.itemText:SetJustifyH("CENTER")
    f.itemText:SetWordWrap(true)

    f.infoText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.infoText:SetPoint("TOPLEFT", f.itemText, "BOTTOMLEFT", 0, -8)
    f.infoText:SetPoint("TOPRIGHT", f.itemText, "BOTTOMRIGHT", 0, -8)
    f.infoText:SetJustifyH("CENTER")
    f.infoText:SetWordWrap(true)

    f.rollBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.rollBtn:SetSize(200, 34)
    f.rollBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 42)
    f.rollBtn:SetScript("OnClick", function(self)
        RandomRoll(1, f.range or AUCTION_TIE_ROLL_MAX)
        -- One roll each: the auctioneer keeps the first one anyway.
        self:Disable()
        f:Hide()
    end)

    -- Bowing out of the roll-off. Their original bid is untouched
    -- either way; this just tells the auctioneer not to wait on a
    -- roll that is never coming.
    f.passBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.passBtn:SetSize(200, 20)
    f.passBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 16)
    f.passBtn:SetText("|TInterface\\Buttons\\UI-GroupLoot-Pass-Up:14:14:0:0|t Pass")
    f.passBtn:SetScript("OnClick", function()
        RedGuild_Auction_SendTieRollPass()
        f:Hide()
    end)

    auctionTiePrompt = f
    return f
end

function RedGuild_Auction_ShowTieRollPrompt(range)
    range = tonumber(range) or AUCTION_TIE_ROLL_MAX

    local f = CreateTiePrompt()
    f.range = range

    f.itemText:SetText(RedGuild_Auction.itemLink
        and RedGuild_Auction_ItemLabel() or "Unknown item")
    f.infoText:SetText(string.format(
        "|cffffff00Tie roll|r - roll off to settle it.\nYour bid still stands as it is."))
    f.rollBtn:SetText(string.format(
        "|TInterface\\Buttons\\UI-GroupLoot-Dice-Up:18:18:0:0|t Roll 1-%d", range))
    f.rollBtn:Enable()
    f.passBtn:Enable()

    f:Show()
end

-- Tells the auctioneer this player is not rolling off after all, so
-- the bid list stops showing them as still to roll.
function RedGuild_Auction_SendTieRollPass()
    if not RedGuild_Auction.posted or not RedGuild_Auction.ml then return end

    if RedGuild_Auction_IsAuctioneer() then
        -- Whispering yourself goes nowhere, so record it directly.
        RedGuild_Auction_RecordTieRollPass(Ambiguate(UnitName("player"), "short"))
    else
        RedGuild_Send("BID_TIEPASS", EncodePayload({
            id = RedGuild_Auction.id,
        }), RedGuild_Auction.ml)
    end

    AuctionPrint("You passed on the tie roll.")
end

-- Auctioneer side. Leaves the bid alone, exactly like a tie roll
-- does - this only clears the "still waiting on them" state.
function RedGuild_Auction_RecordTieRollPass(who)
    local bid = who and RedGuild_Auction.bids[RedGuild_Auction_Bidder(who)]
    if not bid then return end
    if not bid.tieRollWant and not bid.tieRoll then return end

    bid.tieRoll     = nil
    bid.tieRollWant = nil
    bid.tiePassed   = true

    RedGuild_Auction_RefreshMaster()
end

function RedGuild_Auction_HideTieRollPrompt()
    if auctionTiePrompt then auctionTiePrompt:Hide() end
end

function RedGuild_Auction_ShowPrompt()
    if not RedGuild_Auction.posted then return end

    -- A confirmation left over from a previous item must not suppress
    -- the next one, or a later Escape would silently do nothing.
    RedGuild_Auction.passConfirm = nil

    local f = CreatePrompt()
    local bal = RedGuild_Auction_GetBalance(UnitName("player"))

    f.itemText:SetText(RedGuild_Auction.itemLink
        and RedGuild_Auction_ItemLabel() or "Unknown item")
    f.icon:SetTexture(
        (RedGuild_Auction.itemID and GetItemIcon(RedGuild_Auction.itemID))
        or "Interface\\Icons\\INV_Misc_QuestionMark")
    if RedGuild_Auction_ShowSyncingBalance() then
        f.balText:SetText("Your DKP: |cffffff00syncing...|r")
    else
        f.balText:SetText(string.format("Your DKP: |cff00ff00%d|r", bal))
    end
    f.amountBox:SetText("")
    f.ruleText:SetText(PromptRuleText())

    -- A roll-only item has no DKP side, so the bid box goes away and
    -- Bid itself becomes Roll MS (a normal 1-100 need roll) sitting
    -- right where Bid used to, alongside Roll OS (still 1-69) - both
    -- buttons stay in their usual spots either way.
    f.bidBtn:ClearAllPoints()
    f.bidBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 44)
    f.osBtn:ClearAllPoints()
    f.osBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 44)
    f.osBtn:SetText("|TInterface\\Buttons\\UI-GroupLoot-Dice-Up:16:16:0:0|t Roll OS")

    if RedGuild_Auction.rollOnly then
        f.bidLabel:Hide()
        f.amountBox:Hide()
        f.bidBtn:SetText("|TInterface\\Buttons\\UI-GroupLoot-Dice-Up:16:16:0:0|t Roll MS")
    else
        f.bidLabel:Show()
        f.amountBox:Show()
        f.bidBtn:SetText("|TInterface\\Icons\\INV_Misc_Coin_01:14:14:0:0|t Bid")
    end

    -- Set immediately rather than waiting for the first OnUpdate tick,
    -- so a class that can't use the item never sees Bid/Roll enabled
    -- even for a moment.
    if RedGuild_Auction_ItemUsableByMe() then
        f.bidBtn:Enable()
        f.osBtn:Enable()
    else
        f.bidBtn:Disable()
        f.osBtn:Disable()
    end

    f:Show()
end

--------------------------------------------------
-- AUCTIONEER WINDOW
--------------------------------------------------

local function CreateMasterRow(index, parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(440, 16)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * 16))

    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints(row)
    row.hl:SetColorTexture(0.3, 0.5, 0.9, 0.35)
    row.hl:Hide()

    -- Ticked to include this bidder in the next tie roll. Separate
    -- from the row's own selection, which is what Award acts on.
    row.tieCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.tieCheck:SetSize(16, 16)
    row.tieCheck:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.tieCheck:SetScript("OnClick", function(self)
        if not row.bidder then return end
        RedGuild_Auction.tieSelected = RedGuild_Auction.tieSelected or {}
        RedGuild_Auction.tieSelected[row.bidder] = self:GetChecked() and true or nil
    end)

    local function mk(x, w, justify)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", row, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(justify or "LEFT")
        return fs
    end

    row.nameText = mk(22,  112)
    row.bidText  = mk(138,  45, "RIGHT")
    row.modeText = mk(187,  36)
    row.balText  = mk(227,  45, "RIGHT")
    row.rollText = mk(276,  36, "RIGHT")
    row.tieText  = mk(316,  36, "RIGHT")
    row.srcText  = mk(356,  60)

    row:SetScript("OnClick", function(self)
        -- On a multi-copy item, whoever already took one is shown but
        -- cannot be selected again.
        local b = self.bidder and RedGuild_Auction.bids[self.bidder]
        if b and b.won then
            AuctionPrint(string.format(
                "%s already has a copy of this item.", b.name or self.bidder))
            return
        end
        RedGuild_Auction.selected = self.bidder
        RedGuild_Auction_RefreshMaster()
    end)

    return row
end

local function CreateMaster()
    if auctionMaster then return auctionMaster end

    local f = CreateFrame("Frame", "RedGuildAuctionFrame", UIParent, "BasicFrameTemplateWithInset")
    -- Taller than it was: the copies / roll-only row sits between the
    -- item link box and the auction controls.
    -- Wider than it was: the bid list gained a tie-roll tick box
    -- and a Tie column.
    f:SetSize(470, 462)
    f:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    table.insert(UISpecialFrames, "RedGuildAuctionFrame")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.title:SetPoint("CENTER", f.TitleBg, "CENTER", 0, 0)
    f.title:SetText("RedGuild - Item Bidding")

    ----------------------------------------------------------------
    -- Item drop slot
    ----------------------------------------------------------------
    local slot = CreateFrame("Button", nil, f)
    slot:SetSize(36, 36)
    slot:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
    slot:RegisterForDrag("LeftButton")

    slot.bg = slot:CreateTexture(nil, "BACKGROUND")
    slot.bg:SetAllPoints(slot)
    slot.bg:SetColorTexture(0, 0, 0, 0.5)

    f.itemIcon = slot:CreateTexture(nil, "ARTWORK")
    f.itemIcon:SetAllPoints(slot)
    f.itemIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

    local function TakeCursorItem()
        local cursorType, _, itemLink = GetCursorInfo()
        if cursorType == "item" and itemLink then
            ClearCursor()
            RedGuild_Auction_SetItem(itemLink)
        end
    end
    slot:SetScript("OnReceiveDrag", TakeCursorItem)
    slot:SetScript("OnMouseUp", TakeCursorItem)
    slot:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if RedGuild_Auction.itemLink then
            GameTooltip:SetHyperlink(RedGuild_Auction.itemLink)
        else
            GameTooltip:SetText("Drag an item here, shift-click one into the box,\nor use Loot for an item nobody has picked up yet.")
        end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.itemText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.itemText:SetPoint("TOPLEFT", slot, "TOPRIGHT", 8, -2)
    f.itemText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -36)
    f.itemText:SetJustifyH("LEFT")
    f.itemText:SetText("|cff888888No item selected|r")

    ----------------------------------------------------------------
    -- Item link box (shift-click target)
    ----------------------------------------------------------------
    f.itemBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.itemBox:SetSize(230, 20)
    f.itemBox:SetPoint("TOPLEFT", slot, "BOTTOMLEFT", 6, -8)
    f.itemBox:SetAutoFocus(false)
    f.itemBox:SetScript("OnEnterPressed", function(self)
        local txt = self:GetText()
        if txt and txt:find("item:") then
            RedGuild_Auction_SetItem(txt)
        end
        self:ClearFocus()
    end)
    f.itemBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    hooksecurefunc("ChatEdit_InsertLink", function(link)
        if link and auctionMaster and auctionMaster:IsShown()
            and auctionMaster.itemBox and auctionMaster.itemBox:HasFocus() then
            auctionMaster.itemBox:SetText(link)
            RedGuild_Auction_SetItem(link)
        end
    end)

    ----------------------------------------------------------------
    -- Duration + controls
    ----------------------------------------------------------------
    local durLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    durLabel:SetPoint("LEFT", f.itemBox, "RIGHT", 10, 0)
    durLabel:SetText("Secs:")

    f.durBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.durBox:SetSize(36, 20)
    f.durBox:SetPoint("LEFT", durLabel, "RIGHT", 8, 0)
    f.durBox:SetAutoFocus(false)
    f.durBox:SetNumeric(true)
    f.durBox:SetText(tostring(AUCTION_DEFAULT_DURATION))
    f.durBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Loads an item straight out of an open loot window. Items that
    -- have not been picked up cannot be dragged onto the cursor, so
    -- the drop slot alone can never reach them.
    f.lootBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.lootBtn:SetSize(58, 20)
    f.lootBtn:SetPoint("LEFT", f.durBox, "RIGHT", 8, 0)
    f.lootBtn:SetText("Loot")
    f.lootBtn:SetScript("OnClick", function() RedGuild_Auction_ToggleLootPicker() end)
    f.lootBtn:SetScript("OnShow", function() RedGuild_Auction_UpdateLootButton() end)
    f.lootBtn:SetScript("OnHide", function()
        if RedGuildAuctionLootPicker then RedGuildAuctionLootPicker:Hide() end
    end)
    f.lootBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cffffff00Take from loot|r")
        GameTooltip:AddLine("Pick an item out of the open loot window,", 1, 1, 1)
        GameTooltip:AddLine("before anybody has looted it.", 1, 1, 1)
        GameTooltip:AddLine("Shift-click a loot item also works while this window is open.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    f.lootBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    ----------------------------------------------------------------
    -- Copies + roll-only
    ----------------------------------------------------------------
    -- Both are read when Post is pressed, exactly like the duration,
    -- and are locked while an item is up so they cannot drift out of
    -- step with what the raid was told.
    local qtyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    qtyLabel:SetPoint("TOPLEFT", f.itemBox, "BOTTOMLEFT", 0, -10)
    qtyLabel:SetText("Copies:")

    f.qtyBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.qtyBox:SetSize(34, 20)
    f.qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 10, 0)
    f.qtyBox:SetAutoFocus(false)
    f.qtyBox:SetNumeric(true)
    f.qtyBox:SetText("1")
    f.qtyBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.qtyBox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cffffff00Copies|r")
        GameTooltip:AddLine("How many of this item dropped.", 1, 1, 1)
        GameTooltip:AddLine("One auction, one bid from everyone,", 1, 1, 1)
        GameTooltip:AddLine("and you award it once per copy.", 1, 1, 1)
        GameTooltip:AddLine("Taking an item from the loot window fills this in.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    f.qtyBox:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.rollOnlyCheck = CreateFrame("CheckButton", "RedGuildAuctionRollOnlyCheck", f,
        "UICheckButtonTemplate")
    f.rollOnlyCheck:SetSize(22, 22)
    f.rollOnlyCheck:SetPoint("LEFT", f.qtyBox, "RIGHT", 18, 0)
    f.rollOnlyCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cffffff00Roll only|r")
        GameTooltip:AddLine("For items nobody should spend DKP on,", 1, 1, 1)
        GameTooltip:AddLine("such as recipes and patterns.", 1, 1, 1)
        GameTooltip:AddLine("Bidders get a roll button and nothing else,", 0.6, 0.6, 0.6)
        GameTooltip:AddLine("and the award always costs 0 DKP.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    f.rollOnlyCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.rollOnlyCheck:SetScript("OnClick", function() RedGuild_Auction_RefreshMaster() end)

    local rollOnlyLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rollOnlyLabel:SetPoint("LEFT", f.rollOnlyCheck, "RIGHT", 2, 0)
    rollOnlyLabel:SetText("Roll only - no DKP bids")
    f.rollOnlyLabel = rollOnlyLabel

    f.startBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.startBtn:SetSize(62, 22)
    f.startBtn:SetPoint("TOPLEFT", qtyLabel, "BOTTOMLEFT", -6, -10)
    f.startBtn:SetText("Post")
    f.startBtn:SetScript("OnClick", RedGuild_Auction_Start)

    f.pauseBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.pauseBtn:SetSize(62, 22)
    f.pauseBtn:SetPoint("LEFT", f.startBtn, "RIGHT", 6, 0)
    f.pauseBtn:SetText("Pause")
    f.pauseBtn:SetScript("OnClick", RedGuild_Auction_TogglePause)

    f.stopBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.stopBtn:SetSize(62, 22)
    f.stopBtn:SetPoint("LEFT", f.pauseBtn, "RIGHT", 6, 0)
    f.stopBtn:SetText("Close")
    f.stopBtn:SetScript("OnClick", function() RedGuild_Auction_Stop(false) end)

    -- Reopens the closed-but-not-yet-awarded auction without losing
    -- the bids already collected.
    f.reopenBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.reopenBtn:SetSize(62, 22)
    f.reopenBtn:SetPoint("LEFT", f.stopBtn, "RIGHT", 6, 0)
    f.reopenBtn:SetText("Reopen")
    f.reopenBtn:SetScript("OnClick", RedGuild_Auction_Reopen)

    f.cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.cancelBtn:SetSize(62, 22)
    f.cancelBtn:SetPoint("LEFT", f.reopenBtn, "RIGHT", 6, 0)
    f.cancelBtn:SetText("Cancel")
    f.cancelBtn:SetScript("OnClick", RedGuild_Auction_Cancel)

    -- Asks whoever is ticked in the bid list to roll off. See
    -- RedGuild_Auction_TriggerTieRoll.
    f.tieBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.tieBtn:SetSize(72, 22)
    f.tieBtn:SetPoint("LEFT", f.cancelBtn, "RIGHT", 6, 0)
    f.tieBtn:SetText("Tie Roll")
    f.tieBtn:SetScript("OnClick", RedGuild_Auction_TriggerTieRoll)
    f.tieBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Tie Roll")
        GameTooltip:AddLine("Tick the bidders who should roll off,", 1, 1, 1)
        GameTooltip:AddLine("then press this to send them a roll button.", 1, 1, 1)
        GameTooltip:AddLine("Their existing bid or roll is not replaced.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    f.tieBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.timerText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.timerText:SetPoint("LEFT", f.tieBtn, "RIGHT", 10, 0)

    ----------------------------------------------------------------
    -- Column headers
    ----------------------------------------------------------------
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", f.startBtn, "BOTTOMLEFT", 6, -10)
    header:SetSize(440, 14)

    local function hdr(x, w, text, justify)
        local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", header, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH(justify or "LEFT")
        fs:SetText(text)
        return fs
    end
    hdr(22,  112, "Bidder")
    hdr(138,  45, "Bid", "RIGHT")
    hdr(187,  36, "Type")
    hdr(227,  45, "Bal", "RIGHT")
    hdr(276,  36, "Roll", "RIGHT")
    hdr(316,  36, "Tie", "RIGHT")
    hdr(356,  60, "Via")

    ----------------------------------------------------------------
    -- Bid list
    ----------------------------------------------------------------
    local scroll = CreateFrame("ScrollFrame", "RedGuildAuctionScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 46)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(440, 16)
    scroll:SetScrollChild(child)
    f.scrollChild = child

    ----------------------------------------------------------------
    -- Award controls
    ----------------------------------------------------------------
    local costLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    costLabel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 22)
    costLabel:SetText("Cost:")

    f.costBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.costBox:SetSize(50, 20)
    f.costBox:SetPoint("LEFT", costLabel, "RIGHT", 10, 0)
    f.costBox:SetAutoFocus(false)
    f.costBox:SetNumeric(true)
    f.costBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    f.awardBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.awardBtn:SetSize(160, 24)
    f.awardBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 16)
    f.awardBtn:SetText("Award to selected")
    f.awardBtn:SetScript("OnClick", function()
        if not RedGuild_Auction.selected then
            AuctionPrint("Click a bidder in the list first.")
            return
        end
        RedGuild_Auction_Award(RedGuild_Auction.selected, f.costBox:GetNumber())
    end)

    f.hintText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hintText:SetPoint("BOTTOMLEFT", costLabel, "TOPLEFT", 0, 4)
    f.hintText:SetText(
        "Winner is never picked automatically: click a row, check the cost, award.")

    auctionMaster = f
    return f
end

--------------------------------------------------
-- Loot window integration
--------------------------------------------------
-- An item lying in an open loot window cannot be picked up onto the
-- cursor, so the drop slot can never receive it and shift-clicking it
-- only works while the link box happens to have focus. Instead we read
-- the loot slots directly, which lets an editor post an item for
-- bidding before anybody has looted it.

local AUCTION_LOOT_MAX_ROWS = 12
local auctionLootPicker

-- Returns the item slots of the currently open loot window. Money and
-- currency slots have no item link and are skipped.
local function AuctionLootSlots()
    local out = {}
    if not GetNumLootItems or not GetLootSlotLink then return out end

    for slot = 1, (GetNumLootItems() or 0) do
        local isItem = true
        if GetLootSlotType then
            isItem = (GetLootSlotType(slot) == (LOOT_SLOT_ITEM or 1))
        end

        local link = isItem and GetLootSlotLink(slot) or nil
        if link then
            local texture, _, quantity
            if GetLootSlotInfo then
                texture, _, quantity = GetLootSlotInfo(slot)
            end
            table.insert(out, {
                slot     = slot,
                link     = link,
                id       = tonumber(link:match("item:(%d+)")),
                texture  = texture,
                quantity = (quantity and quantity > 1) and quantity or nil,
            })
        end
    end

    return out
end

local function CreateLootPicker()
    if auctionLootPicker then return auctionLootPicker end

    local parent = _G.RedGuildAuctionFrame
    if not parent then return nil end

    local p = CreateFrame("Frame", "RedGuildAuctionLootPicker", parent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    p:SetFrameStrata("DIALOG")
    p:SetSize(260, 40)
    p:EnableMouse(true)
    p:Hide()

    if p.SetBackdrop then
        p:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
    end

    p.rows = {}
    for i = 1, AUCTION_LOOT_MAX_ROWS do
        local row = CreateFrame("Button", nil, p)
        row:SetSize(244, 18)
        row:SetPoint("TOPLEFT", p, "TOPLEFT", 8, -8 - (i - 1) * 18)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        row.text:SetJustifyH("LEFT")

        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints(row)
        row.hl:SetColorTexture(1, 1, 1, 0.15)

        row:SetScript("OnClick", function(self)
            if self.link then
                RedGuild_Auction_SetItem(self.link, self.copies)
            end
            p:Hide()
        end)

        row:SetScript("OnEnter", function(self)
            if not self.link then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            -- Prefer the live loot slot so the tooltip carries the
            -- looted-quantity line; fall back to the plain link.
            if self.slot and GameTooltip.SetLootItem and (GetNumLootItems() or 0) >= self.slot then
                GameTooltip:SetLootItem(self.slot)
            else
                GameTooltip:SetHyperlink(self.link)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row:Hide()
        p.rows[i] = row
    end

    auctionLootPicker = p
    return p
end

-- Repaints the open picker. Also closes it when the loot window goes
-- away, so it can never hand out a stale slot.
function RedGuild_Auction_RefreshLootPicker()
    local p = auctionLootPicker
    if not p or not p:IsShown() then return end

    local items = AuctionLootSlots()
    if #items == 0 then
        p:Hide()
        return
    end

    -- The same item can occupy several loot slots - two tier tokens
    -- off one boss - and that is exactly the case the copies field is
    -- for, so the count is worked out here and pre-filled on click.
    local dupes = {}
    for _, it in ipairs(items) do
        if it.id then dupes[it.id] = (dupes[it.id] or 0) + 1 end
    end

    local shown = math.min(#items, AUCTION_LOOT_MAX_ROWS)
    for i = 1, shown do
        local it  = items[i]
        local row = p.rows[i]
        row.slot = it.slot
        row.link = it.link
        row.copies = math.max(
            (it.id and dupes[it.id]) or 1,
            it.quantity or 1)
        row.icon:SetTexture(it.texture or "Interface\\Icons\\INV_Misc_QuestionMark")

        local text = it.link
        if row.copies > 1 then
            text = string.format("%s |cffffff00x%d|r", it.link, row.copies)
        end
        row.text:SetText(text)
        row:Show()
    end
    for i = shown + 1, AUCTION_LOOT_MAX_ROWS do
        p.rows[i]:Hide()
    end

    p:SetHeight(16 + shown * 18)
end

function RedGuild_Auction_ToggleLootPicker()
    local p = CreateLootPicker()
    if not p then return end

    if p:IsShown() then
        p:Hide()
        return
    end

    if #AuctionLootSlots() == 0 then
        AuctionPrint("No loot window open. Open the corpse or chest first, then pick the item here.")
        return
    end

    p:ClearAllPoints()
    local anchor = _G.RedGuildAuctionFrame and _G.RedGuildAuctionFrame.lootBtn
    if anchor then
        p:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
    else
        p:SetPoint("TOP", _G.RedGuildAuctionFrame, "TOP", 0, -60)
    end

    p:Show()
    RedGuild_Auction_RefreshLootPicker()
end

-- Enables the button and shows the slot count only while there is
-- actually a loot window to read.
function RedGuild_Auction_UpdateLootButton()
    local f = _G.RedGuildAuctionFrame
    if not f or not f.lootBtn then return end

    local n = #AuctionLootSlots()
    if n > 0 then
        f.lootBtn:SetText("Loot (" .. n .. ")")
        f.lootBtn:Enable()
    else
        f.lootBtn:SetText("Loot")
        f.lootBtn:Disable()
    end
end

--------------------------------------------------
-- Loot events
--------------------------------------------------
-- Kept on its own frame so the core event handler stays untouched.
local auctionLootEvents = CreateFrame("Frame")
auctionLootEvents:RegisterEvent("LOOT_OPENED")
auctionLootEvents:RegisterEvent("LOOT_CLOSED")
auctionLootEvents:RegisterEvent("LOOT_SLOT_CLEARED")
auctionLootEvents:SetScript("OnEvent", function()
    -- LOOT_SLOT_CLEARED fires before the slot is really gone, so the
    -- repaint is deferred a frame where a timer is available.
    local function refresh()
        RedGuild_Auction_UpdateLootButton()
        RedGuild_Auction_RefreshLootPicker()
    end
    refresh()
    if C_Timer and C_Timer.After then C_Timer.After(0, refresh) end
end)

--------------------------------------------------
-- Shift-click a loot item straight into the window
--------------------------------------------------
if type(_G.LootFrameItem_OnClick) == "function" then
    hooksecurefunc("LootFrameItem_OnClick", function(self, button)
        if button and button ~= "LeftButton" then return end
        if not IsModifiedClick("CHATLINK") then return end

        local f = _G.RedGuildAuctionFrame
        if not f or not f:IsShown() then return end
        -- The link box has its own ChatEdit_InsertLink path; letting
        -- both run would load the item twice.
        if f.itemBox and f.itemBox:HasFocus() then return end
        -- Never steal a link the user meant for an open chat box.
        if ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow() then return end

        local link = GetLootSlotLink and GetLootSlotLink(self:GetID())
        if link then
            RedGuild_Auction_SetItem(link)
        end
    end)
end

function RedGuild_Auction_RefreshMaster()
    if not auctionMaster or not auctionMaster:IsShown() then return end
    local f = auctionMaster

    ----------------------------------------------------------------
    -- Header state
    ----------------------------------------------------------------
    ----------------------------------------------------------------
    -- Item line: what is up, how many, and how many have gone out
    ----------------------------------------------------------------
    local label = RedGuild_Auction.itemLink or "|cff888888No item selected|r"
    if RedGuild_Auction.posted then
        label = RedGuild_Auction_ItemLabel()
        if RedGuild_Auction.rollOnly then
            label = "|cff55ccff[ROLL]|r " .. label
        end
        local q = tonumber(RedGuild_Auction.qty) or 1
        if q > 1 then
            label = label .. string.format("  |cff888888(%d of %d awarded)|r",
                RedGuild_Auction.awarded or 0, q)
        end
    end
    f.itemText:SetText(label)

    -- Copies and roll-only are fixed for the life of an auction: the
    -- raid was told what is up, so they cannot be edited underneath it.
    if RedGuild_Auction.posted then
        f.qtyBox:Disable()
        f.rollOnlyCheck:Disable()
        f.qtyBox:SetText(tostring(tonumber(RedGuild_Auction.qty) or 1))
        f.rollOnlyCheck:SetChecked(RedGuild_Auction.rollOnly and true or false)
    else
        f.qtyBox:Enable()
        f.rollOnlyCheck:Enable()
    end

    -- Nothing is ever charged on a roll-only item, so the cost box is
    -- held at zero rather than left there to be typed into.
    local rollOnlyNow = RedGuild_Auction.posted
        and RedGuild_Auction.rollOnly
        or (not RedGuild_Auction.posted and f.rollOnlyCheck:GetChecked())
    if rollOnlyNow then
        f.costBox:SetText("0")
        f.costBox:Disable()
    else
        f.costBox:Enable()
    end

    if RedGuild_Auction.open then
        local left = RedGuild_Auction_TimeLeft()
        if RedGuild_Auction.paused then
            f.timerText:SetText(string.format("|cffffff00PAUSED %ds|r", left))
            f.pauseBtn:SetText("Resume")
        else
            local colour = left <= 5 and "|cffff5555" or "|cffffff00"
            f.timerText:SetText(string.format("%s%ds|r", colour, left))
            f.pauseBtn:SetText("Pause")
        end
        f.startBtn:Disable()
        f.stopBtn:Enable()
        f.pauseBtn:Enable()
        f.reopenBtn:Disable()
    else
        f.timerText:SetText(RedGuild_Auction.posted and "|cffff5555closed|r" or "")
        f.pauseBtn:SetText("Pause")
        f.startBtn:Enable()
        f.stopBtn:Disable()
        f.pauseBtn:Disable()
        -- Reopen only makes sense once something has actually closed
        -- without being awarded yet.
        if RedGuild_Auction.posted then
            f.reopenBtn:Enable()
        else
            f.reopenBtn:Disable()
        end
    end

    -- Who rolls off is the editor's call, so this is available
    -- whenever something is posted rather than waiting on the addon to
    -- spot a tie for itself.
    if RedGuild_Auction.posted then
        f.tieBtn:Enable()
    else
        f.tieBtn:Disable()
    end

    ----------------------------------------------------------------
    -- Rows
    ----------------------------------------------------------------
    local list  = RedGuild_Auction_SortedBids()
    local shown = math.min(#list, AUCTION_MAX_ROWS)

    for i = 1, shown do
        local b = list[i]
        local row = auctionMasterRows[i]
        if not row then
            row = CreateMasterRow(i, f.scrollChild)
            auctionMasterRows[i] = row
        end

        row.bidder = b.key

        row.nameText:SetText(ClassColour(b.name) .. b.name .. "|r")

        if b.mode == "MS" and not RedGuild_Auction.rollOnly then
            row.bidText:SetText(tostring(b.amount or 0))
        else
            -- Off spec, passes, and any roll on a roll-only item cost
            -- nothing, so there is no DKP figure - the roll column
            -- carries the number that actually matters instead.
            row.bidText:SetText("|cff888888-|r")
        end

        if b.won then
            -- Already took a copy of this item. Kept on the list so
            -- the editor can see who has what, but out of the running.
            row.modeText:SetText("|cff00ff00WON|r")
        else
            local modeColour = "|cffffffff"
            if b.mode == "OS"   then modeColour = "|cff55ccff" end
            if b.mode == "PASS" then modeColour = "|cff888888" end
            if b.late            then modeColour = "|cffff0000" end
            row.modeText:SetText(modeColour .. (b.mode or "?") .. "|r")
        end

        -- Balance is looked up live from the editor's own table, not
        -- from whatever the bidder claimed.
        local bal = RedGuild_Auction_GetBalance(b.name)
        if b.mode == "MS" and (b.amount or 0) > bal then
            row.balText:SetText("|cffff0000" .. bal .. "|r")
        else
            row.balText:SetText(tostring(bal))
        end

        row.rollText:SetText(b.roll and tostring(b.roll) or "")

        -- The tie roll sits in its own column beside the original, so
        -- both are on screen when the editor picks the winner. Amber
        -- while it is still awaited, white once it lands.
        if b.tieRoll then
            row.tieText:SetText("|cffffffff" .. b.tieRoll .. "|r")
        elseif b.tiePassed then
            row.tieText:SetText("|cff888888pass|r")
        elseif b.tieRollWant then
            row.tieText:SetText("|cffffff00...|r")
        else
            row.tieText:SetText("")
        end

        row.tieCheck:SetChecked(
            (RedGuild_Auction.tieSelected or {})[b.key] and true or false)

        -- A bid placed after bidding closed but before the item was
        -- awarded is still recorded, but the "Via" column flags it
        -- LATE so the editor can see it missed the window.
        if b.won then
            row.srcText:SetText(string.format("|cff00ff00copy %d|r", b.wonCopy or 1))
        elseif b.late then
            row.srcText:SetText("|cffff0000LATE|r")
        else
            row.srcText:SetText("|cff888888" .. (b.src or "") .. "|r")
        end

        if RedGuild_Auction.selected == b.key then
            row.hl:Show()
        else
            row.hl:Hide()
        end

        row:Show()
    end

    for i = shown + 1, #auctionMasterRows do
        auctionMasterRows[i]:Hide()
    end

    f.scrollChild:SetHeight(math.max(1, shown * 16))

    ----------------------------------------------------------------
    -- Pre-fill the cost box from the selection
    ----------------------------------------------------------------
    if RedGuild_Auction.selected then
        local b = RedGuild_Auction.bids[RedGuild_Auction.selected]
        if b and not f.costBox:HasFocus() and not rollOnlyNow then
            -- Main spec suggests the bid; off spec is always free.
            f.costBox:SetText(tostring(b.amount or 0))
        end
    end

    ----------------------------------------------------------------
    -- Award button: says which copy is going out next
    ----------------------------------------------------------------
    local copies = tonumber(RedGuild_Auction.qty) or 1
    if RedGuild_Auction.posted and copies > 1 then
        f.awardBtn:SetText(string.format("Award copy %d of %d",
            math.min((RedGuild_Auction.awarded or 0) + 1, copies), copies))
    else
        f.awardBtn:SetText("Award to selected")
    end
end

function RedGuild_Auction_ShowMaster()
    if not IsAuthorized() then
        AuctionPrint("Only editors can run bidding.")
        return
    end
    local f = CreateMaster()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        RedGuild_Auction_RefreshMaster()
    end
end

--------------------------------------------------
-- Hook a button onto the ML Scorecard tab
--------------------------------------------------

function RedGuild_Auction_AttachUI()
    if not mainFrame or not dkpPanel then return end
    if auctionButton then return end

    -- Parented to the DKP panel, so it is present on the DKP tab and
    -- hides with it. Visibility is still gated on being an editor.
    local btn = CreateFrame("Button", "RedGuildBiddingButton", dkpPanel, "UIPanelButtonTemplate")
    btn:SetSize(70, 18)
    btn:SetText("Bidding")
    btn:SetFrameStrata("HIGH")
    btn:SetScript("OnClick", RedGuild_Auction_ShowMaster)

    -- Sits just left of the Sync indicator. statusText is created by
    -- CreateUI; fall back to the frame corner if it is missing.
    local syncWidget = statusText and statusText:GetParent()
    if syncWidget then
        btn:SetPoint("RIGHT", syncWidget, "LEFT", -10, 0)
    else
        btn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -130, -4)
    end

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("|cffffff00Item Bidding|r")
        GameTooltip:AddLine("Post an item and collect DKP bids from the raid.", 1, 1, 1)
        GameTooltip:AddLine("Also available as /redguild bid", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    auctionButton = btn

    -- Editors only. Re-checked whenever the window opens or the DKP
    -- tab is shown, so the button appears as soon as an editor list
    -- sync arrives rather than needing a reload.
    local function UpdateBidButton()
        if IsEditor(UnitName("player")) then btn:Show() else btn:Hide() end
    end
    UpdateBidButton()
    mainFrame:HookScript("OnShow", UpdateBidButton)
    dkpPanel:HookScript("OnShow", UpdateBidButton)
end


