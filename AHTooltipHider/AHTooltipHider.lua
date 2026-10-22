-- AH Tooltip Hider
--
-- While the auction house is open and its "Hide tooltips" box is checked,
-- hide the item tooltip under the cursor and the equipped-gear comparison
-- tooltips (ShoppingTooltip1/2, the ones titled "Equipped"). Unchecking the
-- box, or closing the auction house, restores normal tooltips immediately.
--
-- The checkbox is not saved. It is created unchecked and forced off every
-- time the auction house shows or hides.
--
-- Forever uses the retail (Mainline) UI, not the Classic AuctionFrame.
-- This file only talks to AuctionHouseFrame from Blizzard_AuctionHouseUI,
-- which is load-on-demand. Hooks are filters: Blizzard's functions still
-- run, and the filter does nothing unless the window is open and the box
-- is checked at the moment a tooltip is shown.

local addonName, ns = ...

ns.name = addonName

-- ---------------------------------------------------------------------------
-- State. All of this lives in this file. There is no SavedVariables table.
-- ---------------------------------------------------------------------------

local checkbox
local attached = false
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
    if not widget or widget == checkbox then
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
        if not current or current == checkbox then
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
    GameTooltip:AddLine("Hides the auction item under your cursor and the equipped-gear comparison, so the preview stays clear. Uncheck to bring them back. This box clears when the auction house closes.", 0.9, 0.9, 0.9, true)
    GameTooltip:Show()
end

local function ResetToggle()
    if checkbox then
        checkbox:SetChecked(false)
    end
end

local function FindCloseButton(ahFrame)
    if ahFrame.CloseButton then
        return ahFrame.CloseButton
    end
    local frameName = ahFrame.GetName and ahFrame:GetName()
    if frameName then
        return _G[frameName .. "CloseButton"]
    end
    return nil
end

local function UpdateHitRect(button, label)
    local width = label:GetStringWidth() or 0
    if width < 1 then
        width = 88
    end
    -- Negative left inset extends the clickable area over the label.
    button:SetHitRectInsets(-(width + 8), 0, -4, -4)
end

-- The auction house is an 800-wide PortraitFrame. The centered title
-- ("Browse Auctions" on the Buy tab) sits in the middle of the title bar.
-- The close button is anchored to TOPRIGHT and is about 32px wide. The
-- search row starts at y=-29, under that bar. Anchoring to the close
-- button's left edge puts this control in the empty parchment between the
-- title text and the X, above the search box, Filter, and Search button.
local function PlaceCheckbox(ahFrame, button)
    local closeButton = FindCloseButton(ahFrame)
    if closeButton then
        button:SetPoint("RIGHT", closeButton, "LEFT", -6, 0)
    else
        button:SetPoint("TOPRIGHT", ahFrame, "TOPRIGHT", -40, -4)
    end

    local level = ahFrame:GetFrameLevel() + 20
    if ahFrame.TitleContainer and ahFrame.TitleContainer.GetFrameLevel then
        level = math.max(level, ahFrame.TitleContainer:GetFrameLevel() + 10)
    end
    if closeButton and closeButton.GetFrameLevel then
        level = math.max(level, closeButton:GetFrameLevel())
    end
    button:SetFrameLevel(level)
end

local function AttachCheckbox(ahFrame)
    if attached or checkbox then
        return
    end
    if FrameIsLocked(ahFrame) then
        attachQueued = true
        return
    end

    local button = CreateFrame("CheckButton", nil, ahFrame, "UICheckButtonTemplate")
    button:SetSize(24, 24)
    button:SetChecked(false)
    -- Remember it before the rest of the setup. A second call cannot create
    -- another box if anything below errors on a future client.
    checkbox = button
    PlaceCheckbox(ahFrame, button)

    -- The template ships its own font string on the right. Ours sits on the
    -- left so the control grows away from the close button.
    if button.Text then
        button.Text:SetText("")
        button.Text:Hide()
    end

    local label = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetText("Hide tooltips")
    label:SetPoint("RIGHT", button, "LEFT", -2, 1)
    UpdateHitRect(button, label)
    button:HookScript("OnShow", function(self)
        UpdateHitRect(self, label)
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
-- Events. One frame, one dispatcher. The auction-house UI loads later.
-- ---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")

function eventFrame:ADDON_LOADED(loaded)
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
end

function eventFrame:PLAYER_LOGIN()
    InstallHooks()
end

function eventFrame:PLAYER_REGEN_ENABLED()
    if attachQueued then
        TryAttach()
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
