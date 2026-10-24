-- Headless tests for the probe's pure logic (ns.Probe._internal) and its
-- command/event paths against the stubbed client. Run from the repo root:
-- lua5.1 tests/run.lua [tocPath]
-- tocPath defaults to AbundanceTally.toc; a scratch TOC can stand in while
-- the real one is unavailable. Exits non-zero on any failure so CI catches a
-- regression here the same way it catches a luacheck or syntax failure.

local stub = dofile("tests/stub.lua")
local fixtures = stub.install()
local SECRET = stub.SECRET

-- Loads every Lua file the TOC lists, in order, against a shared ns --
-- mirrors exactly how the client loads a multi-file addon, and stays correct
-- automatically as files are added or reordered later.
local function LoadAddonFiles(tocPath, addonName, ns)
    local toc = assert(io.open(tocPath, "r"))
    for line in toc:lines() do
        local file = line:match("^%s*(.-)%s*$")
        if file ~= "" and not file:match("^##") then
            local chunk = assert(loadfile(file))
            chunk(addonName, ns)
        end
    end
    toc:close()
end

local ns = {}
LoadAddonFiles(arg and arg[1] or "AbundanceTally.toc", "AbundanceTally", ns)

local Probe = ns.Probe
local I = Probe._internal

local failures = 0
local count = 0

local function check(name, condition, detail)
    count = count + 1
    if not condition then
        failures = failures + 1
        print(string.format("FAIL: %s%s", name, detail and (" -- " .. detail) or ""))
    end
end

