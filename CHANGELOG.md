# RollSheet Changelog

## v1.8.0

**⚠ Breaking change:** v1.8 uses a new communication channel and can't exchange sheets with older versions. Everyone you play with needs to update.

### New look
- **New artwork.** A gilded bar with a lion ornament, painted dice tiles and the RS monogram.
- **Crest-free parchment** for the sheet, suitable for both factions. Pick a different background in the gear menu if you prefer, including the faction quest scroll.
- **Bar size** option: Small, Normal, Large or Extra large.

### Rolling
- **Roll buttons on the bar.** d20, d100, a Custom die and two slots for your own rolls, all usable without opening the sheet.
- **Pin rolls to the bar.** Keep up to twelve rolls in the sheet and pin any two to the bar. Swap them per encounter with the pin buttons or by right-clicking a slot.
- **Any die, any modifier.** Each roll has its own die size and modifier. Right-click the Custom button and type something like `d12+2 Arcane Bolt`.
- **Honest modifier rolls.** A d20 + 3 now rolls 4–23 instead of 1–23, so results always match a real d20 + 3. Players without RollSheet still see a normal, verifiable roll.
- **Readable results.** RollSheet users see rolls as *Sothos · Primary Attack: 15 + 3 = 18 (d20)*, with natural 20s and natural 1s highlighted. Works in every client language. Use `/rs rolls` or the gear menu to choose how roll lines are shown.
- **Custom icons.** Right-click a pinned slot and choose *Change icon...* to browse icons visually: your own spells and action bars, or every icon in the game. Search by keyword: type words like *red*, *sword* or *shadow bolt* to find matching icons by name. You can also drag a spell, item, macro or mount onto the slot. Spells dragged from your action bars go straight back to their slot.
- **Macro-friendly rolling.** `/rs d8+2 Dagger strike` rolls any die with a modifier and a name.

### Sharing sheets
- Sheets are shared with players of your own faction, on your own or a connected realm, and with anyone in your group.
- **Much more reliable syncing.** Fixed sheets not loading for players on connected realms, large sheets arriving broken, and `/rs view` failing when names were typed in lowercase.
- Tooltips stay current, and players who looked at your sheet recently receive your updates automatically.
- Players without RollSheet are no longer spammed with requests.
- Messages are queued and retried during busy moments and Midnight's encounter chat lockdown instead of being lost.

### Handy additions
- Includes **RollSheet Icon Names**, a small companion module that powers the icon search. It only loads the first time you search.
- Click the RS monogram to close the bar, or drag it to move the bar.
- `/rs view` with no name views your target. Viewing yourself shows your sheet exactly as others see it.
- `/rs debug` and `/rs ping` help troubleshoot syncing.
- Updated for WoW 12.1.0.

## v1.3.2

- **Fixed broken networking.** v1.3 attempted to use the YELL channel for addon messages, which is not supported on retail WoW — all stat sync was silently failing. Communication now uses WHISPER for direct requests and PARTY / RAID / INSTANCE_CHAT for passive broadcasts.
- **Cross-faction note.** Cross-faction sync now works through cross-faction groups, which are the standard for organized RP events in modern WoW. Form a group with your cross-faction friends and sheets will exchange automatically.
- Fixed minimap button right-click. It now reliably toggles both the toolbar and the character sheet together.
- Fixed a Lua error that could occur in cross-realm contexts like Timewalking dungeons. Player names returned as protected strings are now skipped gracefully instead of erroring.
- Updated interface compatibility to WoW 12.0.5.

## v1.3.1

- Switched to a manual changelog for cleaner, controlled release notes.

## v1.3

- **Cross-faction support.** Alliance and Horde players can now see each other's RollSheet data. All addon communication has been moved to a silent yell channel that ignores faction restrictions.
- **Passive broadcasting.** Sheets are now broadcast automatically when you enter the world, change zones, or update your stats. Nearby players (within ~300 yards) receive them without needing to ask.
- **Far fewer requests.** With passive broadcasting in place, manual sheet requests are rarely needed. When two players first encounter each other, they automatically exchange sheets in the background.
- **Per-character saved data.** Each of your characters now has their own RollSheet. Switching characters no longer wipes or overwrites your stats.
- **Anguish resource.** Added as a preset for the Midnight expansion, styled in dark blood red.
- **Custom resource colour picker.** Custom resources now have a clickable colour swatch so you can give each one its own colour. Chosen colours sync to other players via the tooltip and remote sheet viewer.
- **Tooltip readability.** RollSheet section header is now bold white, with white labels and warm gold values for clean contrast against the dark tooltip background.
- **Minimap button.** Optional minimap button using LibDataBroker and LibDBIcon. Left-click toggles the toolbar, right-click toggles the character sheet, Shift+drag to reposition. Compatible with all major minimap button collector addons (Titan Panel, ChocolateBar, MBB, MinimapButtonFrame, SexyMap, ElvUI, etc.). Toggle visibility with `/rs minimap`.
- **No auto-open on login.** RollSheet no longer appears on screen automatically when you log in. Open it on demand with `/rs`.

**⚠ Breaking change:** v1.3 is not protocol-compatible with earlier versions. Anyone you want to exchange sheets with will need to update to v1.3 as well.
