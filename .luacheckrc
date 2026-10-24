-- luacheck configuration for a World of Warcraft addon.
-- The WoW client runs Lua 5.1 and injects its API as globals, so every API the
-- addon touches has to be declared here or it reads as an undefined global.

std = "lua51"
max_line_length = 120

-- The luarocks CI action installs into .luarocks/ inside the workspace, so
-- `luacheck .` would otherwise lint the toolchain along with the addon.
exclude_files = {".luarocks/**", ".luarocks", "lua_modules/**"}

-- Globals this addon defines. AbundanceTallyDB is the SavedVariables table,
-- and the slash command globals are how the client discovers commands.
globals = {
    "AbundanceTallyDB",
    "SLASH_ABUNDANCETALLY1",
    "SLASH_ABUNDANCETALLY2",
    "SlashCmdList",
}

-- WoW API surface used by this addon. Deliberately narrow: a typo in an API
-- name should fail the check rather than be silently allowed by a broad list.
-- Most of it is the probe's (AbundanceTally_Probe.lua), which guards every one
-- of these for existence at runtime, since its API surface is unverified on
-- the live 12.x client.
read_globals = {
    "AuraUtil",
    "C_AddOns",
    "C_AreaPoiInfo",
    "C_CurrencyInfo",
    "C_Map",
    "C_QuestLog",
    "C_Scenario",
    "C_ScenarioInfo",
    "C_Timer",
    "C_TooltipInfo",
    "C_UIWidgetManager",
    "C_UnitAuras",
    "CreateFrame",
    "Enum",
    "GetBuildInfo",
    "GetInstanceInfo",
    "GetQuestProgressBarPercent",
    "GetServerTime",
    "GetSubZoneText",
    "GetTime",
    "GetZoneText",
    "InCombatLockdown",
    "UnitAffectingCombat",
    "issecretvalue",
}

-- The offline test harness temporarily reassigns print() to capture slash
-- command output, and installs its own WoW stubs into _G on purpose.
files["tests/**"] = {
    ignore = {"121", "122"},
}