local function assertEqual(name, actual, expected)
    check(name, actual == expected, string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

-- Captures ns.Print output (which goes through the global print) for one call.
local originalPrint = print
local function capture(fn, ...)
    local lines = {}
    print = function(line) lines[#lines + 1] = tostring(line) end
    local ok, err = pcall(fn, ...)
    print = originalPrint
    return ok, err, lines
end

local function anyLineHas(lines, needle)
    for _, line in ipairs(lines) do
        if line:find(needle, 1, true) then
            return true
        end
    end
    return false
end

local function entries()
    return AbundanceTallyDB.probe.entries
end

local function lastEntry()
    local list = entries()
    return list[#list]
end

local function countKind(kind)
    local n = 0
    for _, entry in ipairs(entries()) do
        if entry.kind == kind then
            n = n + 1
        end
    end
    return n
end

local TIER = ns.TIER_AURA_IDS[1]

--------------------------------------------------------------------------
-- 1. Tooltip "current / max" parsing.
--------------------------------------------------------------------------
do
    local current, max = I.ParseCurrentMax("Current: 1234 / 3000")
    assertEqual("plain current", current, 1234)
    assertEqual("plain max", max, 3000)

    current, max = I.ParseCurrentMax("Current: 1,234 / 3,000")
    assertEqual("comma thousands, current", current, 1234)
    assertEqual("comma thousands, max", max, 3000)

    current, max = I.ParseCurrentMax("12 / 1,000,000")
    assertEqual("multiple separator groups are all joined", max, 1000000)
    assertEqual("...without disturbing the other side", current, 12)

    current, max = I.ParseCurrentMax("|cffffffff1.234|r/5000")
    assertEqual("colour codes stripped and period separator joined", current, 1234)
    assertEqual("no spaces around the slash still parses", max, 5000)

    assertEqual("no match returns nil", I.ParseCurrentMax("Blessing of Abundance"), nil)
    assertEqual("non-string returns nil", I.ParseCurrentMax(nil), nil)
    assertEqual("a secret marker returns nil", I.ParseCurrentMax(I.SECRET), nil)

    local lines = I.TooltipLines({ lines = {
        { leftText = "Abundance" },
        { leftText = "Current: 2500 / 5000", rightText = nil },
    } })
    assertEqual("tooltip lines keep the raw text", lines[2].leftText, "Current: 2500 / 5000")
    assertEqual("tooltip lines carry the parse", lines[2].current, 2500)
    assertEqual("a line without a pair has no parse", lines[1].current, nil)
    local firstCurrent, firstMax = I.FirstCurrentMax({ lines = lines })
    check("first parsed pair is found across lines", firstCurrent == 2500 and firstMax == 5000)
end

--------------------------------------------------------------------------
-- 2. Change detection.
--------------------------------------------------------------------------
do
    local lastSeen = {}
    local a = { x = 1, nested = { y = "two" } }
    local same = { nested = { y = "two" }, x = 1 }
    check("first observation records", I.ShouldRecord(lastSeen, "k", I.Fingerprint(a)))
    check("an identical value (different key order) does not", not I.ShouldRecord(lastSeen, "k", I.Fingerprint(same)))
    check("a changed nested value records", I.ShouldRecord(lastSeen, "k", I.Fingerprint({ x = 1, nested = { y = 3 } })))
    check("keys are independent", I.ShouldRecord(lastSeen, "other", I.Fingerprint(a)))
    check("type is part of the fingerprint", I.Fingerprint(1) ~= I.Fingerprint("1"))

    local ignore = { secondsLeft = true }
    I.ShouldRecord(lastSeen, "poi", I.Fingerprint({ name = "A", pois = { { secondsLeft = 100 } } }, ignore))
    check("an ignored key's churn is not a change",
        not I.ShouldRecord(lastSeen, "poi", I.Fingerprint({ name = "A", pois = { { secondsLeft = 99 } } }, ignore)))

    check("a record inside the interval is throttled", I.WithinInterval(100, 104.9, 5))
    check("a record at the interval is not", not I.WithinInterval(100, 105, 5))
    check("no earlier record never throttles", not I.WithinInterval(nil, 100, 5))
    check("a marker clock never throttles", not I.WithinInterval(100, "<missing>", 5))

    local tracker = {}
    assertEqual("the first value only sets the baseline", I.AccumulateRise(tracker, 6490, 10000), 0)
    assertEqual("a rise adds the difference", I.AccumulateRise(tracker, 9710, 10000), 3220)
    assertEqual("a reset counts the rest of the bar plus the new value", I.AccumulateRise(tracker, 190, 10000), 3700)
    assertEqual("an unchanged value adds nothing", I.AccumulateRise(tracker, 190, 10000), 3700)
    I.AccumulateRise(tracker, 10010, 10000)
    assertEqual("a reset after overshooting the max adds no negative rest", I.AccumulateRise(tracker, 0, 10000), 13520)
    assertEqual("a missing value keeps the total", I.AccumulateRise(tracker, nil, 10000), 13520)
    assertEqual("...and the next value starts a new baseline", I.AccumulateRise(tracker, 5000, 10000), 13520)
end

--------------------------------------------------------------------------
-- 3. Bounded log.
--------------------------------------------------------------------------
do
    local list, dropped = {}, 0
    for value = 1, 5 do
        dropped = dropped + I.Append(list, value, 3)
    end
    assertEqual("list is trimmed to the cap", #list, 3)
    assertEqual("oldest entries are the ones dropped", list[1], 3)
    assertEqual("newest entry is last", list[3], 5)
    assertEqual("drop count is reported", dropped, 2)
    assertEqual("under the cap nothing is dropped", I.Append({}, 1, 3), 0)

    -- Trimming more than one at once (cap lowered between sessions).
    local long = { 1, 2, 3, 4, 5, 6 }
    assertEqual("a list far over the cap drops the excess at once", I.Append(long, 7, 2), 5)
    check("...keeping the newest two", #long == 2 and long[1] == 6 and long[2] == 7)
end

--------------------------------------------------------------------------
-- 4. Secret-value sanitizing.
--------------------------------------------------------------------------
do
    check("the stub's secret really errors when touched", not pcall(function() return SECRET .. "" end))

    assertEqual("a top-level secret becomes the marker", I.Sanitize(SECRET), I.SECRET)
    local clean = I.Sanitize({ a = SECRET, b = { c = SECRET, d = 1 }, list = { SECRET, "x" }, f = print })
    assertEqual("a secret field becomes the marker", clean.a, I.SECRET)
    assertEqual("a nested secret becomes the marker", clean.b.c, I.SECRET)
    assertEqual("plain nested values survive", clean.b.d, 1)
    assertEqual("secrets inside arrays become the marker", clean.list[1], I.SECRET)
    assertEqual("array order is kept", clean.list[2], "x")
    assertEqual("functions become a type marker", clean.f, "<function>")

    assertEqual("Read sanitizes a secret return", I.Read(function() return SECRET end), I.SECRET)
    check("Read turns a thrown error into a marker",
        tostring(I.Read(function() error("boom") end)):find("^<err: ") ~= nil)
    assertEqual("Read marks a missing function", I.Read(nil), I.MISSING)
    local all = I.ReadAll(function() return 1, nil, SECRET end)
    check("ReadAll keeps every return, nils included", all.n == 3 and all[1] == 1 and all[2] == nil
        and all[3] == I.SECRET)

    local deep = {}
    local node = deep
    for _ = 1, 10 do
        node.next = {}
        node = node.next
    end
    check("depth is capped", I.Fingerprint(I.Sanitize(deep)):find("<depth>", 1, true) ~= nil)

    fixtures.removeIsSecretValue()
    check("without issecretvalue nothing is treated as secret", not I.IsSecret("x"))
    assertEqual("...and plain values pass through", I.Sanitize({ v = 5 }).v, 5)
    fixtures.reset()

    _G.issecretvalue = function() error("no") end
    check("an issecretvalue that errors counts as secret", I.IsSecret(1))
    fixtures.reset()
end

--------------------------------------------------------------------------
-- 5. Candidate-quest scoring.
--------------------------------------------------------------------------
do
    local weekly = { [Enum.QuestFrequency.Weekly] = true }
    local abundance = {
        questID = 90001, title = "Weekly: Abundance", frequency = Enum.QuestFrequency.Weekly,
        objectives = { { type = "progressbar", numFulfilled = 0, numRequired = 20000 } },
    }
    local offerings = {
        questID = 90002, title = "Abundant Offerings", frequency = 0,
        objectives = { { type = "monster", numFulfilled = 0, numRequired = 1 } },
    }
    local otherWeekly = { questID = 90003, title = "Some Other Weekly", frequency = Enum.QuestFrequency.Weekly,
        objectives = { { type = "item", numFulfilled = 0, numRequired = 4 } } }

    check("a title match is a candidate", I.IsCandidate(offerings, weekly))
    check("an 'offering' title is a candidate", I.IsCandidate({ title = "Dundun's Offering" }, weekly))
    check("weekly frequency alone is a candidate", I.IsCandidate(otherWeekly, weekly))
    check("anything else is not", not I.IsCandidate({ title = "Kill Rats", frequency = 0 }, weekly))

    abundance.score = I.ScoreCandidate(abundance, weekly)
    offerings.score = I.ScoreCandidate(offerings, weekly)
    otherWeekly.score = I.ScoreCandidate(otherWeekly, weekly)
    check("the 20,000 progress-bar weekly outranks a bare title match", abundance.score > offerings.score)
    check("weekly frequency alone stays below the best-guess cut", otherWeekly.score < I.MIN_BEST_SCORE)

    assertEqual("best candidate is the 20,000 weekly", I.PickBestCandidate({ otherWeekly, offerings, abundance }),
        abundance)
    assertEqual("no candidate above the cut means no guess", I.PickBestCandidate({ otherWeekly }), nil)
    check("a secret title scores nothing for its title",
        I.ScoreCandidate({ title = I.SECRET, frequency = 0 }, weekly) == 0)

    local text = I.DescribeObjectives({ objectives = { { text = "Points", numFulfilled = 5, numRequired = 20000,
        type = "progressbar" } }, progressBarPercent = 12 })
    check("objective description carries the numbers", text:find("5/20000", 1, true) ~= nil)
    check("objective description carries the bar percent", text:find("bar 12%", 1, true) ~= nil)
end

--------------------------------------------------------------------------
-- 6. Context helpers.
--------------------------------------------------------------------------
do
    assertEqual("cave name from POI", I.CaveNameFromPOI("Abundance: Enchanting Crypt"), "Enchanting Crypt")
    assertEqual("non-Abundance POI has no cave", I.CaveNameFromPOI("Something: Else"), nil)
    assertEqual("non-string POI name has no cave", I.CaveNameFromPOI(nil), nil)

    check("tier aura alone is context", I.IsAbundanceContext(true, {}, {}))
    check("subzone equal to the cave is context",
        I.IsAbundanceContext(false, { subZone = "enchanting crypt" }, { "Enchanting Crypt" }))
    check("a name mentioning Dundun is context", I.IsAbundanceContext(false, { zone = "Shrine of Dundun" }, {}))
    check("elsewhere is not context", not I.IsAbundanceContext(false, { zone = "Silvermoon City" }, { "Crypt" }))

    local flat = I.FlattenScalars({ text = "a", barValue = 5, nested = { inner = 1, deeper = { x = 1 } } }, 3)
    assertEqual("scalars are kept", flat.text, "a")
    assertEqual("nested scalars are flattened", flat["nested.inner"], 1)
    assertEqual("the field cap holds", flat["nested.deeper.x"], nil)
end

--------------------------------------------------------------------------
-- 7. Commands before ADDON_LOADED, then the documented subcommands.
--------------------------------------------------------------------------
do
    fixtures.reset()
    local ok, err, lines = capture(Probe.HandleCommand, "status")
    check("status before ADDON_LOADED does not error", ok, tostring(err))
    check("...and says the probe is not ready", anyLineHas(lines, "not ready"))
    assertEqual("...without creating saved variables", AbundanceTallyDB, nil)

    _G.AbundanceTallyDB = {}
    Probe.OnAddonLoaded()
    assertEqual("ADDON_LOADED alone does not create the probe table", AbundanceTallyDB.probe, nil)

    for _, args in ipairs({ "", "help", "status", "start", "stop", "clear", "bogus", "quest", "quest off" }) do
        ok, err, lines = capture(Probe.HandleCommand, args)
        check("HandleCommand(\"" .. args .. "\") does not error", ok, tostring(err))
        check("HandleCommand(\"" .. args .. "\") prints something", #lines > 0)
    end
    ok, err = capture(Probe.HandleCommand, nil)
    check("HandleCommand(nil) does not error", ok, tostring(err))

    ok, err, lines = capture(Probe.HandleCommand, "help")
    check("help lists start", ok and anyLineHas(lines, "/tally probe start"), tostring(err))
    check("help names the log file", anyLineHas(lines, "SavedVariables/AbundanceTally.lua"))

    ok, err, lines = capture(Probe.HandleCommand, "bogus")
    check("an unknown subcommand is named", ok and anyLineHas(lines, "Unknown probe command: bogus"), tostring(err))

    -- The full slash path through the other agent's Commands file, when loaded.
    if SlashCmdList.ABUNDANCETALLY then
        ok, err, lines = capture(SlashCmdList.ABUNDANCETALLY, "probe status")
        check("/tally probe status reaches the probe", ok and anyLineHas(lines, "recording:"), tostring(err))
    end
end

--------------------------------------------------------------------------
-- 8. Recording: start snapshot, aura dedupe, combat secrets, stop/clear.
--------------------------------------------------------------------------
do
    fixtures.reset()
    _G.AbundanceTallyDB = {}
    Probe.OnAddonLoaded()
    I.state.lastSeen = {}

    fixtures.setQuests({
        { isHeader = true, title = "Midnight" },
        { questID = 90001, title = "Weekly: Abundance", frequency = Enum.QuestFrequency.Weekly,
            objectives = { { type = "progressbar", text = "Abundance", numFulfilled = 1200, numRequired = 20000,
                finished = false } }, progress = 6 },
        { questID = 90003, title = "Kill Rats", frequency = 0 },
    })
    fixtures.setAuras("HARMFUL", { { spellId = TIER, name = "Abundance", auraInstanceID = 77, applications = 0,
        duration = 180, expirationTime = 680, points = { 1234 } } })
    fixtures.setTooltip(77, { { leftText = "Abundance" }, { leftText = "Current: 1234 / 3000" } })
    fixtures.setCurrency(ns.CURRENCY_SHARD, { name = "Shard of Dundun", quantity = 3,
        quantityEarnedThisWeek = 1, maxWeeklyQuantity = 0 })
    fixtures.setCurrency(ns.CURRENCY_UNALLOYED, { name = "Unalloyed Abundance", quantity = 600 })
    fixtures.setPOIs(2395, { { poiID = 8001, name = "Abundance: Enchanting Crypt", secondsLeft = 900 } })
    fixtures.setWidgets(1, { { widgetID = 555, widgetType = Enum.UIWidgetVisualizationType.StatusBar,
        info = { barValue = 1234, barMax = 3000, text = "Score" } } })

    local ok, err = capture(Probe.HandleCommand, "start")
    check("start does not error", ok, tostring(err))
    assertEqual("start persists enabled", AbundanceTallyDB.probe.enabled, true)
    assertEqual("start takes a snapshot", lastEntry().kind, "snapshot")
    assertEqual("best weekly guess is the 20,000 quest", AbundanceTallyDB.probe.weeklyQuestID, 90001)

    local snapshot = lastEntry()
    check("entries are timestamped", snapshot.t == 1000000 and snapshot.clock == 500.0)
    assertEqual("entries carry the combat flag", snapshot.inCombat, false)
    assertEqual("snapshot lists non-header quests", #snapshot.data.questLog, 2)
    assertEqual("snapshot candidates exclude unrelated quests", #snapshot.data.candidates, 1)
    local tier = I.TierSummary(snapshot.data.auras)
    check("snapshot sees the tier aura with its parsed tooltip", tier and tier.current == 1234 and tier.max == 3000)
    assertEqual("the tooltip getter that answered is recorded",
        snapshot.data.auras.HARMFUL.tracked[1].tooltip.getter, "GetUnitDebuffByAuraInstanceID")
    assertEqual("snapshot records the active POI", snapshot.data.context.pois[1].name, "Abundance: Enchanting Crypt")
    assertEqual("snapshot reads the widget through its type's getter",
        snapshot.data.widgets[1].widgets[1].fields.barValue, 1234)
    assertEqual("snapshot records currencies", snapshot.data.currencies[1].quantity, 3)

    local before = #entries()
    I.OnEvent(nil, "UNIT_AURA", "player")
    assertEqual("an unchanged aura after a snapshot adds no entry", #entries(), before)
    I.OnEvent(nil, "UNIT_AURA", "target")
    assertEqual("another unit's UNIT_AURA is ignored", #entries(), before)

    fixtures.setTooltip(77, { { leftText = "Abundance" }, { leftText = "Current: 1500 / 3000" } })
    I.OnEvent(nil, "UNIT_AURA", "player")
    assertEqual("a tooltip score change adds one entry", #entries(), before + 1)
    assertEqual("...of kind aura", lastEntry().kind, "aura")

    -- Combat: the aura's identifying fields turn secret, but its instance ID
    -- does not, so it is still followed and still counted as the tier aura.
    fixtures.setCombat(true)
    fixtures.setAuras("HARMFUL", { { spellId = SECRET, name = SECRET, auraInstanceID = 77, points = SECRET } })
    fixtures.setTooltip(77, { { leftText = SECRET } })
    local okEvent = pcall(I.OnEvent, nil, "PLAYER_REGEN_DISABLED")
    check("combat enter with secret aura fields does not error", okEvent)
    local combat = lastEntry()
    assertEqual("combat transition is logged", combat.kind, "combat")
    assertEqual("combat entry carries inCombat", combat.inCombat, true)
    check("combat entry still identifies the tier aura by instance ID", type(combat.data.tier) == "table")
    local auraEntry = entries()[#entries() - 1]
    assertEqual("the aura entry before it stores secrets as the marker",
        auraEntry.data.HARMFUL.tracked[1].spellId, I.SECRET)
    assertEqual("...matched by auraInstanceID", auraEntry.data.HARMFUL.tracked[1].matchedBy, "auraInstanceID")
    assertEqual("...with the secret tooltip line stored as the marker",
        auraEntry.data.HARMFUL.tracked[1].tooltip.lines[1].leftText, I.SECRET)

    -- The whole aura table secret: the walk stops and says why.
    fixtures.setAuras("HARMFUL", SECRET)
    okEvent = pcall(I.OnEvent, nil, "UNIT_AURA", "player")
    check("a wholly secret aura list does not error", okEvent)
    assertEqual("...and the stop reason is recorded", lastEntry().data.HARMFUL.stopped.value, I.SECRET)
    fixtures.setCombat(false)
    fixtures.setAuras("HARMFUL", {})
    I.OnEvent(nil, "PLAYER_REGEN_ENABLED")
    assertEqual("combat leave is logged", lastEntry().data.state, "leave")

    -- Quest objective progress during the run.
    before = #entries()
    I.OnEvent(nil, "QUEST_LOG_UPDATE")
    assertEqual("an unchanged quest log adds no entry", #entries(), before)
    fixtures.setQuests({
        { questID = 90001, title = "Weekly: Abundance", frequency = Enum.QuestFrequency.Weekly,
            objectives = { { type = "progressbar", text = "Abundance", numFulfilled = 2700, numRequired = 20000,
                finished = false } }, progress = 13 },
    })
    I.OnEvent(nil, "QUEST_LOG_UPDATE")
    assertEqual("an objective change is logged", lastEntry().kind, "quest")
    assertEqual("...with the new progress", lastEntry().data.objectives[1].numFulfilled, 2700)

    -- Chat filter.
    before = #entries()
    I.OnEvent(nil, "CHAT_MSG_MONSTER_YELL", "Dundun accepts your offering!", "Dundun")
    assertEqual("a Dundun yell is logged", #entries(), before + 1)
    I.OnEvent(nil, "CHAT_MSG_SYSTEM", "You have been awarded a thing.", "")
    assertEqual("unrelated system chat is not", #entries(), before + 1)

    -- Widgets are only logged in an Abundance context.
    I.state.tierAuraPresent = false
    I.state.contextTexts = { zone = "Silvermoon City" }
    I.state.caveNames = {}
    before = #entries()
    I.OnEvent(nil, "UPDATE_UI_WIDGET", { widgetID = 555, widgetSetID = 1,
        widgetType = Enum.UIWidgetVisualizationType.StatusBar })
    assertEqual("a widget update outside a run is not logged", #entries(), before)
    I.state.contextTexts = { subZone = "Enchanting Crypt" }
    I.state.caveNames = { "Enchanting Crypt" }
    fixtures.setWidgets(1, { { widgetID = 555, widgetType = Enum.UIWidgetVisualizationType.StatusBar,
        info = { barValue = 2000, barMax = 3000, text = "Score" } } })
    I.OnEvent(nil, "UPDATE_UI_WIDGET", { widgetID = 555, widgetSetID = 1,
        widgetType = Enum.UIWidgetVisualizationType.StatusBar })
    assertEqual("a widget update inside a run is logged", lastEntry().kind, "widget")
    assertEqual("...with its scalar fields", lastEntry().data.fields.barValue, 2000)

    -- The shared altar meter (7316) is recorded at most once per interval.
    local ALTAR = 7316
    local interval = I.THROTTLED_WIDGETS[ALTAR]
    check("the shared altar widget is throttled", type(interval) == "number" and interval > 0)
    local function altarUpdate(value)
        fixtures.setWidgets(1, { { widgetID = ALTAR, widgetType = Enum.UIWidgetVisualizationType.StatusBar,
            info = { barValue = value, barMax = 10000, text = "Public Altar Contribution" } } })
        I.OnEvent(nil, "UPDATE_UI_WIDGET", { widgetID = ALTAR, widgetSetID = 1,
            widgetType = Enum.UIWidgetVisualizationType.StatusBar })
    end
    before = #entries()
    altarUpdate(100)
    altarUpdate(200)
    fixtures.advanceClock(interval / 2)
    altarUpdate(300)
    assertEqual("altar changes inside the interval log once", #entries(), before + 1)
    fixtures.advanceClock(interval / 2)
    altarUpdate(400)
    assertEqual("the first change after the interval logs", #entries(), before + 2)
    assertEqual("...with the value reached by then", lastEntry().data.fields.barValue, 400)
    fixtures.advanceClock(interval)
    altarUpdate(400)
    assertEqual("an unchanged altar value still logs nothing", #entries(), before + 2)
    altarUpdate(500)
    assertEqual("...and a real change after it does", #entries(), before + 3)
    altarUpdate(600)
    -- A fill and reset inside the throttle interval still reaches the total.
    altarUpdate(9900)
    altarUpdate(50)
    fixtures.advanceClock(interval)
    altarUpdate(150)
    assertEqual("the entry after a throttled reset carries the full rise",
        lastEntry().data.rise, (400 - 100) + (500 - 400) + (10000 - 500) + 150)
    before = before + 1
    fixtures.setWidgets(1, { { widgetID = 555, widgetType = Enum.UIWidgetVisualizationType.StatusBar,
        info = { barValue = 2100, barMax = 3000, text = "Score" } } })
    I.OnEvent(nil, "UPDATE_UI_WIDGET", { widgetID = 555, widgetSetID = 1,
        widgetType = Enum.UIWidgetVisualizationType.StatusBar })
    assertEqual("other widgets are not throttled", #entries(), before + 4)

    -- A handler bug is logged, never thrown.
    local savedGetInfo = C_QuestLog.GetNumQuestLogEntries
    C_QuestLog.GetNumQuestLogEntries = function() error("renamed API") end
    okEvent = pcall(I.OnEvent, nil, "QUEST_LOG_UPDATE")
    check("a failing quest API never throws out of the event handler", okEvent)
    C_QuestLog.GetNumQuestLogEntries = savedGetInfo

    -- snap summary.
    local okSnap, errSnap, lines = capture(Probe.HandleCommand, "snap")
    check("snap does not error", okSnap, tostring(errSnap))
    check("snap summary names the weekly quest", anyLineHas(lines, "90001"))
    check("snap summary points at the SavedVariables file",
        anyLineHas(lines, "WTF/Account/<ACCOUNT>/SavedVariables/AbundanceTally.lua"))
    check("snap summary stays short", #lines <= 7, tostring(#lines))

    -- The real Record path trims at the cap.
    local savedCap = I.MAX_ENTRIES
    I.MAX_ENTRIES = 5
    for index = 1, 10 do
        I.OnEvent(nil, "CHAT_MSG_MONSTER_SAY", "Dundun line " .. index, "Dundun")
    end
    assertEqual("the saved log is trimmed at the cap", #entries(), 5)
    assertEqual("...keeping the newest entry", lastEntry().data.text, "Dundun line 10")
    check("...and counting the dropped ones", AbundanceTallyDB.probe.dropped > 0)
    I.MAX_ENTRIES = savedCap

    capture(Probe.HandleCommand, "stop")
    assertEqual("stop clears enabled", AbundanceTallyDB.probe.enabled, false)
    before = #entries()
    I.OnEvent(nil, "CHAT_MSG_MONSTER_SAY", "Dundun again", "Dundun")
    assertEqual("events are ignored while stopped", #entries(), before)
    capture(Probe.HandleCommand, "snap")
    assertEqual("snap still records while stopped", #entries(), before + 1)

    local function containsSecret(value, depth)
        if rawequal(value, SECRET) then
            return true
        end
        if type(value) == "table" and depth < 12 then
            for key, inner in pairs(value) do
                if rawequal(key, SECRET) or containsSecret(inner, depth + 1) then
                    return true
                end
            end
        end
        return false
    end
    check("no raw secret value ever reached the saved log", not containsSecret(AbundanceTallyDB, 0))
    check("the log holds snapshots and event entries alike", countKind("snapshot") >= 1 and countKind("chat") >= 1)

    capture(Probe.HandleCommand, "clear")
    assertEqual("clear empties the log", #entries(), 0)
    assertEqual("clear keeps the weekly guess", AbundanceTallyDB.probe.weeklyQuestID, 90001)

    capture(Probe.HandleCommand, "quest 12345")
    assertEqual("quest <id> pins the weekly questID", AbundanceTallyDB.probe.pinnedQuestID, 12345)
    capture(Probe.HandleCommand, "quest off")
    assertEqual("quest off unpins it", AbundanceTallyDB.probe.pinnedQuestID, nil)

    -- Recording resumes after a reload: a fresh session sees enabled = true.
    capture(Probe.HandleCommand, "start")
    I.state.lastSeen = {}
    Probe.OnAddonLoaded()
    assertEqual("a reload while recording logs a session entry", lastEntry().kind, "session")
end

print(string.format("%d checks, %d failure(s)", count, failures))
if failures > 0 then
    os.exit(1)
end
