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
-- Two saved options live in AHDressingRoomHelperDB. Both default off.
-- "Close Dressing Room with Auction House" also hides DressUpFrame when
-- the auction house closes. "Dim unsellable items when Sell tab selected"
-- fades bag items that cannot be posted, and only while that tab is open.
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
local DB_DIM_KEY = "dimUnsellable"
local SETTINGS_CATEGORY_NAME = "AH Dressing Room Helper"

local checkbox
local holder
local attached = false
local settingsCategory
local settingsPanel
local settingsCloseCheck
local settingsDimCheck
local settingsDimNote
local settingsRegistered = false
local settingsFailed = false
local closeDressingRoomQueued = false
local CloseDressingRoomWithAuctionHouse
local RequestDimRefresh
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

-- Minimum open space between the search box and Filter before the control
-- moves left of the favorites star instead of sitting in the gap.
local SEARCH_ROW_MIN_GAP = 8

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

-- Center the holder in the gap between the search box and Filter. The left
-- edge of the holder is offset from the search box's right edge by half of
-- (gap - width), so the combined checkbox and label are centered, not just
-- the checkbox. Returns "placed", "tight", or nil when edges are unknown.
local function PlaceCenteredInSearchGap(bar, layout)
    if not bar or not bar.SearchBox or not bar.FilterButton then
        return nil
    end
    holder:SetParent(bar)
    layout()
    local box = bar.SearchBox
    local filter = bar.FilterButton
    local boxRight = box.GetRight and box:GetRight()
    local filterLeft = filter.GetLeft and filter:GetLeft()
    local width = holder:GetWidth()
    if not boxRight or not filterLeft or not width or width < 1 then
        return nil
    end
    local gap = ScreenGapToLocal(holder, filterLeft, boxRight)
    if gap < width + SEARCH_ROW_MIN_GAP then
        return "tight"
    end
    holder:ClearAllPoints()
    holder:SetPoint("LEFT", box, "RIGHT", (gap - width) / 2, 0)
    return "placed"
end

-- When the search-to-Filter gap is too narrow, sit just left of the star.
local function PlaceLeftOfFavorites(bar, layout)
    local fav = bar and bar.FavoritesSearchButton
    if not fav then
        return false
    end
    holder:SetParent(bar)
    layout()
    holder:ClearAllPoints()
    holder:SetPoint("RIGHT", fav, "LEFT", -8, 0)
    return true
end

-- Browse and item detail both keep SearchBar visible. Parent to SearchBar and
-- anchor from the search box / Filter geometry only, never from Back or the
-- refresh row, so the control does not jump when a listing is opened.
local function TryStableSearchPlacement(ahFrame, bar)
    local state = PlaceCenteredInSearchGap(bar, LayoutHorizontal)
    if state == nil then
        return nil
    end
    if state == "placed" then
        local blocked = SearchIsBlocked(ahFrame)
        if blocked == nil then
            return nil
        end
        if not blocked then
            return true
        end
    end

    if PlaceLeftOfFavorites(bar, LayoutHorizontal) then
        local blocked = SearchIsBlocked(ahFrame)
        if blocked == nil then
            return nil
        end
        if not blocked then
            return true
        end
    end

    state = PlaceCenteredInSearchGap(bar, LayoutStacked)
    if state == "placed" then
        local blocked = SearchIsBlocked(ahFrame)
        if blocked == nil then
            return nil
        end
        if not blocked then
            return true
        end
    end

    if PlaceLeftOfFavorites(bar, LayoutStacked) then
        return true
    end

    if state == "tight" and PlaceLeftOfFavorites(bar, LayoutHorizontal) then
        return true
    end
    return state == "placed"
end

