# RollSheet

Lightweight RP character sheet and dice roller for World of Warcraft: Midnight.

Roll a d20, a d100, a custom die or your own named rolls straight from a compact bar, and keep track of health, armour, resources and rolls in a character sheet that other RollSheet users of your faction can see. Each character has its own sheet.

## Installation

Copy **both** folders into `World of Warcraft/_retail_/Interface/AddOns/`:

- `RollSheet`: the addon itself
- `RollSheet_IconNames`: icon names for the icon picker's search (only loads when you search)

Then restart WoW.

## Commands

- `/rs`: show or hide the bar
- `/rs sheet`: open or close your character sheet
- `/rs view [name]`: view another player's sheet (your target if no name is given)
- `/rs share`: send your sheet to your group
- `/rs d20+3 [label]`: roll any die with a modifier, e.g. `/rs d8+2 Dagger strike`
- `/rs rolls`: choose how roll results are shown in chat
- `/rs minimap`: show or hide the minimap button
- `/rs debug`, `/rs ping`: troubleshoot sheet syncing
- `/rs reset`: reset this character's sheet

Everyone who wants to see each other's sheets needs RollSheet 1.8 or later.

## Credits

- **Author:** SothosVoidstar
- **Icon names:** from the [wowdev community listfile](https://github.com/wowdev/wow-listfile), used for the icon picker's search.
- **Libraries:** LibStub, CallbackHandler-1.0, LibDataBroker-1.1 and LibDBIcon-1.0, by their respective authors in the WoW addon community.
