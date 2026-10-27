# Probe session

The v0.1.0 milestone exists to answer five questions from live game data before the progress display is designed. `/tally probe` records the data; this page describes the recording session that answers all five in one sitting, and how each answer is read out of the log.

## Status

The project was abandoned on 2026-10-27 and the repository archived (see README.md). Four of the five questions were answered and closed. #5 was left open and unresolved: the deposit-only run under "Next run" below was never done. The full answers and per-run numbers are in each issue's comments.

| Issue | Question | Status |
| --- | --- | --- |
| #3 | What is the weekly quest's ID, title and objective format? | Closed. Quest 89507 "Abundant Offerings", weekly, one objective of type 14, out of 20,000. |
| #4 | Does the weekly objective update during a run, or only after it ends? | Closed. Only after: `numFulfilled` changes once, when the run timer (widget 6731) reaches 0. |
| #5 | Does a run's final score carry 1:1 into the weekly total? | Open. No, it does not carry 1:1; the formula is still unknown. |
| #6 | Is the Abundance aura and tooltip data readable during combat? | Closed. No: aura reads fail in combat (`Auras cannot be accessed when secret`). UI widgets stay readable. |
| #7 | Which UI widget, if any, carries the live run score? | Closed. None carries the weekly score. Widget 6849 "Abundance Bag" carries the orbs held. |

## Findings so far

Widgets seen in Abundance caves:

| Widget | Meaning |
| --- | --- |
| 6849 "Abundance Bag" | Orbs held by the player; its max is 1,500 / 3,000 / 5,000 by reward tier. A drop in its value is a deposit. |
| 7366 "Abundance Held" | Hidden twin of 6849. |
| 7316 / 7317 "Public Altar Contribution" | Shared altar meter, 0 to 10,000, reset when full. 7316 in Enchanting Crypt, 7317 in Herbalism Grotto. |
| 7372 | Rises by 17,000 per run regardless of activity; likely a regional meter. |
| 6731 | The 180-second run timer. |
| 6979 / 6980 "Runestone Charge" | Not yet interpreted. |

The tier aura (spells 1229266 / 1229501 / 1229681) tooltip reads `Current: X/Y` with thresholds 1,000 then 5,000; the tier 3 tooltip has no `Current` line. Quest 93890 "Midnight: Abundance" (0/2 events) also appears in the log.

Runs recorded for #5:

| Run | Cave | Activity | Altar rise | Weekly gain | Unalloyed reward |
| --- | --- | --- | --- | --- | --- |
| 2 | Enchanting Crypt | about 820 orbs picked up, about 980 deposited | about 3,950 | 10,375 | 900 |
| 3 | Herbalism Grotto | none of its own | about 2,310 | 2,500 | 300 |
| 4 | Herbalism Grotto | none at all | 0 | 2,500 | 300 |
| 5 | Herbalism Grotto | kills only: 13 fights, 728 orbs held, 0 deposited | 100 | 4,028 (5,000 to 9,028) | 300 |

Run 1 was lost to a weekly that was already complete; run 2's figures are partly reconstructed after the altar widget filled the log.

What these show:

- A completed run gives at least 2,500 toward the weekly, even with no activity.
- Other players' altar contributions add nothing to the weekly.
- The gain is not fixed per reward tier: runs 3 to 5 all gave 300 Unalloyed but different weekly gains.
- Orbs held count without being deposited (run 5). Depositing seems to count for more: a fit over runs 2 and 5 suggests about 2.1 per orb held plus about 6 per orb deposited. Two runs are not enough to confirm it.
- The probe does not count kills, so kill counts come from combat entries (`combat` kind, entering and leaving combat) and are approximate.

## Next run

Not done; kept as a record of the planned experiment in case the work is picked up again. A deposit-only run separates the deposit term from the held-orb term:

1. Use a character whose weekly is far enough from 20,000 that one run cannot complete it (the snapshot's quest entry for 89507 shows `numFulfilled`).
2. `/tally probe clear`, then `/tally probe start`. Clear before every run; a run recorded on top of an old log is hard to separate out.
3. Start a run, gather and deposit orbs while avoiding fights as far as the cave allows, and stay until the timer ends and the reward arrives.
4. `/tally probe snap`, `/tally probe stop`, then `/reload`.

Read out of the log: the weekly gain (89507 `numFulfilled` before and after), orbs picked up (rises in widget 6849), orbs deposited (drops in 6849), fights (`combat` entries), the altar `rise` over the run, and the Unalloyed reward. Compare against the 2,500 floor and the fit above, post the result on #5, and close it if the formula holds.

## Open questions (original plan)

| Issue | Question | Answered by |
| --- | --- | --- |
| #3 | What is the weekly quest's ID, title and objective format? | The quest entries in the first snapshot |
| #4 | Does the weekly objective update during a run, or only after it ends? | Quest-objective entries timestamped against the run's aura and chat entries |
| #5 | Does a run's final score carry 1:1 into the weekly total? | The last tier-aura `current` value of a run versus the change in the quest's `numFulfilled` (or progress-bar percent) across that run |
| #6 | Is the Abundance aura and tooltip data readable during combat? | Aura entries recorded with `inCombat = true`: real numbers, or `"<secret>"` |
| #7 | Which UI widget, if any, carries the live run score? | Widget entries recorded during the run whose values move with the aura's `current` |

## Setup

These steps work on any PC, including one that has never had the repo.

1. Clone the repo next to the other addon repos, so AddOnTools can find it:
   ```bash
   git clone https://github.com/Tharavol/AbundanceTally.git
   ```
2. Install the addon into `<WoW folder>\_retail_\Interface\AddOns\AbundanceTally`, by one of:
   - AddOnTools, from its own folder: `.\Update-AddOns.ps1 -Repo AbundanceTally`. It builds with the same packager the release workflow uses.
   - The `abundancetally-package` zip from the latest successful CI run on main (repo's Actions tab), extracted into `AddOns`.
   - Copying `AbundanceTally.toc` and the three `AbundanceTally_*.lua` files into `AddOns\AbundanceTally` by hand. The folder must be named `AbundanceTally`. An unpackaged copy reports its version as `dev`.
3. If World of Warcraft was already running when the addon folder was added, restart the client fully. `/reload` does not pick up a newly added addon.
4. Check that it loaded: AbundanceTally appears in the character-select AddOns list, and `/tally version` prints a version in chat.

## Session

1. Use a level 90 character that has finished the Abundance tutorial and has the weekly Abundance quest in its quest log (pick it up from Chel the Chip in Amani'Zar Village if it is not there).
2. `/tally probe clear`, then `/tally probe start`. Starting takes a full snapshot, which already answers #3 if the quest is in the log.
3. Travel to the active Abundance cave and do one full run without stopping the probe: start it with Dundun, kill Abundance mobs, gather at least one node, deposit orbs at the shrine more than once, and stay until the run ends and the reward arrives. Fighting is what makes the combat entries for #6.
4. After the reward arrives, `/tally probe snap`. Its chat summary is a quick check that the quest total moved. If the summary names the wrong quest as the weekly, `/tally probe quest <id>` pins the right one (the quest ID is in the snapshot's `questLog` list).
5. Optional: a second run, so #5 can be checked against two data points instead of one.
6. `/tally probe stop`, then `/reload`. The reload writes the log to disk.

## After the session

The log is in `<WoW folder>\_retail_\WTF\Account\<ACCOUNT>\SavedVariables\AbundanceTally.lua`, written on `/reload` or logout. The file is plain Lua.

- To analyze it, open a Claude Code session in the repo on the PC that ran the session and ask it to read that file and answer #3 through #7. The answers go on each issue as a comment, and the issues close once answered.
- Review the file before attaching it to a public issue. The `<ACCOUNT>` folder name in its path is the Battle.net account folder, and system chat lines can carry character names.
- Once all five are answered, the answers feed v0.3.0's readers (#12, #13, #14), and v0.1.0 can be tagged and its milestone closed.

## Notes

- Only entries whose value changed since the last entry of the same kind are recorded, so a long session stays readable. Snapshots record everything regardless.
- The "Public Altar Contribution" widget is a shared meter that every player in the cave moves. Each cave has its own widget ID for it (7316 in Enchanting Crypt, 7317 in Herbalism Grotto), so the probe matches it by its text. Its changes are recorded at most once every 5 seconds; in the first session it filled the log on its own. Each of its entries carries `rise`, the running total of everything the meter rose by (across fills and resets), so the difference in `rise` between two entries is how much the cave contributed in between.
- Values the client marks as secret are stored as the string `"<secret>"`, and an API call that fails is stored as `"<err: ...>"`, so a missing or restricted API shows up in the log instead of breaking the recording.
- The log has a fixed size cap; once full, the oldest entries are dropped. `/tally probe status` shows the current count.
