-- Published history and explicitly labeled development notes.
pfQuestChangelog:Register("pfQuest", {
{ ["version"] = "8.0.45", ["date"] = "2026-10-04", ["notes"] = {
"Fixed map and minimap tooltips staying visible after leaving a marker.",
"Added support for the optional repeatable quest display setting supplied by Turtle quest data.",
"Added profession skill-rank checks for quest availability.",
"Added this changelog and one update reminder per installed version."
} },
{ ["version"] = "8.0.44", ["date"] = "2026-10-02", ["notes"] = {
"Redrew minimap objectives and route arrows immediately after quest-log changes while the World Map is closed.",
"Made quest abandonment restore the abandoned quest without removing nearby completed quest markers."
} },
{ ["version"] = "8.0.43", ["date"] = "2026-10-01", ["notes"] = {
"Refreshed quest objectives, map markers, and navigation routes immediately when objective progress changes without requiring the World Map to open."
} },
{ ["version"] = "8.0.42", ["date"] = "2026-09-30", ["notes"] = {
"Recalculated automatic routes immediately after a turned-in quest removes its final map node.",
"Added required-all prerequisite support for convergence quests such as Zanzil's Mixture and a Fool's Stout."
} },
{ ["version"] = "8.0.41", ["date"] = "2026-09-29", ["notes"] = {
"Restored active quest map nodes when an accidentally hidden quest is removed from the Journal, and fixed the Journal remove button flickering before clicks register.",
"Prevented duplicate non-HDB tracker rows when live and database quest titles use visually identical punctuation with different encodings.",
"Refreshed non-HDB minimap and world-map ender icons immediately when an active quest becomes complete."
} },
{ ["version"] = "8.0.40", ["date"] = "2026-09-27", ["notes"] = {
"Fixed manually completed map quests returning after reload when a database provider supplied their quest IDs as text.",
"Made the Quest Log Clean button and database browser Clean Map button clear their selected route arrows.",
"Prevented cleared arrows from being immediately restored from cached objective candidates."
} },
{ ["version"] = "8.0.39", ["date"] = "2026-09-26", ["notes"] = {
"Reorganized the configuration window into five clearer tabs while preserving every existing option.",
"Made new characters open the configuration window at the largest usable size while retaining saved sizing for existing characters.",
"Fixed live updates for map-node transparency, the route-arrow toggle, and the minimap-button toggle and reload prompt.",
"Added generic extension hooks that let database addons register their own tracking categories without exposing addon-specific options to vanilla users."
} },
{ ["version"] = "8.0.38", ["date"] = "2026-09-26", ["notes"] = {
"Added rendering and routing support for pfQuest-turtle's new party quest map pins (recolorable marker, route-arrow support, including while the World Map is closed)."
} },
{ ["version"] = "8.0.37", ["date"] = "2026-09-24", ["notes"] = {
"Added an optional Turtle boundary-alias hook so Current Zone Only can suppress quest entities duplicated between custom zones and older base maps."
} }
}, "lua")
