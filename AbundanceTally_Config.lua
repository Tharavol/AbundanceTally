--[[
AbundanceTally - shows progress toward the weekly Abundance quest while an
Abundance event run is in progress in World of Warcraft.

Copyright (C) 2026 Tharavol

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
--]]

-- ns is addon-private: it is the vararg table WoW hands every file listed in
-- the TOC, so it is how AbundanceTally's files share state without adding
-- globals. This file loads first and owns identity and the game-data
-- constants -- nothing here touches a frame.
local ADDON_NAME, ns = ...

-- Every command-output call site routes through this instead of hand-writing
-- its own copy of the colour code, so the addon has exactly one place that
-- owns the prefix.
local PREFIX = "|cff33ff99AbundanceTally|r: "
function ns.Print(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    print(PREFIX .. msg)
end

-- The TOC's @project-version@ placeholder is only substituted by the packager
-- at release time, so an unpackaged dev copy still carries the literal token.
function ns.GetVersion()
    local version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
    if not version or version == "" or version == "@project-version@" then
        return "dev"
    end
    return version
end

-- Game data the probe (#2) records against. None of it is confirmed in-game
-- by this addon yet; each value comes from another addon's source, cited
-- below, and the probe exists to confirm or correct it.

-- The per-run score debuff, one spell ID per reward tier. From the
-- Abundance Helper addon's source (github.com/Hubbotu/Abundance-Helper).
ns.TIER_AURA_IDS = { 1229266, 1229501, 1229681 }

-- Shard of Dundun starts an Abundant Harvest; Unalloyed Abundance is the
-- event's vendor currency. 3377 is confirmed by warcraft.wiki.gg's link to
-- Wowhead; 3376 comes from the DundunTracker addon's source.
ns.CURRENCY_SHARD = 3376
ns.CURRENCY_UNALLOYED = 3377

-- Zone maps the rotating Abundance cave can be on, in DundunTracker's order:
-- Eversong Woods, Zul'Aman, Harandar, Voidstorm.
ns.ABUNDANCE_MAP_IDS = { 2395, 2437, 2413, 2405 }
