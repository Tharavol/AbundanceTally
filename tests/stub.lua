-- Minimal fake of the WoW API surface AbundanceTally's files touch.
--
-- Each file is loaded whole (there is no module boundary to require()
-- around), so every top-level statement runs, including frame creation and
-- event registration -- not just the pure logic under test. Two kinds of stub
-- cover that:
--
-- 1. A generic "any method, any field, always chainable" object for the frame
--    API (CreateFrame, UIParent, and everything created off them). The files
--    only ever call methods on these and never inspect their return values,
--    so one catch-all shape is enough for all of it.
-- 2. Configurable fakes for the C_* namespaces and globals the probe reads
--    (quest log, auras, tooltips, widgets, map/zone/instance, scenario, area
--    POIs, currencies, combat state, issecretvalue). Tests populate these
--    through the returned fixtures table.

local function StubObject()
    local obj = {}
    setmetatable(obj, {
        __index = function()
            return function()
                return StubObject()
            end
        end,
    })
    return obj
end

-- Stands in for a 12.x secret value: the fake issecretvalue recognises it,
-- and every other way of touching it (indexing, concatenation, comparison,
-- arithmetic, length, calling) raises an error, the way the real client does
-- -- so a test passes only if the probe asked issecretvalue first.
local function SecretError()
    error("attempt to use a secret value", 2)
end
local SECRET = setmetatable({}, {
    __index = SecretError,
    __newindex = SecretError,
    __concat = SecretError,
    __lt = SecretError,
    __le = SecretError,
    __add = SecretError,
    __sub = SecretError,
    __len = SecretError,
    __call = SecretError,
    __tostring = SecretError,
})

local M = {}
M.SECRET = SECRET

local function FakeIsSecretValue(value)
    return rawequal(value, SECRET)
end