PlaceCheckbox = function(ahFrame)
    if not holder or not ahFrame then
        return
    end
    RaiseHolder(ahFrame)

    local bar = ahFrame.SearchBar
    if IsShown(bar) and bar and bar.SearchBox and bar.FilterButton then
        local ok = TryStableSearchPlacement(ahFrame, bar)
        if ok == nil then
            if IsShown(ahFrame) then
                ScheduleLayoutRetry(ahFrame)
            end
            return
        end
        if ok then
            layoutRetries = 0
            return
        end
    end

    holder:SetParent(ahFrame)
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
        if RequestDimRefresh then
            RequestDimRefresh()
        end
    end)

    -- SetDisplayMode hides the old panes, then shows the new ones, then
    -- returns. Repositioning from here sees the final view, so the box does
    -- not flash through the browse spot on the way to an item. The same
    -- moment is when Buy / Sell / Auctions has actually changed.
    if type(hooksecurefunc) == "function" and type(ahFrame.SetDisplayMode) == "function" then
        hooksecurefunc(ahFrame, "SetDisplayMode", function()
            PlaceCheckbox(ahFrame)
            if RequestDimRefresh then
                RequestDimRefresh()
            end
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
    if AHDressingRoomHelperDB[DB_DIM_KEY] == nil then
        AHDressingRoomHelperDB[DB_DIM_KEY] = false
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

-- ---------------------------------------------------------------------------
-- Dim unsellable bag items while the Sell tab is open.
--
-- Default bags (ContainerFrame1..N and ContainerFrameCombinedBags) are the
-- primary path. Bagnon is the secondary path and was checked against
-- BagBrother's item button, which resets alpha inside UpdateBorder.
-- Baganator, AdiBags, BetterBags, and ArkInventory each have a small
-- adapter that runs only when that add-on is loaded. A generic bag+slot
-- scan covers a button the adapters miss.
--
-- A known unsupported bag add-on grays out the setting and skips dimming.
-- The saved checkbox value is left alone. Any unexpected error stops
-- dimming for this session, restores what we changed, and prints once.
-- ---------------------------------------------------------------------------

local DIM_ALPHA = 0.35
local DIM_TOOLTIP = "While the Sell tab is open, items in your bags that cannot be posted are dimmed. Soulbound items are dimmed. A quest item is dimmed only when it cannot be posted, not just because it is a quest item. Leaving the Sell tab, closing the auction house, or turning this off restores every icon."
local SUPPORTED_BAGS = "default bags, Bagnon, Baganator, AdiBags, BetterBags, ArkInventory"

-- Folder names (the name C_AddOns.IsAddOnLoaded expects), plus a short label
-- used when the TOC title cannot be read. These UIs replace the bag buttons
-- in ways this add-on does not hook.
local UNSUPPORTED_BAG_ADDONS = {
    { name = "Combuctor", label = "Combuctor" },
    { name = "Inventorian", label = "Inventorian" },
    { name = "LiteBag", label = "LiteBag" },
    { name = "Sorted", label = "Sorted" },
    { name = "cargBags", label = "cargBags" },
    { name = "cargBags_Nivaya", label = "cargBags Nivaya" },
    { name = "cargBags_Smoof", label = "cargBags Smoof" },
    { name = "cargBags_Simplicity", label = "cargBags Simplicity" },
    { name = "Baggins", label = "Baggins" },
    { name = "BaudBag", label = "BaudBag" },
    { name = "OneBag", label = "OneBag" },
    { name = "OneBag3", label = "OneBag3" },
    { name = "ElvUI", label = "ElvUI" },
    { name = "Tukui", label = "Tukui" },
}

local SELL_PANE_KEYS = {
    "ItemSellFrame",
    "CommoditiesSellFrame",
    "WoWTokenSellFrame",
    "PostAuctionsFrame",
    "CreateAuctionFrame",
    "SellFrame",
    "AuctionSellFrame",
}

local BIND_LINE_GLOBALS = {
    "ITEM_SOULBOUND",
    "ITEM_BIND_ON_PICKUP",
    "ITEM_BIND_QUEST",
    "ITEM_CONJURED",
    "ITEM_ACCOUNTBOUND",
    "ITEM_BIND_TO_ACCOUNT",
    "ITEM_BNETACCOUNTBOUND",
    "ITEM_BIND_TO_BNETACCOUNT",
}

local dimState = setmetatable({}, { __mode = "k" })
local seenButtons = setmetatable({}, { __mode = "k" })
local hookedButtons = setmetatable({}, { __mode = "k" })
local hookedContainers = setmetatable({}, { __mode = "k" })
local passButtons = {}
local unsupportedLabel
local dimSessionDisabled = false
local dimCombatQueued = false
local dimRestoring = false
local dimApplying = false
local dimScanning = false
local dimTickerOn = false
local dimActive = false
local dimEpoch = 0
local scanEpoch = 0
local sellProbe
local bagnonMethodsHooked = false
local arkMethodsHooked = false
local baganatorRegistered = false
local lastGenericScan = 0

local function PlainString(value)
    if IsSecret(value) or type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

local function AddonLoaded(name)
    if C_AddOns and type(C_AddOns.IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, name)
        if ok and loaded == true then
            return true
        end
    end
    if type(IsAddOnLoaded) == "function" then
        local ok, loaded = pcall(IsAddOnLoaded, name)
        if ok and loaded == true then
            return true
        end
    end
    return false
end

local function AddonTitle(entry)
    local title
    if C_AddOns and type(C_AddOns.GetAddOnMetadata) == "function" then
        local ok, value = pcall(C_AddOns.GetAddOnMetadata, entry.name, "Title")
        if ok then
            title = PlainString(value)
        end
    elseif type(GetAddOnMetadata) == "function" then
        local ok, value = pcall(GetAddOnMetadata, entry.name, "Title")
        if ok then
            title = PlainString(value)
        end
    end
    if title then
        title = title:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        title = title:gsub("^%s+", ""):gsub("%s+$", "")
        if title ~= "" then
            return title
        end
    end
    return entry.label
end

local function RefreshUnsupportedLabel()
    local found = {}
    for i = 1, #UNSUPPORTED_BAG_ADDONS do
        local entry = UNSUPPORTED_BAG_ADDONS[i]
        if AddonLoaded(entry.name) then
            found[#found + 1] = AddonTitle(entry)
        end
    end
    if #found == 0 then
        unsupportedLabel = nil
    else
        unsupportedLabel = table.concat(found, ", ")
    end
end

local function UnsupportedBagLabel()
    return unsupportedLabel
end

local function DimBlockedTooltip(label)
    return "Not available with " .. label .. ". Supported: " .. SUPPORTED_BAGS .. "."
end

local function DimCheckboxTooltip()
    RefreshUnsupportedLabel()
    if unsupportedLabel then
        return DimBlockedTooltip(unsupportedLabel)
    end
    return DIM_TOOLTIP
end

local function DimSavedOn()
    return type(AHDressingRoomHelperDB) == "table" and AHDressingRoomHelperDB[DB_DIM_KEY] == true
end

-- Equipped bags only: backpack 0, bags 1-4, reagent bag 5. Bank, keyring,
-- and account-bank ids are outside this range on purpose.
local function IsPlayerCarryBag(bag)
    if type(bag) ~= "number" or IsSecret(bag) then
        return false
    end
    return bag >= 0 and bag <= 5
end

local function SlotOk(slot)
    return type(slot) == "number" and not IsSecret(slot) and slot >= 1 and slot <= 200
end

local function WindowTitle(ah)
    if ah.TitleText and ah.TitleText.GetText then
        local text = PlainString(ah.TitleText:GetText())
        if text then
            return text
        end
    end
    if ah.TitleContainer and ah.TitleContainer.TitleText and ah.TitleContainer.TitleText.GetText then
        return PlainString(ah.TitleContainer.TitleText:GetText())
    end
    return nil
end

local function TitleLooksLikeSell(text)
    text = PlainString(text)
    if not text then
        return false
    end
    local sellTitle = PlainString(_G.AUCTION_HOUSE_FRAME_TITLE_SELL)
    if sellTitle and text == sellTitle then
        return true
    end
    local lower = text:lower()
    if lower:find("browse", 1, true) then
        return false
    end
    if lower:find("post auction", 1, true) or lower:find("create auction", 1, true) or lower:find("sell auction", 1, true) then
        return true
    end
    return lower == "sell"
end

-- Forever's sell window is titled "Post Auctions" and is not the retail
-- item-sell layout. Any one positive check is enough. A false from
-- IsListingAuctions is not final, because that method only knows retail modes.
local function SellTabIsSelected()
    local ah = AuctionHouseFrame
    if not ah then
        return false
    end

    if type(ah.IsListingAuctions) == "function" then
        local ok, listing = pcall(ah.IsListingAuctions, ah)
        if ok and listing == true and not IsSecret(listing) then
            return true
        end
    end

    if type(AuctionHouseFrameDisplayMode) == "table" and type(ah.GetDisplayMode) == "function" then
        local ok, mode = pcall(ah.GetDisplayMode, ah)
        if ok and mode and (
            mode == AuctionHouseFrameDisplayMode.ItemSell
            or mode == AuctionHouseFrameDisplayMode.CommoditiesSell
            or mode == AuctionHouseFrameDisplayMode.WoWTokenSell
        ) then
            return true
        end
    end

    if ah.SellTab and type(ah.SellTab.GetChecked) == "function" then
        local checkedOk, checked = pcall(ah.SellTab.GetChecked, ah.SellTab)
        if checkedOk and checked and not IsSecret(checked) then
            return true
        end
    end

    if type(PanelTemplates_GetSelectedTab) == "function" and ah.Tabs and ah.SellTab then
        local ok, index = pcall(PanelTemplates_GetSelectedTab, ah)
        if ok and type(index) == "number" and not IsSecret(index) and ah.Tabs[index] == ah.SellTab then
            return true
        end
    end

    for i = 1, #SELL_PANE_KEYS do
        if IsShown(ah[SELL_PANE_KEYS[i]]) then
            return true
        end
    end

    local title = WindowTitle(ah)
    if TitleLooksLikeSell(title) then
        return true
    end

    -- Buy / Sell / Auctions, in that order, on the retail frame and on the
    -- Forever screenshots. Used only when the title did not say otherwise.
    if type(PanelTemplates_GetSelectedTab) == "function" and not title then
        local ok, index = pcall(PanelTemplates_GetSelectedTab, ah)
        if ok and index == 2 and not IsSecret(index) then
            return true
        end
    end

    return false
end

local function ShouldDimBags()
    if dimSessionDisabled or unsupportedLabel then
        return false
    end
    if not DimSavedOn() or not AuctionHouseIsOpen() then
        return false
    end
    return SellTabIsSelected()
end

local function StripColor(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function LineMarksUnsellable(value)
    local text = PlainString(value)
    if not text then
        return false
    end
    text = StripColor(text)
    for i = 1, #BIND_LINE_GLOBALS do
        local globalLine = PlainString(_G[BIND_LINE_GLOBALS[i]])
        if globalLine and text == globalLine then
            return true
        end
    end
    local lower = text:lower()
    if lower:find("binds when equipped", 1, true) or lower:find("binds when used", 1, true) or lower:find("until equipped", 1, true) then
        return false
    end
    if lower:find("soulbound", 1, true) or lower:sub(1, 8) == "conjured" then
        return true
    end
    if lower == "quest item" then
        return true
    end
    if lower:find("account bound", 1, true) or lower:find("binds to account", 1, true) then
        return true
    end
    return false
end

-- true: can be posted. false: cannot. nil: empty or unknown (leave it alone).
-- IsSellItemValid is asked first, with displayError false so a soulbound
-- item does not pop a Blizzard error. The fallback never uses item class.
local function ItemCanBePosted(bag, slot)
    if not IsPlayerCarryBag(bag) or not SlotOk(slot) then
        return nil
    end
    if not ItemLocation or type(ItemLocation.CreateFromBagAndSlot) ~= "function" then
        return nil
    end

    local ok, loc = pcall(ItemLocation.CreateFromBagAndSlot, bag, slot)
    if not ok or not loc or IsSecret(loc) then
        return nil
    end
    if loc.IsValid then
        local validOk, valid = pcall(loc.IsValid, loc)
        if validOk and valid == false then
            return nil
        end
    end
    if C_Item and type(C_Item.DoesItemExist) == "function" then
        local existsOk, exists = pcall(C_Item.DoesItemExist, loc)
        if existsOk and exists == false then
            return nil
        end
    end
    if C_Container and type(C_Container.GetContainerItemInfo) == "function" then
        local infoOk, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
        if infoOk and type(info) ~= "table" then
            return nil
        end
    end

    if sellProbe ~= "none" and C_AuctionHouse and type(C_AuctionHouse.IsSellItemValid) == "function" then
        if sellProbe ~= "one" then
            local apiOk, result = pcall(C_AuctionHouse.IsSellItemValid, loc, false)
            if apiOk and type(result) == "boolean" and not IsSecret(result) then
                sellProbe = "two"
                return result
            end
            if not apiOk then
                sellProbe = "one"
            end
        end
        if sellProbe == "one" then
            local apiOk, result = pcall(C_AuctionHouse.IsSellItemValid, loc)
            if apiOk and type(result) == "boolean" and not IsSecret(result) then
                return result
            end
            if not apiOk then
                sellProbe = "none"
            end
        end
    end

    local decided = false
    if C_Item and type(C_Item.IsBound) == "function" then
        local boundOk, bound = pcall(C_Item.IsBound, loc)
        if boundOk and not IsSecret(bound) then
            decided = true
            if bound == true then
                return false
            end
        end
    end

    if C_TooltipInfo and type(C_TooltipInfo.GetBagItem) == "function" then
        local tipOk, tip = pcall(C_TooltipInfo.GetBagItem, bag, slot)
        if tipOk and type(tip) == "table" and type(tip.lines) == "table" then
            decided = true
            for i = 1, #tip.lines do
                local line = tip.lines[i]
                if type(line) == "table" and (LineMarksUnsellable(line.leftText) or LineMarksUnsellable(line.rightText)) then
                    return false
                end
            end
        end
    end

    if decided then
        return true
    end
    return nil
end

local function ButtonIcon(button)
    if type(button.icon) == "table" then
        return button.icon
    end
    if type(button.Icon) == "table" then
        return button.Icon
    end
    if type(button.IconTexture) == "table" then
        return button.IconTexture
    end
    if button.GetName then
        local name = button:GetName()
        if type(name) == "string" then
            local tex = _G[name .. "IconTexture"]
            if type(tex) == "table" then
                return tex
            end
        end
    end
    return nil
end

local function CurrentAlpha(button)
    if button.GetAlpha then
        local alpha = button:GetAlpha()
        if type(alpha) == "number" and not IsSecret(alpha) then
            return alpha
        end
    end
    return 1
end

local function IconIsDesaturated(icon)
    if icon and icon.IsDesaturated then
        local ok, value = pcall(icon.IsDesaturated, icon)
        if ok and type(value) == "boolean" and not IsSecret(value) then
            return value
        end
    end
    return nil
end

-- Bagnon stores the bag on the button (.bag / GetBag) and the slot in
-- GetID(). Blizzard's GetBagID falls back to the parent frame's id, which
-- is correct for a container slot and wrong for a Bagnon slot, so the
-- button's own bag field wins when it is present.
-- AdiBags and BetterBags use .bag/.slot or .bagID/.slotID. ArkInventory
-- uses ARK_Data.blizzard_id and .slot_id. Adapters may set AHDRHBag.
local function ResolveBagSlot(button)
    if type(button) ~= "table" then
        return nil
    end
    if type(button.AHDRHBag) == "number" and type(button.AHDRHSlot) == "number" then
        if IsPlayerCarryBag(button.AHDRHBag) and SlotOk(button.AHDRHSlot) then
            return button.AHDRHBag, button.AHDRHSlot
        end
    end
    if type(button.GetBag) == "function" and type(button.GetID) == "function" then
        local bagOk, bag = pcall(button.GetBag, button)
        local slotOk, slot = pcall(button.GetID, button)
        if bagOk and slotOk and IsPlayerCarryBag(bag) and SlotOk(slot) then
            return bag, slot
        end
    end

    local bag = button.bag
    if type(bag) ~= "number" then
        bag = button.bagID
    end
    local slot = button.slot
    if type(slot) ~= "number" then
        slot = button.slotID
    end
    if type(slot) ~= "number" and type(button.GetID) == "function" and type(bag) == "number" then
        local idOk, id = pcall(button.GetID, button)
        if idOk then
            slot = id
        end
    end
    if IsPlayerCarryBag(bag) and SlotOk(slot) then
        return bag, slot
    end

    if type(button.ARK_Data) == "table" then
        bag = button.ARK_Data.blizzard_id
        slot = button.ARK_Data.slot_id
        if IsPlayerCarryBag(bag) and SlotOk(slot) then
            return bag, slot
        end
    end

    if type(button.GetBagID) == "function" and type(button.GetID) == "function" then
        local bagOk, bagId = pcall(button.GetBagID, button)
        local slotOk, slotId = pcall(button.GetID, button)
        if bagOk and slotOk and IsPlayerCarryBag(bagId) and SlotOk(slotId) then
            return bagId, slotId
        end
    end
    return nil
end

local function ShowOverlay(button, rec, icon)
    local overlay = rec.overlay
    if not overlay then
        if type(InCombatLockdown) == "function" and InCombatLockdown() then
            return
        end
        if type(button.CreateTexture) ~= "function" then
            return
        end
        overlay = button:CreateTexture(nil, "ARTWORK", nil, 2)
        if not overlay then
            return
        end
        local anchor = icon or button
        overlay:SetAllPoints(anchor)
        if overlay.SetColorTexture then
            overlay:SetColorTexture(0, 0, 0, 0.5)
        else
            overlay:SetTexture("Interface\\Buttons\\WHITE8X8")
            overlay:SetVertexColor(0, 0, 0, 0.5)
        end
        rec.overlay = overlay
    end
    overlay:Show()
end

local function RememberOriginal(button, rec, icon)
    local alpha = CurrentAlpha(button)
    local forced = rec.forcedAlpha
    if not rec.applied or type(forced) ~= "number" or math.abs(alpha - forced) > 0.02 then
        rec.alpha = alpha
    end
    local desat = IconIsDesaturated(icon)
    if desat ~= nil and (not rec.applied or desat == false) then
        rec.desat = desat
    end
end

local function DimButton(button)
    local rec = dimState[button]
    if not rec then
        rec = {}
        dimState[button] = rec
    end
    local icon = ButtonIcon(button)
    RememberOriginal(button, rec, icon)

    local target = DIM_ALPHA
    if type(rec.alpha) == "number" and rec.alpha < target then
        target = rec.alpha
    end
    rec.forcedAlpha = target
    if button.SetAlpha then
        button:SetAlpha(target)
    end
    if icon and icon.SetDesaturated then
        icon:SetDesaturated(true)
    end
    if type(button.SetDesaturated) == "function" then
        pcall(button.SetDesaturated, button, true)
    end
    ShowOverlay(button, rec, icon)
    rec.applied = true
end

local function RestoreOne(button)
    local rec = dimState[button]
    if not rec then
        return
    end
    dimState[button] = nil
    rec.applied = false
    if rec.overlay and rec.overlay.Hide then
        rec.overlay:Hide()
    end
    if button.SetAlpha and type(rec.alpha) == "number" then
        button:SetAlpha(rec.alpha)
    end
    local icon = ButtonIcon(button)
    if type(rec.desat) == "boolean" then
        if icon and icon.SetDesaturated then
            icon:SetDesaturated(rec.desat)
        end
        if type(button.SetDesaturated) == "function" then
            pcall(button.SetDesaturated, button, rec.desat)
        end
    end
    -- Bagnon writes its own alpha in UpdateBorder (1, or 0.3 when the
    -- search misses). Calling it here, while dimRestoring is set, puts
    -- that choice back without our hook dimming the button again.
    if type(button.UpdateBorder) == "function" then
        pcall(button.UpdateBorder, button)
    end
end

local function ClearAllDims()
    local previous = dimRestoring
    dimRestoring = true
    local buttons = {}
    for button in pairs(dimState) do
        buttons[#buttons + 1] = button
    end
    for i = 1, #buttons do
        pcall(RestoreOne, buttons[i])
    end
    dimRestoring = previous
end

local function DimSessionFailed()
    if dimSessionDisabled then
        return
    end
    dimSessionDisabled = true
    dimTickerOn = false
    dimActive = false
    pcall(ClearAllDims)
    print("AH Dressing Room Helper: item dimming turned off — bag add-on not supported")
end

local function NoteDimFailure()
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        dimCombatQueued = true
        return
    end
    DimSessionFailed()
end

local ApplyOne

local function AfterButtonRedraw(button)
    if dimRestoring or dimApplying or dimSessionDisabled or type(button) ~= "table" then
        return
    end
    if not ShouldDimBags() then
        return
    end
    local ok, err = pcall(ApplyOne, button)
    if not ok then
        NoteDimFailure()
    end
end

local function HookButton(button)
    if hookedButtons[button] or type(hooksecurefunc) ~= "function" then
        return
    end
    hookedButtons[button] = true
    local function after()
        AfterButtonRedraw(button)
    end
    if type(button.Update) == "function" then
        pcall(hooksecurefunc, button, "Update", after)
    end
    if type(button.UpdateItem) == "function" then
        pcall(hooksecurefunc, button, "UpdateItem", after)
    end
    if type(button.UpdateBorder) == "function" then
        pcall(hooksecurefunc, button, "UpdateBorder", after)
    end
end

ApplyOne = function(button)
    if dimApplying or dimRestoring or dimSessionDisabled then
        return
    end
    -- A tab change or close bumps dimEpoch while a scan is still walking
    -- buttons. Those later buttons must not be dimmed after the restore.
    if dimEpoch ~= scanEpoch then
        return
    end
    if dimScanning and passButtons[button] then
        return
    end
    if type(button) ~= "table" then
        return
    end
    if AuctionHouseFrame and IsUnder(button, AuctionHouseFrame) then
        return
    end
    if dimScanning then
        passButtons[button] = true
    end
    dimApplying = true
    local ok, err = pcall(function()
        local bag, slot = ResolveBagSlot(button)
        if not bag then
            if dimState[button] then
                RestoreOne(button)
            end
            return
        end
        seenButtons[button] = true
        HookButton(button)
        if not IsShown(button) then
            return
        end
        local canPost = ItemCanBePosted(bag, slot)
        if canPost == false then
            DimButton(button)
        elseif dimState[button] then
            RestoreOne(button)
        end
    end)
    dimApplying = false
    if not ok then
        NoteDimFailure()
    end
end

local function WipePass()
    for key in pairs(passButtons) do
        passButtons[key] = nil
    end
end

local function EachContainerButton(container, visitor)
    if type(container.EnumerateValidItems) == "function" then
        local ok = pcall(function()
            for _, button in container:EnumerateValidItems() do
                if type(button) == "table" then
                    visitor(button)
                end
            end
        end)
        if ok then
            return
        end
    end
    if type(container.Items) == "table" then
        for i = 1, #container.Items do
            local button = container.Items[i]
            if type(button) == "table" then
                visitor(button)
            end
        end
    end
end

local function EachBlizzardContainer(visitor)
    if type(ContainerFrameCombinedBags) == "table" then
        visitor(ContainerFrameCombinedBags)
    end
    local count = NUM_CONTAINER_FRAMES
    if type(count) ~= "number" then
        count = 13
    end
    for i = 1, count do
        local frame = _G["ContainerFrame" .. i]
        if type(frame) == "table" then
            visitor(frame)
        end
    end
end

local function HookContainer(frame)
    if hookedContainers[frame] then
        return
    end
    hookedContainers[frame] = true
    if frame.HookScript then
        frame:HookScript("OnShow", function()
            if RequestDimRefresh then
                RequestDimRefresh()
            end
        end)
        frame:HookScript("OnHide", function()
            if RequestDimRefresh then
                RequestDimRefresh()
            end
        end)
    end
    -- UpdateItems desaturates locked slots after it draws. Re-apply once
    -- that pass has finished.
    if type(hooksecurefunc) == "function" and type(frame.UpdateItems) == "function" then
        pcall(hooksecurefunc, frame, "UpdateItems", function(self)
            if dimRestoring or dimSessionDisabled or not ShouldDimBags() then
                return
            end
            EachContainerButton(self, ApplyOne)
        end)
    end
end

local function ScanBlizzardBags()
    EachBlizzardContainer(function(frame)
        HookContainer(frame)
        if IsShown(frame) then
            EachContainerButton(frame, ApplyOne)
        end
    end)
end

local function HookBagnonClass(class)
    if bagnonMethodsHooked or type(class) ~= "table" or type(hooksecurefunc) ~= "function" then
        return
    end
    local function after(self)
        AfterButtonRedraw(self)
    end
    local hooked = false
    if type(class.Update) == "function" then
        hooksecurefunc(class, "Update", after)
        hooked = true
    end
    if type(class.UpdateBorder) == "function" then
        hooksecurefunc(class, "UpdateBorder", after)
        hooked = true
    end
    if hooked then
        bagnonMethodsHooked = true
    end
end

local function WalkItemChildren(frame, depth)
    if depth > 5 or type(frame) ~= "table" or type(frame.GetChildren) ~= "function" then
        return
    end
    local children = { frame:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        if type(child) == "table" then
            if child.bag ~= nil or type(child.GetBag) == "function" or type(child.GetBagID) == "function" then
                ApplyOne(child)
            end
            WalkItemChildren(child, depth + 1)
        end
    end
end

local function ScanBagnon()
    if not AddonLoaded("Bagnon") then
        return
    end
    local addon = Bagnon
    if type(addon) == "table" then
        HookBagnonClass(addon.ContainerItem or addon.Item)
        local classes = { addon.ContainerItem, addon.Item }
        for i = 1, #classes do
            local frames = classes[i] and classes[i].__frames
            if type(frames) == "table" then
                for key, value in pairs(frames) do
                    local button = type(key) == "table" and key or value
                    if type(button) == "table" then
                        ApplyOne(button)
                    end
                end
            end
        end
    end
    for i = 1, 4 do
        local frame = _G["BagnonInventory" .. i]
        if type(frame) == "table" then
            WalkItemChildren(frame, 0)
        end
    end
end

local function ScanBaganator()
    if not AddonLoaded("Baganator") or baganatorRegistered then
        return
    end
    if type(Baganator) ~= "table" or type(Baganator.API) ~= "table" or type(Baganator.API.RegisterCornerWidget) ~= "function" then
        return
    end
    Baganator.API.RegisterCornerWidget(
        "Unsellable on the auction house",
        "AHDressingRoomHelperUnsellable",
        function(cornerFrame, details)
            local button = cornerFrame and cornerFrame.GetParent and cornerFrame:GetParent()
            local loc = details and details.itemLocation
            if type(button) ~= "table" or type(loc) ~= "table" then
                return false
            end
            if type(loc.bagID) == "number" then
                button.AHDRHBag = loc.bagID
            end
            if type(loc.slotIndex) == "number" then
                button.AHDRHSlot = loc.slotIndex
            end
            if ShouldDimBags() then
                ApplyOne(button)
            elseif dimState[button] then
                RestoreOne(button)
            end
            return false
        end,
        function(itemButton)
            local tex = itemButton:CreateTexture(nil, "OVERLAY")
            tex:SetSize(1, 1)
            tex:Hide()
            return tex
        end
    )
    baganatorRegistered = true
end

local function ScanNamedButtons(prefix, limit, missLimit)
    local misses = 0
    for i = 1, limit do
        local button = _G[prefix .. i]
        if type(button) == "table" then
            misses = 0
            ApplyOne(button)
        else
            misses = misses + 1
            if misses >= missLimit and i > missLimit then
                return
            end
        end
    end
end

local function ScanAdiBags()
    if not AddonLoaded("AdiBags") then
        return
    end
    ScanNamedButtons("AdiBagsItemButton", 400, 25)
end

local function NoteBetterBagsSlot(button)
    if type(button) ~= "table" or type(button.GetSlotAndBagID) ~= "function" then
        return
    end
    local ok, first, second = pcall(button.GetSlotAndBagID, button)
    if not ok then
        return
    end
    if IsPlayerCarryBag(second) and SlotOk(first) then
        button.AHDRHBag, button.AHDRHSlot = second, first
    elseif IsPlayerCarryBag(first) and SlotOk(second) then
        button.AHDRHBag, button.AHDRHSlot = first, second
    end
end

local function ScanBetterBags()
    if not AddonLoaded("BetterBags") then
        return
    end
    if type(LibStub) == "function" then
        pcall(function()
            local ace = LibStub("AceAddon-3.0")
            local addon = ace:GetAddon("BetterBags")
            local bags = addon and addon.Bags and addon.Bags.Backpack
            local view = bags and bags.currentView
            local items = view and view.itemsByBagAndSlot
            if type(items) ~= "table" and view and type(view.GetItemsByBagAndSlot) == "function" then
                items = view:GetItemsByBagAndSlot()
            end
            if type(items) ~= "table" then
                return
            end
            for _, item in pairs(items) do
                if type(item) == "table" then
                    local data = item.data
                    if type(data) ~= "table" and type(item.GetItemData) == "function" then
                        data = item:GetItemData()
                    end
                    local button = item.button or item
                    if type(button) == "table" and type(data) == "table" then
                        if type(data.bagid) == "number" then
                            button.AHDRHBag = data.bagid
                        end
                        if type(data.slotid) == "number" then
                            button.AHDRHSlot = data.slotid
                        end
                        ApplyOne(button)
                    end
                end
            end
        end)
    end
    local misses = 0
    for i = 1, 800 do
        local button = _G["BetterBagsItemButton" .. i]
        if type(button) == "table" then
            misses = 0
            NoteBetterBagsSlot(button)
            ApplyOne(button)
        else
            misses = misses + 1
            if misses >= 40 and i > 40 then
                return
            end
        end
    end
end

local function ScanArkInventory()
    if not AddonLoaded("ArkInventory") then
        return
    end
    if type(ArkInventory) ~= "table" or type(ArkInventory.API) ~= "table" then
        return
    end
    local api = ArkInventory.API
    if not arkMethodsHooked and type(hooksecurefunc) == "function" and type(api.ItemFrameUpdated) == "function" then
        hooksecurefunc(api, "ItemFrameUpdated", function(frame)
            AfterButtonRedraw(frame)
        end)
        arkMethodsHooked = true
    end
    if type(api.ItemFrameLoadedIterate) ~= "function" then
        return
    end
    local iter, state, first = api.ItemFrameLoadedIterate()
    if type(iter) ~= "function" then
        return
    end
    local guard = 0
    local key, extra = iter(state, first)
    while key ~= nil and guard < 2000 do
        guard = guard + 1
        local frame = type(key) == "table" and key or extra
        if type(frame) == "table" then
            ApplyOne(frame)
        end
        key, extra = iter(state, key)
    end
end

local function NameLooksLikeAction(name)
    return name:find("ActionButton", 1, true)
        or name:find("MultiBar", 1, true)
        or name:find("StanceButton", 1, true)
        or name:find("PetAction", 1, true)
        or name:find("SpellFlyout", 1, true)
end

local function GenericCandidate(frame)
    if type(frame) ~= "table" or type(frame.GetObjectType) ~= "function" then
        return false
    end
    if not IsShown(frame) then
        return false
    end
    local ok, kind = pcall(frame.GetObjectType, frame)
    if not ok or (kind ~= "Button" and kind ~= "ItemButton" and kind ~= "CheckButton") then
        return false
    end
    if AuctionHouseFrame and IsUnder(frame, AuctionHouseFrame) then
        return false
    end
    if frame.GetName then
        local name = frame:GetName()
        if type(name) == "string" and NameLooksLikeAction(name) then
            return false
        end
    end
    if not ButtonIcon(frame) or type(frame.GetWidth) ~= "function" then
        return false
    end
    local width, height = frame:GetWidth(), frame:GetHeight()
    if type(width) ~= "number" or type(height) ~= "number" then
        return false
    end
    if width < 18 or width > 90 or height < 18 or height > 90 or math.abs(width - height) > 16 then
        return false
    end
    local bag = ResolveBagSlot(frame)
    return bag ~= nil
end

local function GenericScan(force)
    if type(EnumerateFrames) ~= "function" then
        return
    end
    local now = 0
    if type(GetTime) == "function" then
        local stamp = GetTime()
        if type(stamp) == "number" and not IsSecret(stamp) then
            now = stamp
        end
    end
    if not force and (now - lastGenericScan) < 0.9 then
        return
    end
    lastGenericScan = now
    local frame = EnumerateFrames()
    local guard = 0
    while frame and guard < 6000 do
        guard = guard + 1
        local matchOk, match = pcall(GenericCandidate, frame)
        if matchOk and match then
            ApplyOne(frame)
        end
        frame = EnumerateFrames(frame)
    end
end

local function RunAdapter(fn)
    local ok, err = pcall(fn)
    if not ok then
        NoteDimFailure()
        return false
    end
    return not dimSessionDisabled
end

local function RefreshDim(forceGeneric)
    if dimSessionDisabled then
        return
    end
    WipePass()
    scanEpoch = dimEpoch
    if not ShouldDimBags() then
        dimActive = false
        dimTickerOn = false
        if next(dimState) then
            ClearAllDims()
        end
        WipePass()
        return
    end
    dimActive = true
    dimScanning = true
    local adaptersOk = RunAdapter(ScanBlizzardBags)
        and RunAdapter(ScanBagnon)
        and RunAdapter(ScanBaganator)
        and RunAdapter(ScanAdiBags)
        and RunAdapter(ScanBetterBags)
        and RunAdapter(ScanArkInventory)
        and RunAdapter(function()
            for button in pairs(seenButtons) do
                if IsShown(button) then
                    ApplyOne(button)
                end
            end
        end)
        and RunAdapter(function()
            GenericScan(forceGeneric)
        end)
    dimScanning = false
    WipePass()
    return adaptersOk
end

local function EnsureDimTicker()
    if dimTickerOn or dimSessionDisabled or not C_Timer or type(C_Timer.After) ~= "function" then
        return
    end
    dimTickerOn = true
    local ticks = 0
    local function step()
        if not dimTickerOn or dimSessionDisabled or not ShouldDimBags() then
            dimTickerOn = false
            return
        end
        ticks = ticks + 1
        local ok, err = pcall(RefreshDim, ticks % 3 == 0)
        if not ok then
            dimTickerOn = false
            NoteDimFailure()
            return
        end
        if dimTickerOn and ShouldDimBags() then
            C_Timer.After(0.4, step)
        else
            dimTickerOn = false
        end
    end
    C_Timer.After(0.4, step)
end

local dimRefreshQueued = false
RequestDimRefresh = function()
    RefreshUnsupportedLabel()
    if dimSessionDisabled or not ShouldDimBags() then
        dimEpoch = dimEpoch + 1
        dimTickerOn = false
        dimActive = false
        if next(dimState) then
            pcall(ClearAllDims)
        end
        return
    end
    if not dimActive then
        lastGenericScan = 0
    end
    if dimRefreshQueued then
        return
    end
    dimRefreshQueued = true
    local function run()
        dimRefreshQueued = false
        local ok, err = pcall(RefreshDim, false)
        if not ok then
            NoteDimFailure()
            return
        end
        if ShouldDimBags() then
            EnsureDimTicker()
        end
    end
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0, run)
    else
        run()
    end
end

local SETTINGS_RESET_POPUP = "AHDRESSINGROOMHELPER_RESET_SETTINGS"
local SETTINGS_CLOSE_LABEL = "Close Dressing Room with Auction House"
local SETTINGS_DIM_LABEL = "Dim unsellable items when Sell tab selected"
local SETTINGS_CLOSE_TIP = "When checked, closing the auction house also closes the Dressing Room. The close button, walking away, and other close paths all count. Leave this off and the Dressing Room stays up."

local function ResetHelperSettingsToDefaults()
    InitDB()
    AHDressingRoomHelperDB[DB_CLOSE_KEY] = false
    AHDressingRoomHelperDB[DB_DIM_KEY] = false
    if settingsPanel and settingsPanel.OnRefresh then
        settingsPanel:OnRefresh()
    end
    if RequestDimRefresh then
        RequestDimRefresh()
    end
end

local function EnsureSettingsResetPopup()
    if type(StaticPopupDialogs) ~= "table" then
        return
    end
    if StaticPopupDialogs[SETTINGS_RESET_POPUP] then
        return
    end
    local okay = OKAY or ACCEPT or YES
    local cancel = CANCEL or NO
    StaticPopupDialogs[SETTINGS_RESET_POPUP] = {
        text = "Reset AH Dressing Room Helper settings to defaults?",
        button1 = okay,
        button2 = cancel,
        OnAccept = ResetHelperSettingsToDefaults,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
        preferredIndex = 3,
    }
end

local function ShowSettingsRowTip(owner, title, body)
    if not GameTooltip or not owner then
        return
    end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 1, 1)
    if body and body ~= "" then
        GameTooltip:AddLine(body, 0.9, 0.9, 0.9, true)
    end
    GameTooltip:Show()
end

local function CreateSettingsCheckboxRow(parent, anchorTo, yOffset, labelText, tooltipTitle, tooltipBody, onClick)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOffset)
    row:SetPoint("RIGHT", parent, "RIGHT", -32, 0)
    row:SetHeight(44)

    local checkTemplate = "SettingsCheckboxTemplate"
    local check = CreateFrame("CheckButton", nil, row, checkTemplate)
    if not check or not check.SetChecked then
        check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        check:SetSize(24, 24)
    end
    check:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -6)

    local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetJustifyH("LEFT")
    label:SetJustifyV("TOP")
    label:SetWordWrap(true)
    label:SetNonSpaceWrap(false)
    label:SetText(labelText)
    label:SetPoint("TOPLEFT", check, "TOPRIGHT", 8, -2)
    label:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    check.label = label

    local tipFrame = CreateFrame("Frame", nil, row)
    tipFrame:SetAllPoints(row)
    tipFrame:EnableMouse(true)
    tipFrame:SetScript("OnEnter", function()
        local body = tooltipBody
        if type(body) == "function" then
            body = body()
        end
        ShowSettingsRowTip(tipFrame, tooltipTitle, body)
    end)
    tipFrame:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)

    check:SetScript("OnClick", function(self)
        if not self:IsEnabled() then
            self:SetChecked(not self:GetChecked())
            return
        end
        local checked = self:GetChecked() and true or false
        if onClick then
            onClick(checked)
        end
        PlayToggleSound(checked)
    end)

    return check, row
