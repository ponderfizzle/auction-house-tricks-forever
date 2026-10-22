-- Auction House Dressing Room Helper
--
-- While the auction house is open and its "Hide tooltips" box is checked,
-- hide the item tooltip under the cursor and the equipped-gear comparison
-- tooltips (ShoppingTooltip1/2, the ones titled "Equipped"). Unchecking the
-- box, or closing the auction house, restores normal tooltips immediately.
--
-- That checkbox is not saved. It is created unchecked and forced off every
-- time the auction house shows or hides.
--
-- One saved option, "Close Dressing Room with Auction House", lives in
-- AHDressingRoomHelperDB. It defaults off. When it is on, closing the
-- auction house also hides DressUpFrame.
--
-- Forever uses the retail (Mainline) UI, not the Classic AuctionFrame.
-- This file only talks to AuctionHouseFrame from Blizzard_AuctionHouseUI,
-- which is load-on-demand. Hooks are filters: Blizzard's functions still
-- run, and the filter does nothing unless the window is open and the box
-- is checked at the moment a tooltip is shown.

local addonName, ns = ...

ns.name = addonName

-- ---------------------------------------------------------------------------
-- State. The Hide tooltips box is not saved. The Dressing Room option is.
-- AHDressingRoomHelperDB is created in ADDON_LOADED, not here.
-- ---------------------------------------------------------------------------

local DB_CLOSE_KEY = "closeDressingRoom"
local SETTINGS_CATEGORY_NAME = "AH Dressing Room Helper"

local checkbox
local holder
local attached = false
local settingsCategory
local settingsRegistered = false
local settingsFailed = false
local closeDressingRoomQueued = false
local CloseDressingRoomWithAuctionHouse
local attachQueued = false
local hooksInstalled = false
local canMarkItems = false
local hidingTooltip = false

-- True only between SetOwner (cleared) and the item call that filled the
-- tooltip (set). Hide does not clear it: Blizzard often hides and shows the
-- same item tooltip again, and the comparison frames can appear a moment
-- after the main tooltip. The next SetOwner starts a new cycle.
local markedItem = {}

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value)
end

local function IsShown(frame)
    return frame and frame.IsShown and frame:IsShown()
end

-- AuctionHouseFrame is not a protected frame. The check is here so a future
-- client that locks it down cannot be written during combat.
local function FrameIsLocked(frame)
    return InCombatLockdown() and frame and frame.IsProtected and frame:IsProtected()
end

local function IsUnder(widget, ancestor)
    if not widget or not ancestor or not widget.GetParent then
        return false
    end
    local current = widget
    for _ = 1, 30 do
        if current == ancestor then
            return true
        end
        if not current.GetParent then
            return false
        end
        current = current:GetParent()
        if not current then
            return false
        end
    end
    return false
end

-- The auction house itself, plus the dressing room Ctrl-click opens beside it.
-- DressUpFrame is only included while the auction house is open; see
-- AuctionHouseIsOpen, which the callers check first.
local function IsPreviewOwner(widget)
    if not widget or widget == checkbox or widget == holder then
        return false
    end
    if IsUnder(widget, AuctionHouseFrame) then
        return true
    end
    if IsUnder(widget, DressUpFrame) then
        return true
    end
    if IsUnder(widget, SideDressUpFrame) then
        return true
    end
    return false
end

local function AuctionHouseIsOpen()
    return IsShown(AuctionHouseFrame)
end

-- Read both gates every time. Do not cache "tooltips are hidden" in a flag
-- that could stay true after the window closes.
local function ShouldSuppress()
    return AuctionHouseIsOpen() and checkbox and checkbox:GetChecked()
end

-- ---------------------------------------------------------------------------
-- Deciding which tooltips are the ones that cover the preview
-- ---------------------------------------------------------------------------

local function LiveDataIsItem(tooltip)
    if not tooltip or not Enum or not Enum.TooltipDataType then
        return false
    end

    local data
    if tooltip.GetPrimaryTooltipData then
        data = tooltip:GetPrimaryTooltipData()
    elseif tooltip.GetTooltipData then
        data = tooltip:GetTooltipData()
    end
    if not data then
        return false
    end

    local dataType = data.type
    if IsSecret(dataType) then
        return false
    end
    return dataType == Enum.TooltipDataType.Item
