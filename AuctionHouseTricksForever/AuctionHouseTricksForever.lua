-- Auction House Tricks Forever
--
-- While the auction house is open and Filter > Hide tooltips is checked,
-- hide the item tooltip under the cursor and the equipped-gear comparison
-- tooltips (ShoppingTooltip1/2, the ones titled "Equipped"). Unchecking the
-- entry, or closing the auction house, restores normal tooltips immediately.
--
-- That entry is not saved. It starts unchecked and is forced off every time
-- the auction house closes. It stays checked across Buy, Sell, and Auctions.
--
-- Two saved options live in AuctionHouseTricksForeverDB. Both default off.
-- "Close Dressing Room with Auction House" also hides DressUpFrame when
-- the auction house closes. "Dim unsellable items when Sell tab selected"
-- fades bag items that cannot be posted, and only while that tab is open.
--
-- Forever uses the retail (Mainline) UI, not the Classic AuctionFrame.
-- This file only talks to AuctionHouseFrame from Blizzard_AuctionHouseUI,
-- which is load-on-demand. Hooks are filters: Blizzard's functions still
-- run, and the filter does nothing unless the window is open and Hide
-- tooltips is checked at the moment a tooltip is shown.

local addonName, ns = ...

ns.name = addonName
local ADDON_VERSION = "2.0.0"

-- ---------------------------------------------------------------------------
-- State. Hide tooltips is not saved. The Dressing Room and dim options are.
-- AuctionHouseTricksForeverDB is created in ADDON_LOADED, not here.
-- ---------------------------------------------------------------------------

local DB_CLOSE_KEY = "closeDressingRoom"
local DB_DIM_KEY = "dimUnsellable"
local SETTINGS_CATEGORY_NAME = "Auction House Tricks Forever"

local hideTooltips = false
local settingsCategory
local settingsPanel
local settingsCloseCheck
local settingsDimCheck
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
    if not widget then
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
    return AuctionHouseIsOpen() and hideTooltips
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
-- Hide tooltips. Not saved. It lives in the Filter dropdown, under Usable
-- Only, and is cleared whenever the auction house closes.
-- ---------------------------------------------------------------------------

local HIDE_TOOLTIPS_LABEL = "Hide tooltips"
local HIDE_TOOLTIPS_HELP = "Hides the gear comparison tooltips to prevent them from obscuring the Dressing Room preview.  Uncheck this setting to bring them back.  This setting clears when the auction house window closes."

local filterMenuDebug = {
    injected = false,
    method = "not-installed",
    tag = nil,
    placed = "not-yet",
    tooltip = "not-set",
    error = nil,
    hasGenerator = false,
    hasSetupMenu = false,
    insertions = 0,
    clearClick = "none",
    clearUpdate = "none",
}

local RefreshFilterClearButton

local registeredMenuTags = {}
local legacyAddHooked = false
local legacyDepth = 0
local legacyInserting = false
local menuWrapping = false
local ahShowHooked = false

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
        if not current then
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

local function ResetToggle()
    hideTooltips = false
    if RefreshFilterClearButton then
        RefreshFilterClearButton()
    end
end

local function SetHideTooltips(want)
    if not AuctionHouseIsOpen() then
        hideTooltips = false
        if RefreshFilterClearButton then
            RefreshFilterClearButton()
        end
        return
    end
    want = want and true or false
    if hideTooltips == want then
        return
    end
    hideTooltips = want
    if hideTooltips then
        HidePreviewTooltipsNow()
    else
        RestoreTooltipUnderCursor()
    end
    PlayToggleSound(hideTooltips)
    if RefreshFilterClearButton then
        RefreshFilterClearButton()
    end
end

-- Filter X clears Blizzard filters. This only drops our flag. It does not
-- play the checkbox sound or send a browse query.
local function ClearHideTooltipsFromReset()
    if hideTooltips then
        hideTooltips = false
        RestoreTooltipUnderCursor()
    end
    if RefreshFilterClearButton then
        RefreshFilterClearButton()
    end
end

local function FrameTag(frame)
    if not frame then
        return "nil"
    end
    if frame.GetName then
        local name = frame:GetName()
        if type(name) == "string" and name ~= "" then
            return name
        end
    end
    if frame.GetParentKey then
        local key = frame:GetParentKey()
        if type(key) == "string" and key ~= "" then
            return key
        end
    end
    return "frame"
end

local function PlainLower(value)
    if type(value) ~= "string" or value == "" or IsSecret(value) then
        return nil
    end
    return value:lower()
end

local function IsUsableLabel(text)
    if type(text) ~= "string" then
        return false
    end
    local globalText = _G.AUCTION_HOUSE_FILTER_USABLE_ONLY
    if type(globalText) == "string" and text == globalText then
        return true
    end
    local lower = PlainLower(text)
    if not lower then
        return false
    end
    if lower == "usable only" then
        return true
    end
    return lower:find("usable only", 1, true) ~= nil
end

local function IsUncollectedLabel(text)
    if type(text) ~= "string" then
        return false
    end
    local globalText = _G.AUCTION_HOUSE_FILTER_UNCOLLECTED_ONLY
    if type(globalText) == "string" and text == globalText then
        return true
    end
    local lower = PlainLower(text)
    return lower ~= nil and lower:find("uncollected", 1, true) ~= nil
end

local function IsRarityLabel(text)
    if type(text) ~= "string" then
        return false
    end
    if type(_G.RARITY) == "string" and text == _G.RARITY then
        return true
    end
    local lower = PlainLower(text)
    return lower == "rarity" or (lower and lower:find("rarity", 1, true) ~= nil)