-- Installs the stub globals and returns a fixtures table tests use to set up
-- scenarios before (or between) driving the addon.
function M.install()
    local quests, auras, tooltips, widgetSets, widgetInfo, pois, currencies
    local context, scenario, inCombat, serverTime, clock

    local function Reset()
        quests = {} -- ordered quest log entries; see setQuests
        auras = { HELPFUL = {}, HARMFUL = {} } -- [filter] = list of aura tables
        tooltips = {} -- [auraInstanceID] = list of { leftText, rightText }
        widgetSets = { topCenter = 1 } -- named set IDs
        widgetInfo = {} -- [setID] = list of { widgetID, widgetType, info }
        pois = {} -- [mapID] = list of { poiID, name, secondsLeft }
        currencies = {} -- [currencyID] = info table
        context = { mapID = 2395, mapName = "Eversong Woods", zone = "Eversong Woods", subZone = "",
            instance = { "Quel'Thalas", "none", 0 } }
        scenario = nil -- nil = not in a scenario
        inCombat = false
        serverTime = 1000000
        clock = 500.0
        _G.AbundanceTallyDB = nil
        _G.issecretvalue = FakeIsSecretValue
    end
    Reset()

    _G.SlashCmdList = {}
    _G.CreateFrame = function()
        return StubObject()
    end
    _G.UIParent = StubObject()

    _G.C_AddOns = {
        GetAddOnMetadata = function(_, key)
            if key == "Version" then
                return "@project-version@"
            end
            return nil
        end,
    }

    _G.GetServerTime = function() return serverTime end
    _G.GetTime = function() return clock end
    _G.InCombatLockdown = function() return inCombat end
    _G.UnitAffectingCombat = function() return inCombat end
    _G.GetBuildInfo = function() return "12.0.5", "99999", "Oct 1 2026", 120005 end

    _G.Enum = {
        QuestFrequency = { Default = 0, Daily = 1, Weekly = 2, ResetByScheduler = 3 },
        UIWidgetVisualizationType = { IconAndText = 0, CaptureBar = 1, StatusBar = 2, TextWithState = 8 },
    }

    _G.C_QuestLog = {
        GetNumQuestLogEntries = function()
            return #quests, #quests
        end,
        GetInfo = function(index)
            local q = quests[index]
            if not q then
                return nil
            end
            return {
                questID = q.questID, title = q.title, frequency = q.frequency or 0,
                isHeader = q.isHeader == true, isTask = q.isTask == true, isOnMap = q.isOnMap == true,
            }
        end,
        GetQuestObjectives = function(questID)
            for _, q in ipairs(quests) do
                if q.questID == questID then
                    return q.objectives or {}
                end
            end
            return {}
        end,
        IsComplete = function() return false end,
        IsQuestFlaggedCompleted = function() return false end,
        GetTitleForQuestID = function(questID)
            for _, q in ipairs(quests) do
                if q.questID == questID then
                    return q.title
                end
            end
            return nil
        end,
    }
    _G.GetQuestProgressBarPercent = function(questID)
        for _, q in ipairs(quests) do
            if q.questID == questID then
                return q.progress or 0
            end
        end
        return 0
    end

    _G.C_UnitAuras = {
        GetAuraDataByIndex = function(_, index, filter)
            local list = auras[filter]
            -- A whole-list secret simulates the aura table itself coming
            -- back secret mid-combat.
            if rawequal(list, SECRET) then
                return SECRET
            end
            return list and list[index] or nil
        end,
        GetPlayerAuraBySpellID = function(spellID)
            for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
                local list = auras[filter]
                if not rawequal(list, SECRET) then
                    for _, aura in ipairs(list) do
                        if aura.spellId == spellID then
                            return aura
                        end
                    end
                end
            end
            return nil
        end,
    }

    -- GetUnitAuraByAuraInstanceID is deliberately absent, so the probe's
    -- fallback to the buff/debuff-specific getters is what gets exercised.
    local function TooltipFor(_, auraInstanceID)
        local lines = tooltips[auraInstanceID]
        if not lines then
            return nil
        end
        return { lines = lines }
    end
    _G.C_TooltipInfo = {
        GetUnitBuffByAuraInstanceID = TooltipFor,
        GetUnitDebuffByAuraInstanceID = TooltipFor,
    }

    local function FindWidget(widgetID)
        for _, list in pairs(widgetInfo) do
            for _, widget in ipairs(list) do
                if widget.widgetID == widgetID then
                    return widget
                end
            end
        end
        return nil
    end
    _G.C_UIWidgetManager = {
        GetTopCenterWidgetSetID = function() return widgetSets.topCenter end,
        GetObjectiveTrackerWidgetSetID = function() return widgetSets.objectiveTracker end,
        GetBelowMinimapWidgetSetID = function() return widgetSets.belowMinimap end,
        GetPowerBarWidgetSetID = function() return widgetSets.powerBar end,
        GetAllWidgetsBySetID = function(setID)
            local out = {}
            for _, widget in ipairs(widgetInfo[setID] or {}) do
                out[#out + 1] = { widgetID = widget.widgetID, widgetType = widget.widgetType, widgetSetID = setID }
            end
            return out
        end,
        GetStatusBarWidgetVisualizationInfo = function(widgetID)
            local widget = FindWidget(widgetID)
            return widget and widget.info or nil
        end,
        GetTextWithStateWidgetVisualizationInfo = function(widgetID)
            local widget = FindWidget(widgetID)
            return widget and widget.info or nil
        end,
    }

    _G.C_Map = {
        GetBestMapForUnit = function() return context.mapID end,
        GetMapInfo = function(mapID) return { mapID = mapID, name = context.mapName } end,
    }
    _G.GetZoneText = function() return context.zone end
    _G.GetSubZoneText = function() return context.subZone end
    _G.GetInstanceInfo = function()
        local inst = context.instance
        return inst[1], inst[2], inst[3], "", 5, 0, false, inst[8] or 0
    end

    _G.C_Scenario = {
        IsInScenario = function() return scenario ~= nil end,
    }
    _G.C_ScenarioInfo = {
        GetScenarioInfo = function() return scenario and scenario.info or nil end,
        GetScenarioStepInfo = function() return scenario and scenario.step or nil end,
        GetCriteriaInfo = function(index) return scenario and scenario.criteria and scenario.criteria[index] or nil end,
    }

    local function POIFor(mapID, poiID)
        for _, poi in ipairs(pois[mapID] or {}) do
            if poi.poiID == poiID then
                return poi
            end
        end
        return nil
    end
    _G.C_AreaPoiInfo = {
        GetEventsForMap = function(mapID)
            local ids = {}
            for _, poi in ipairs(pois[mapID] or {}) do
                ids[#ids + 1] = poi.poiID
            end
            return ids
        end,
        GetAreaPOIForMap = function() return {} end,
        GetAreaPOIInfo = function(mapID, poiID)
            local poi = POIFor(mapID, poiID)
            return poi and { areaPoiID = poiID, name = poi.name, description = "" } or nil
        end,
        GetAreaPOISecondsLeft = function(poiID)
            for _, list in pairs(pois) do
                for _, poi in ipairs(list) do
                    if poi.poiID == poiID then
                        return poi.secondsLeft
                    end
                end
            end
            return nil
        end,
    }

    _G.C_CurrencyInfo = {
        GetCurrencyInfo = function(currencyID)
            return currencies[currencyID]
        end,
    }

    local fixtures = {
        reset = Reset,
        -- list of { questID, title, frequency, isHeader, isTask, isOnMap,
        -- objectives = { {type, text, numFulfilled, numRequired, finished} }, progress }
        setQuests = function(list) quests = list end,
        -- filter is "HELPFUL"/"HARMFUL"; list is aura tables, or M.SECRET
        setAuras = function(filter, list) auras[filter] = list end,
        setTooltip = function(auraInstanceID, lines) tooltips[auraInstanceID] = lines end,
        setWidgetSet = function(name, setID) widgetSets[name] = setID end,
        -- list of { widgetID, widgetType, info }
        setWidgets = function(setID, list) widgetInfo[setID] = list end,
        setContext = function(fields)
            for key, value in pairs(fields) do
                context[key] = value
            end
        end,
        setScenario = function(value) scenario = value end,
        setPOIs = function(mapID, list) pois[mapID] = list end,
        setCurrency = function(currencyID, info) currencies[currencyID] = info end,
        setCombat = function(value) inCombat = value end,
        setServerTime = function(value) serverTime = value end,
        advanceClock = function(seconds) clock = clock + seconds end,
        -- Simulates a client build without issecretvalue at all.
        removeIsSecretValue = function() _G.issecretvalue = nil end,
    }
    return fixtures
end

return M
