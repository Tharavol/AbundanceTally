# AbundanceTally

> **Abandoned.** This project is no longer developed and the repository is archived (read-only). The progress display was never built; only the v0.1.0 data probe exists.
>
> The probe found that the idea does not work well with the game's data:
>
> - The weekly quest (89507 "Abundant Offerings") updates only once, when a run ends, so there is no live weekly total to read during a run.
> - The run-score aura cannot be read in combat (its values are secret), and no UI widget carries the score.
> - A run's contribution to the weekly is not its final score. A completed run gives at least 2,500; the rest depends on the player's own orbs held and deposited, by a formula that was not pinned down.
>
> An in-run display could therefore only show an estimate, which did not seem worth the remaining effort. The findings and per-run numbers are in [docs/PROBE.md](docs/PROBE.md) and on issues #3 to #7.

AbundanceTally was planned as a World of Warcraft addon for Retail / Midnight that shows progress toward the weekly Abundance quest while an Abundance event run is in progress. The weekly quest needs 20,000 points from Abundance runs, and the default UI gives no indication during a run of how close that total is.

**Status: abandoned.** The only build (v0.1.0, untagged) contains only a data probe. The milestones under [Roadmap](#roadmap) were not pursued.

## Features

- `/tally probe` records the game data the progress display will be built on, into the addon's SavedVariables file:
  - the weekly quest's ID, title and objective (numeric count or progress bar), and every change to it
  - the Abundance run auras, including their tooltip text (the `Current: X / Y` score line)
  - UI widgets shown during a run
  - combat transitions, so it can be checked which data stays readable in combat
  - zone, scenario and active Abundance cave
  - Shard of Dundun and Unalloyed Abundance
  - Dundun's chat lines, which mark when a run starts and ends
- Recording survives a `/reload` or relog until it is stopped
- The log has a fixed size cap; once full, the oldest entries are dropped

## Slash commands

`/tally` and `/abundancetally` are both recognized.

- `/tally probe start` - start recording; takes a full snapshot immediately
- `/tally probe stop` - stop recording
- `/tally probe snap` - take one full snapshot now and print a short summary to chat
- `/tally probe status` - show whether recording is on, the entry count, and the weekly quest ID if one has been found
- `/tally probe clear` - delete the recorded entries
- `/tally probe quest <id>|off` - pin the weekly quest ID by hand when the probe's guess is wrong, or unpin it
- `/tally version` - show the addon version
- `/tally help` - list all commands

The probe log is written to `WTF/Account/<ACCOUNT>/SavedVariables/AbundanceTally.lua` when the UI reloads or the character logs out. [docs/PROBE.md](docs/PROBE.md) describes a recording session that answers the open questions.

## Installation

1. Copy the AbundanceTally folder into your World of Warcraft AddOns directory.
2. Launch World of Warcraft.
3. Reload the UI or restart the game.

## Roadmap

The plan as it stood when the project was abandoned. Each phase is a GitHub milestone, with its steps as issues; only v0.1.0 was worked on, and its issue #5 was left unresolved.

- **v0.1.0 - In-game probe:** repository setup and the `/tally probe` command. It confirms the weekly quest's ID and objective format, whether the objective updates during a run, whether a run's score carries over 1:1, whether the data can be read in combat, and which UI widget holds the live score.
- **v0.2.0 - Scaffold:** file split, SavedVariables schema, options panel shell, test coverage.
- **v0.3.0 - Data collection:** weekly-quest and live run-score readers, the projected weekly total, run history, handling for characters that cannot get the quest.
- **v0.4.0 - Display:** a movable in-run progress bar with a tier marker and a runs-remaining estimate, an optional compact summary line, and display options.
- **v1.0.0 - Polish and release:** a documentation and code polish pass, then the first stable release.
- **v1.1.0 - Extras:** weekly status for every character on the account, Shard of Dundun count, the active cave and its time remaining.

## Changelog

Release history is in [CHANGELOG.md](CHANGELOG.md).

## Development and CI

- GitHub Actions validates the addon on pushes and pull requests: `luac5.1 -p` for syntax, a headless test suite (`tests/run.lua`), luacheck for undefined globals, and a check that the TOC declares an interface version.
- A release artifact is packaged automatically on pushes to main.
- Tagging a release with a version like v1.0.0 creates a GitHub Release with the packaged addon zip; alpha and beta tags go through the pre-release workflow.
- A daily workflow updates the TOC's `## Interface` line when Blizzard ships a new client build.

## Credits

- Created by Tharavol
- Research, probe and scaffold by Claude Opus 5.5 (Anthropic), working through Claude Code
- The tier debuff spell IDs and their `Current: X / Y` tooltip line were found in [Abundance Helper](https://github.com/Hubbotu/Abundance-Helper)'s source. The Shard of Dundun currency ID and the Area POI method for finding the active cave were found in [DundunTracker](https://github.com/samurairacy/DundunTracker)'s source (MIT licensed). No code from either addon is included in AbundanceTally.
- Event facts (run length, the 20,000-point weekly, cave rotation) come from [Icy Veins](https://www.icy-veins.com/wow/midnight-world-events-guide), [Method](https://www.method.gg/guides/abundance-midnight-event-and-vendor-rewards-guide) and [warcraft.wiki.gg](https://warcraft.wiki.gg/wiki/Abundance)

## License

AbundanceTally is licensed under the GNU General Public License, version 3 or
(at your option) any later version. The full license text is in
[LICENSE](LICENSE), and the first file the TOC loads carries the standard GPL
notice.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.