end

local function TooltipIsItem(tooltip)
    if markedItem[tooltip] then
        return true
    end
    -- Once a marker is installed, a clear mark means this cycle is not an
    -- item (a seller-name tip, the checkbox help, a button tip). Falling
    -- through to leftover tooltip data would hide those too.
    if canMarkItems then
        return false
    end
    return LiveDataIsItem(tooltip)
end

local function ShouldHideMainTooltip(tooltip)
    if hidingTooltip or not ShouldSuppress() or tooltip ~= GameTooltip then
        return false
    end
    if not tooltip.GetOwner or not IsPreviewOwner(tooltip:GetOwner()) then
        return false
    end
    return TooltipIsItem(tooltip)
end

-- Comparison frames are only suppressed for the preview item. Hovering a bag
-- (the auction house opens your bags) keeps normal bag comparisons.
local function ShouldHideShopping()
    if not ShouldSuppress() or not GameTooltip or not GameTooltip.GetOwner then
        return false
    end
    if not IsPreviewOwner(GameTooltip:GetOwner()) then
        return false
    end
    return TooltipIsItem(GameTooltip)
end

local function ForEachShoppingTooltip(apply)
    local seen = {}
    local function once(tip)
        if tip and not seen[tip] then
            seen[tip] = true
            apply(tip)
        end
    end

    if GameTooltip and type(GameTooltip.shoppingTooltips) == "table" then
        for _, tip in ipairs(GameTooltip.shoppingTooltips) do
            once(tip)
        end
    end
    once(ShoppingTooltip1)
    once(ShoppingTooltip2)
    once(ShoppingTooltip3)
end

local function HideOne(tooltip)
    if hidingTooltip or not tooltip or not tooltip.Hide or not tooltip:IsShown() then
        return
    end
    hidingTooltip = true
    tooltip:Hide()
    hidingTooltip = false
end

local function HideShoppingTooltips()
    ForEachShoppingTooltip(HideOne)
end

local function HidePreviewTooltipsNow()
    if GameTooltip and ShouldHideMainTooltip(GameTooltip) then
        HideOne(GameTooltip)
    end
    if ShouldHideShopping() then
        HideShoppingTooltips()
    end
end

-- ---------------------------------------------------------------------------
-- Hooks. These run after Blizzard's own functions and only hide frames.
-- They do not replace GameTooltip:Show or GameTooltip_ShowCompareItem.
-- ---------------------------------------------------------------------------

local function MarkItemTooltip(tooltip)
    canMarkItems = true
    markedItem[tooltip] = true
end

local hookedShopping = {}

local function HookShoppingTooltip(tip)
    if not tip or hookedShopping[tip] or type(tip.Show) ~= "function" then
        return
    end
    hookedShopping[tip] = true

    hooksecurefunc(tip, "Show", function(self)
        if ShouldHideShopping() then
            HideOne(self)
        end
    end)

    -- Retail comparison code shows these with SetShown(true), which calls
    -- Show. Hooking both covers a client that sets the shown flag directly.
    if type(tip.SetShown) == "function" then
        hooksecurefunc(tip, "SetShown", function(self, shown)
            if shown and ShouldHideShopping() then
                HideOne(self)
            end
        end)
    end
end

local function HookShoppingTooltips()
    ForEachShoppingTooltip(HookShoppingTooltip)
end

