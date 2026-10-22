# AH Tooltip Hider

A World of Warcraft: Forever add-on. While the auction house is open and **Hide tooltips** is checked, it hides the item tooltip under your cursor and the equipped-gear comparison tooltip (the one titled **Equipped**). That keeps the character preview clear when you Ctrl-click gear in the Browse Auctions window.

The box is not saved. It starts unchecked, and it is cleared every time the auction house opens or closes. Outside that window, tooltips behave as they always have.

This targets Forever's retail-style UI (`AuctionHouseFrame` from `Blizzard_AuctionHouseUI`), not the older Classic `AuctionFrame`.

## Install

1. Copy the `AHTooltipHider` folder into your client's `Interface\AddOns` directory. The folder name must stay `AHTooltipHider`.
2. Fully restart the client. A new add-on folder is picked up at startup. `/reload` is not enough the first time.
3. On the character screen, open **AddOns** and enable **AH Tooltip Hider**.

Beta clients used this path:

`World of Warcraft\_classic_beta_\Interface\AddOns\AHTooltipHider`

The Warcraft Wiki lists `_forever_` as the Forever PTR folder. After the November 4, 2026 launch the folder name may be different. Put the add-on in the `Interface\AddOns` directory of the client you actually start.

## Interface version

Both TOC files declare:

```
## Interface: 16001
```