end

local function BuildSettingsPanel()
    if settingsPanel then
        return settingsPanel
    end
    EnsureSettingsResetPopup()

    local panel = CreateFrame("Frame", "AHDressingRoomHelperSettingsPanel", UIParent)
    panel:SetSize(600, 420)

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(SETTINGS_CATEGORY_NAME)

    local defaultsLabel = DEFAULTS
    if type(defaultsLabel) ~= "string" then
        defaultsLabel = "Defaults"
    end
    local defaultsButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    defaultsButton:SetSize(96, 22)
    defaultsButton:SetPoint("TOPRIGHT", -24, -12)
    defaultsButton:SetText(defaultsLabel)
    defaultsButton:SetScript("OnClick", function()
        EnsureSettingsResetPopup()
        if StaticPopup_Show then
            StaticPopup_Show(SETTINGS_RESET_POPUP)
        end
    end)

    local dressHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    dressHeader:SetPoint("TOPLEFT", 16, -56)
    dressHeader:SetText("Dressing Room")

    local closeRow
    settingsCloseCheck, closeRow = CreateSettingsCheckboxRow(
        panel,
        dressHeader,
        -8,
        SETTINGS_CLOSE_LABEL,
        SETTINGS_CLOSE_LABEL,
        SETTINGS_CLOSE_TIP,
        function(checked)
            InitDB()
            AHDressingRoomHelperDB[DB_CLOSE_KEY] = checked
        end
    )

    local ahHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    ahHeader:SetPoint("TOPLEFT", closeRow, "BOTTOMLEFT", -8, -20)
    ahHeader:SetText("Auction House")

    local dimRow
    settingsDimCheck, dimRow = CreateSettingsCheckboxRow(
        panel,
        ahHeader,
        -8,
        SETTINGS_DIM_LABEL,
        SETTINGS_DIM_LABEL,
        SETTINGS_DIM_LABEL,
        DimCheckboxTooltip,
        function(checked)
            InitDB()
            AHDressingRoomHelperDB[DB_DIM_KEY] = checked
            if RequestDimRefresh then
                RequestDimRefresh()
            end
        end
    )

    settingsDimNote = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    settingsDimNote:SetJustifyH("LEFT")
    settingsDimNote:SetJustifyV("TOP")
    settingsDimNote:SetWordWrap(true)
    settingsDimNote:SetPoint("TOPLEFT", dimRow, "BOTTOMLEFT", 40, -4)
    settingsDimNote:SetPoint("RIGHT", panel, "RIGHT", -32, 0)
    settingsDimNote:Hide()

    function panel:OnRefresh()
        InitDB()
        RefreshUnsupportedLabel()
        if settingsCloseCheck then
            settingsCloseCheck:SetChecked(AHDressingRoomHelperDB[DB_CLOSE_KEY] == true)
        end
        if settingsDimCheck then
            local blocked = unsupportedLabel ~= nil
            settingsDimCheck:SetEnabled(not blocked)
            settingsDimCheck:SetChecked(not blocked and AHDressingRoomHelperDB[DB_DIM_KEY] == true)
            if settingsDimCheck.label then
                if blocked then
                    settingsDimCheck.label:SetTextColor(0.5, 0.5, 0.5)
                else
                    settingsDimCheck.label:SetTextColor(1, 0.82, 0)
                end
            end
        end
        if settingsDimNote then
            if unsupportedLabel then
                settingsDimNote:SetText(DimBlockedTooltip(unsupportedLabel))
                settingsDimNote:Show()
            else
                settingsDimNote:Hide()
            end
        end
    end

    function panel:OnCommit()
    end

    function panel:OnDefault()
        -- Blizzard's panel Defaults button is hidden for canvas categories.
        -- Our Defaults button uses SETTINGS_RESET_POPUP instead.
    end

    panel:OnRefresh()
    settingsPanel = panel
    return panel
