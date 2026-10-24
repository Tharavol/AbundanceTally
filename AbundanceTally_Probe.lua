-- In-game data probe for the Abundance event. Nothing about the weekly quest,
-- the run-score aura or the score widget has been confirmed against the live
-- client yet -- only other addons' source and wiki pages -- so before the real
-- tracker is built, this records what the client actually exposes: quest log
-- objectives, the tier aura and its tooltip, UI widgets, currencies, chat lines
-- and combat transitions, each timestamped, into AbundanceTallyDB.probe. The
-- client writes that to disk on /reload or logout.
--
-- Loaded after AbundanceTally_Config.lua (ns.Print, ns.GetVersion and the ID
-- constants) and before AbundanceTally_Commands.lua, which owns ADDON_LOADED
-- and forwards "/tally probe <args>" to ns.Probe.HandleCommand.
local ADDON_NAME, ns = ...

local Probe = {}
ns.Probe = Probe

-- The pure parts (sanitizing, change detection, the bounded log, tooltip
-- parsing, candidate scoring) live here rather than as file locals, so
-- tests/run.lua can exercise them without driving events through a frame.
local I = {}
Probe._internal = I

I.MAX_ENTRIES = 3000
I.SECRET = "<secret>"
I.MISSING = "<missing>"
I.MAX_DEPTH = 5
I.WIDGET_FIELD_CAP = 40
I.POLL_SECONDS = 2
I.WEEKLY_GOAL = 20000
-- A best guess must at least match the title or carry the 20,000 objective;
-- weekly frequency alone would happily nominate any unrelated weekly.
I.MIN_BEST_SCORE = 10

-- "Public Altar Contribution" is a shared meter every player in the cave
-- moves: it changes about ten times a second and alone filled the capped log
-- in the first probe session. Each cave has its own widget ID for it (7316 in
-- Enchanting Crypt, 7317 in Herbalism Grotto), so it is matched by text, with
-- the known IDs as a fallback for a read whose text is empty or secret. Its
-- changes are recorded at most once per I.ALTAR_THROTTLE_SECONDS; snapshots
-- still record it in full.
I.ALTAR_TEXT = "Public Altar Contribution"
I.ALTAR_WIDGET_IDS = { [7316] = true, [7317] = true }
I.ALTAR_THROTTLE_SECONDS = 5

I.TITLE_NEEDLES = { "abund", "offering" }
I.AURA_NEEDLES = { "abund", "dundun", "blessing" }
I.CHAT_NEEDLES = { "dundun", "abund" }
I.CONTEXT_NEEDLES = { "abund", "dundun" }

-- Session-only state: never saved, so a /reload re-records the first
-- observation of everything instead of silently trusting a stale baseline.
local state = {
    loaded = false,
    lastSeen = {}, -- ["kind:key"] = fingerprint of the last recorded value
    knownAuras = {}, -- [auraInstanceID] = "tier" | "other", for auras whose spellId later reads secret
    tierAuraPresent = false,
    caveNames = {}, -- "Enchanting Crypt" from "Abundance: Enchanting Crypt"
    contextTexts = {}, -- zone/subzone/instance/scenario names last read
    seenWidgetSets = {}, -- widget sets UPDATE_UI_WIDGET reported while in an Abundance context
    widgetRecordedAt = {}, -- [widgetID] = GetTime() of the last recorded change of an altar widget
    widgetRise = {}, -- [widgetID] = { last, total } running rise of a throttled bar, see I.AccumulateRise
}
I.state = state

--------------------------------------------------------------------------
-- Secret values and safe reads
--------------------------------------------------------------------------

-- 12.x hands some values to addons as "secret" during combat: comparing,
-- concatenating, indexing with or doing arithmetic on one raises an error.
-- issecretvalue is the only safe thing to do with an unknown value, so it is
-- always asked first, and an issecretvalue that itself errors counts as
-- secret -- a value that could not be cleared is never touched.
function I.IsSecret(value)
    if type(issecretvalue) ~= "function" then
        return false
    end
    local ok, secret = pcall(issecretvalue, value)
    if not ok then
        return true
    end
    return secret == true
end

function I.ErrorText(err)
    if I.IsSecret(err) then
        return "<err: " .. I.SECRET .. ">"
    end
    return "<err: " .. tostring(err) .. ">"
end

local SCALAR_TYPES = { string = true, number = true, boolean = true }

-- Returns a copy that is safe to compare, concatenate and save: secrets
-- become I.SECRET, functions/userdata become a "<type>" marker, and tables
-- are copied (string/number keys only) down to I.MAX_DEPTH.
function I.Sanitize(value, depth)
    if I.IsSecret(value) then
        return I.SECRET
    end
    local valueType = type(value)
    if valueType == "nil" or SCALAR_TYPES[valueType] then
        return value
    end
    if valueType ~= "table" then
        return "<" .. valueType .. ">"
    end
    depth = depth or 0
    if depth >= I.MAX_DEPTH then
        return "<depth>"
    end
    local copy = {}
    local ok, err = pcall(function()
        for key, inner in pairs(value) do
            -- A secret can never actually be a table key, but checking costs
            -- nothing and keeps the "ask first" rule absolute.
            if not I.IsSecret(key) then
                local keyType = type(key)
                if keyType == "string" or keyType == "number" then
                    copy[key] = I.Sanitize(inner, depth + 1)
                end
            end
        end
    end)
    if not ok then
        return I.ErrorText(err)
    end
    return copy
end

-- Resolves namespace[name] to a function, or nil when the namespace or the
-- function is absent on this client build.
local function Fn(namespace, name)
    if type(namespace) ~= "table" then
        return nil
    end
    local fn = namespace[name]
    if type(fn) == "function" then
        return fn
    end
    return nil
end
I.Fn = Fn

local function Pack(...)
    return { n = select("#", ...), ... }
end

-- Calls fn under pcall and returns every result sanitized, as a list with
-- an explicit `n` (results may contain nils). A missing function reads as
-- I.MISSING and a thrown error as "<err: ...>", both in slot 1.
function I.ReadAll(fn, ...)
    if type(fn) ~= "function" then
        return { n = 1, I.MISSING }
    end
    local packed = Pack(pcall(fn, ...))
    if not packed[1] then
        return { n = 1, I.ErrorText(packed[2]) }
    end
    local results = { n = packed.n - 1 }
    for index = 2, packed.n do
        results[index - 1] = I.Sanitize(packed[index])
    end
    return results
end

function I.Read(fn, ...)
    return I.ReadAll(fn, ...)[1]
end

