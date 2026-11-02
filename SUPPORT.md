# pfQuest troubleshooting and reports

## Missing markers or incorrect quest offers

1. Open `/db config`. Check **Show low-level quests**, the map's **Level Range**, and its tracking mode. Use **All Quests** while checking a report.
2. For an accepted quest, select it in the quest log and press **Show**. For an offer that still appears after completion, run `/db query` to request completed quest history from the server. This refreshes history; it does not download new database records.
3. Run `/db reset` to refresh quest nodes after checking the settings.
4. Check for duplicate addon folders and update the base and Turtle extension together. For a possible conflict, reproduce with pfQuest and its matching extension enabled and other map/nameplate addons disabled.

Quest level and minimum acceptance level are different. For example, a level 55 quest with minimum level 48 is hidden from a level 60 character when **Show low-level quests** is off. An offer may also require earlier quests, a faction, or a profession.

## Report a problem

Use the issue tracker for the edition you installed. Include:

- pfQuest and Turtle extension versions, regular or HDB edition, and client version.
- Character level and faction; relevant filter settings.
- Quest/NPC/object/item name and database link or ID.
- Whether the missing marker is an offer before acceptance, an objective, or a turn-in.
- Zone/map name, in-game coordinates, and a screenshot showing the map and tooltip if possible.
- Other map/nameplate addons, what you expected, and what happened after the checks above.
- Full Lua error text if one appeared. For HDB, include `/pfqhdb` output and which DLL you use.

Player reports and confirmed in-game coordinates are welcome. Database corrections are reviewed as maintenance time allows. Screenshots alone may not show the quest ID, completion history, or active filters.
