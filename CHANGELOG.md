# pfQuest base patch notes

## 8.0.18 — 2026-09-09

- Restored automatic quest-tracker visibility after login and reload.
- Reduced idle quest-log polling from once per second to a one-minute fallback; normal quest events still refresh immediately.
- Reduced quest-arrow allocation by updating its visual state at the route update rate instead of every rendered frame.
- Made the Quest Log Translate label blue before a language is selected.

## 8.0.17 — 2026-09-09

- Fixed periodic FPS hitches caused by the collapsed quest-section tracker update.
- The tracker now refreshes collapsed sections only when the quest log changes.

## 8.0.16 — 2026-09-08

- Quest tracker now hides quests in collapsed quest-log sections and restores them when expanded.
- Collapsed sections do not remove active quest data or map markers.

## 8.0.15 — 2026-09-08

- Fixed Quest Log controls on clients with incompatible HookScript implementations.
- Quest browser links now contain the actual quest ID.
- Unresolved quest links are inserted as plain text instead of invalid Quest 0 links.

## 2026-09-07

- Made Russian quest text selectable on English Turtle clients through pfQuest's existing Quest Log translation menu.
- Retains only the Russian quest-text table; foreign item and NPC databases remain unloaded to limit memory use.

## 2026-09-07

- Fixed Russian client support: the release now loads the base Russian database before the Turtle Russian overlay.

## 2026-09-07

- Fixed Current Zone Only missing objective pins after quest acceptance; the active quest map data now receives one deferred refresh after Turtle's quest-log updates settle.
- Added merged-spawn support so creatures sharing an exact quest-item spawn can each resolve the matching tooltip without duplicating map pins.

## 2026-09-06

- Fixed High Elf and Goblin race-specific starter quest markers.
- Avoided a native quest-log selection path for uniquely named quests, improving compatibility with older hooked clients.

## 2026-09-04

- Fixed a continent/world-map refresh error caused by attempting to index a missing zone map.
- Fixed tracker entries overlapping after quest-log objective updates.
- Fixed the tracker title index becoming stale after sorting, which could cause automatic updates to affect the wrong entry.

This is the required base-addon companion for the matching `pfQuest-turtle` release.
