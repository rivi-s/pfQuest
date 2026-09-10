# pfQuest setup guide

## What to install

### pfQuest — required

pfQuest is the base addon. It provides:

- Quest markers on the world map and minimap
- Current Zone Only and Hide Unexplored Areas
- Routes and the direction arrow
- Tracker integration
- Kill and item-drop nameplate icons

pfQuest works on a clean 1.12 client.

### pfQuest Turtle — required for Turtle WoW content

Install pfQuest Turtle alongside pfQuest if you play Turtle WoW. It adds:

- Turtle quests, NPCs, objects, items, and custom zones
- Support for Turtle maps such as Blackstone Island and Thalassian Highlands
- Auto-questing: accept, complete, turn in, and collect no-choice rewards
- Optional low-level quest skipping and runecloth-donation automation

Without pfQuest Turtle, pfQuest still works, but Turtle-specific quest content and auto-questing are unavailable.

## Optional: ClassicAPI

**ClassicAPI** comes from a compatible modded client. It is optional; both addons work without it.

| With ClassicAPI | Without ClassicAPI |
| --- | --- |
| **Hide Unexplored Areas** can read exploration data for maps you have not opened during the session. | Open a zone map once so pfQuest can record its exploration state. |
| City, cave, and continent map placement has extra map context. | pfQuest uses its built-in map and database fallbacks. |
| Quest markers and tracker refresh from direct accept, turn-in, and abandon notices. | They refresh through normal 1.12 quest-log events. |
| Item objective icons can be read directly by item ID. | pfQuest uses its normal icon and tooltip fallbacks. |

ClassicAPI makes map filtering and updates more direct. It does not enable a feature that a clean client cannot use.

Use `/db api` in game to see whether pfQuest detected ClassicAPI.

## Clean-client notes

The clean client supports markers, routes, Current Zone Only, minimap markers, and kill/drop nameplate icons. The only behavior to keep in mind is **Hide Unexplored Areas**: visit a zone map once before expecting its exploration state to be known.

Hold **Shift** while speaking to an NPC to bypass auto-questing for that interaction.
