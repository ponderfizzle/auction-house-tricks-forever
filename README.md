# Auction House Dressing Room Helper

A World of Warcraft: Forever add-on. While the auction house is open and **Hide tooltips** is checked, it hides the item tooltip under your cursor and the equipped-gear comparison tooltip (the one titled **Equipped**). That keeps the Dressing Room clear when you Ctrl-click gear in Browse Auctions.

**Hide tooltips** is not saved. It starts unchecked, and it is cleared every time the auction house opens or closes.

Two options are saved under Game Menu → Options → AddOns. Both default to off.

- **Close Dressing Room with Auction House** also closes the Dressing Room when the auction house closes.
- **Dim unsellable items when Sell tab selected** fades bag items that cannot be posted, and only while that tab is open.

This targets Forever's retail-style UI (`AuctionHouseFrame` from `Blizzard_AuctionHouseUI`), not the older Classic `AuctionFrame`.

## Install

Delete an older copy before you install this one. The add-on used to be named `AHTooltipHider`. Leaving that folder in `Interface\AddOns` loads the old version beside this one.

1. Remove `Interface\AddOns\AHTooltipHider` if it is there.
2. Copy the `AHDressingRoomHelper` folder into `Interface\AddOns`. The folder name must stay `AHDressingRoomHelper`.
3. Fully restart the client. A new add-on folder is picked up at startup. `/reload` is not enough the first time.
4. On the character screen, open **AddOns** and enable **Auction House Dressing Room Helper**.

Beta clients used this path:

`World of Warcraft\_classic_beta_\Interface\AddOns\AHDressingRoomHelper`

The Warcraft Wiki lists `_forever_` as the Forever PTR folder. After the November 4, 2026 launch the folder name may be different. Put the add-on in the `Interface\AddOns` directory of the client you actually start.

## Interface version

Both TOC files declare:

```
## Interface: 16001
```