end

local function RegisterSettings()
    if settingsRegistered then
        return true
    end
    if settingsFailed then
        return false
    end
    if type(Settings) ~= "table" then
        return false
    end
    if type(Settings.RegisterCanvasLayoutCategory) ~= "function"
        or type(Settings.RegisterAddOnCategory) ~= "function" then
        return false
    end

    InitDB()

    local panel = BuildSettingsPanel()
    if not panel then
        settingsFailed = true
        return false
    end

    -- Canvas layout hides the settings list, including Blizzard's Defaults
    -- button that can reset all UI settings. We draw our own Defaults control
    -- on the panel and only reset AHDressingRoomHelperDB through a StaticPopup.
    local ok, category, layout = pcall(Settings.RegisterCanvasLayoutCategory, panel, SETTINGS_CATEGORY_NAME)
    if not ok or not category or not layout then
        settingsFailed = true
        return false
    end
    if layout.AddAnchorPoint then
        pcall(function()
            layout:AddAnchorPoint("TOPLEFT", 0, 0)
            layout:AddAnchorPoint("BOTTOMRIGHT", 0, 0)
        end)
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
    RefreshUnsupportedLabel()
    if settingsPanel and settingsPanel.OnRefresh then
        settingsPanel:OnRefresh()
    end
    if RequestDimRefresh then
        RequestDimRefresh()
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
    if RequestDimRefresh then
        RequestDimRefresh()
    end
