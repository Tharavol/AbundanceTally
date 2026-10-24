# Probe session

The v0.1.0 milestone exists to answer five questions from live game data before the progress display is designed. `/tally probe` records the data; this page describes the recording session that answers all five in one sitting, and how each answer is read out of the log.

## Open questions

| Issue | Question | Answered by |
| --- | --- | --- |
| #3 | What is the weekly quest's ID, title and objective format? | The quest entries in the first snapshot |
| #4 | Does the weekly objective update during a run, or only after it ends? | Quest-objective entries timestamped against the run's aura and chat entries |
| #5 | Does a run's final score carry 1:1 into the weekly total? | The last tier-aura `current` value of a run versus the change in the quest's `numFulfilled` (or progress-bar percent) across that run |
| #6 | Is the Abundance aura and tooltip data readable during combat? | Aura entries recorded with `inCombat = true`: real numbers, or `"<secret>"` |
| #7 | Which UI widget, if any, carries the live run score? | Widget entries recorded during the run whose values move with the aura's `current` |

## Session

1. Use a level 90 character that has finished the Abundance tutorial and has the weekly Abundance quest in its quest log (pick it up from Chel the Chip in Amani'Zar Village if it is not there).
2. `/tally probe clear`, then `/tally probe start`. Starting takes a full snapshot, which already answers #3 if the quest is in the log.
3. Travel to the active Abundance cave and do one full run without stopping the probe: start it with Dundun, kill Abundance mobs, gather at least one node, deposit orbs at the shrine more than once, and stay until the run ends and the reward arrives. Fighting is what makes the combat entries for #6.
4. After the reward arrives, `/tally probe snap`. Its chat summary is a quick check that the quest total moved. If the summary names the wrong quest as the weekly, `/tally probe quest <id>` pins the right one (the quest ID is in the snapshot's `questLog` list).
5. Optional: a second run, so #5 can be checked against two data points instead of one.
6. `/tally probe stop`, then `/reload`. The reload writes the log to disk.

The log is in `WTF/Account/<ACCOUNT>/SavedVariables/AbundanceTally.lua` under the World of Warcraft `_retail_` folder. The file is plain Lua; it can be read directly or attached to the relevant issue.

## Notes

- Only entries whose value changed since the last entry of the same kind are recorded, so a long session stays readable. Snapshots record everything regardless.
- Values the client marks as secret are stored as the string `"<secret>"`, and an API call that fails is stored as `"<err: ...>"`, so a missing or restricted API shows up in the log instead of breaking the recording.
- The log has a fixed size cap; once full, the oldest entries are dropped. `/tally probe status` shows the current count.
