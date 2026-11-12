"""Offline smoke test for the QuestieCN_Runtime addon using a mock WoW environment.

Compiles both Lua files and drives ADDON_LOADED / PLAYER_LOGIN / several ticks,
checking that official-style Chinese text is injected through l10n.SetCorrection.
"""
import lupa

ADDON_DIR = r"D:/World of Warcraft/_forever_/Interface/AddOns/QuestieCN_Runtime"

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()

log = []
g.print = lambda *parts: log.append(" ".join(str(p) for p in parts))

lua.execute(r"""
    SlashCmdList = {}
    _test = { corrections = {}, ticks = {}, after = {}, events = {}, requested = {}, areaCalls = 0 }

    unpack = table.unpack
    strsplit = function(delim, s)
        local out, n = {}, 0
        for part in string.gmatch(s, "([^" .. delim .. "]+)") do
            n = n + 1; out[n] = part
        end
        return unpack(out, 1, n)
    end

    issecretvalue = function() return false end
    GetLocale = function() return "zhCN" end
    _test_time = 0
    GetTime = function() return _test_time end
    HaveQuestData = function(id) return _test.requested[id] ~= nil end

    CreateFrame = function()
        local f = {}
        function f:RegisterEvent(e) _test.events[e] = true end
        function f:UnregisterEvent(e) _test.events[e] = nil end
        function f:SetScript(kind, handler)
            if kind == "OnEvent" then _test.onEvent = handler end
            if kind == "OnUpdate" then _test.onUpdate = handler end
        end
        _test.frame = f
        return f
    end

    LibQuestieDB = {
        Meta = {
            Quest = { keys = { name = 1, objectivesText = 8 } },
            Item  = { keys = { name = 1 } },
            Npc   = { keys = { name = 1, subName = 14 } },
            Object= { keys = { name = 1 } },
        },
        l10n = {},
    }
    -- Mirror the real SetCorrection validation closely enough to catch malformed rows.
    function LibQuestieDB.l10n.SetCorrection(owner, locale, datatype, name, rows)
        assert(owner == "QuestieCN_Runtime", "owner")
        assert(locale == "zhCN", "locale")
        assert(datatype == "Quest" or datatype == "Item" or datatype == "Npc" or datatype == "Object", "datatype")
        if rows == nil then
            _test.corrections[datatype] = 0
            return true
        end
        assert(type(rows) == "table")
        local count = 0
        for id, fields in pairs(rows) do
            assert(type(id) == "number" and id > 0)
            assert(type(fields) == "table")
            for key, value in pairs(fields) do
                if datatype == "Quest" and key == 8 and type(value) == "table" then
                    _test.withObjectives = (_test.withObjectives or 0) + 1
                end
                if type(value) == "string" then
                    assert(value ~= "")
                else
                    assert(type(value) == "table" and #value > 0)
                    for i = 1, #value do
                        assert(type(value[i]) == "string" and value[i] ~= "")
                    end
                end
            end
            count = count + 1
            _test.lastRow = { datatype = datatype, id = id, fields = fields }
        end
        _test.corrections[datatype] = count
        if datatype == "Quest" and rows and rows[93928] then _test.staticSeen = true end
        return true
    end

    C_QuestLog = {
        GetNumQuestLogEntries = function() return 2 end,
        GetInfo = function(i)
            if i == 1 then return { questID = 90702, title = "坟墓的秘密" } end
            if i == 2 then return { questID = 96393, title = "谅解条约" } end
        end,
        GetTitleForQuestID = function(id) return "官方任务名" .. id end,
        GetQuestInfo = function(id) return "官方任务名" .. id end,
        GetQuestObjectives = function(id)
            _test.requested[id] = true
            return { { text = "消灭 10 只测试怪物" }, { text = "找回失物" } }
        end,
    }

    C_TooltipInfo = {
        GetHyperlink = function(link)
            local id = link:match("quest:(%d+)")
            return { lines = {
                { leftText = "链接任务中文" .. (id or "?"), type = 10 },
                { leftText = "官方中文目标一", type = 11 },
                { leftText = "官方中文目标二", type = 11 },
            } }
        end,
    }

    C_Item = {
        GetItemNameByID = function(id)
            if id % 3 == 0 then return "官方物品名" .. id end
            return nil
        end,
    }

    C_Map = {
        GetAreaInfo = function(id)
            _test.areaCalls = _test.areaCalls + 1
            return "官方区域" .. id
        end,
    }

    C_Timer = {
        NewTicker = function(_, fn) table.insert(_test.ticks, fn); return {} end,
        After = function(_, fn) table.insert(_test.after, fn) end,
    }

    Enum = {
        TooltipDataType = { Unit = 1, Item = 2, GameObject = 3 },
        TooltipDataLineType = { QuestTitle = 10, QuestObjective = 11 },
    }
    TooltipDataProcessor = {
        AddTooltipPostCall = function(kind, fn)
            _test["tooltip" .. kind] = fn
        end,
    }

    QuestieLoader = {}
    function QuestieLoader:ImportModule(name)
        if name ~= "l10n" then return nil end
        return {
            zoneLookup = {
                [0] = { [1] = "Dun Morogh", [12] = "Elwynn Forest" },
                [1] = { [17] = "The Barrens" },
            },
            zoneCategoryLookup = { [9] = { [206] = "Utgarde Keep" } },
        }
    end
""")