--------------------------------------------------------------------------
-- Pure helpers
--------------------------------------------------------------------------

-- Case-insensitive plain substring match against any needle; false for
-- anything that is not a string, which covers every marker value too.
function I.Matches(text, needles)
    if type(text) ~= "string" then
        return false
    end
    local lower = text:lower()
    for _, needle in ipairs(needles) do
        if lower:find(needle, 1, true) then
            return true
        end
    end
    return false
end

local function CompareKeys(a, b)
    local typeA, typeB = type(a), type(b)
    if typeA ~= typeB then
        return typeA < typeB
    end
    return a < b
end

local function SortedKeys(tbl, ignore)
    local keys = {}
    for key in pairs(tbl) do
        if not (ignore and ignore[key]) then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys, CompareKeys)
    return keys
end

-- Deterministic string form of a sanitized value, for change detection.
-- `ignore` names keys (at any depth) whose churn should not count as a
-- change, e.g. a POI's secondsLeft ticking down.
function I.Fingerprint(value, ignore)
    if type(value) ~= "table" then
        return type(value):sub(1, 1) .. ":" .. tostring(value)
    end
    local parts = {}
    for _, key in ipairs(SortedKeys(value, ignore)) do
        parts[#parts + 1] = tostring(key) .. "=" .. I.Fingerprint(value[key], ignore)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- True, remembering the new fingerprint, when `key`'s value differs from the
-- last one recorded under it.
function I.ShouldRecord(lastSeen, key, fingerprint)
    if lastSeen[key] == fingerprint then
        return false
    end
    lastSeen[key] = fingerprint
    return true
end

-- True when a record at `now` would come less than `interval` seconds after
-- the one at `last`. A missing or non-numeric time never throttles, so a
-- clock that reads as a marker cannot silence a widget for good.
function I.WithinInterval(last, now, interval)
    if type(last) ~= "number" or type(now) ~= "number" or type(interval) ~= "number" then
        return false
    end
    return now - last < interval
end

-- True for a "Public Altar Contribution" widget, by its text or a known ID.
function I.IsAltarWidget(widget)
    if type(widget) ~= "table" then
        return false
    end
    local fields = widget.fields
    if type(fields) == "table" and fields.text == I.ALTAR_TEXT then
        return true
    end
    return I.ALTAR_WIDGET_IDS[widget.widgetID] == true
end

-- Adds the rise from the tracker's last bar value to `value` and returns the
-- running total. A drop is the bar filling and resetting, so it counts the
-- rest of the way to the top (or to the last value, when it overshot `max`)
-- plus `value`. A non-numeric value forgets the baseline instead, so a bar
-- that vanishes between runs does not credit what moved while it was gone.
function I.AccumulateRise(tracker, value, max)
    tracker.total = tracker.total or 0
    if type(value) ~= "number" then
        tracker.last = nil
        return tracker.total
    end
    local last = tracker.last
    if type(last) == "number" then
        if value >= last then
            tracker.total = tracker.total + value - last
        else
            local top = type(max) == "number" and math.max(max, last) or last
            tracker.total = tracker.total + top - last + value
        end
    end
    tracker.last = value
    return tracker.total
end

-- Appends to a plain list and drops the oldest entries beyond `cap`, in one
-- shift rather than a table.remove(list, 1) per excess entry. Returns how
-- many were dropped. A plain list (not a head-indexed ring) keeps the
-- SavedVariables file readable in chronological order.
function I.Append(list, entry, cap)
    list[#list + 1] = entry
    local count = #list
    local excess = count - cap
    if excess <= 0 then
        return 0
    end
    for index = 1, count - excess do
        list[index] = list[index + excess]
    end
    for index = count - excess + 1, count do
        list[index] = nil
    end
    return excess
end

-- Removes colour codes, textures, atlases and line breaks so a tooltip line
-- like "|cffffffff1,234|r / 3000" parses the same as the plain text.
function I.StripEscapes(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|cn[^:]*:", "")
    text = text:gsub("|r", "")
    text = text:gsub("|T.-|t", "")
    text = text:gsub("|A.-|a", "")
    text = text:gsub("|n", " ")
    return text
end

-- Parses the first "current / max" pair out of a tooltip line, accepting
-- "1,234" or "1.234" thousands separators. Returns two numbers, or nil.
function I.ParseCurrentMax(text)
    if type(text) ~= "string" then
        return nil
    end
    local plain = I.StripEscapes(text)
    -- One pass only joins every other group of "1,234,567"; repeat until stable.
    local replaced
    repeat
        plain, replaced = plain:gsub("(%d)[,.](%d%d%d)%f[%D]", "%1%2")
    until replaced == 0
    local current, max = plain:match("(%d+)%s*/%s*(%d+)")
    if not current then
        return nil
    end
    return tonumber(current), tonumber(max)
end

-- Tooltip data -> list of { leftText, rightText, current, max } per line,
-- raw text kept alongside the parse so a wrong pattern can be fixed later
-- from the saved log alone.
function I.TooltipLines(tooltipData)
    local lines = {}
    if type(tooltipData) ~= "table" or type(tooltipData.lines) ~= "table" then
        return lines
    end
    for index, line in ipairs(tooltipData.lines) do
        if type(line) == "table" then
            local current, max = I.ParseCurrentMax(line.leftText)
            if not current then
                current, max = I.ParseCurrentMax(line.rightText)
            end
            lines[index] = { leftText = line.leftText, rightText = line.rightText, current = current, max = max }
        end
    end
    return lines
end

-- First parsed current/max pair across a ReadAuraTooltip result's lines.
function I.FirstCurrentMax(tooltip)
    if type(tooltip) ~= "table" or type(tooltip.lines) ~= "table" then
        return nil
    end
    for _, line in pairs(tooltip.lines) do
        if line.current then
            return line.current, line.max
        end
    end
    return nil
end

-- Copies a sanitized table's scalar leaves into a flat {["a.b"] = v} map,
-- two levels deep and capped at `cap` fields, scalars of each level before
-- its sub-tables, so widget entries stay readable.
function I.FlattenScalars(tbl, cap)
    local flat, count = {}, 0
    local function Walk(node, prefix, depth)
        local keys = SortedKeys(node)
        for pass = 1, 2 do
            for _, key in ipairs(keys) do
                if count >= cap then
                    return
                end
                local value = node[key]
                local path = prefix and (prefix .. "." .. tostring(key)) or key
                local isTable = type(value) == "table"
                if pass == 1 and not isTable then
                    flat[path] = value
                    count = count + 1
                elseif pass == 2 and isTable and depth < 2 then
                    Walk(value, tostring(path), depth + 1)
                end
            end
        end
    end
    if type(tbl) == "table" then
        Walk(tbl, nil, 1)
    end
    return flat
end

function I.IsCandidate(quest, weeklyFrequencies)
    return I.Matches(quest.title, I.TITLE_NEEDLES) or weeklyFrequencies[quest.frequency] == true
end

-- Ranks how likely a quest is to be the 20,000-point weekly. `quest` carries
-- title, frequency, objectives (sanitized C_QuestLog.GetQuestObjectives
-- output) and progressBarPercent.
function I.ScoreCandidate(quest, weeklyFrequencies)
    local score = 0
    if I.Matches(quest.title, { "abund" }) then
        score = score + 10
    elseif I.Matches(quest.title, { "offering" }) then
        score = score + 6
    end
    if weeklyFrequencies[quest.frequency] then
        score = score + 3
    end
    if type(quest.objectives) == "table" then
        for _, objective in ipairs(quest.objectives) do
            if type(objective) == "table" then
                local required = objective.numRequired
                if required == I.WEEKLY_GOAL then
                    score = score + 20
                elseif type(required) == "number" and required >= 1000 then
                    score = score + 5
                end
                if objective.type == "progressbar" then
                    score = score + 4
                end
            end
        end
    end
    if type(quest.progressBarPercent) == "number" and quest.progressBarPercent > 0 then
        score = score + 4
    end
    return score
end

-- Highest-scoring candidate at or above I.MIN_BEST_SCORE; the earlier one
-- wins a tie. Expects each candidate's `score` already filled in.
function I.PickBestCandidate(candidates)
    local best
    for _, quest in ipairs(candidates) do
        if type(quest.score) == "number" and quest.score >= I.MIN_BEST_SCORE
            and (not best or quest.score > best.score) then
            best = quest
        end
    end
    return best
end

-- "Abundance: Enchanting Crypt" -> "Enchanting Crypt".
function I.CaveNameFromPOI(name)
    if type(name) ~= "string" then
        return nil
    end
    local cave = name:match("^[^:]*[Aa][Bb][Uu][Nn][Dd][^:]*:%s*(.-)%s*$")
    if cave == "" then
        return nil
    end
    return cave
end

-- Whether the player is plausibly inside a run: a tier aura is up, or a
-- zone/subzone/instance/scenario name either mentions Abundance/Dundun or
-- equals the active POI's cave name.
function I.IsAbundanceContext(tierAuraPresent, texts, caveNames)
    if tierAuraPresent then
        return true
    end
    for _, text in pairs(texts) do
        if I.Matches(text, I.CONTEXT_NEEDLES) then
            return true
        end
        if type(text) == "string" then
            for _, cave in pairs(caveNames) do
                if text:lower() == cave:lower() then
                    return true
                end
            end
        end
    end
    return false
end

-- One line per objective, e.g. `"0/20000 Abundance" 0/20000 (progressbar)`.
function I.DescribeObjectives(quest)
    local parts = {}
    if type(quest.objectives) == "table" then
        for _, objective in ipairs(quest.objectives) do
            if type(objective) == "table" then
                parts[#parts + 1] = string.format("\"%s\" %s/%s (%s)", tostring(objective.text),
                    tostring(objective.numFulfilled), tostring(objective.numRequired), tostring(objective.type))
            end
        end
    else
        parts[#parts + 1] = "objectives " .. tostring(quest.objectives)
    end
    if type(quest.progressBarPercent) == "number" and quest.progressBarPercent > 0 then
        parts[#parts + 1] = "bar " .. quest.progressBarPercent .. "%"
    end
    return table.concat(parts, "; ")
end

--------------------------------------------------------------------------
-- SavedVariables and the log
--------------------------------------------------------------------------

-- AbundanceTallyDB is only trustworthy once ADDON_LOADED has run (before it,
-- the client has not loaded the saved table yet). `create` builds the probe
-- sub-table on first use; reads that only gate on it pass false.
local function GetDB(create)
    if not state.loaded or type(AbundanceTallyDB) ~= "table" then
        return nil
    end
    local db = AbundanceTallyDB.probe
    if type(db) ~= "table" then
        if not create then
            return nil
        end
        db = { schema = 1, enabled = false, entries = {}, dropped = 0 }
        AbundanceTallyDB.probe = db
    end
    if type(db.entries) ~= "table" then
        db.entries = {}
    end
    return db
end
I.GetDB = GetDB

local function IsRecording()
    local db = GetDB(false)
    return db ~= nil and db.enabled == true
end

local function NewEntry(kind, event, data)
    return {
        t = I.Read(GetServerTime),
        clock = I.Read(GetTime),
        kind = kind,
        event = event,
        inCombat = I.Read(InCombatLockdown),
        affectingCombat = I.Read(UnitAffectingCombat, "player"),
        data = data,
    }
end

local function Record(kind, event, data)
    local db = GetDB(true)
    if not db then
        return
    end
    db.dropped = (tonumber(db.dropped) or 0) + I.Append(db.entries, NewEntry(kind, event, data), I.MAX_ENTRIES)
end

-- Records only when `data` differs from the last record under the same
-- kind and key, so a QUEST_LOG_UPDATE storm logs one line per real change.
local function RecordIfChanged(kind, key, event, data, ignore)
    if I.ShouldRecord(state.lastSeen, kind .. ":" .. tostring(key), I.Fingerprint(data, ignore)) then
        Record(kind, event, data)
        return true
    end
    return false
end

-- Seeds the change baseline without writing an entry -- a snapshot already
-- carries the value, so the next event only logs a real change.
local function Remember(kind, key, data, ignore)
    state.lastSeen[kind .. ":" .. tostring(key)] = I.Fingerprint(data, ignore)
end

--------------------------------------------------------------------------
-- Quest log
--------------------------------------------------------------------------

-- Enum.QuestFrequency values that count as "weekly". ResetByScheduler is
-- included because event weeklies are often flagged that way instead.
local function WeeklyFrequencies()
    local set = {}
    local frequency = type(Enum) == "table" and Enum.QuestFrequency
    if type(frequency) == "table" then
        if frequency.Weekly ~= nil then
            set[frequency.Weekly] = true
        end
        if frequency.ResetByScheduler ~= nil then
            set[frequency.ResetByScheduler] = true
        end
    end
    return set
end

local function AddQuestDetails(quest)
    local questID = quest.questID
    quest.objectives = I.Read(Fn(C_QuestLog, "GetQuestObjectives"), questID)
    quest.progressBarPercent = I.Read(GetQuestProgressBarPercent, questID)
    quest.isComplete = I.Read(Fn(C_QuestLog, "IsComplete"), questID)
    quest.flaggedCompleted = I.Read(Fn(C_QuestLog, "IsQuestFlaggedCompleted"), questID)
end

-- Returns every non-header quest log entry (basic fields only) and the
-- candidate subset with objectives and a score. The pinned and the
-- remembered weekly questID are always candidates, even out of the log.
local function ReadQuestLog()
    local quests, candidates, seen = {}, {}, {}
    local weekly = WeeklyFrequencies()
    local count = I.Read(Fn(C_QuestLog, "GetNumQuestLogEntries"))
    local getInfo = Fn(C_QuestLog, "GetInfo")
    if type(count) == "number" then
        for index = 1, count do
            local info = I.Read(getInfo, index)
            if type(info) == "table" and info.isHeader ~= true then
                local quest = {
                    questID = info.questID, title = info.title, frequency = info.frequency,
                    isTask = info.isTask, isOnMap = info.isOnMap,
                }
                quests[#quests + 1] = quest
                if type(quest.questID) == "number" and not seen[quest.questID] and I.IsCandidate(quest, weekly) then
                    seen[quest.questID] = true
                    quest.candidate = true
                    local detailed = {
                        questID = quest.questID, title = quest.title, frequency = quest.frequency,
                        isTask = quest.isTask, isOnMap = quest.isOnMap, inLog = true,
                    }
                    AddQuestDetails(detailed)
                    candidates[#candidates + 1] = detailed
                end
            end
        end
    else
        quests.error = count
    end

    local db = GetDB(false)
    for _, questID in ipairs({ db and db.pinnedQuestID or false, db and db.weeklyQuestID or false }) do
        if type(questID) == "number" and not seen[questID] then
            seen[questID] = true
            local quest = {
                questID = questID, inLog = false, remembered = true,
                title = I.Read(Fn(C_QuestLog, "GetTitleForQuestID"), questID),
            }
            AddQuestDetails(quest)
            candidates[#candidates + 1] = quest
        end
    end

    for _, quest in ipairs(candidates) do
        quest.score = I.ScoreCandidate(quest, weekly)
    end
    return quests, candidates
end

-- A pinned questID (/tally probe quest <id>) always wins over scoring.
local function UpdateWeeklyGuess(candidates, event)
    local db = GetDB(true)
    if not db then
        return
    end
    local best
    if type(db.pinnedQuestID) == "number" then
        for _, quest in ipairs(candidates) do
            if quest.questID == db.pinnedQuestID then
                best = quest
            end
        end
    else
        best = I.PickBestCandidate(candidates)
    end
    if best then
        db.weeklyQuestID = best.questID
        db.weeklyQuestTitle = best.title
        db.weeklyQuestScore = best.score
        RecordIfChanged("weeklyGuess", "best", event,
            { questID = best.questID, title = best.title, score = best.score, pinned = db.pinnedQuestID ~= nil })
    end
end

local function RecordQuestChanges(event)
    local _, candidates = ReadQuestLog()
    UpdateWeeklyGuess(candidates, event)
    for _, quest in ipairs(candidates) do
        RecordIfChanged("quest", quest.questID, event, quest)
    end
end

--------------------------------------------------------------------------
-- Auras
--------------------------------------------------------------------------

local function TierSet()
    local set = {}
    for _, spellID in ipairs(ns.TIER_AURA_IDS or {}) do
        set[spellID] = true
    end
    return set
end

-- Which rule matched an aura, or nil: its spellId is a tier ID, its name
-- mentions the event, or its auraInstanceID was matched earlier (so a tier
-- aura whose spellId/name turn secret in combat is still followed).
function I.MatchAura(aura, tierSet, knownAuras)
    if type(aura.spellId) == "number" and tierSet[aura.spellId] then
        return "spellId"
    end
    if I.Matches(aura.name, I.AURA_NEEDLES) then
        return "name"
    end
    if type(aura.auraInstanceID) == "number" and knownAuras[aura.auraInstanceID] then
        return "auraInstanceID"
    end
    return nil
end

-- Which C_TooltipInfo getter exists for aura instance IDs is unverified on
-- 12.x, so each is tried in turn and the one that answered is recorded.
local TOOLTIP_GETTERS = {
    HELPFUL = { "GetUnitAuraByAuraInstanceID", "GetUnitBuffByAuraInstanceID" },
    HARMFUL = { "GetUnitAuraByAuraInstanceID", "GetUnitDebuffByAuraInstanceID" },
}

local function ReadAuraTooltip(auraInstanceID, filter)
    local attempts = {}
    for _, name in ipairs(TOOLTIP_GETTERS[filter]) do
        local fn = Fn(C_TooltipInfo, name)
        if fn then
            local data = I.Read(fn, "player", auraInstanceID, filter)
            if type(data) == "table" then
                return { getter = name, lines = I.TooltipLines(data) }
            end
            attempts[name] = data == nil and "<nil>" or data
        else
            attempts[name] = I.MISSING
        end
    end
    return { getter = false, attempts = attempts }
end

local function DescribeAura(aura, filter, matchedBy, isTier)
    local described = {
        spellId = aura.spellId, name = aura.name, applications = aura.applications,
        auraInstanceID = aura.auraInstanceID, duration = aura.duration,
        expirationTime = aura.expirationTime, points = aura.points,
        filter = filter, matchedBy = matchedBy, isTier = isTier,
    }
    if type(aura.auraInstanceID) == "number" then
        described.tooltip = ReadAuraTooltip(aura.auraInstanceID, filter)
    end
    return described
end

-- One filter's auras as sanitized tables, preferring
-- C_UnitAuras.GetAuraDataByIndex and falling back to AuraUtil.ForEachAura.
-- Returns the list, the method that worked, and why the walk stopped early
-- (an error or a whole-table secret), if it did.
local function ListAuras(filter)
    local byIndex = Fn(C_UnitAuras, "GetAuraDataByIndex")
    local stopped
    if byIndex then
        local auras = {}
        for index = 1, 255 do
            local aura = I.Read(byIndex, "player", index, filter)
            if type(aura) ~= "table" then
                if aura ~= nil then
                    stopped = { index = index, value = aura }
                end
                break
            end
            auras[#auras + 1] = aura
        end
        if #auras > 0 or not stopped then
            return auras, "GetAuraDataByIndex", stopped
        end
    end
    local forEach = Fn(AuraUtil, "ForEachAura")
    if forEach then
        local auras = {}
        local ok, err = pcall(forEach, "player", filter, nil, function(aura)
            auras[#auras + 1] = I.Sanitize(aura)
        end, true)
        return auras, "ForEachAura", (not ok) and I.ErrorText(err) or stopped
    end
    return {}, byIndex and "GetAuraDataByIndex" or "none", stopped
end

-- Change detection ignores the raw aura counts: other buffs coming and going
-- in combat would otherwise log an entry on every UNIT_AURA.
I.AURA_IGNORE = { count = true, unidentified = true }

local function ReadAuras()
    local tierSet = TierSet()
    local result = { tierPresent = false }
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        local auras, method, stopped = ListAuras(filter)
        local tracked, unidentified = {}, 0
        for _, aura in ipairs(auras) do
            local matchedBy = I.MatchAura(aura, tierSet, state.knownAuras)
            if matchedBy then
                local instanceID = aura.auraInstanceID
                local isTier = (matchedBy == "spellId")
                    or (matchedBy == "auraInstanceID" and state.knownAuras[instanceID] == "tier")
                if type(instanceID) == "number" and matchedBy ~= "auraInstanceID" then
                    state.knownAuras[instanceID] = isTier and "tier" or "other"
                end
                result.tierPresent = result.tierPresent or isTier
                tracked[#tracked + 1] = DescribeAura(aura, filter, matchedBy, isTier)
            elseif aura.spellId == I.SECRET or aura.name == I.SECRET then
                unidentified = unidentified + 1
            end
        end
        result[filter] = {
            method = method, stopped = stopped, count = #auras, unidentified = unidentified, tracked = tracked,
        }
    end

    -- Cross-check by ID: this call takes the spell ID as input, so it may
    -- still answer when the walk above can only see secrets.
    local bySpellID = {}
    local getBySpell = Fn(C_UnitAuras, "GetPlayerAuraBySpellID")
    for _, spellID in ipairs(ns.TIER_AURA_IDS or {}) do
        local aura = I.Read(getBySpell, spellID)
        if type(aura) == "table" then
            result.tierPresent = true
            bySpellID[tostring(spellID)] = {
                spellId = aura.spellId, name = aura.name, auraInstanceID = aura.auraInstanceID,
                applications = aura.applications, points = aura.points,
            }
        else
            bySpellID[tostring(spellID)] = aura == nil and false or aura
        end
    end
    result.bySpellID = bySpellID

    state.tierAuraPresent = result.tierPresent
    return result
end

-- The first tier aura in a ReadAuras result, with its tooltip's parsed
-- current/max, or nil when none is up.
function I.TierSummary(auras)
    for _, filter in ipairs({ "HARMFUL", "HELPFUL" }) do
        local group = auras[filter]
        if type(group) == "table" and type(group.tracked) == "table" then
            for _, aura in ipairs(group.tracked) do
                if aura.isTier then
                    local current, max = I.FirstCurrentMax(aura.tooltip)
                    return { spellId = aura.spellId, name = aura.name, current = current, max = max }
                end
            end
        end
    end
    if type(auras.bySpellID) == "table" then
        for _, aura in pairs(auras.bySpellID) do
            if type(aura) == "table" then
                return { spellId = aura.spellId, name = aura.name }
            end
        end
    end
    return nil
end

local function RecordAuras(event)
    local auras = ReadAuras()
    RecordIfChanged("aura", "player", event, auras, I.AURA_IGNORE)
    return auras
end

--------------------------------------------------------------------------
-- UI widgets
--------------------------------------------------------------------------

I.FALLBACK_WIDGET_TYPES = {
    "StatusBar", "TextWithState", "IconAndText", "ScenarioHeaderTimer",
    "ScenarioHeaderCurrenciesAndBackground", "DoubleStatusBar", "TextureAndText", "CaptureBar",
}

local SET_GETTERS = {
    "GetTopCenterWidgetSetID", "GetObjectiveTrackerWidgetSetID",
    "GetBelowMinimapWidgetSetID", "GetPowerBarWidgetSetID",
}

-- Enum.UIWidgetVisualizationType value -> type name, built once.
local widgetTypeNames
local function WidgetTypeName(widgetType)
    if not widgetTypeNames then
        widgetTypeNames = {}
        local enum = type(Enum) == "table" and Enum.UIWidgetVisualizationType
        if type(enum) == "table" then
            for name, value in pairs(enum) do
                widgetTypeNames[value] = name
            end
        end
    end
    if widgetType == nil then
        return nil
    end
    return widgetTypeNames[widgetType]
end

local function GetterFor(typeName)
    return Fn(C_UIWidgetManager, "Get" .. typeName .. "WidgetVisualizationInfo")
end

-- The type's own getter when Enum names it, else each common getter in turn
-- (marked `guessed`, since a getter for the wrong type may still answer).
local function ReadWidget(widgetID, widgetType)
    local widget = { widgetID = widgetID, widgetType = widgetType }
    local typeName = WidgetTypeName(widgetType)
    widget.typeName = typeName
    local getter = typeName and GetterFor(typeName)
    if getter then
        local info = I.Read(getter, widgetID)
        if type(info) == "table" then
            widget.fields = I.FlattenScalars(info, I.WIDGET_FIELD_CAP)
        else
            widget.fields = info == nil and false or info
        end
        return widget
    end
    for _, name in ipairs(I.FALLBACK_WIDGET_TYPES) do
        local info = I.Read(GetterFor(name), widgetID)
        if type(info) == "table" then
            widget.typeName, widget.guessed = name, true
            widget.fields = I.FlattenScalars(info, I.WIDGET_FIELD_CAP)
            return widget
        end
    end
    widget.fields = false
    return widget
end

local function WidgetSetIDs()
    local sets, seen = {}, {}
    local function Add(source, setID)
        if type(setID) == "number" and not seen[setID] then
            seen[setID] = true
            sets[#sets + 1] = { source = source, setID = setID }
        end
    end
    for _, name in ipairs(SET_GETTERS) do
        Add(name, I.Read(Fn(C_UIWidgetManager, name)))
    end
    local step = I.Read(Fn(C_ScenarioInfo, "GetScenarioStepInfo"))
    if type(step) == "table" then
        Add("GetScenarioStepInfo", step.widgetSetID)
    end
    for setID in pairs(state.seenWidgetSets) do
        Add("UPDATE_UI_WIDGET", setID)
    end
    return sets
end

local function ReadAllWidgets()
    local result = {}
    local getAll = Fn(C_UIWidgetManager, "GetAllWidgetsBySetID")
    for _, set in ipairs(WidgetSetIDs()) do
        local widgets = I.Read(getAll, set.setID)
        local entry = { source = set.source, setID = set.setID, widgets = {} }
        if type(widgets) == "table" then
            for _, widget in ipairs(widgets) do
                if type(widget) == "table" and type(widget.widgetID) == "number" then
                    entry.widgets[#entry.widgets + 1] = ReadWidget(widget.widgetID, widget.widgetType)
                end
            end
        else
            entry.widgets = widgets == nil and false or widgets
        end
        result[#result + 1] = entry
    end
    return result
end

local function RememberWidgets(sets)
    for _, set in ipairs(sets) do
        if type(set.widgets) == "table" then
            for _, widget in ipairs(set.widgets) do
                Remember("widget", widget.widgetID, widget)
            end
        end
    end
end

-- RecordIfChanged for one widget, throttling altar widgets (I.IsAltarWidget).
-- A throttled change leaves the fingerprint alone, so the first read after
-- the interval records whatever value the widget has reached by then. Every
-- read of an altar widget still feeds its running rise, stored on the widget
-- as `rise`, so fills and resets between two recorded entries are not lost.
local function RecordWidgetIfChanged(event, widget)
    local widgetID = widget.widgetID
    local interval = I.IsAltarWidget(widget) and I.ALTAR_THROTTLE_SECONDS or nil
    if interval then
        local fields = type(widget.fields) == "table" and widget.fields or {}
        state.widgetRise[widgetID] = state.widgetRise[widgetID] or {}
        widget.rise = I.AccumulateRise(state.widgetRise[widgetID], fields.barValue, fields.barMax)
    end
    local now = interval and I.Read(GetTime)
    if interval and I.WithinInterval(state.widgetRecordedAt[widgetID], now, interval) then
        return false
    end
    if RecordIfChanged("widget", widgetID, event, widget) then
        if interval then
            state.widgetRecordedAt[widgetID] = now
        end
        return true
    end
    return false
end

local function RecordWidgets(event)
    for _, set in ipairs(ReadAllWidgets()) do
        if type(set.widgets) == "table" then
            for _, widget in ipairs(set.widgets) do
                widget.setID = set.setID
                RecordWidgetIfChanged(event, widget)
            end
        end
    end
end

--------------------------------------------------------------------------
-- Context, scenario, currencies
--------------------------------------------------------------------------

-- Active "Abundance: <cave>" area POIs on the event's maps. Both POI list
-- getters are walked, since which one carries the event POI is unverified.
local function ReadAbundancePOIs()
    local pois, seen = {}, {}
    local getInfo = Fn(C_AreaPoiInfo, "GetAreaPOIInfo")
    local getSeconds = Fn(C_AreaPoiInfo, "GetAreaPOISecondsLeft")
    for _, mapID in ipairs(ns.ABUNDANCE_MAP_IDS or {}) do
        for _, listName in ipairs({ "GetEventsForMap", "GetAreaPOIForMap" }) do
            local ids = I.Read(Fn(C_AreaPoiInfo, listName), mapID)
            if type(ids) == "table" then
                for _, poiID in ipairs(ids) do
                    if type(poiID) == "number" and not seen[poiID] then
                        seen[poiID] = true
                        local info = I.Read(getInfo, mapID, poiID)
                        if type(info) == "table" and I.Matches(info.name, { "abund" }) then
                            pois[#pois + 1] = {
                                mapID = mapID, poiID = poiID, source = listName,
                                name = info.name, description = info.description,
                                secondsLeft = I.Read(getSeconds, poiID),
                            }
                        end
                    end
                end
            elseif ids ~= nil then
                pois[#pois + 1] = { mapID = mapID, source = listName, error = ids }
            end
        end
    end
    return pois
end

local function ReadContext()
    local instance = I.ReadAll(GetInstanceInfo)
    local mapID = I.Read(Fn(C_Map, "GetBestMapForUnit"), "player")
    local mapInfo = type(mapID) == "number" and I.Read(Fn(C_Map, "GetMapInfo"), mapID) or nil
    local context = {
        mapID = mapID,
        mapName = type(mapInfo) == "table" and mapInfo.name or nil,
        zone = I.Read(GetZoneText),
        subZone = I.Read(GetSubZoneText),
        instanceName = instance[1],
        instanceType = instance[2],
        difficultyID = instance[3],
        instanceID = instance[8],
        pois = ReadAbundancePOIs(),
    }

    local caves = {}
    for _, poi in ipairs(context.pois) do
        caves[#caves + 1] = I.CaveNameFromPOI(poi.name)
    end
    state.caveNames = caves
    state.contextTexts.zone = context.zone
    state.contextTexts.subZone = context.subZone
    state.contextTexts.mapName = context.mapName
    state.contextTexts.instanceName = context.instanceName
    return context
end

local function ScalarsOf(value)
    if type(value) == "table" then
        return I.FlattenScalars(value, I.WIDGET_FIELD_CAP)
    end
    return value
end

local function ReadScenario()
    local scenario = {
        inScenario = I.Read(Fn(C_Scenario, "IsInScenario")),
        info = ScalarsOf(I.Read(Fn(C_ScenarioInfo, "GetScenarioInfo"))),
        step = ScalarsOf(I.Read(Fn(C_ScenarioInfo, "GetScenarioStepInfo"))),
        criteria = {},
    }
    local numCriteria = type(scenario.step) == "table" and scenario.step.numCriteria
    if type(numCriteria) == "number" then
        local getCriteria = Fn(C_ScenarioInfo, "GetCriteriaInfo")
        for index = 1, math.min(numCriteria, 20) do
            scenario.criteria[index] = ScalarsOf(I.Read(getCriteria, index)) or false
        end
    end
    state.contextTexts.scenarioName = type(scenario.info) == "table" and scenario.info.name or nil
    return scenario
end

local function ReadCurrencies()
    local currencies = {}
    local getInfo = Fn(C_CurrencyInfo, "GetCurrencyInfo")
    for _, currencyID in ipairs({ ns.CURRENCY_SHARD or false, ns.CURRENCY_UNALLOYED or false }) do
        if currencyID then
            local info = I.Read(getInfo, currencyID)
            if type(info) == "table" then
                currencies[#currencies + 1] = {
                    currencyID = currencyID, name = info.name, quantity = info.quantity,
                    quantityEarnedThisWeek = info.quantityEarnedThisWeek,
                    maxWeeklyQuantity = info.maxWeeklyQuantity, maxQuantity = info.maxQuantity,
                    totalEarned = info.totalEarned,
                }
            else
                currencies[#currencies + 1] = { currencyID = currencyID, error = info == nil and false or info }
            end
        end
    end
    return currencies
end

local function InAbundanceContext()
    return I.IsAbundanceContext(state.tierAuraPresent, state.contextTexts, state.caveNames)
end

--------------------------------------------------------------------------
-- Snapshot
--------------------------------------------------------------------------

-- Everything at once, regardless of the change filter: the whole quest log,
-- candidates, auras, every widget in every known set, context, scenario and
-- currencies. Also seeds each change baseline so the next event-driven entry
-- is a real change rather than a repeat of what the snapshot just stored.
local function TakeSnapshot(reason)
    local quests, candidates = ReadQuestLog()
    UpdateWeeklyGuess(candidates, reason)
    local data = {
        reason = reason,
        version = I.Read(ns.GetVersion),
        build = I.ReadAll(GetBuildInfo),
        questLog = quests,
        candidates = candidates,
        auras = ReadAuras(),
        widgets = ReadAllWidgets(),
        context = ReadContext(),
        scenario = ReadScenario(),
        currencies = ReadCurrencies(),
    }
    data.inAbundanceContext = InAbundanceContext()

    for _, quest in ipairs(candidates) do
        Remember("quest", quest.questID, quest)
    end
    Remember("aura", "player", data.auras, I.AURA_IGNORE)
    RememberWidgets(data.widgets)
    Remember("context", "player", data.context, { secondsLeft = true })
    Remember("scenario", "player", data.scenario)
    Remember("currency", "tracked", data.currencies)

    Record("snapshot", reason, data)
    return data
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

local function RecordContext(event)
    RecordIfChanged("context", "player", event, ReadContext(), { secondsLeft = true })
    RecordIfChanged("scenario", "player", event, ReadScenario())
end

-- Combat entries embed an aura read taken at the transition itself: whether
-- the tier aura's ID and tooltip were still readable at that moment is the
-- combat-readability question, answered whether or not anything changed.
local function OnCombat(event)
    local auras = RecordAuras(event)
    Record("combat", event, {
        state = event == "PLAYER_REGEN_DISABLED" and "enter" or "leave",
        tier = I.TierSummary(auras) or false,
        unidentified = {
            HELPFUL = type(auras.HELPFUL) == "table" and auras.HELPFUL.unidentified or nil,
            HARMFUL = type(auras.HARMFUL) == "table" and auras.HARMFUL.unidentified or nil,
        },
    })
end

local function OnQuestEvent(event, questID)
    questID = I.Sanitize(questID)
    local title = type(questID) == "number" and I.Read(Fn(C_QuestLog, "GetTitleForQuestID"), questID) or nil
    Record("questEvent", event, { questID = questID, title = title })
    RecordQuestChanges(event)
end

-- Monster chat can itself be secret in 12.x; a secret line cannot be
-- matched, so it is kept only while plausibly inside a run.
local function OnChat(event, text, sender)
    text, sender = I.Sanitize(text), I.Sanitize(sender)
    local secret = text == I.SECRET or sender == I.SECRET
    if I.Matches(text, I.CHAT_NEEDLES) or I.Matches(sender, I.CHAT_NEEDLES)
        or (secret and InAbundanceContext()) then
        Record("chat", event, { text = text, sender = sender })
    end
end

local function OnWidget(event, widgetInfo)
    if not InAbundanceContext() then
        return
    end
    widgetInfo = I.Sanitize(widgetInfo)
    if type(widgetInfo) ~= "table" or type(widgetInfo.widgetID) ~= "number" then
        return
    end
    if type(widgetInfo.widgetSetID) == "number" then
        state.seenWidgetSets[widgetInfo.widgetSetID] = true
    end
    local widget = ReadWidget(widgetInfo.widgetID, widgetInfo.widgetType)
    widget.setID = widgetInfo.widgetSetID
    RecordWidgetIfChanged(event, widget)
end

local function IsPlayer(unit)
    return I.Sanitize(unit) == "player"
end

local HANDLERS = {
    QUEST_LOG_UPDATE = RecordQuestChanges,
    QUEST_WATCH_UPDATE = RecordQuestChanges,
    UNIT_QUEST_LOG_CHANGED = function(event, unit)
        if IsPlayer(unit) then
            RecordQuestChanges(event)
        end
    end,
    QUEST_ACCEPTED = OnQuestEvent,
    QUEST_TURNED_IN = OnQuestEvent,
    QUEST_REMOVED = OnQuestEvent,
    UNIT_AURA = function(event, unit)
        if IsPlayer(unit) then
            RecordAuras(event)
        end
    end,
    UPDATE_UI_WIDGET = OnWidget,
    PLAYER_REGEN_DISABLED = OnCombat,
    PLAYER_REGEN_ENABLED = OnCombat,
    ZONE_CHANGED = RecordContext,
    ZONE_CHANGED_NEW_AREA = RecordContext,
    ZONE_CHANGED_INDOORS = RecordContext,
    SCENARIO_UPDATE = RecordContext,
    SCENARIO_CRITERIA_UPDATE = RecordContext,
    PLAYER_ENTERING_WORLD = TakeSnapshot,
    CURRENCY_DISPLAY_UPDATE = function(event)
        RecordIfChanged("currency", "tracked", event, ReadCurrencies())
    end,
    CHAT_MSG_MONSTER_SAY = OnChat,
    CHAT_MSG_MONSTER_YELL = OnChat,
    CHAT_MSG_MONSTER_EMOTE = OnChat,
    CHAT_MSG_RAID_BOSS_EMOTE = OnChat,
    CHAT_MSG_SYSTEM = OnChat,
}

-- Runs a handler so a probe bug can never throw into the client's error
-- frame (which would repeat on every UNIT_AURA mid-combat); the error is
-- logged instead, once per distinct message.
local function Guarded(event, handler, ...)
    local ok, err = pcall(handler, event, ...)
    if not ok then
        RecordIfChanged("probeError", event, event, { error = I.ErrorText(err) })
    end
end

-- Gated on the saved flag rather than unregistering, so start/stop is one
-- assignment and /reload resumes exactly where recording was left.
function I.OnEvent(_, event, ...)
    if not IsRecording() then
        return
    end
    local handler = HANDLERS[event]
    if handler then
        Guarded(event, handler, ...)
    end
end

-- Some changes (the tooltip's "Current:" text above all) may not raise any
-- event; while recording inside a run, a slow poll catches them. Change
-- detection keeps it from adding entries when nothing moved.
function I.Poll()
    if not IsRecording() or not InAbundanceContext() then
        return
    end
    Guarded("poll", function(event)
        RecordAuras(event)
        RecordQuestChanges(event)
        RecordWidgets(event)
    end)
end

local frame = CreateFrame("Frame")

-- Registering an event the client does not know about raises an error,
-- which would abort the rest of this file; register each one defensively.
for event in pairs(HANDLERS) do
    pcall(frame.RegisterEvent, frame, event)
end
frame:SetScript("OnEvent", I.OnEvent)

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

local pollTicker

-- Called by AbundanceTally_Commands.lua once ADDON_LOADED has made
-- AbundanceTallyDB trustworthy. Does not create the probe table; that waits
-- for the first command or recorded entry.
function Probe.OnAddonLoaded()
    state.loaded = true
    if IsRecording() then
        Record("session", "ADDON_LOADED", { version = I.Read(ns.GetVersion), build = I.ReadAll(GetBuildInfo) })
    end
    if not pollTicker and type(C_Timer) == "table" and type(C_Timer.NewTicker) == "function" then
        pollTicker = C_Timer.NewTicker(I.POLL_SECONDS, I.Poll)
    end
end

local LOG_PATH = "WTF/Account/<ACCOUNT>/SavedVariables/" .. ADDON_NAME .. ".lua"

local function EntryCount(db)
    return #db.entries
end

local function PrintSnapshotSummary(data, db)
    ns.Print("snapshot taken (recording %s, in combat: %s, in Abundance context: %s).",
        db.enabled and "on" or "off", tostring(I.Read(InCombatLockdown)), tostring(data.inAbundanceContext))

    local shown = 0
    for _, quest in ipairs(data.candidates) do
        local pinned = db.pinnedQuestID ~= nil and quest.questID == db.pinnedQuestID
        if shown < 2 and type(quest.score) == "number" and (pinned or quest.score >= I.MIN_BEST_SCORE) then
            shown = shown + 1
            ns.Print("quest %s \"%s\" (score %d): %s", tostring(quest.questID), tostring(quest.title),
                quest.score, I.DescribeObjectives(quest))
        end
    end
    if shown == 0 then
        ns.Print("no weekly candidate found (%d weekly/title candidate(s) below the cut); "
            .. "/tally probe quest <id> pins one by hand.", #data.candidates)
    end

    local tier = I.TierSummary(data.auras)
    if tier then
        ns.Print("tier aura %s \"%s\": current %s / max %s", tostring(tier.spellId), tostring(tier.name),
            tostring(tier.current), tostring(tier.max))
    else
        ns.Print("tier aura: none")
    end

    local parts = {}
    for _, currency in ipairs(data.currencies) do
        parts[#parts + 1] = string.format("%s %s (week %s/%s)", tostring(currency.name or currency.currencyID),
            tostring(currency.quantity), tostring(currency.quantityEarnedThisWeek),
            tostring(currency.maxWeeklyQuantity))
    end
    ns.Print("currencies: %s", #parts > 0 and table.concat(parts, ", ") or "none")

    ns.Print("%d entries logged; the full log is written on /reload or logout to %s", EntryCount(db), LOG_PATH)
end

local function PrintStatus(db)
    ns.Print("recording: %s", db.enabled and "on" or "off")
    ns.Print("entries: %d (%d dropped at the %d cap)", EntryCount(db), tonumber(db.dropped) or 0, I.MAX_ENTRIES)
    if db.weeklyQuestID then
        ns.Print("weekly quest guess: %s \"%s\" (score %s)%s", tostring(db.weeklyQuestID),
            tostring(db.weeklyQuestTitle), tostring(db.weeklyQuestScore),
            db.pinnedQuestID and " - pinned" or "")
    else
        ns.Print("weekly quest guess: none yet")
    end
end

local SUBCOMMANDS = {
    {
        name = "start",
        help = "/tally probe start - record changes (survives /reload) and take a snapshot now",
        handler = function(db)
            db.enabled = true
            TakeSnapshot("start")
            ns.Print("recording on; %d entries so far.", EntryCount(db))
        end,
    },
    {
        name = "stop",
        help = "/tally probe stop - stop recording",
        handler = function(db)
            db.enabled = false
            ns.Print("recording off; %d entries kept.", EntryCount(db))
        end,
    },
    {
        name = "snap",
        help = "/tally probe snap - take one full snapshot now and summarize it",
        handler = function(db)
            PrintSnapshotSummary(TakeSnapshot("snap"), db)
        end,
    },
    {
        name = "status",
        help = "/tally probe status - recording state, entry count, weekly quest guess",
        handler = PrintStatus,
    },
    {
        name = "clear",
        help = "/tally probe clear - delete every recorded entry",
        handler = function(db)
            db.entries = {}
            db.dropped = 0
            state.lastSeen = {}
            state.widgetRecordedAt = {}
            state.widgetRise = {}
            ns.Print("probe log cleared.")
        end,
    },
    {
        name = "quest",
        help = "/tally probe quest <id>|off - pin the weekly questID by hand, or unpin it",
        handler = function(db, arg)
            local questID = tonumber(arg)
            if arg == "off" then
                db.pinnedQuestID = nil
                ns.Print("weekly quest unpinned; scoring picks it again.")
            elseif questID then
                db.pinnedQuestID = questID
                db.weeklyQuestID = questID
                ns.Print("weekly quest pinned to %d.", questID)
            else
                ns.Print("Usage: /tally probe quest <id>|off")
            end
        end,
    },
}

local function PrintUsage()
    ns.Print("probe commands (log saved to %s):", LOG_PATH)
    for _, entry in ipairs(SUBCOMMANDS) do
        ns.Print(entry.help)
    end
    ns.Print("/tally probe help - show this list")
end

-- Receives whatever followed "/tally probe" (possibly "").
function Probe.HandleCommand(args)
    local tokens = {}
    for word in (type(args) == "string" and args or ""):gmatch("%S+") do
        tokens[#tokens + 1] = word:lower()
    end
    local cmd = tokens[1] or ""
    if cmd == "" or cmd == "help" then
        PrintUsage()
        return
    end

    local db = GetDB(true)
    if not db then
        ns.Print("probe not ready: saved variables have not loaded yet.")
        return
    end
    for _, entry in ipairs(SUBCOMMANDS) do
        if entry.name == cmd then
            entry.handler(db, tokens[2])
            return
        end
    end
    ns.Print("Unknown probe command: %s", cmd)
    PrintUsage()
end
