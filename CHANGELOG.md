# RollSheet Changelog

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