local function InstallHooks()
    HookShoppingTooltips()
    if hooksInstalled or not GameTooltip or type(GameTooltip.Show) ~= "function" then
        return
    end
    hooksInstalled = true

    if type(GameTooltip.SetOwner) == "function" then
        hooksecurefunc(GameTooltip, "SetOwner", function(self)
            markedItem[self] = nil
        end)
    end

    -- Item setters used by the auction house (SetItemKey / SetHyperlink) and
    -- by the dressing room. Each one marks the tooltip before Show runs.
    local setters = { "SetHyperlink", "SetItemKey", "SetBagItem", "SetItemByID" }
    for i = 1, #setters do
        local name = setters[i]
        if type(GameTooltip[name]) == "function" then
            hooksecurefunc(GameTooltip, name, function(self)
                MarkItemTooltip(self)
            end)
        end
    end

    if type(TooltipDataProcessor) == "table"
        and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
        and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
            if tooltip then
                MarkItemTooltip(tooltip)
            end
        end)
    end

    hooksecurefunc(GameTooltip, "Show", function(self)
        if not ShouldHideMainTooltip(self) then
            return
        end
        HideOne(self)
        -- The comparison frames are often shown from inside the item build,
        -- before this Show returns. Sweep them now, and again if a later
        -- compare call shows them.
        HideShoppingTooltips()
    end)

    if type(GameTooltip_ShowCompareItem) == "function" then
        hooksecurefunc("GameTooltip_ShowCompareItem", function()
            if ShouldHideShopping() then
                HideShoppingTooltips()
            end
        end)
    end

    -- Current retail builds (and the 12.1.5 API Forever shares) do the real
    -- work in TooltipComparisonManager: it fills ShoppingTooltip1/2 and then
    -- shows them from AnchorShoppingTooltips. Hook that when it exists.
    if type(TooltipComparisonManager) == "table"
        and type(TooltipComparisonManager.AnchorShoppingTooltips) == "function" then
        hooksecurefunc(TooltipComparisonManager, "AnchorShoppingTooltips", function()
            if ShouldHideShopping() then
                HideShoppingTooltips()
            end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Checkbox
-- ---------------------------------------------------------------------------

local function PlayToggleSound(checked)
    if type(PlaySound) ~= "function" or type(SOUNDKIT) ~= "table" then
        return
    end
    local kit = checked and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF
    if kit then
        PlaySound(kit)
    end
end

local function FindUpdateTarget(widget)
    local current = widget
    for _ = 1, 15 do
        if not current or current == checkbox or current == holder then
            return nil
        end
        if current.UpdateTooltip and IsPreviewOwner(current) then
            return current
        end
        if not current.GetParent then
            return nil
        end
        current = current:GetParent()
    end
    return nil
end

-- Unchecking only helps at once if the cursor is still over an item row.
-- Clicking the box moves the cursor onto the box, so this often no-ops and
-- the next hover shows the tooltip. That is still immediate: the filter is
-- already off.
local function RestoreTooltipUnderCursor()
    if type(GetMouseFoci) ~= "function" then
        return
    end
    local foci = GetMouseFoci()
    if type(foci) ~= "table" then
        return
    end
    for i = 1, 20 do
        local target = FindUpdateTarget(foci[i])
        if target then
            if not FrameIsLocked(target) then
                target:UpdateTooltip()
            end
            return
        end
        if not foci[i] then
            return
        end
    end
end

local function ShowCheckboxTip(owner)
    if not GameTooltip or not GameTooltip.SetOwner then
        return
    end
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT")
    if GameTooltip.ClearLines then
        GameTooltip:ClearLines()
    end
    GameTooltip:SetText("Hide tooltips", 1, 1, 1)
    GameTooltip:AddLine("Hides the gear comparison tooltips to prevent them from obscuring the Dressing Room preview.  Uncheck this setting to bring them back.  This setting clears when the auction house window closes.", 0.9, 0.9, 0.9, true)
    GameTooltip:Show()
end

local function ResetToggle()
    if checkbox then
        checkbox:SetChecked(false)
    end
end

-- Gap kept between this control and the frame it sits beside.
local ANCHOR_GAP = 8

-- GetStringWidth is 0 until the fontstring has been drawn at least once.
local LABEL_WIDTH_FALLBACK = 96

-- How many times to remeasure after a show, once anchors have a real rect.
local layoutRetries = 0

local PlaceCheckbox

local function RectsOverlap(a, b, pad)
    if not a or not b or not a.GetLeft or not b.GetLeft then
        return false
    end
    local al, ar, at, ab = a:GetLeft(), a:GetRight(), a:GetTop(), a:GetBottom()
    local bl, br, bt, bb = b:GetLeft(), b:GetRight(), b:GetTop(), b:GetBottom()
    if not (al and ar and at and ab and bl and br and bt and bb) then
        return nil
    end
    pad = pad or 0
    return (al - pad) < br and (ar + pad) > bl and (ab - pad) < bt and (at + pad) > bb
end

local function LabelWidth()
    local textWidth = 0
    if holder.Label and holder.Label.GetStringWidth then
        textWidth = holder.Label:GetStringWidth() or 0
    end
    if textWidth >= 1 then
        return textWidth, true
    end
    return LABEL_WIDTH_FALLBACK, false
end

-- Box, then the words. Used on the results row and in the footer, where
-- there is horizontal room and the row is only about 22px tall.
local function LayoutHorizontal()
    if not holder or not holder.Label or not holder.Check then
        return
    end
    local label = holder.Label
    local button = holder.Check
    button:ClearAllPoints()
    button:SetPoint("LEFT", holder, "LEFT", 0, 0)
    label:ClearAllPoints()
    label:SetJustifyH("LEFT")
    label:SetPoint("LEFT", button, "RIGHT", 4, 1)
    local textWidth = LabelWidth()
    holder:SetSize(24 + 4 + textWidth, 24)
    button:SetHitRectInsets(0, -(textWidth + 8), -4, -4)
end

-- Words above the box. The browse search row is a short gap between the
-- search box and Filter; a horizontal label often does not fit there, and
-- this keeps the same words in that gap without crossing either control.
local function LayoutStacked()
    if not holder or not holder.Label or not holder.Check then
        return
    end
    local label = holder.Label
    local button = holder.Check
    button:ClearAllPoints()
    button:SetPoint("BOTTOM", holder, "BOTTOM", 0, 0)
    label:ClearAllPoints()
    label:SetJustifyH("CENTER")
    label:SetPoint("BOTTOM", button, "TOP", 0, 0)
    local textWidth, known = LabelWidth()
    local textHeight = 12
    if known and label.GetStringHeight then
        local measured = label:GetStringHeight() or 0
        if measured > 4 then
            textHeight = measured
        end
    end
    local width = textWidth
    if width < 24 then
        width = 24
    end
    holder:SetSize(width, textHeight + 24)
    local side = (width - 24) / 2
    button:SetHitRectInsets(-(side + 4), -(side + 4), -(textHeight + 4), -4)
end

local function RaiseHolder(ahFrame)
    local level = (ahFrame:GetFrameLevel() or 0) + 30
    -- Buy/cancel dialogs use DialogOverlay at frame level 1000. Stay under it.
    if level > 980 then
        level = 980
    end
    holder:SetFrameLevel(level)
    if holder.Check then
        holder.Check:SetFrameLevel(level + 1)
    end
end

-- Gear results and commodity results both pull their "N Available" row
-- (ItemList.RefreshFrame, 200x20) up onto the Back button's row.
-- Gear uses refreshFrameYOffset 132; commodities uses 30. Either way the
-- row under the search bar, left of that frame, is empty: Back ends near
-- x=293 and the count frame starts near x=591 on the 800-wide window.
local function ShownRefresh(frame)
    if not IsShown(frame) or not frame.ItemList then
        return nil
    end
    local refresh = frame.ItemList.RefreshFrame
    if IsShown(refresh) then
        return refresh
    end
    return nil
end

local function AnchorBeside(frame, relativeTo, gap)
    frame:ClearAllPoints()
    frame:SetPoint("RIGHT", relativeTo, "LEFT", -gap, 0)
end

local function DetailIsBlocked(ahFrame, refresh)
    if not holder:GetLeft() then
        return nil
    end
    local blocked = RectsOverlap(holder, refresh, 2)
    if blocked == nil then
        return nil
    end
    if blocked then
        return true
    end

    local frames = {}
    if IsShown(ahFrame.ItemBuyFrame) then
        frames[#frames + 1] = ahFrame.ItemBuyFrame.BackButton
        frames[#frames + 1] = ahFrame.ItemBuyFrame.ItemDisplay
        frames[#frames + 1] = ahFrame.ItemBuyFrame.ItemList
    end
    if IsShown(ahFrame.CommoditiesBuyFrame) then
        frames[#frames + 1] = ahFrame.CommoditiesBuyFrame.BackButton
        frames[#frames + 1] = ahFrame.CommoditiesBuyFrame.BuyDisplay
        frames[#frames + 1] = ahFrame.CommoditiesBuyFrame.ItemList
    end
    for i = 1, #frames do
        local hit = RectsOverlap(holder, frames[i], 2)
        if hit == nil then
            return nil
        end
        if hit then
            return true
        end
    end
    return false
end

-- Category browse hides its refresh row (hideRefreshFrame) and has no Back
-- button. Column headers start just under the search bar, so the results
-- row from the retail mockup is the header row here. The clear spot on the
-- Forever beta is the gap between the search box and Filter.
local function SearchIsBlocked(ahFrame)
    if not holder:GetLeft() then
        return nil
    end
    local bar = ahFrame.SearchBar
    if not bar then
        return false
    end
    local obstacles = { bar.SearchBox, bar.FilterButton, bar.FavoritesSearchButton, bar.SearchButton }
    for i = 1, #obstacles do
        local hit = RectsOverlap(holder, obstacles[i], 1)
        if hit == nil then
            return nil
        end
        if hit then
            return true
        end
    end

    local lists = {}
    if IsShown(ahFrame.BrowseResultsFrame) and ahFrame.BrowseResultsFrame.ItemList then
        lists[#lists + 1] = ahFrame.BrowseResultsFrame.ItemList
    end
    if IsShown(ahFrame.WoWTokenResults) then
        lists[#lists + 1] = ahFrame.WoWTokenResults
    end
    for i = 1, #lists do
        local hit = RectsOverlap(holder, lists[i], 1)
        if hit == nil then
            return nil
        end
        if hit then
            return true
        end
    end
    return false
end

-- Sell, Auctions, and a browse locale whose Filter label eats the search-row
-- gap. The coin display is 158px at the bottom left. To its right, under the
-- category list and the results, is empty frame padding.
local function AnchorFooter(ahFrame)
    holder:ClearAllPoints()
    local money = ahFrame.MoneyFrameBorder
    if money then
        holder:SetPoint("LEFT", money, "RIGHT", 16, -2)
    else
        holder:SetPoint("BOTTOMLEFT", ahFrame, "BOTTOMLEFT", 190, 4)
    end
end

local function ScheduleLayoutRetry(ahFrame)
    if layoutRetries >= 2 then
        return
    end
    if not (C_Timer and type(C_Timer.After) == "function") then
        return
    end
    layoutRetries = layoutRetries + 1
    C_Timer.After(0, function()
        PlaceCheckbox(ahFrame)
    end)
end

-- GetLeft/GetRight are screen pixels. SetPoint offsets are in the holder's
-- own scale. Divide so a scaled auction frame still lands on the midpoint.
local function ScreenGapToLocal(leftFrame, rightEdge, leftEdge)
    local scale = 1
    if leftFrame.GetEffectiveScale then
        scale = leftFrame:GetEffectiveScale() or 1
    end
    if scale == 0 then
        scale = 1
    end
    return (rightEdge - leftEdge) / scale
end

-- Center the control in the open space between the search box and Filter.
-- Returns nil when those edges are not measurable yet.
local function AnchorCenteredInSearchGap(bar)
    local box = bar.SearchBox
    local filter = bar.FilterButton
    if not box or not filter or not box.GetRight or not filter.GetLeft then
        return nil
    end
    local boxRight = box:GetRight()
    local filterLeft = filter:GetLeft()
    local width = holder:GetWidth()
    if not boxRight or not filterLeft or not width or width < 1 then
        return nil
    end
    local gap = ScreenGapToLocal(holder, filterLeft, boxRight)
    local rightGap = (gap - width) / 2
    holder:ClearAllPoints()
    holder:SetPoint("RIGHT", filter, "LEFT", -rightGap, 0)
    return true
end

-- Item results: right edge 8px left of the count/refresh row, in line with Back.
-- Category browse on the Forever beta: column headers fill that row, so the
-- control sits in the search row. Its midpoint is halfway between the search
-- box's right edge and Filter's left edge. A line that would cross the search
-- box is stacked (words above the box) in that same gap. If that still
-- collides, the control moves to the footer beside the money display.
local function TrySearchRow(ahFrame, layout)
    local bar = ahFrame.SearchBar
    if not (IsShown(bar) and bar.FilterButton) then
        return false
    end
    layout()
    local centered = AnchorCenteredInSearchGap(bar)
    if centered == nil then
        AnchorBeside(holder, bar.FilterButton, ANCHOR_GAP)
        if IsShown(ahFrame) then
            ScheduleLayoutRetry(ahFrame)
        end
        return true
    end
    local blocked = SearchIsBlocked(ahFrame)
    if blocked == nil and IsShown(ahFrame) then
        ScheduleLayoutRetry(ahFrame)
        return true
    end
    layoutRetries = 0
    return not blocked
end

PlaceCheckbox = function(ahFrame)
    if not holder or not ahFrame then
        return
    end
    RaiseHolder(ahFrame)

    local refresh = ShownRefresh(ahFrame.ItemBuyFrame) or ShownRefresh(ahFrame.CommoditiesBuyFrame)
    if refresh then
        LayoutHorizontal()
        AnchorBeside(holder, refresh, ANCHOR_GAP)
        local blocked = DetailIsBlocked(ahFrame, refresh)
        if blocked == nil and IsShown(ahFrame) then
            ScheduleLayoutRetry(ahFrame)
            return
        end
        layoutRetries = 0
        if not blocked then
            return
        end
    end

    -- Horizontal first, then the narrower stack, then the footer.
    if TrySearchRow(ahFrame, LayoutHorizontal) then
        return
    end
    if TrySearchRow(ahFrame, LayoutStacked) then
        return
    end

    LayoutHorizontal()
    AnchorFooter(ahFrame)
    layoutRetries = 0
end

local function AttachCheckbox(ahFrame)
    if attached or checkbox then
        return
    end
    if FrameIsLocked(ahFrame) then
        attachQueued = true
        return
    end

    -- One frame holds the box and the words so a single anchor moves both.
    -- Parent stays the auction frame; the box is not a named global.
    local holderFrame = CreateFrame("Frame", nil, ahFrame)
    holderFrame:SetSize(24 + 4 + LABEL_WIDTH_FALLBACK, 24)
    holder = holderFrame

    local button = CreateFrame("CheckButton", nil, holderFrame, "UICheckButtonTemplate")
    button:SetSize(24, 24)
    button:SetChecked(false)
    button:ClearAllPoints()
    button:SetPoint("LEFT", holderFrame, "LEFT", 0, 0)
    -- Remember it before the rest of the setup. A second call cannot create
    -- another box if anything below errors on a future client.
    checkbox = button
    holderFrame.Check = button

    -- The template ships its own font string. Hide it and draw the label to
    -- the right of the box, in normal reading order.
    if button.Text then
        button.Text:SetText("")
        button.Text:Hide()
    end

    local label = holderFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetJustifyH("LEFT")
    label:SetText("Hide tooltips")
    label:SetPoint("LEFT", button, "RIGHT", 4, 1)
    holderFrame.Label = label
    LayoutHorizontal()
    PlaceCheckbox(ahFrame)

    button:HookScript("OnShow", function()
        PlaceCheckbox(ahFrame)
    end)

    button:SetScript("OnClick", function(self)
        if not AuctionHouseIsOpen() then
            self:SetChecked(false)
            return
        end
        local checked = self:GetChecked() and true or false
        if checked then
            HidePreviewTooltipsNow()
        else
            RestoreTooltipUnderCursor()
        end
        PlayToggleSound(checked)
    end)

    button:SetScript("OnEnter", function(self)
        ShowCheckboxTip(self)
    end)
    button:SetScript("OnLeave", function(self)
        if GameTooltip and GameTooltip.GetOwner and GameTooltip:GetOwner() == self then
            GameTooltip:Hide()
        end
    end)

    attached = true
    attachQueued = false

    -- HookScript does not fire for a frame that is already on screen, so a
    -- late attach (the UI is load-on-demand) resets the box itself.
    if IsShown(ahFrame) then
        ResetToggle()
    end

    ahFrame:HookScript("OnShow", ResetToggle)
    ahFrame:HookScript("OnHide", ResetToggle)
    ahFrame:HookScript("OnHide", function()
        CloseDressingRoomWithAuctionHouse()
    end)

    -- SetDisplayMode hides the old panes, then shows the new ones, then
    -- returns. Repositioning from here sees the final view, so the box does
    -- not flash through the browse spot on the way to an item.
    if type(hooksecurefunc) == "function" and type(ahFrame.SetDisplayMode) == "function" then
        hooksecurefunc(ahFrame, "SetDisplayMode", function()
            PlaceCheckbox(ahFrame)
        end)
    end

    PlaceCheckbox(ahFrame)
end

local function TryAttach()
    InstallHooks()
    if not AuctionHouseFrame then
        return
    end
    AttachCheckbox(AuctionHouseFrame)
end

local function TryAttachSoon()
    if AuctionHouseFrame then
        TryAttach()
        return
    end
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0, TryAttach)
    end
end

-- ---------------------------------------------------------------------------
-- Saved option. Hide tooltips stays ephemeral. This one does not.
-- ---------------------------------------------------------------------------

local function InitDB()
    -- SavedVariables are applied just before this addon's ADDON_LOADED.
    -- Creating the table here, not at file scope, is what the Forever guide asks.
    if type(AHDressingRoomHelperDB) ~= "table" then
        AHDressingRoomHelperDB = {}
    end
    if AHDressingRoomHelperDB[DB_CLOSE_KEY] == nil then
        AHDressingRoomHelperDB[DB_CLOSE_KEY] = false
    end
end

local function CloseDressingRoomEnabled()
    return type(AHDressingRoomHelperDB) == "table" and AHDressingRoomHelperDB[DB_CLOSE_KEY] == true
end

local function HideDressingRoomFrame()
    if type(HideUIPanel) == "function" then
        HideUIPanel(DressUpFrame)
        return
    end
    if DressUpFrame.Hide then
        DressUpFrame:Hide()
    end
end

-- X, walking away, and AUCTION_HOUSE_CLOSED all land here. Escape already
-- closes both windows; hiding an already-hidden DressUpFrame is a no-op.
-- Off leaves the Dressing Room where it is.
CloseDressingRoomWithAuctionHouse = function()
    if not CloseDressingRoomEnabled() then
        closeDressingRoomQueued = false
        return
    end
    if not DressUpFrame or not IsShown(DressUpFrame) then
        closeDressingRoomQueued = false
        return
    end
    -- DressUpFrame is a protected UI panel. HideUIPanel during combat is blocked.
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        closeDressingRoomQueued = true
        return
    end
    closeDressingRoomQueued = false
    HideDressingRoomFrame()
end

local function RegisterSettings()
    if settingsRegistered then
        return true
    end
    -- A failed attempt must not run again. A second category would duplicate
    -- the AddOns entry. Missing API is not a failure: PLAYER_LOGIN retries it.
    if settingsFailed then
        return false
    end
    if type(Settings) ~= "table" then
        return false
    end
    if type(Settings.RegisterVerticalLayoutCategory) ~= "function"
        or type(Settings.RegisterAddOnSetting) ~= "function"
        or type(Settings.CreateCheckbox) ~= "function"
        or type(Settings.RegisterAddOnCategory) ~= "function"
        or type(Settings.VarType) ~= "table" then
        return false
    end

    InitDB()

    -- pcall only isolates a Lua error from a changed signature. It does not
    -- make a protected call safe, and none of these touch combat-locked frames.
    local ok, category, layout = pcall(Settings.RegisterVerticalLayoutCategory, SETTINGS_CATEGORY_NAME)
    if not ok or not category then
        settingsFailed = true
        return false
    end

    -- Same header row the Game options use (Controls, Mouse, and so on).
    -- The checkbox still registers if this header helper is missing.
    if layout and layout.AddInitializer and type(CreateSettingsListSectionHeaderInitializer) == "function" then
        pcall(function()
            layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Dressing Room"))
        end)
    end

    local settingOk, setting = pcall(
        Settings.RegisterAddOnSetting,
        category,
        "AHDressingRoomHelper_CloseDressingRoom",
        DB_CLOSE_KEY,
        AHDressingRoomHelperDB,
        Settings.VarType.Boolean,
        "Close Dressing Room with Auction House",
        false
    )
    if not settingOk or not setting then
        settingsFailed = true
        return false
    end

    local checkboxOk = pcall(
        Settings.CreateCheckbox,
        category,
        setting,
        "When checked, closing the auction house also closes the Dressing Room. The close button, walking away, and other close paths all count. Leave this off and the Dressing Room stays up."
    )
    if not checkboxOk then
        settingsFailed = true
        return false
    end

    local categoryOk = pcall(Settings.RegisterAddOnCategory, category)
    if not categoryOk then
        settingsFailed = true
        return false
    end

    settingsCategory = category
    settingsRegistered = true
    return true
end

local function OpenSettings()
    if not RegisterSettings() or not settingsCategory or not settingsCategory.GetID then
        return false
    end
    if type(Settings) ~= "table" or type(Settings.OpenToCategory) ~= "function" then
        return false
    end
    local categoryID = settingsCategory:GetID()
    if type(categoryID) ~= "number" then
        return false
    end
    Settings.OpenToCategory(categoryID)
    return true
end

-- WoW matches slash commands without regard to case. Both spellings are
-- registered so /ahdrh and /AHDRH open the same category.
SLASH_AHDRESSINGROOMHELPER1 = "/ahdrh"
SLASH_AHDRESSINGROOMHELPER2 = "/AHDRH"
SlashCmdList.AHDRESSINGROOMHELPER = function()
    if not OpenSettings() then
        print("AH Dressing Room Helper: open Game Menu, Options, AddOns, then AH Dressing Room Helper.")
    end
end

-- ---------------------------------------------------------------------------
-- Events. One frame, one dispatcher. The auction-house UI loads later.
-- ---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")

function eventFrame:ADDON_LOADED(loaded)
    if loaded == addonName then
        InitDB()
        RegisterSettings()
    end
    if loaded == "Blizzard_AuctionHouseUI" then
        TryAttach()
    end
end

function eventFrame:AUCTION_HOUSE_SHOW()
    -- Show can beat creation of the load-on-demand frame. Try now, and once
    -- on the next frame if the frame is not there yet. ADDON_LOADED covers
    -- the case where the UI loads after that.
    --
    -- Only the first show needs a reset from this event (the OnShow hook is
    -- not installed yet). Later opens are reset by that hook. Resetting here
    -- on every show would clear the box if this event ever fired again
    -- while the window was already open.
    local hadCheckbox = checkbox ~= nil
    TryAttachSoon()
    if not hadCheckbox then
        ResetToggle()
    end
end

function eventFrame:AUCTION_HOUSE_CLOSED()
    ResetToggle()
    CloseDressingRoomWithAuctionHouse()
end

function eventFrame:PLAYER_LOGIN()
    InstallHooks()
    InitDB()
    RegisterSettings()
end

function eventFrame:PLAYER_REGEN_ENABLED()
    if attachQueued then
        TryAttach()
    end
    if closeDressingRoomQueued and not AuctionHouseIsOpen() then
        CloseDressingRoomWithAuctionHouse()
    else
        closeDressingRoomQueued = false
    end
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    local handler = self[event]
    if handler then
        handler(self, ...)
    end
end)

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

InstallHooks()
