# Changelog

All notable changes to AbundanceTally are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Repository setup (#1): GPL-3.0-or-later license, README, this changelog, developer handoff notes, BigWigsMods/packager metadata, CI (syntax check, headless tests, luacheck, package layout check), stable and pre-release workflows, and a daily TOC interface-version update.
- `/tally probe` (#2) records the weekly Abundance quest's objective, the Abundance run auras and their tooltip text, UI widgets, combat transitions, zone/scenario/cave context, Shard of Dundun and Unalloyed Abundance, and Dundun's chat lines into `AbundanceTallyDB.probe`, so the progress display can be built against confirmed game data. Subcommands: `start`, `stop`, `snap`, `status`, `clear`, and `quest <id>|off` to pin the weekly quest ID by hand.
- `/tally version` and `/tally help`; `/abundancetally` is registered as a fallback alias.

### Changed
- The probe records widget 7316 ("Public Altar Contribution", a shared meter that changes about ten times a second) at most once every 5 seconds, so it no longer pushes the start of a run out of the capped log. Snapshots still record it in full.