end

local function DescriptionText(element)
    if type(element) ~= "table" then
        return nil
    end
    local fields = { "text", "buttonText", "label", "title" }
    for i = 1, #fields do
        local value = element[fields[i]]
        if type(value) == "string" and value ~= "" and not IsSecret(value) then
            return value
        end
    end
    if type(element.GetData) == "function" then
        local ok, data = pcall(element.GetData, element)
        if ok and type(data) == "string" and not IsSecret(data) then
            return data
        end
        if ok and type(data) == "table" and type(data.text) == "string" then
            return data.text
        end
    end
    return nil
end

local function IsRadioElement(element)
    if type(element) ~= "table" or element.ahtfHideTooltips then
        return false
    end
    if element.isRadio or element.radio then
        return true
    end
    local kind = element.elementType or element.type or element.descriptionType
    if type(kind) == "string" and kind:lower():find("radio", 1, true) then
        return true
    end
    return false
end

local function ElementLists(root)
    local lists = {}
    if type(root) ~= "table" then
        return lists
    end
    local fields = { "elements", "elementDescriptions", "queuedDescriptions", "children" }
    for i = 1, #fields do
        local list = root[fields[i]]
        if type(list) == "table" then
            local seen = false
            for j = 1, #lists do
                if lists[j] == list then
                    seen = true
                end
            end
            if not seen then
                lists[#lists + 1] = list
            end
        end
    end
    return lists
end

local function ListHasEntry(list)
    for i = 1, #list do
        local element = list[i]
        if type(element) == "table" and (element.ahtfHideTooltips or DescriptionText(element) == HIDE_TOOLTIPS_LABEL) then
            return true
        end
    end
    return false
end

local function MoveElement(list, element, index)
    local from
    for i = 1, #list do
        if list[i] == element then
            from = i
            break
        end
    end
    if not from then
        if index < 1 then
            index = 1
        end
        if index > #list + 1 then
            index = #list + 1
        end
        table.insert(list, index, element)
        return
    end
    if index > from then
        index = index - 1
    end
    if index < 1 then
        index = 1
    end
    if index > #list then
        index = #list
    end
    if from == index then
        return
    end
    table.remove(list, from)
    table.insert(list, index, element)
end

local function SetEntryTooltip(element)
    if type(element) ~= "table" or type(element.SetTooltip) ~= "function" then
        filterMenuDebug.tooltip = "no-SetTooltip"
        return
    end
    local function paint(tooltip)
        if not tooltip or type(tooltip.SetText) ~= "function" then
            return
        end
        local r, g, b = 1, 0.82, 0
        if type(NORMAL_FONT_COLOR) == "table" and type(NORMAL_FONT_COLOR.GetRGB) == "function" then
            local ok, rr, gg, bb = pcall(NORMAL_FONT_COLOR.GetRGB, NORMAL_FONT_COLOR)
            if ok and type(rr) == "number" and type(gg) == "number" and type(bb) == "number" then
                r, g, b = rr, gg, bb
            end
        end
        local titled = false
        if type(GameTooltip_SetTitle) == "function" then
            titled = pcall(GameTooltip_SetTitle, tooltip, HIDE_TOOLTIPS_LABEL, NORMAL_FONT_COLOR, true)
        end
        if not titled then
            tooltip:SetText(HIDE_TOOLTIPS_LABEL, r, g, b, 1)
        end
        if tooltip.AddLine then
            tooltip:AddLine(HIDE_TOOLTIPS_HELP, 1, 1, 1, true)
        end
    end
    if pcall(element.SetTooltip, element, paint) then
        filterMenuDebug.tooltip = "SetTooltip"
        return
    end
    if pcall(element.SetTooltip, element, HIDE_TOOLTIPS_LABEL, HIDE_TOOLTIPS_HELP) then
        filterMenuDebug.tooltip = "SetTooltip-text"
        return
    end
    filterMenuDebug.tooltip = "SetTooltip-failed"
end

local function RememberTag(root)
    if type(root) ~= "table" then
        return
    end
    local tag
    if type(root.GetTag) == "function" then
        local ok, value = pcall(root.GetTag, root)
        if ok and type(value) == "string" and value ~= "" then
            tag = value
        end
    end
    if not tag and type(root.tag) == "string" and root.tag ~= "" then
        tag = root.tag
    end
    if tag then
        filterMenuDebug.tag = tag
    end
end

local function InsertHideTooltipsEntry(root)
    if type(root) ~= "table" or type(root.CreateCheckbox) ~= "function" then
        filterMenuDebug.error = "no-CreateCheckbox"
        return
    end
    RememberTag(root)
    local lists = ElementLists(root)
    for i = 1, #lists do
        if ListHasEntry(lists[i]) then
            filterMenuDebug.injected = true
            return
        end
    end

    local element
    local ok, created = pcall(root.CreateCheckbox, root, HIDE_TOOLTIPS_LABEL, function()
        return hideTooltips and true or false
    end, function(newSelected)
        if type(newSelected) == "boolean" then
            SetHideTooltips(newSelected)
        else
            SetHideTooltips(not hideTooltips)
        end
    end)
    if not ok then
        filterMenuDebug.error = tostring(created)
        return
    end
    element = created
    if type(element) == "table" then
        element.ahtfHideTooltips = true
        SetEntryTooltip(element)
    end

    lists = ElementLists(root)
    local home
    for L = 1, #lists do
        for i = 1, #lists[L] do
            if lists[L][i] == element then
                home = lists[L]
                break
            end
        end
        if home then
            break
        end
    end
    local place = "appended"
    if home then
        local usableAt, rarityAt, radioAt
        for i = 1, #home do
            if home[i] ~= element then
                local text = DescriptionText(home[i])
                if not usableAt and IsUsableLabel(text) then
                    usableAt = i
                end
                if not rarityAt and IsRarityLabel(text) then
                    rarityAt = i
                end
                if not radioAt and IsRadioElement(home[i]) then
                    radioAt = i
                end
            end
        end
        if usableAt then
            MoveElement(home, element, usableAt + 1)
            place = "after-usable"
        elseif rarityAt then
            MoveElement(home, element, rarityAt)
            place = "before-rarity"
        elseif radioAt then
            MoveElement(home, element, radioAt)
            place = "before-radios"
        end
    end
    filterMenuDebug.injected = true
    filterMenuDebug.placed = place
end

local function FindClearButton(filterButton)
    if not filterButton then
        return nil
    end
    local named = filterButton.ClearFiltersButton or filterButton.ResetButton or filterButton.ClearButton
    if type(named) == "table" and named.SetShown then
        local key = "ClearFiltersButton"
        if named == filterButton.ResetButton then
            key = "ResetButton"
        elseif named == filterButton.ClearButton then
            key = "ClearButton"
        end
        return named, key
    end
    if filterButton.GetChildren then
        local children = { filterButton:GetChildren() }
        for i = 1, #children do
            local child = children[i]
            local key
            if child.GetParentKey then
                key = child:GetParentKey()
            end
            if type(key) == "string" and (key:find("Clear", 1, true) or key:find("Reset", 1, true)) and child.SetShown then
                return child, key
            end
        end
    end
    return nil
end

local function ForceClearButtonShown(filterButton)
    if not hideTooltips then
        return
    end
    local clear = FindClearButton(filterButton)
    if clear and clear.SetShown then
        pcall(clear.SetShown, clear, true)
    end
end

RefreshFilterClearButton = function()
    local ah = AuctionHouseFrame
    local bar = ah and ah.SearchBar
    local button = bar and bar.FilterButton or (ah and ah.FilterButton)
    if bar and type(bar.UpdateClearFiltersButton) == "function" then
        pcall(bar.UpdateClearFiltersButton, bar)
    end
    if button and type(button.UpdateClearFiltersButton) == "function" then
        pcall(button.UpdateClearFiltersButton, button)
    end
    ForceClearButtonShown(button)
end

local function HookNamedMethod(object, name, after)
    if not object or type(object[name]) ~= "function" or type(hooksecurefunc) ~= "function" then
        return false
    end
    object.ahtfHooked = object.ahtfHooked or {}
    if object.ahtfHooked[name] then
        return true
    end
    local ok = pcall(hooksecurefunc, object, name, after)
    if ok then
        object.ahtfHooked[name] = true
    end
    return ok
end

local function NoteHook(field, text)
    if filterMenuDebug[field] == "none" or filterMenuDebug[field] == nil then
        filterMenuDebug[field] = text
        return
    end
    if not tostring(filterMenuDebug[field]):find(text, 1, true) then
        filterMenuDebug[field] = filterMenuDebug[field] .. "," .. text
    end
end

local function InstallClearButtonHooks(ahFrame)
    local bar = ahFrame and ahFrame.SearchBar
    local button = bar and bar.FilterButton or (ahFrame and ahFrame.FilterButton)
    if not button then
        return
    end
    local function afterUpdate(self)
        local owner = self
        if owner and not owner.ClearFiltersButton and owner.FilterButton then
            owner = owner.FilterButton
        end
        ForceClearButtonShown(owner)
    end
    local function afterReset()
        ClearHideTooltipsFromReset()
    end
    local updateNames = { "UpdateClearFiltersButton", "UpdateResetButton" }
    local barResetNames = { "ResetFilterButton", "ResetFilters", "ClearFilters", "ClearAllFilters" }
    local buttonResetNames = { "ResetFilters", "ClearFilters", "Reset", "ResetToDefault", "ClearAllFilters" }
    for i = 1, #updateNames do
        if HookNamedMethod(bar, updateNames[i], afterUpdate) then
            NoteHook("clearUpdate", "SearchBar:" .. updateNames[i])
        end
        if HookNamedMethod(button, updateNames[i], afterUpdate) then
            NoteHook("clearUpdate", "FilterButton:" .. updateNames[i])
        end
    end
    for i = 1, #barResetNames do
        if HookNamedMethod(bar, barResetNames[i], afterReset) then
            NoteHook("clearClick", "SearchBar:" .. barResetNames[i])
        end
    end
    for i = 1, #buttonResetNames do
        if HookNamedMethod(button, buttonResetNames[i], afterReset) then
            NoteHook("clearClick", "FilterButton:" .. buttonResetNames[i])
        end
    end

    local clear, clearKey = FindClearButton(button)
    if clear and not clear.ahtfClearHook and clear.HookScript then
        local ok = pcall(clear.HookScript, clear, "OnClick", function()
            ClearHideTooltipsFromReset()
        end)
        if ok then
            clear.ahtfClearHook = true
            NoteHook("clearClick", "ClearButton:" .. (clearKey or "OnClick"))
        end
    end

    if type(button.SetDefaultCallback) == "function" and not button.ahtfDefaultHooked and type(hooksecurefunc) == "function" then
        button.ahtfDefaultHooked = true
        hooksecurefunc(button, "SetDefaultCallback", function(self, callback)
            if self.ahtfWrappingDefault or type(callback) ~= "function" or callback == self.ahtfDefaultWrapped then
                return
            end
            self.ahtfWrappingDefault = true
            local wrapped = function(...)
                ClearHideTooltipsFromReset()
                pcall(callback, ...)
            end
            self.ahtfDefaultWrapped = wrapped
            self.defaultCallback = wrapped
            self.ahtfWrappingDefault = false
        end)
        NoteHook("clearClick", "SetDefaultCallback")
    end
    if type(button.defaultCallback) == "function" and button.defaultCallback ~= button.ahtfDefaultWrapped then
        local callback = button.defaultCallback
        local wrapped = function(...)
            ClearHideTooltipsFromReset()
            pcall(callback, ...)
        end
        button.ahtfDefaultWrapped = wrapped
        button.defaultCallback = wrapped
        NoteHook("clearClick", "defaultCallback")
    end

    if type(button.SetIsDefaultCallback) == "function" and not button.ahtfIsDefaultHooked and type(hooksecurefunc) == "function" then
        button.ahtfIsDefaultHooked = true
        hooksecurefunc(button, "SetIsDefaultCallback", function(self, callback)
            if self.ahtfWrappingIsDefault or callback == self.ahtfIsDefaultWrapped then
                return
            end
            self.ahtfWrappingIsDefault = true
            local wrapped = function(...)
                local isDefault = true
                if type(callback) == "function" then
                    local ok, value = pcall(callback, ...)
                    if ok then
                        isDefault = not not value
                    end
                end
                if hideTooltips then
                    return false
                end
                return isDefault
            end
            self.ahtfIsDefaultWrapped = wrapped
            self.isDefaultCallback = wrapped
            self.ahtfWrappingIsDefault = false
        end)
        NoteHook("clearUpdate", "SetIsDefaultCallback")
    end
    if button.isDefaultCallback ~= button.ahtfIsDefaultWrapped then
        local callback = button.isDefaultCallback
        local wrapped = function(...)
            local isDefault = true
            if type(callback) == "function" then
                local ok, value = pcall(callback, ...)
                if ok then
                    isDefault = not not value
                end
            end
            if hideTooltips then
                return false
            end
            return isDefault
        end
        button.ahtfIsDefaultWrapped = wrapped
        button.isDefaultCallback = wrapped
        NoteHook("clearUpdate", "isDefaultCallback")
    end
end

local function AddOurCheckbox(original, owner)
    local element = original(owner, HIDE_TOOLTIPS_LABEL, function()
        return hideTooltips and true or false
    end, function(newSelected)
        if type(newSelected) == "boolean" then
            SetHideTooltips(newSelected)
        else
            SetHideTooltips(not hideTooltips)
        end
    end)
    if type(element) == "table" then
        element.ahtfHideTooltips = true
        SetEntryTooltip(element)
    end
    filterMenuDebug.insertions = (filterMenuDebug.insertions or 0) + 1
    filterMenuDebug.injected = true
    return element
end

local function WrapGenerator(generator, via)
    return function(dropdown, rootDescription, ...)
        filterMenuDebug.insertions = 0
        filterMenuDebug.placed = "not-seen"
        filterMenuDebug.method = via
        local restore = {}
        local buildCount = 0
        local function wrapDescription(desc)
            if type(desc) ~= "table" or desc.ahtfCreateWrapped or type(desc.CreateCheckbox) ~= "function" then
                return
            end
            desc.ahtfCreateWrapped = true
            local original = desc.CreateCheckbox
            restore[#restore + 1] = function()
                desc.CreateCheckbox = original
                desc.ahtfCreateWrapped = nil
            end
            local prevUncollected = false
            desc.CreateCheckbox = function(self, text, isSelected, setSelected, data)
                local element = original(self, text, isSelected, setSelected, data)
                wrapDescription(element)
                if buildCount == 0 and type(text) == "string" and text ~= HIDE_TOOLTIPS_LABEL then
                    if IsUsableLabel(text) or prevUncollected then
                        buildCount = 1
                        AddOurCheckbox(original, self)
                        filterMenuDebug.placed = "after-usable"
                    end
                end
                prevUncollected = IsUncollectedLabel(text)
                return element
            end
        end
        wrapDescription(rootDescription)
        local genOk, err = pcall(generator, dropdown, rootDescription, ...)
        for i = 1, #restore do
            restore[i]()
        end
        if not genOk then
            filterMenuDebug.error = tostring(err)
        end
        if buildCount == 0 and type(rootDescription) == "table" and type(rootDescription.CreateCheckbox) == "function" then
            local ok, appendErr = pcall(AddOurCheckbox, rootDescription.CreateCheckbox, rootDescription)
            if ok then
                filterMenuDebug.placed = "appended"
            else
                filterMenuDebug.error = tostring(appendErr)
            end
        end
        RememberTag(rootDescription)
    end
end

local function StoreWrappedGenerator(button, wrapped)
    button.menuGenerator = wrapped
    if type(button.SetMenuGenerator) == "function" then
        local ok = pcall(button.SetMenuGenerator, button, wrapped)
        if ok then
            return "SetMenuGenerator"
        end
    end
    return "menuGenerator"
end

local function ApplyMenuWrap(button, generator, via)
    if menuWrapping or type(generator) ~= "function" then
        return
    end
    if generator == button.ahtfWrappedGenerator then
        return
    end
    if button.ahtfWrappedGenerator and button.menuGenerator == button.ahtfWrappedGenerator and generator == button.ahtfOriginalGenerator then
        return
    end
    menuWrapping = true
    button.ahtfOriginalGenerator = generator
    local wrapped = WrapGenerator(generator, via)
    button.ahtfWrappedGenerator = wrapped
    local stored = StoreWrappedGenerator(button, wrapped)
    button.ahtfMenuWrapped = true
    filterMenuDebug.method = via .. "->" .. stored
    menuWrapping = false
end

local function EnsureAddButtonHook()
    if legacyAddHooked or type(hooksecurefunc) ~= "function" or type(UIDropDownMenu_AddButton) ~= "function" then
        return
    end
    legacyAddHooked = true
    hooksecurefunc("UIDropDownMenu_AddButton", function(info, level)
        if legacyDepth <= 0 or legacyInserting then
            return
        end
        if type(info) ~= "table" or info.ahtfHideTooltips or not IsUsableLabel(info.text) then
            return
        end
        if type(UIDropDownMenu_CreateInfo) ~= "function" then
            return
        end
        legacyInserting = true
        local our = UIDropDownMenu_CreateInfo()
        our.text = HIDE_TOOLTIPS_LABEL
        our.ahtfHideTooltips = true
        our.isNotRadio = true
        our.keepShownOnClick = true
        our.checked = hideTooltips
        our.tooltipTitle = HIDE_TOOLTIPS_LABEL
        our.tooltipText = HIDE_TOOLTIPS_HELP
        our.tooltipOnButton = true
        our.func = function(_, _, _, checked)
            if type(checked) == "boolean" then
                SetHideTooltips(checked)
            else
                SetHideTooltips(not hideTooltips)
            end
        end
        pcall(UIDropDownMenu_AddButton, our, level)
        filterMenuDebug.injected = true
        filterMenuDebug.insertions = 1
        filterMenuDebug.method = "UIDropDownMenu"
        filterMenuDebug.placed = "after-usable"
        filterMenuDebug.tooltip = "dropdown-tooltipTitle"
        legacyInserting = false
    end)
end

local function InstallFilterMenu(ahFrame)
    local bar = ahFrame and ahFrame.SearchBar
    local button = bar and bar.FilterButton or ahFrame.FilterButton
    if not button then
        filterMenuDebug.method = "no-filter-button"
        return false
    end
    filterMenuDebug.hasSetupMenu = type(button.SetupMenu) == "function"
    filterMenuDebug.hasGenerator = type(button.menuGenerator) == "function"
    pcall(InstallClearButtonHooks, ahFrame)

    if filterMenuDebug.hasSetupMenu or filterMenuDebug.hasGenerator then
        if type(button.menuGenerator) == "function" then
            ApplyMenuWrap(button, button.menuGenerator, "CreateCheckbox-wrap")
        end
        if type(hooksecurefunc) == "function" and filterMenuDebug.hasSetupMenu and not button.ahtfSetupHooked then
            button.ahtfSetupHooked = true
            hooksecurefunc(button, "SetupMenu", function(self, generator)
                ApplyMenuWrap(self, generator, "CreateCheckbox-wrap")
            end)
        end
    elseif type(button.initialize) == "function" and not button.ahtfLegacy then
        EnsureAddButtonHook()
        local original = button.initialize
        button.initialize = function(self, level, menuList)
            legacyDepth = legacyDepth + 1
            filterMenuDebug.insertions = 0
            local ok, err = pcall(original, self, level, menuList)
            legacyDepth = legacyDepth - 1
            if not ok then
                filterMenuDebug.error = tostring(err)
            end
            if filterMenuDebug.insertions == 0 and type(UIDropDownMenu_CreateInfo) == "function" and type(UIDropDownMenu_AddButton) == "function" then
                legacyInserting = true
                local our = UIDropDownMenu_CreateInfo()
                our.text = HIDE_TOOLTIPS_LABEL
                our.ahtfHideTooltips = true
                our.isNotRadio = true
                our.keepShownOnClick = true
                our.checked = hideTooltips
                our.tooltipTitle = HIDE_TOOLTIPS_LABEL
                our.tooltipText = HIDE_TOOLTIPS_HELP
                our.tooltipOnButton = true
                our.func = function(_, _, _, checked)
                    if type(checked) == "boolean" then
                        SetHideTooltips(checked)
                    else
                        SetHideTooltips(not hideTooltips)
                    end
                end
                pcall(UIDropDownMenu_AddButton, our, level)
                filterMenuDebug.injected = true
                filterMenuDebug.insertions = 1
                filterMenuDebug.method = "UIDropDownMenu-append"
                filterMenuDebug.placed = "appended"
                legacyInserting = false
            end
        end
        button.ahtfLegacy = true
        if filterMenuDebug.method == "not-installed" then
            filterMenuDebug.method = "UIDropDownMenu-wrapped"
        end
    end

    return button.ahtfMenuWrapped or button.ahtfLegacy or filterMenuDebug.clearClick ~= "none"
end

local function AttachAuctionHouse(ahFrame)
    if not ahFrame then
        return
    end
    if not ahShowHooked then
        if FrameIsLocked(ahFrame) then
            attachQueued = true
            return
        end
        local hookOk = pcall(function()
            ahFrame:HookScript("OnShow", ResetToggle)
            ahFrame:HookScript("OnHide", function()
                ResetToggle()
                CloseDressingRoomWithAuctionHouse()
                if RequestDimRefresh then
                    RequestDimRefresh()
                end
            end)
            if type(hooksecurefunc) == "function" and type(ahFrame.SetDisplayMode) == "function" then
                hooksecurefunc(ahFrame, "SetDisplayMode", function()
                    if RequestDimRefresh then
                        RequestDimRefresh()
                    end
                end)
            end
        end)
        if hookOk then
            ahShowHooked = true
            attachQueued = false
            if IsShown(ahFrame) then
                ResetToggle()
            end
        end
    end
    pcall(InstallFilterMenu, ahFrame)
end

local function TryAttach()
    InstallHooks()
    if AuctionHouseFrame then
        AttachAuctionHouse(AuctionHouseFrame)
    end
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
    if type(AuctionHouseTricksForeverDB) ~= "table" then
        AuctionHouseTricksForeverDB = {}
    end
    if AuctionHouseTricksForeverDB[DB_CLOSE_KEY] == nil then
        AuctionHouseTricksForeverDB[DB_CLOSE_KEY] = false
    end
    if AuctionHouseTricksForeverDB[DB_DIM_KEY] == nil then
        AuctionHouseTricksForeverDB[DB_DIM_KEY] = false
    end
end

local function CloseDressingRoomEnabled()
    return type(AuctionHouseTricksForeverDB) == "table" and AuctionHouseTricksForeverDB[DB_CLOSE_KEY] == true
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
-- Any unexpected error stops dimming for this session, restores what we
-- changed, and prints once. Nothing in this path raises a Lua error popup.
-- ---------------------------------------------------------------------------

local DIM_ALPHA = 0.35

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
local hookedBagClasses = setmetatable({}, { __mode = "k" })
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

local function DimSavedOn()
    return type(AuctionHouseTricksForeverDB) == "table" and AuctionHouseTricksForeverDB[DB_DIM_KEY] == true
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
    if dimSessionDisabled then
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
-- uses ARK_Data.blizzard_id and .slot_id. Adapters may set AHTFBag.
local function ResolveBagSlot(button)
    if type(button) ~= "table" then
        return nil
    end
    if type(button.AHTFBag) == "number" and type(button.AHTFSlot) == "number" then
        if IsPlayerCarryBag(button.AHTFBag) and SlotOk(button.AHTFSlot) then
            return button.AHTFBag, button.AHTFSlot
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
    print("Auction House Tricks Forever: item dimming turned off for this session (/reload to try again).")
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

local function HookBagFamilyClass(class)
    if hookedBagClasses[class] or type(class) ~= "table" or type(hooksecurefunc) ~= "function" then
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
        hookedBagClasses[class] = true
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

-- Bagnon, Bagnonium, and Combuctor are skins on the same BagBrother item
-- button: .bag / GetBag(), GetID() is the slot, and UpdateBorder resets alpha.
local BAG_FAMILY = {
    { addon = "Bagnon", framePrefix = "BagnonInventory" },
    { addon = "Bagnonium", framePrefix = "BagnoniumInventory" },
    { addon = "Combuctor", framePrefix = "CombuctorInventory" },
}

local function ScanBagFamily(spec)
    local addon = _G[spec.addon]
    if type(addon) ~= "table" and not AddonLoaded(spec.addon) then
        return
    end
    if type(addon) == "table" then
        HookBagFamilyClass(addon.ContainerItem or addon.Item)
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
        local frame = _G[spec.framePrefix .. i]
        if type(frame) == "table" then
            WalkItemChildren(frame, 0)
        end
    end
end

local function ScanBagnon()
    for i = 1, #BAG_FAMILY do
        ScanBagFamily(BAG_FAMILY[i])
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
        "AuctionHouseTricksForeverUnsellable",
        function(cornerFrame, details)
            local button = cornerFrame and cornerFrame.GetParent and cornerFrame:GetParent()
            local loc = details and details.itemLocation
            if type(button) ~= "table" or type(loc) ~= "table" then
                return false
            end
            if type(loc.bagID) == "number" then
                button.AHTFBag = loc.bagID
            end
            if type(loc.slotIndex) == "number" then
                button.AHTFSlot = loc.slotIndex
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
        button.AHTFBag, button.AHTFSlot = second, first
    elseif IsPlayerCarryBag(first) and SlotOk(second) then
        button.AHTFBag, button.AHTFSlot = first, second
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
                            button.AHTFBag = data.bagid
                        end
                        if type(data.slotid) == "number" then
                            button.AHTFSlot = data.slotid
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

local SETTINGS_RESET_POPUP = "AUCTIONHOUSETRICKSFOREVER_RESET_SETTINGS"
local SETTINGS_CLOSE_LABEL = "Close Dressing Room with Auction House"
local SETTINGS_DIM_LABEL = "Dim unsellable items when Sell tab selected"
local SETTINGS_CLOSE_TIP = "When this is enabled, the Dressing Room closes when the Auction House closes, including when you click the X or walk away."
local SETTINGS_DIM_TIP = "When this is enabled, bag items that can't be listed on the Auction House (such as Soulbound items) are dimmed while the Sell tab is selected."
local SETTINGS_DIM_WARNING = " This setting may not be compatible with your bag add-on if you use one. If it can't dim your bags, dimming turns itself off until you /reload."

local function ResetHelperSettingsToDefaults()
    InitDB()
    AuctionHouseTricksForeverDB[DB_CLOSE_KEY] = false
    AuctionHouseTricksForeverDB[DB_DIM_KEY] = false
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
        text = "Reset Auction House Tricks Forever settings to defaults?",
        button1 = okay,
        button2 = cancel,
        OnAccept = ResetHelperSettingsToDefaults,
        timeout = 0,
        whileDead = 1,
        hideOnEscape = 1,
        preferredIndex = 3,
    }
end

local function TitleColorRGB()
    local r, g, b = 1, 0.82, 0
    if type(NORMAL_FONT_COLOR) == "table" and type(NORMAL_FONT_COLOR.GetRGB) == "function" then
        local ok, rr, gg, bb = pcall(NORMAL_FONT_COLOR.GetRGB, NORMAL_FONT_COLOR)
        if ok and type(rr) == "number" and type(gg) == "number" and type(bb) == "number" then
            r, g, b = rr, gg, bb
        end
    end
    return r, g, b
end

-- SetText's 5th argument is text alpha (a number), not wrap. Passing true
-- there does not raise a script error on this client; the line is drawn with
-- alpha 0, so the tooltip looks missing. AddLine's 5th argument is wrap.
local function ShowSettingsRowTip(owner, title, description, warningTail)
    if not GameTooltip or not owner then
        return
    end
    local function show()
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        if GameTooltip.SetAlpha then
            GameTooltip:SetAlpha(1)
        end
        local r, g, b = TitleColorRGB()
        local titled = false
        if type(GameTooltip_SetTitle) == "function" then
            local color = (type(NORMAL_FONT_COLOR) == "table") and NORMAL_FONT_COLOR or nil
            titled = pcall(GameTooltip_SetTitle, GameTooltip, title or "", color, true)
        end
        if not titled then
            GameTooltip:SetText(title or "", r, g, b, 1)
        end
        if type(description) == "string" and description ~= "" then
            GameTooltip:AddLine(description, 1, 1, 1, true)
        end
        if type(warningTail) == "string" and warningTail ~= "" then
            GameTooltip:AddLine(" ")
            local warningWord = "|cffffd100Warning!|r"
            if type(NORMAL_FONT_COLOR) == "table" and type(NORMAL_FONT_COLOR.WrapTextInColorCode) == "function" then
                local colorOk, colored = pcall(NORMAL_FONT_COLOR.WrapTextInColorCode, NORMAL_FONT_COLOR, "Warning!")
                if colorOk and type(colored) == "string" and colored ~= "" then
                    warningWord = colored
                end
            end
            GameTooltip:AddLine(warningWord .. warningTail, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end
    if pcall(show) then
        return
    end
    pcall(function()
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        GameTooltip:SetText(title or "", 1, 0.82, 0, 1)
        GameTooltip:Show()
    end)
end

local function WriteSavedOption(key, checked)
    InitDB()
    AuctionHouseTricksForeverDB[key] = checked and true or false
end

-- Both saved rows use this. onClick receives the new boolean and writes the
-- same DB table OnRefresh reads. A full-row mouse frame is not used: it sat
-- on top of the checkbox and anchored the tooltip to the panel's right edge.
local function CreateSettingsCheckboxRow(parent, anchorTo, yOffset, labelText, tooltipTitle, tooltipBody, onClick, tooltipWarning)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOffset)
    row:SetPoint("RIGHT", parent, "RIGHT", -32, 0)
    row:SetHeight(28)

    local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("LEFT", row, "LEFT", 0, 0)
    if check.SetMotionScriptsWhileDisabled then
        check:SetMotionScriptsWhileDisabled(true)
    end
    if check.Text then
        check.Text:SetText("")
        check.Text:Hide()
    end

    local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetJustifyH("LEFT")
    label:SetJustifyV("MIDDLE")
    label:SetWordWrap(false)
    label:SetText(labelText)
    label:SetPoint("LEFT", check, "RIGHT", 6, 0)
    label:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    check.label = label

    local function tipBody()
        if type(tooltipBody) == "function" then
            return tooltipBody()
        end
        return tooltipBody
    end

    -- The option words are a FontString, which never receives mouse. A button
    -- beside the checkbox covers that text. The checkbox itself also gets
    -- OnEnter, and its hit rect is stretched over the words so either target
    -- opens the tip. Both scripts are reapplied from OnRefresh.
    local labelHit = CreateFrame("Button", nil, row)
    labelHit:SetPoint("TOPLEFT", check, "TOPRIGHT", 2, 6)
    labelHit:SetPoint("BOTTOMLEFT", check, "BOTTOMRIGHT", 2, -6)
    labelHit:SetWidth(32)
    check.ahtfLabelHit = labelHit

    local function hideTip()
        if GameTooltip and GameTooltip.GetOwner and GameTooltip:GetOwner() == check then
            GameTooltip:Hide()
        end
    end
    local function showTip()
        ShowSettingsRowTip(check, tooltipTitle, tipBody(), tooltipWarning)
    end
    local function bindTipScripts()
        check:EnableMouse(true)
        check:SetScript("OnEnter", showTip)
        check:SetScript("OnLeave", hideTip)
        labelHit:EnableMouse(true)
        labelHit:SetScript("OnEnter", showTip)
        labelHit:SetScript("OnLeave", hideTip)
        labelHit:SetScript("OnClick", function()
            check:Click()
        end)
        local level = check:GetFrameLevel() or 1
        labelHit:SetFrameLevel(level + 2)
        local textW = 0
        if label.GetStringWidth then
            textW = label:GetStringWidth() or 0
        end
        if type(textW) ~= "number" or textW < 8 then
            textW = 180
        end
        labelHit:SetWidth(textW + 8)
        check:SetHitRectInsets(0, -(textW + 16), -6, -6)
        check.ahtfTipBound = true
    end
    check.ahtfRebindTip = bindTipScripts
    bindTipScripts()

    check:SetScript("OnClick", function(self)
        if self.ahtfLocked then
            self:SetChecked(self.ahtfSaved == true)
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

    local panel = CreateFrame("Frame", "AuctionHouseTricksForeverSettingsPanel", UIParent)
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

    local dressHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    dressHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -56)
    dressHeader:SetText("Dressing Room")

    local closeRow
    settingsCloseCheck, closeRow = CreateSettingsCheckboxRow(
        panel,
        dressHeader,
        -6,
        SETTINGS_CLOSE_LABEL,
        SETTINGS_CLOSE_LABEL,
        SETTINGS_CLOSE_TIP,
        function(checked)
            WriteSavedOption(DB_CLOSE_KEY, checked)
        end
    )

    local ahHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    ahHeader:SetPoint("TOPLEFT", closeRow, "BOTTOMLEFT", 0, -18)
    ahHeader:SetText("Auction House")

    local dimRow
    settingsDimCheck, dimRow = CreateSettingsCheckboxRow(
        panel,
        ahHeader,
        -6,
        SETTINGS_DIM_LABEL,
        SETTINGS_DIM_LABEL,
        SETTINGS_DIM_TIP,
        function(checked)
            WriteSavedOption(DB_DIM_KEY, checked)
            if RequestDimRefresh then
                RequestDimRefresh()
            end
        end,
        SETTINGS_DIM_WARNING
    )

    function panel:OnRefresh()
        InitDB()
        if settingsCloseCheck then
            local closeOn = AuctionHouseTricksForeverDB[DB_CLOSE_KEY] == true
            settingsCloseCheck.ahtfLocked = false
            settingsCloseCheck.ahtfSaved = closeOn
            settingsCloseCheck:SetChecked(closeOn)
            settingsCloseCheck:Enable()
            if settingsCloseCheck.label then
                settingsCloseCheck.label:SetFontObject("GameFontHighlight")
            end
            if settingsCloseCheck.ahtfRebindTip then
                settingsCloseCheck.ahtfRebindTip()
            end
        end
        if settingsDimCheck then
            local dimOn = AuctionHouseTricksForeverDB[DB_DIM_KEY] == true
            settingsDimCheck.ahtfSaved = dimOn
            settingsDimCheck.ahtfLocked = false
            settingsDimCheck:SetChecked(dimOn)
            settingsDimCheck:Enable()
            if settingsDimCheck.label then
                settingsDimCheck.label:SetFontObject("GameFontHighlight")
            end
            if settingsDimCheck.ahtfRebindTip then
                settingsDimCheck.ahtfRebindTip()
            end
        end
    end

    function panel:OnCommit()
    end

    function panel:OnDefault()
        -- Blizzard's panel Defaults button is hidden for canvas categories.
        -- Our Defaults button uses SETTINGS_RESET_POPUP instead.
    end

    panel:SetScript("OnShow", function(self)
        self:OnRefresh()
    end)

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
    -- on the panel and only reset AuctionHouseTricksForeverDB through a StaticPopup.
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

local function TipTargetLine(check, which)
    if not check then
        return which .. ": missing"
    end
    local function flag(frame, label)
        if not frame then
            return label .. " missing"
        end
        local mouse = "?"
        if frame.IsMouseEnabled then
            mouse = frame:IsMouseEnabled() and "mouse-on" or "mouse-off"
        end
        local script = "OnEnter-missing"
        if frame.GetScript and frame:GetScript("OnEnter") then
            script = "OnEnter-set"
        end
        local name = FrameTag(frame)
        return label .. "=" .. name .. " " .. mouse .. " " .. script
    end
    return which .. ": " .. flag(check, "check") .. "; " .. flag(check.ahtfLabelHit, "labelHit")
end

local function PrintLayoutDebug()
    local meta = nil
    if C_AddOns and type(C_AddOns.GetAddOnMetadata) == "function" then
        local ok, value = pcall(C_AddOns.GetAddOnMetadata, addonName, "Version")
        if ok then
            meta = value
        end
    elseif type(GetAddOnMetadata) == "function" then
        local ok, value = pcall(GetAddOnMetadata, addonName, "Version")
        if ok then
            meta = value
        end
    end
    print("Auction House Tricks Forever debug " .. ADDON_VERSION .. " (toc " .. tostring(meta) .. ")")
    print(string.format(
        "filterMenu injected=%s method=%s tag=%s placed=%s insertions=%s tooltip=%s clearClick=%s clearUpdate=%s error=%s checked=%s",
        tostring(filterMenuDebug.injected),
        tostring(filterMenuDebug.method),
        tostring(filterMenuDebug.tag),
        tostring(filterMenuDebug.placed),
        tostring(filterMenuDebug.insertions),
        tostring(filterMenuDebug.tooltip),
        tostring(filterMenuDebug.clearClick),
        tostring(filterMenuDebug.clearUpdate),
        tostring(filterMenuDebug.error),
        tostring(hideTooltips)
    ))
    print(TipTargetLine(settingsCloseCheck, "close"))
    print(TipTargetLine(settingsDimCheck, "dim"))
end

-- WoW matches slash commands without regard to case. /ahtf, /AHTF, and
-- /ahtricks open the settings category. "/ahtf debug" prints the Filter-menu
-- injection and the settings-tooltip owners.
SLASH_AUCTIONHOUSETRICKSFOREVER1 = "/ahtf"
SLASH_AUCTIONHOUSETRICKSFOREVER2 = "/AHTF"
SLASH_AUCTIONHOUSETRICKSFOREVER3 = "/ahtricks"
SlashCmdList.AUCTIONHOUSETRICKSFOREVER = function(msg)
    local text = ""
    if type(msg) == "string" then
        text = msg:lower():match("^%s*(.-)%s*$") or ""
    end
    if text == "debug" then
        PrintLayoutDebug()
        return
    end
    if not OpenSettings() then
        print("Auction House Tricks Forever: open Game Menu, Options, AddOns, then Auction House Tricks Forever.")
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
    local hadHooks = ahShowHooked
    TryAttachSoon()
    if not hadHooks then
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