That is the Forever beta value from the [Warcraft Wiki TOC table](https://warcraft.wiki.gg/wiki/TOC_format), as cited by the [Forever addon guide](https://wowforeverguides.com/addons/developers) (updated October 13, 2026). It is a reported beta number, not something this project could check against a running client. Classic Era is 11509. Midnight retail is 120100 on that same guide (the wiki's Standard row may read 120105). This add-on does not claim those.

Confirm the number in game:

```
/dump select(4, GetBuildInfo())
```

To see the build and the interface number together:

```
/run print(select(2, GetBuildInfo()), select(4, GetBuildInfo()))
```

If the dumped number is not `16001`, change the `## Interface:` line in both `AHTooltipHider.toc` and `AHTooltipHider_Camelot.toc` to that number, then restart. If the add-on is only flagged out of date, checking **Load out of date AddOns** will load it, but matching the dumped number is the real fix.

`AHTooltipHider_Camelot.toc` is the game-type file the wiki lists for Forever (internal name Camelot). The client loads it instead of the unsuffixed TOC when it recognizes that suffix. The suffix may be renamed at launch. The unsuffixed file is the fallback and declares the same interface number.

## Use

1. Talk to an auctioneer and open **Browse Auctions**.
2. **Hide tooltips** sits in the window, and which row it uses follows the pane:

   - **Item results and commodity results** (the view with **Back** and a count such as "53 Available"). The box is on that row, under **Filter**, immediately left of the count and the refresh button, lined up with **Back**. Its right edge is anchored to the count frame. Back, the count, the refresh button, and the results stay clear.
   - **Category browse** (the list before you pick an item). That row is the column headers, which start just under the search bar. The closest clear spot is the search row, immediately left of **Filter**. A single line usually meets the search box, so the words sit above the checkbox in that gap. If the gap is wide enough, they stay on one line beside the box. If a long **Filter** label leaves no room either way, the box moves to the bottom edge, just right of your money. The results list stays clear.
   - **Sell** and **Auctions** hide the search bar, so the box uses that same bottom spot, just right of your money.
3. Leave it unchecked for normal item tooltips and the **Equipped** comparison.
4. Check it when you want the preview unobstructed. Hovering an auction item no longer shows that item's tooltip or the equipped-gear comparison. Ctrl-click still previews the item (the default dress-up shortcut).
5. Uncheck it and the filter stops at once. Move onto an item row if a tooltip does not reappear on its own. The cursor is on the checkbox when you click it, so the row's hover may not fire again until you move.
6. Close the auction house. The box is cleared, and tooltips in the world, bags, and character sheet are normal. Open the auction house again and the box is unchecked.

Seller names, time-left text, the Search button, and the checkbox's own help tip are not item tooltips, so they still show while the box is checked. Bag slots are not part of the auction frame, so bag tooltips and their comparisons stay up too. The auction house opens your bags on its own. That is unchanged.

## How it works

`Blizzard_AuctionHouseUI` loads the first time you open the auction house. The add-on listens for `ADDON_LOADED`, `AUCTION_HOUSE_SHOW`, and `AUCTION_HOUSE_CLOSED`, and it hooks the frame's `OnShow` and `OnHide`.

Hiding is decided at the moment a tooltip is shown, from both of these:

- `AuctionHouseFrame:IsShown()`
- the checkbox is checked

Closing the window makes `IsShown()` false, and `OnHide` / `AUCTION_HOUSE_CLOSED` also uncheck the box. There is no saved variable, so nothing can reload a "hidden" state later.

The hooks are filters, not replacements. `hooksecurefunc` runs after Blizzard's function. When the gates are off, the hook returns without doing anything.

- The hovered item tooltip is `GameTooltip`. The auction house fills it with `SetItemKey` or `SetHyperlink`, then calls `Show`. An item post-call on `TooltipDataProcessor` marks that cycle as an item tooltip. The `Show` hook hides it only when the owner is the auction house or the dressing room.
- The **Equipped** comparison is `ShoppingTooltip1` and `ShoppingTooltip2`. Current retail code (the same system Forever's 12.1.5-family UI uses) builds those in `TooltipComparisonManager:AnchorShoppingTooltips`, usually via `GameTooltip_ShowCompareItem` and `C_TooltipComparison.CompareItem`. Their `Show` / `SetShown` hooks hide them when the main tooltip is an auction or dressing-room item.

An invisible tooltip would still block clicks on the preview, so the frames are actually hidden, not faded out.

## Manual test

Run this in game. This project cannot launch the client.

1. Install, restart, and enable the add-on. Confirm `/dump select(4, GetBuildInfo())`.
2. Open the auction house. The box is present and unchecked. On category browse it sits on the search row, left of **Filter** (or, if that gap is too narrow, beside your money at the bottom). Open an item such as a dagger. The box moves to the row with **Back**, left of the available-count and the refresh button. Back, the count, the refresh button, and the results stay clear.
3. Hover a weapon or armor (a belt or a dagger is enough). You should see the item tooltip and, when comparison is on, the **Equipped** tooltip.
4. Check **Hide tooltips**. Hover another piece of gear. Neither tooltip should appear. Ctrl-click the row and confirm the preview model is not covered.
5. Hover a non-item control (the Search button, a category, a seller name). Its normal text tooltip should still appear.
6. Uncheck the box. Hover an item. Both tooltips should be back.
7. Check the box, close the auction house, and hover gear in your bags and on the character sheet. Tooltips and comparisons must be normal.
8. Reopen the auction house. The box must be unchecked.
9. Check it, uncheck it, close, and reopen. It must still be unchecked.

## Forever guide checklist

From the [addon development guide](https://wowforeverguides.com/addons/developers). Items that do not apply to this add-on are marked.

| # | Check | This add-on |
| --- | --- | --- |
| 1 | `## Interface: 16001`, alone or on a multi-client line | Yes, in both TOC files. Confirm with `/dump select(4, GetBuildInfo())`. |
| 2 | Lua 5.1: no `goto`, `//`, `_ENV`, `require`, `io`, or `os` | Yes. |
| 3 | Files start with `local addonName, ns = ...`; helpers are local | Yes. The checkbox is an unnamed frame, not a global. |
| 4 | Item and spell lookups go through `C_Item` / `C_Spell`, with nil checks | Not used. No `GetItemInfo` or `GetSpellInfo`. |
| 5 | No `COMBAT_LOG_EVENT_UNFILTERED` or combat-log parsing | Yes. |
| 6 | Secret values guarded before math or printing | No health, power, or names are read. Tooltip data type is checked with `issecretvalue` before it is compared. |
| 7 | No Classic-vs-retail branch on `WOW_PROJECT_ID` alone | Yes. APIs are probed (`TooltipDataProcessor`, `TooltipComparisonManager`, `GetMouseFoci`, `C_Timer`). |
| 8 | No secure snippets or secure attributes on Blizzard unit frames | Yes. |
| 9 | SavedVariables created in `ADDON_LOADED`, not at file scope | No SavedVariables on purpose. The box must reset every visit. |
| 10 | Protected frame changes wait for `PLAYER_REGEN_ENABLED` | The checkbox is parented only when the auction frame is not protected-in-combat. `GameTooltip` is not a protected frame. |

## What still needs an in-game check

- The interface number `16001` and the `_Camelot` TOC suffix. Both come from the wiki and the Forever guide, and either can change at launch.
- That `TooltipComparisonManager` on your build still shows comparisons on `ShoppingTooltip1` and `ShoppingTooltip2`. That is what the current public Mainline UI source does. If a Forever build draws the **Equipped** tip on some other frame, the `Show` hooks on those two frames would miss it.
- That the results row beside the count is still empty on your build. The control's right edge is 8px left of the count/refresh frame (`PlaceCheckbox`). A very long translation grows left; if it would cross **Back**, the code uses the search-row spot instead.
- That category browse still has no empty band under the search bar. The checkbox uses the gap left of **Filter** for that reason. If your locale's **Filter** button leaves no room beside the search box, it belongs at the bottom, just right of the money display.
- That unchecking restores a tooltip without moving the mouse. `GetMouseFoci` is used to re-fire the row under the cursor. The cursor is usually on the checkbox itself, so expect to move back onto the row.

## Layout of the download

```
AHTooltipHider/
    AHTooltipHider.toc
    AHTooltipHider_Camelot.toc
    AHTooltipHider.lua
```

`AHTooltipHider.zip` is that folder, ready to unzip into `Interface\AddOns`.
