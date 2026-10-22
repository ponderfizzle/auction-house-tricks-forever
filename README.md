# Auction House Dressing Room Helper

A World of Warcraft: Forever add-on. While the auction house is open and **Hide tooltips** is checked, it hides the item tooltip under your cursor and the equipped-gear comparison tooltip (the one titled **Equipped**). That keeps the Dressing Room clear when you Ctrl-click gear in Browse Auctions.

**Hide tooltips** is not saved. It starts unchecked, and it is cleared every time the auction house opens or closes.

One option is saved: **Close Dressing Room with Auction House**. It lives under Game Menu → Options → AddOns, and it defaults to off. When it is on, closing the auction house also closes the Dressing Room.

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
7. The saved option is separate. Open it with `/ahdrh` (or `/AHDRH`), or with Game Menu → **Options** → **AddOns** → **AH Dressing Room Helper**. **Close Dressing Room with Auction House** starts off.

Seller names, time-left text, the Search button, and the checkbox's own help tip are not item tooltips, so they still show while the box is checked. Bag slots are not part of the auction frame, so bag tooltips and their comparisons stay up too. The auction house opens your bags on its own. That is unchanged.

## Close Dressing Room with Auction House

Pressing Escape already closes the auction house and the Dressing Room. Clicking the auction house's red X, or walking away, closes only the auction house and leaves the Dressing Room up.

Turn the option on and every auction-house close also hides `DressUpFrame` through `HideUIPanel`. That covers the X button, walking away, and `AUCTION_HOUSE_CLOSED`. The option off does nothing to the Dressing Room. The option is stored in `AHDressingRoomHelperDB` and is created in `ADDON_LOADED`. It survives `/reload` and relog. **Hide tooltips** is not in that table.

If the close happens in combat, the hide waits until combat ends (`PLAYER_REGEN_ENABLED`). `DressUpFrame` is a protected panel, and `HideUIPanel` is not called while `InCombatLockdown()` is true. If you reopen the auction house before combat ends, the queued close is dropped.

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

The options entry uses `Settings.RegisterVerticalLayoutCategory`, `Settings.RegisterAddOnSetting`, and `Settings.CreateCheckbox`, then `Settings.RegisterAddOnCategory`. The list name is **AH Dressing Room Helper**. `/ahdrh` calls `Settings.OpenToCategory` on that category.

## Manual test

Run this in game. This project cannot launch the client.

1. Remove any old `AHTooltipHider` folder. Install `AHDressingRoomHelper`, restart, and enable **Auction House Dressing Room Helper**. Confirm `/dump select(4, GetBuildInfo())` is `16001`.
2. Open the auction house. **Hide tooltips** is present and unchecked, centered between the search box and **Filter**, with the label above the box on the compact browse layout. It does not cover the search box, Filter, or the results.
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

## Forever guide checklist

From the [addon development guide](https://wowforeverguides.com/addons/developers). Items that do not apply to this add-on are marked.

| # | Check | This add-on |
| --- | --- | --- |
| 1 | `## Interface: 16001`, alone or on a multi-client line | Yes, in both TOC files. Confirmed in the Forever beta with `/dump select(4, GetBuildInfo())`. |
| 2 | Lua 5.1: no `goto`, `//`, `_ENV`, `require`, `io`, or `os` | Yes. |
| 3 | Files start with `local addonName, ns = ...`; helpers are local | Yes. The auction-house checkbox is an unnamed frame. SavedVariables and the slash command are the globals WoW requires. |
| 4 | Item and spell lookups go through `C_Item` / `C_Spell`, with nil checks | Not used. No `GetItemInfo` or `GetSpellInfo`. |
| 5 | No `COMBAT_LOG_EVENT_UNFILTERED` or combat-log parsing | Yes. |
| 6 | Secret values guarded before math or printing | No health, power, or names are read. Tooltip data type is checked with `issecretvalue` before it is compared. |
| 7 | No Classic-vs-retail branch on `WOW_PROJECT_ID` alone | Yes. APIs are probed (`TooltipDataProcessor`, `TooltipComparisonManager`, `GetMouseFoci`, `C_Timer`, `Settings`). |
| 8 | No secure snippets or secure attributes on Blizzard unit frames | Yes. |
| 9 | SavedVariables created in `ADDON_LOADED`, not at file scope | `AHDressingRoomHelperDB` is created in `ADDON_LOADED`. **Hide tooltips** is not stored in it. |
| 10 | Protected frame changes wait for `PLAYER_REGEN_ENABLED` | The checkbox is parented only when the auction frame is not protected-in-combat. Closing `DressUpFrame` waits out `InCombatLockdown`. `GameTooltip` is not a protected frame. |

## What still needs an in-game check

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