end

function eventFrame:AUCTION_HOUSE_CLOSED()
    ResetToggle()
    CloseDressingRoomWithAuctionHouse()
    if RequestDimRefresh then
        RequestDimRefresh()
    end
end

function eventFrame:PLAYER_LOGIN()
    InstallHooks()
    InitDB()
    RefreshUnsupportedLabel()
    RegisterSettings()
    if settingsPanel and settingsPanel.OnRefresh then
        settingsPanel:OnRefresh()
    end
end

function eventFrame:BAG_UPDATE()
    if RequestDimRefresh then
        RequestDimRefresh()
    end
end

eventFrame.BAG_UPDATE_DELAYED = eventFrame.BAG_UPDATE
eventFrame.ITEM_LOCK_CHANGED = eventFrame.BAG_UPDATE

function eventFrame:PLAYER_REGEN_ENABLED()
    if attachQueued then
        TryAttach()
    end
    if closeDressingRoomQueued and not AuctionHouseIsOpen() then
        CloseDressingRoomWithAuctionHouse()
    else
        closeDressingRoomQueued = false
    end
    if dimCombatQueued then
        dimCombatQueued = false
        if RequestDimRefresh then
            RequestDimRefresh()
        end
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
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("ITEM_LOCK_CHANGED")

InstallHooks()
