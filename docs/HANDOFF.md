# Handoff Notes

## Project summary

AbundanceTally is a World of Warcraft addon for Retail / Midnight that will show progress toward the weekly Abundance quest (20,000 points from Abundance event runs) while a run is in progress, since the default UI gives no indication of it. As of v0.1.0 it contains only a data probe, `/tally probe`, which records the game data the display will be built on. The open questions the probe answers are listed in docs/PROBE.md.

## Current state

- Addon files, in TOC load order: AbundanceTally.toc, AbundanceTally_Config.lua, AbundanceTally_Probe.lua, AbundanceTally_Commands.lua. See "File layout" below.
- Tests: tests/stub.lua (fake WoW API), tests/run.lua (the tests, run with `lua5.1 tests/run.lua` from the repo root). CI runs them.
- Release history is in CHANGELOG.md, following Keep a Changelog. Add an entry there as part of any change worth releasing. Do not touch `## Version` in the TOC: it is the literal `@project-version@`, substituted by the packager from the release tag.
- Planning lives on GitHub: one milestone per phase (v0.1.0 probe, v0.2.0 scaffold, v0.3.0 data collection, v0.4.0 display, v1.0.0 polish and release, v1.1.0 extras), each step an issue.
- License: GPL-3.0-or-later. LICENSE holds the full GPLv3 text. AbundanceTally_Config.lua (the first file the TOC loads) carries the standard GPL notice header; the other files are part of the same work and are not each re-headered.

## File layout

The layout follows MoxieTracker's Config / Collect / UI / Options / Commands split. v0.1.0 needs only three of those files; the rest arrive in v0.2.0 (#8).

- **AbundanceTally_Config.lua** -- loads first. `local ADDON_NAME, ns = ...` (every file repeats this line; WoW hands the same `ns` table to each file listed in the TOC, which is how state crosses files without adding globals). Owns `ns.Print`, `ns.GetVersion`, and the game-data constants: `ns.TIER_AURA_IDS`, `ns.CURRENCY_SHARD`, `ns.CURRENCY_UNALLOYED`, `ns.ABUNDANCE_MAP_IDS`. Nothing here touches a frame.
- **AbundanceTally_Probe.lua** -- the `/tally probe` recorder (#2), exposed as `ns.Probe` (`OnAddonLoaded`, `HandleCommand`). Owns `AbundanceTallyDB.probe` = `{ schema, enabled, entries, dropped, weeklyQuestID, weeklyQuestTitle, weeklyQuestScore, pinnedQuestID }`; each entry is `{ t, clock, kind, event, inCombat, affectingCombat, data }`, with kinds `snapshot`, `session`, `quest`, `questEvent`, `weeklyGuess`, `aura`, `combat`, `widget`, `context`, `scenario`, `currency`, `chat` and `probeError`. The pure pieces (sanitizing, fingerprint-based change detection, the capped log, tooltip `current / max` parsing, candidate-quest scoring) are on `ns.Probe._internal` so tests/run.lua can reach them. While recording inside an Abundance context, a 2-second `C_Timer` poll re-reads auras, quests and widgets, since the tooltip score may change without raising an event.
- **AbundanceTally_Commands.lua** -- loads last. Initializes `AbundanceTallyDB` on ADDON_LOADED and then calls `ns.Probe.OnAddonLoaded()`; registers `/tally` and `/abundancetally` and dispatches `/tally probe ...` to `ns.Probe.HandleCommand`.

Load order is enforced by the TOC list, not by Lua. Commands.lua calls into `ns.Probe` and so must stay after Probe.lua.

## What is known, and from where

None of the following has been confirmed in-game by this addon yet; confirming it is the point of v0.1.0.

- Runs last 3 minutes. Orbs come from Abundance mobs and gathering and are deposited at a shrine of Dundun. The active cave rotates every 8 hours across Eversong Woods, Zul'Aman, Harandar and Voidstorm. (Method, Icy Veins, warcraft.wiki.gg.)
- The weekly needs 20,000 points. Its name differs between sources: "Weekly: Abundance" (Icy Veins) and "Abundant Offerings" from Chel the Chip (warcraft.wiki.gg). No source gives its quest ID.
- The per-run score is a player debuff, spell 1229266 / 1229501 / 1229681 by tier, whose tooltip reads `Current: X / Y`; thresholds 1,000 / 3,000 / 5,000 for 300 / 600 / 900 Unalloyed Abundance. (Abundance Helper's source.) That addon stops updating in combat, which is why combat readability is its own question (#6).
- Shard of Dundun is currency 3376 (DundunTracker's source); Unalloyed Abundance is 3377 (warcraft.wiki.gg).
- The active cave is an Area POI named `Abundance: <X>`, found with `C_AreaPoiInfo.GetEventsForMap` on maps 2395 / 2437 / 2413 / 2405 and timed with `GetAreaPOISecondsLeft`. (DundunTracker's source, MIT.)
- An August 2026 forum thread reports characters under level 90 not being offered the weekly; a 2026-08-17 hotfix fixed under-90 characters being unable to complete activities. Gating is handled in #16.

## Development notes

- The probe log is written to `WTF/Account/<ACCOUNT>/SavedVariables/AbundanceTally.lua` (named after the addon folder) only on `/reload` or logout, so the file on disk is stale until one of those happens.
- In 12.x some API values are "secret" during combat: comparing, concatenating, doing arithmetic on, or indexing with one raises an error. The probe checks `issecretvalue` before touching any value it records and wraps every API read in `pcall`, so a restricted or renamed API shows up in the log as `"<secret>"` or `"<err: ...>"` instead of breaking the recording.
- `/tally` and `/abundancetally` are both registered (`SLASH_ABUNDANCETALLY1/2`); SlashCmdList registration is last-writer-wins, so the longer alias is a fallback in case another addon takes the short one.
- The TOC's `## Interface` line is kept current by the daily `toc-interface-check.yml` workflow (`p3lim/toc-interface-updater`), which commits a bump straight to main; don't hand-edit it. Changes to the TOC require a full client restart, not a UI reload.
- Local deployment uses the sibling AddOnTools repo's `Update-AddOns.ps1 -Repo AbundanceTally`, which builds with the same packager the release workflow runs.

## Next steps

- Run the probe session in docs/PROBE.md and record the answers on #3 through #7. v0.3.0's readers (#12, #13, #14) depend on them. PROBE.md covers setup from a fresh clone on any PC (install, client restart, load check), the session itself, and where the log lands. As of the initial commit, the probe build has passed CI and been deployed, but it has not yet run in-game.

## Local setup checklist

1. Install Git if needed.
2. Clone the repo from GitHub on the target machine.
3. Copy the addon folder into the WoW AddOns directory, or deploy with AddOnTools.
4. Reload the UI to test.