That is the Forever beta value. It was confirmed in game: `/dump select(4, GetBuildInfo())` returned `16001`. It can still change at launch. Classic Era is 11509. Midnight retail is 120100 on the [Forever addon guide](https://wowforeverguides.com/addons/developers) (the wiki's Standard row may read 120105). This add-on does not claim those.

To see the build and the interface number together:

```
/run print(select(2, GetBuildInfo()), select(4, GetBuildInfo()))
```

If a later dump is not `16001`, change the `## Interface:` line in both `AHDressingRoomHelper.toc` and `AHDressingRoomHelper_Camelot.toc` to that number, then restart. If the add-on is only flagged out of date, checking **Load out of date AddOns** will load it, but matching the dumped number is the real fix.

`AHDressingRoomHelper_Camelot.toc` is the game-type file the wiki lists for Forever (internal name Camelot). The client loads it instead of the unsuffixed TOC when it recognizes that suffix. The suffix may be renamed at launch. The unsuffixed file is the fallback and declares the same interface number.

## Use

1. Talk to an auctioneer and open **Browse Auctions**.
2. **Hide tooltips** sits on the search row. On the Forever beta the category list's column headers start immediately under the search bar, so there is no empty Back row there. The control is centered in the gap between the search box and **Filter**: the words are above the checkbox when a single line would run into the search box. The midpoint is measured from the search box's right edge and Filter's left edge, so it stays in that gap if the window scale changes. Back, the count, the refresh button, and the results stay clear on panes that have them. If an item or commodity page shows the **Back** / "N Available" row, the control moves onto that row, just left of the count. Sell and Auctions hide the search bar, so the control sits at the bottom, just right of your money.
3. Leave **Hide tooltips** unchecked for normal item tooltips and the **Equipped** comparison.
4. Check it when you want the preview unobstructed. Hovering an auction item no longer shows that item's tooltip or the equipped-gear comparison. Ctrl-click still previews the item.
5. Uncheck it and the filter stops at once. Move onto an item row if a tooltip does not reappear on its own. The cursor is on the checkbox when you click it, so the row's hover may not fire again until you move.
6. Close the auction house. **Hide tooltips** is cleared. Open the auction house again and the box is unchecked.
7. The saved options are separate. Open them with `/ahdrh` (or `/AHDRH`), or with Game Menu → **Options** → **AddOns** → **AH Dressing Room Helper**. Both start off. **Close Dressing Room with Auction House** is under **Dressing Room**. **Dim unsellable items when Sell tab selected** is under **Auction House**.

Seller names, time-left text, the Search button, and the checkbox's own help tip are not item tooltips, so they still show while the box is checked. Bag slots are not part of the auction frame, so bag tooltips and their comparisons stay up too. The auction house opens your bags on its own. That is unchanged.

## Close Dressing Room with Auction House

Pressing Escape already closes the auction house and the Dressing Room. Clicking the auction house's red X, or walking away, closes only the auction house and leaves the Dressing Room up.

Turn the option on and every auction-house close also hides `DressUpFrame` through `HideUIPanel`. That covers the X button, walking away, and `AUCTION_HOUSE_CLOSED`. The option off does nothing to the Dressing Room. The option is stored in `AHDressingRoomHelperDB` and is created in `ADDON_LOADED`. It survives `/reload` and relog. **Hide tooltips** is not in that table.

If the close happens in combat, the hide waits until combat ends (`PLAYER_REGEN_ENABLED`). `DressUpFrame` is a protected panel, and `HideUIPanel` is not called while `InCombatLockdown()` is true. If you reopen the auction house before combat ends, the queued close is dropped.

## Dim unsellable items when Sell tab selected

Turn this on and, while the auction house is open on the **Sell** tab, items in your bags that cannot be posted are dimmed: the icon is desaturated, the button is faded, and a dark overlay sits on the icon. Clicks still work. Empty slots are left alone.

The dimming stops as soon as any of these happen:

- You switch to **Buy** or **Auctions**.
- The auction house closes (red X, Escape, walking away, or `AUCTION_HOUSE_CLOSED`).
- You turn the option off.

Moving items, posting an auction, opening or closing a bag, and the bag add-on redrawing its buttons all refresh the dim. The option is stored in `AHDressingRoomHelperDB` as `dimUnsellable` and survives `/reload` and relog. **Hide tooltips** is still not saved.

Forever's sell window is titled **Post Auctions**. The add-on treats the tab as Sell when any of these is true: `IsListingAuctions()`, the Sell tab button is selected, a sell pane is on screen, or the window title is the sell title (including "Post Auctions"). A false result from `IsListingAuctions()` is not treated as "not the sell tab", because Forever may not use the retail sell layout.

What counts as unsellable:

1. `C_AuctionHouse.IsSellItemValid(itemLocation, false)` when that call works. The second argument keeps Blizzard from popping an error on a soulbound item. This is the check that knows a quest item can still be posted.
2. If that call is missing or errors, `C_Item.IsBound` plus the item tooltip. Soulbound, conjured, and account-bound lines dim the item. A tooltip line that is exactly "Quest Item" dims it. "Binds when equipped" and "Binds when used" do not. Item class is never used, so quest items are not dimmed as a group. If the result is unknown, the item is left bright.

Bank bags are not dimmed. Backpack, equipped bags, and the reagent bag are.

### Bags that are handled

| Bag UI | Role |
| --- | --- |
| Default Blizzard bags (`ContainerFrame1` through `ContainerFrameN`, and `ContainerFrameCombinedBags`) | First test target. Buttons come from `EnumerateValidItems` / `Items`, with `GetBagID()` and `GetID()`. |
| Bagnon and Bagnonium | Second test target. Same BagBrother item button (`.bag` / `GetBag()`, `GetID()` is the slot, `UpdateBorder` resets alpha). Bagnonium is the current name of Combuctor. Reviewed against that source, not run inside the game. |
| Baganator, AdiBags, BetterBags, ArkInventory | Included for later testing. Each adapter loads only when that add-on is loaded, and each is wrapped so a missing or changed add-on does not error. |
| Any other button that can report a player bag and slot | Small generic scan, only while dimming is on. It skips action bars and the auction house window. |

### Bag UIs that turn the option off

If one of these is loaded, the checkbox is grayed out and dimming does not run. The saved value is not changed, so it comes back when you stop using that bag UI and `/reload`.

Inventorian, LiteBag, Sorted, cargBags (including Nivaya, Smoof, and Simplicity), Baggins, BaudBag, OneBag, OneBag3, ElvUI, and Tukui.

The checkbox tooltip, and a gray note under it, read: "Not available with &lt;AddOnName&gt;. Supported: default bags, Bagnon, Bagnonium, Baganator, AdiBags, BetterBags, ArkInventory." The checkbox is disabled (`Disable()`), the label uses `GameFontDisable`, and clicks do not change `dimUnsellable`. Detection runs when the options panel is shown, from `C_AddOns.IsAddOnLoaded` and `C_AddOns.GetAddOnEnableState`. Having no bag add-on is not a block.

If some other bag UI errors while dimming, dimming stops for that session, every icon we changed is restored, and chat gets one line: `AH Dressing Room Helper: item dimming turned off — bag add-on not supported`. The saved checkbox stays as it was. `/reload` tries again.

## How it works

`Blizzard_AuctionHouseUI` loads the first time you open the auction house. The add-on listens for `ADDON_LOADED`, `AUCTION_HOUSE_SHOW`, and `AUCTION_HOUSE_CLOSED`, and it hooks the frame's `OnShow` and `OnHide`.

Hiding tooltips is decided at the moment a tooltip is shown, from both of these:

- `AuctionHouseFrame:IsShown()`
- the **Hide tooltips** checkbox is checked

Closing the window makes `IsShown()` false, and `OnHide` / `AUCTION_HOUSE_CLOSED` also uncheck that box. Nothing in SavedVariables reloads a "hidden tooltips" state.

The hooks are filters, not replacements. `hooksecurefunc` runs after Blizzard's function. When the gates are off, the hook returns without doing anything.

- The hovered item tooltip is `GameTooltip`. The auction house fills it with `SetItemKey` or `SetHyperlink`, then calls `Show`. An item post-call on `TooltipDataProcessor` marks that cycle as an item tooltip. The `Show` hook hides it only when the owner is the auction house or the dressing room.
- The **Equipped** comparison is `ShoppingTooltip1` and `ShoppingTooltip2`. Current retail code (the same system Forever's 12.1.5-family UI uses) builds those in `TooltipComparisonManager:AnchorShoppingTooltips`, usually via `GameTooltip_ShowCompareItem` and `C_TooltipComparison.CompareItem`. Their `Show` / `SetShown` hooks hide them when the main tooltip is an auction or dressing-room item.

An invisible tooltip would still block clicks on the preview, so the frames are actually hidden, not faded out.

The options entry uses `Settings.RegisterCanvasLayoutCategory` with a custom panel frame, then `Settings.RegisterAddOnCategory`. Canvas layout replaces the scrollable settings list for this category, which hides Blizzard's header **Defaults** button (the one that can reset all game UI settings). The add-on draws its own **Defaults** control on the panel; it opens a `StaticPopup` that only resets `AHDressingRoomHelperDB` keys (`closeDressingRoom` and `dimUnsellable` to false) and refreshes the checkboxes. The list name is still **AH Dressing Room Helper**. `/ahdrh` calls `Settings.OpenToCategory` on that category. Both sections use the same left edge. Headers use `GameFontNormal`. Option labels use `GameFontHighlight`. Each checkbox's click writes its key through the same helper, and the panel refresh reads those keys back. The dim row is disabled while an unsupported bag add-on is loaded, without rewriting the saved value.

## Manual test

Run this in game. This project cannot launch the client.

1. Remove any old `AHTooltipHider` folder. Install `AHDressingRoomHelper`, restart, and enable **Auction House Dressing Room Helper**. Confirm `/dump select(4, GetBuildInfo())` is `16001`.
2. Open the auction house on **Buy** / Browse. **Hide tooltips** is present and unchecked, centered between the search box and **Filter** (the checkbox and the words together). It stays in that gap. It does not cover the search box, Filter, or the results.
3. Hover a piece of armor. You should see the item tooltip and, when comparison is on, the **Equipped** tooltip.
4. Check **Hide tooltips**. Hover another piece of gear. Neither tooltip should appear. Ctrl-click the row and confirm the Dressing Room model is not covered. The checkbox help should read: "Hides the gear comparison tooltips to prevent them from obscuring the Dressing Room preview.  Uncheck this setting to bring them back.  This setting clears when the auction house window closes."
5. Hover a non-item control (the Search button, a category). Its normal text tooltip should still appear.
6. Uncheck the box. Hover an item. Both tooltips should be back.
7. Check the box, close the auction house, and hover gear in your bags and on the character sheet. Tooltips and comparisons must be normal.
8. Reopen the auction house. **Hide tooltips** must be unchecked.
9. With **Close Dressing Room with Auction House** off, Ctrl-click gear so the Dressing Room is open. Click the auction house's red X. The Dressing Room stays open. Reopen the auction house, open the Dressing Room again, and press Escape. Both close. That is the default Escape behavior, and the option is still off.
10. `/ahdrh` opens Options on **AddOns → AH Dressing Room Helper**. Turn **Close Dressing Room with Auction House** on. Reopen the auction house, open the Dressing Room, and click the red X. The Dressing Room closes. Repeat, then walk out of range of the auctioneer. The Dressing Room closes again.
11. `/reload`. The option is still on. **Hide tooltips** is unchecked the next time you open the auction house. Log out and back in. The option is still on.
12. Turn the option off, `/reload`, and close the auction house with the X while the Dressing Room is open. The Dressing Room stays open.

### Default bags (first)

13. Use Blizzard's bags (disable Bagnon for this pass). `/ahdrh`, and under **Auction House** turn on **Dim unsellable items when Sell tab selected**. Open the auction house on **Buy**. Nothing in your bags is dimmed.
14. Switch to **Sell** (the window may be titled **Post Auctions**). A soulbound item such as Deepgrave Trousers is dimmed. A bind-on-equip item that can be posted stays bright. A quest item stays bright when it can be posted, and dims when it cannot.
15. Switch to **Buy**, then **Auctions**. The bags return to normal each time. Go back to **Sell** and they dim again.
16. Close the auction house with the red X, with Escape, and by walking away (reopen between each). The bags are normal after every close.
17. On the Sell tab, turn the option off. Icons restore immediately. Turn it on. They dim again. `/reload` and relog: the option is still on. **Hide tooltips** is unchecked the next time the auction house opens.

### Bagnon (second)

18. Enable Bagnon and repeat steps 13–17 with Bagnon's bag window open (the window titled with your inventory). Soulbound items dim on Sell and restore on Buy, Auctions, close, and when the option is turned off. Filtering the bag with Bagnon's search still leaves unsellable matches dimmed after Bagnon redraws.

### Other bag add-ons (later, not verified in this build)

19. When you want to try them: Baganator, AdiBags, BetterBags, and ArkInventory. Same Sell-tab checks as step 14. A missing or changed add-on should not throw a Lua error.

### Unsupported bag UI

20. Enable one add-on from the unsupported list (Inventorian is enough). `/reload`. `/ahdrh`. **Dim unsellable items when Sell tab selected** is grayed out and cannot be clicked. Its tooltip names that add-on and lists the supported bag UIs, including Bagnonium. A gray note under the row names the add-on. `/dump AHDressingRoomHelperDB.dimUnsellable` is unchanged. Disable that bag add-on, `/reload`, and the checkbox works again with the same saved value.

### v1.5

21. **Dim setting saves.** With default bags (no bag add-on), check **Dim unsellable items when Sell tab selected**, close Options, and open them again. It is still checked. `/dump AHDressingRoomHelperDB.dimUnsellable` is `true`. Open the Sell tab and confirm soulbound items dim. Repeat with Bagnon, then with Bagnonium. **Close Dressing Room with Auction House** still saves on its own.
22. **Settings layout.** Both headers line up on the left. Both checkboxes line up in one column. Both option labels are the same color.
23. **Tooltips.** Hover each checkbox. The tip sits on the checkbox. The title is the setting name once, then a short description. A blocked dim row also includes the "Not available with …" line.
24. **Browse placement.** **Hide tooltips** sits between the search box and **Filter**, centered as a pair. It does not sit left of the favorites star. Open an item and press Back: it stays in that same spot.

## Forever guide checklist

From the [addon development guide](https://wowforeverguides.com/addons/developers). Items that do not apply to this add-on are marked.

| # | Check | This add-on |
| --- | --- | --- |
| 1 | `## Interface: 16001`, alone or on a multi-client line | Yes, in both TOC files. Confirmed in the Forever beta with `/dump select(4, GetBuildInfo())`. |
| 2 | Lua 5.1: no `goto`, `//`, `_ENV`, `require`, `io`, or `os` | Yes. |
| 3 | Files start with `local addonName, ns = ...`; helpers are local | Yes. The auction-house checkbox is an unnamed frame. SavedVariables and the slash command are the globals WoW requires. |
| 4 | Item and spell lookups go through `C_Item` / `C_Spell`, with nil checks | Sellability uses `C_AuctionHouse.IsSellItemValid` when it exists, then `C_Item.IsBound` and `C_TooltipInfo.GetBagItem`. Each call is nil-checked and `pcall`ed. No `GetItemInfo` or `GetSpellInfo`. |
| 5 | No `COMBAT_LOG_EVENT_UNFILTERED` or combat-log parsing | Yes. |
| 6 | Secret values guarded before math or printing | No health, power, or names are read. Tooltip data type, bag ids, slot ids, and sellability results are checked with `issecretvalue` before they are compared. Item names are not printed. |
| 7 | No Classic-vs-retail branch on `WOW_PROJECT_ID` alone | Yes. APIs are probed (`TooltipDataProcessor`, `TooltipComparisonManager`, `GetMouseFoci`, `C_Timer`, `Settings`). |
| 8 | No secure snippets or secure attributes on Blizzard unit frames | Yes. |
| 9 | SavedVariables created in `ADDON_LOADED`, not at file scope | `AHDressingRoomHelperDB` is created in `ADDON_LOADED`. **Hide tooltips** is not stored in it. `closeDressingRoom` and `dimUnsellable` default to false there. An unsupported bag add-on does not overwrite `dimUnsellable`. |
| 10 | Protected frame changes wait for `PLAYER_REGEN_ENABLED` | The checkbox is parented only when the auction frame is not protected-in-combat. Closing `DressUpFrame` waits out `InCombatLockdown`. `GameTooltip` is not a protected frame. |

## What still needs an in-game check

- Dimming itself. Default bags and Bagnon were checked against the public UI and BagBrother sources. The game client is not available here, so Sell-tab dimming, the grayed-out checkbox, and the other bag adapters still need the manual test above.
- The `_Camelot` TOC suffix. The interface number `16001` is confirmed on the current beta and can still change at launch.
- That `TooltipComparisonManager` on your build still shows comparisons on `ShoppingTooltip1` and `ShoppingTooltip2`. That is what the current public Mainline UI source does. If a Forever build draws the **Equipped** tip on some other frame, the `Show` hooks on those two frames would miss it.
- The centered gap on your UI scale. The control measures the search box and Filter after they have screen positions. A very narrow gap falls through to the footer beside the money display.
- That unchecking restores a tooltip without moving the mouse. `GetMouseFoci` is used to re-fire the row under the cursor. The cursor is usually on the checkbox itself, so expect to move back onto the row.

## Layout of the download

```
AHDressingRoomHelper/
    AHDressingRoomHelper.toc
    AHDressingRoomHelper_Camelot.toc
    AHDressingRoomHelper.lua
```

`AHDressingRoomHelper.zip` is that folder, ready to unzip into `Interface\AddOns`.