def load_file(path, addon="QuestieCN_Runtime", ns=None):
    code = open(path, encoding="utf-8").read()
    fn = lua.eval("function(code, name) return load(code, name) end")(code, path.rsplit("/", 1)[-1])
    if ns is None:
        ns = lua.table()
    fn(addon, ns)
    return ns


ns = lua.table()
load_file(ADDON_DIR + "/Gaps.lua", ns=ns)
print("Gaps.lua compiled; stats:", dict(ns.Gaps.stats))
load_file(ADDON_DIR + "/Static.lua", ns=ns)
print("Static.lua compiled; entries:", len(list(ns.Static.quests.keys())))
load_file(ADDON_DIR + "/Core.lua", ns=ns)
print("Core.lua compiled")

t = g._test
print("registered events:", sorted(t.events.keys()))
assert t.onEvent is not None

# Fire the lifecycle
t.onEvent(t.frame, "ADDON_LOADED", "SomeOtherAddon")
t.onEvent(t.frame, "ADDON_LOADED", "QuestieCN_Runtime")
t.onEvent(t.frame, "PLAYER_LOGIN")
for i in range(1, len(t.after) + 1):
    t.after[i]()
print("after login, corrections:", dict(t.corrections))
print("startup messages:", log[:3])

# Drive several ticks
for i in range(12):
    g._test_time = g._test_time + 0.5
    for j in range(1, len(t.ticks) + 1):
        t.ticks[j]()
print("after ticks, corrections:", dict(t.corrections))
print("area calls:", t.areaCalls)

# Tooltip learning paths
if t.tooltip1:
    unit_data = lua.eval(
        'function() return { guid = "Creature-0-1-0-0-123456-0000000000",'
        ' lines = { { leftText = "测试中文NPC" } } } end')()
    t.tooltip1(None, unit_data)
if t.tooltip2:
    item_data = lua.eval(
        'function() return { id = 99999, lines = { { leftText = "测试中文物品" } } } end')()
    t.tooltip2(None, item_data)
if t.tooltip3:
    object_data = lua.eval(
        'function() return { id = 77777, lines = { { leftText = "测试中文物件" } } } end')()
    t.tooltip3(None, object_data)
g._test_time = g._test_time + 2   # let the 1.5s injection throttle elapse
for j in range(1, len(t.ticks) + 1):
    t.ticks[j]()
print("after tooltip hooks, corrections:", dict(t.corrections))

# Slash commands + explicit server refusal (QUEST_DATA_LOAD_RESULT success=false)
g.SlashCmdList.QUESTIECN("")
g.SlashCmdList.QUESTIECN("pause")
g.SlashCmdList.QUESTIECN("resume")
for qid in list(g._test.requested.keys()):
    t.onEvent(t.frame, "QUEST_DATA_LOAD_RESULT", qid, False)
unavailable = list(g.QuestieCN_RuntimeDB.unavailable.keys())
print("server-refused ids recorded:", len(unavailable))
assert len(unavailable) > 0, "explicit refusals were not recorded"
g.SlashCmdList.QUESTIECN("missing")
assert g.QuestieCN_RuntimeDB.missingReport is not None, "missingReport not written"
print("missingReport noData:", len(list(g.QuestieCN_RuntimeDB.missingReport.noData.keys())))
g.SlashCmdList.QUESTIECN("scan")
assert len(list(g.QuestieCN_RuntimeDB.unavailable.keys())) == 0, "scan did not clear refusals"
assert (t.withObjectives or 0) > 0, "objective lines from native tooltip were not learned"

saved = g.QuestieCN_RuntimeDB
print("saved quest entries:", len([k for k in saved.quest.keys()]))

assert t.staticSeen, "static supplement was not injected"
assert t.corrections["Quest"] > 0, "no quest translations were injected"
assert t.corrections["Item"] > 0, "no item translations were injected"
assert t.corrections["Npc"] > 0, "no npc translations were injected"
assert t.areaCalls > 0, "area names were not queried"

# Second login: the SavedVariables cache must apply immediately, before any tick.
lua.execute("_test.corrections = {}")
load_file(ADDON_DIR + "/Core.lua", ns=ns)
t.onEvent(t.frame, "ADDON_LOADED", "QuestieCN_Runtime")
t.onEvent(t.frame, "PLAYER_LOGIN")
print("second login, immediate corrections:", dict(t.corrections))
assert t.corrections["Quest"] > 0, "cached Chinese did not apply on next login"
assert t.corrections["Item"] > 0, "cached item names did not apply on next login"
print("\nSMOKE TEST PASSED")
