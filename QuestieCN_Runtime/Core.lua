-- QuestieCN_Runtime / Core.lua
--
-- Runtime Chinese completion for QuestieDB on the official zhCN "Forever" client.
--
-- QuestieDB ships a zhCN localization column block, but the quests/items/NPCs added by
-- Forever have no entry in it, so Questie shows English. This addon never translates
-- anything: it only reads text the client itself already has in Chinese and injects it
-- through QuestieDB's public localization-correction API. Everything learned is kept in
-- SavedVariables so the next login starts with Chinese already in place.
--
-- Official Chinese sources used, in order of reliability:
--   1. C_QuestLog (quest log / HaveQuestData / GetTitleForQuestID / GetQuestObjectives)
--      Calling GetQuestObjectives(id) makes the client prefetch that quest's server-side
--      localized data, exactly like Questie's own QuestLinks/ChatFilter.lua does.
--   2. C_TooltipInfo.GetHyperlink("quest:<id>:0") for the native Chinese quest title.
--   3. C_Item.GetItemNameByID / native item tooltips for item names.
--   4. Native unit tooltips (GUID -> NPC id) for NPC names.
--   5. C_Map.GetAreaInfo(areaID) for zone/area names shown by Questie's UI.
--
-- Anything the client cannot supply stays untouched (English). No guessing, no machine
-- translation, no edits to Questie or QuestieDB files.

local ADDON, ns = ...
local Gaps = ns.Gaps
-- Optional static supplement for quest ids the client refuses to serve.
-- Injected at read time only: it never overwrites text learned from the client,
-- and deleting Static.lua removes it without touching the SavedVariables cache.
local StaticQuests = (ns.Static and ns.Static.quests) or {}

local OWNER = "QuestieCN_Runtime"
local LOCALE = "zhCN"
local SAVED_VAR = "QuestieCN_RuntimeDB"

local QDB, SetCorrection
local QuestKeys, ItemKeys, NpcKeys, ObjectKeys
local db, learned
local dirty = {}
local started, paused = false, false
local ticker
local questQueue, questIndex, inflight
local itemQueue, itemIndex
local frame

local stats = {
    requested = 0,
    learnedQuest = 0,
    learnedItem = 0,
    learnedNpc = 0,
    zones = 0,
    setError = false,
}

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function hasCJK(value)
    if type(value) ~= "string" then return false end
    local i, n = 1, #value
    while i <= n - 2 do
        local b1, b2, b3 = value:byte(i, i + 2)
        if b1 >= 0xE4 and b1 <= 0xE9 and b2 >= 0x80 and b2 <= 0xBF
            and b3 >= 0x80 and b3 <= 0xBF then
            return true
        end
        i = i + 1
    end
    return false
end

local function isSecret(value)
    return type(_G.issecretvalue) == "function" and _G.issecretvalue(value)
end

-- Only accept a real, localized (Chinese) string. English text is never cached as a
-- "translation", which is the whole point of this addon.
local function clean(value)
    if type(value) ~= "string" or value == "" or isSecret(value) then return nil end
    if not hasCJK(value) then return nil end
    return value
end

-- pcall wrapper returning the first result only.
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, first = pcall(fn, ...)
    if ok then return first end
    return nil
end

local function areaName(areaID)
    if C_Map and type(C_Map.GetAreaInfo) == "function" then
        return call(C_Map.GetAreaInfo, areaID)
    end
    if type(_G.GetAreaInfo) == "function" then
        return call(_G.GetAreaInfo, areaID)
    end
    return nil
end

local function countKeys(t)
    local n = 0
    if type(t) == "table" then
        for _ in pairs(t) do n = n + 1 end
    end
    return n
end

local function printMsg(text)
    print("|cff46bf72QuestieCN|r " .. tostring(text))
end

--------------------------------------------------------------------------------
-- Saved variables / learned cache
--------------------------------------------------------------------------------

local function initDB()
    local saved = _G[SAVED_VAR]
    if type(saved) ~= "table" then
        saved = {}
        _G[SAVED_VAR] = saved
    end
    saved.version = 1
    if type(saved.quest) ~= "table" then saved.quest = {} end
    if type(saved.item) ~= "table" then saved.item = {} end
    if type(saved.npc) ~= "table" then saved.npc = {} end
    if type(saved.object) ~= "table" then saved.object = {} end
    if type(saved.zones) ~= "table" then saved.zones = {} end
    if type(saved.failed) ~= "table" then saved.failed = {} end
    if type(saved.unavailable) ~= "table" then saved.unavailable = {} end
    -- Timeouts are per-session: a slow login must not blacklist a quest forever.
    for id in pairs(saved.failed) do saved.failed[id] = nil end
    if saved.enabled == nil then saved.enabled = true end
    if saved.learnItems == nil then saved.learnItems = true end
    db = saved
    learned = {
        quest = saved.quest,
        item = saved.item,
        npc = saved.npc,
        object = saved.object,
    }
    for _, datatype in ipairs({ "Quest", "Item", "Npc", "Object" }) do
        dirty[datatype] = true
    end
end

--------------------------------------------------------------------------------
-- Inject learned text into QuestieDB (l10n outranks entity corrections)
--------------------------------------------------------------------------------

local function buildRows(datatype)
    local rows = {}
    if datatype == "Quest" then
        for id, data in pairs(learned.quest) do
            if type(data) == "table" then
                local row = {}
                if type(data.name) == "string" and data.name ~= "" then
                    row[QuestKeys.name] = data.name
                end
                if type(data.objectives) == "table" and #data.objectives > 0 then
                    local list = {}
                    for i = 1, #data.objectives do
                        local text = data.objectives[i]
                        if type(text) == "string" and text ~= "" then
                            list[#list + 1] = text
                        end
                    end
                    if #list > 0 then row[QuestKeys.objectivesText] = list end
                end
                if next(row) then rows[id] = row end
            end
        end
        for id, data in pairs(StaticQuests) do
            local row = rows[id] or {}
            if not row[QuestKeys.name] and type(data.name) == "string" and data.name ~= "" then
                row[QuestKeys.name] = data.name
            end
            if not row[QuestKeys.objectivesText] and type(data.objectives) == "table" then
                local list = {}
                for i = 1, #data.objectives do
                    local text = data.objectives[i]
                    if type(text) == "string" and text ~= "" then list[#list + 1] = text end
                end
                if #list > 0 then row[QuestKeys.objectivesText] = list end
            end
            if next(row) then rows[id] = row end
        end
    elseif datatype == "Item" then
        for id, name in pairs(learned.item) do
            if type(name) == "string" and name ~= "" then
                rows[id] = { [ItemKeys.name] = name }
            end
        end
    elseif datatype == "Npc" then
        for id, name in pairs(learned.npc) do
            if type(name) == "string" and name ~= "" then
                rows[id] = { [NpcKeys.name] = name }
            end
        end
    elseif datatype == "Object" then
        for id, name in pairs(learned.object) do
            if type(name) == "string" and name ~= "" then
                rows[id] = { [ObjectKeys.name] = name }
            end
        end
    end
    return rows
end

local lastFlush = 0

local function flush(force)
    if not SetCorrection or not started then return end
    local now = GetTime()
    if not force and now - lastFlush < 1.5 then return end
    lastFlush = now
    for _, datatype in ipairs({ "Quest", "Item", "Npc", "Object" }) do
        if dirty[datatype] then
            local rows = buildRows(datatype)
            local ok, err = pcall(SetCorrection, OWNER, LOCALE, datatype, "Runtime",
                next(rows) and rows or nil)
            if ok then
                dirty[datatype] = false
            else
                dirty[datatype] = true
                if not stats.setError then
                    stats.setError = true
                    printMsg("写入 QuestieDB 失败：" .. tostring(err))
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Learning
--------------------------------------------------------------------------------

local function learnQuest(id, name, objectives)
    local rec = learned.quest[id]
    local changed = false

    local zhName = clean(name)
    if zhName and (not rec or rec.name ~= zhName) then
        if not rec then rec = {}; learned.quest[id] = rec end
        rec.name = zhName
        changed = true
        stats.learnedQuest = stats.learnedQuest + 1
        db.failed[id] = nil
        db.unavailable[id] = nil
    end

    if type(objectives) == "table" then
        local list, seen = {}, {}
        for i = 1, #objectives do
            local entry = objectives[i]
            local raw = type(entry) == "table" and entry.text or entry
            local zh = clean(raw)
            if zh and not seen[zh] then
                seen[zh] = true
                list[#list + 1] = zh
            end
        end
        if #list > 0 then
            local same = rec and type(rec.objectives) == "table" and #rec.objectives == #list
            if same then
                for i = 1, #list do
                    if rec.objectives[i] ~= list[i] then same = false; break end
                end
            end
            if not same then
                if not rec then rec = {}; learned.quest[id] = rec end
                rec.objectives = list
                changed = true
            end
        end
    end

    if changed then dirty.Quest = true end
    return changed
end

local function learnSimple(kind, datatype, id, name)
    local zh = clean(name)
    if not zh then return end
    if learned[kind][id] == zh then return end
    learned[kind][id] = zh
    dirty[datatype] = true
    if kind == "item" then
        stats.learnedItem = stats.learnedItem + 1
    elseif kind == "npc" then
        stats.learnedNpc = stats.learnedNpc + 1
    end
end

-- Read whatever the client has cached for this quest. Returns true once the official
-- Chinese text was actually obtained.
local function readQuest(id)
    local have = true
    if type(_G.HaveQuestData) == "function" then
        local ok, result = pcall(_G.HaveQuestData, id)
        have = ok and result
    end
    if not have then return false end

    local name, objectives
    if C_QuestLog then
        if type(C_QuestLog.GetTitleForQuestID) == "function" then
            name = call(C_QuestLog.GetTitleForQuestID, id)
        end
        if not clean(name) and type(C_QuestLog.GetQuestInfo) == "function" then
            name = call(C_QuestLog.GetQuestInfo, id)
        end
        if type(C_QuestLog.GetQuestObjectives) == "function" then
            objectives = call(C_QuestLog.GetQuestObjectives, id)
        end
    end
    learnQuest(id, name, objectives)
    local rec = learned.quest[id]
    -- Objectives alone are still official Chinese and worth keeping.
    return rec ~= nil and (rec.name ~= nil or rec.objectives ~= nil)
end

-- Fallback source: the native quest hyperlink tooltip carries the localized title.
local function readQuestTooltip(id)
    if not (C_TooltipInfo and type(C_TooltipInfo.GetHyperlink) == "function") then return end
    local info = call(C_TooltipInfo.GetHyperlink, "quest:" .. tostring(id) .. ":0")
    if type(info) ~= "table" or type(info.lines) ~= "table" then return end
    local lineTypes = _G.Enum and _G.Enum.TooltipDataLineType
    local titleType = lineTypes and lineTypes.QuestTitle
    local objectiveType = lineTypes and lineTypes.QuestObjective
    local first, title, objectives = nil, nil, {}
    for i = 1, #info.lines do
        local line = info.lines[i]
        if type(line) == "table" then
            local zh = clean(line.leftText)
            if zh then
                if titleType and line.type == titleType then
                    title = zh
                elseif objectiveType and line.type == objectiveType then
                    objectives[#objectives + 1] = zh
                elseif not first and i == 1 then
                    first = zh
                end
            end
        end
    end
    title = title or first
    if title or #objectives > 0 then
        learnQuest(id, title, #objectives > 0 and objectives or nil)
    end
end

-- Quest log is the most reliable source: accepted quests always carry official Chinese.
local function scanQuestLog()
    if not (C_QuestLog and type(C_QuestLog.GetNumQuestLogEntries) == "function") then return end
    local count = call(C_QuestLog.GetNumQuestLogEntries) or 0
    if type(count) ~= "number" then return end
    for i = 1, count do
        local info = call(C_QuestLog.GetInfo, i)
        if type(info) == "table" and not isSecret(info) and type(info.questID) == "number" then
            local objectives
            if type(C_QuestLog.GetQuestObjectives) == "function" then
                objectives = call(C_QuestLog.GetQuestObjectives, info.questID)
            end
            learnQuest(info.questID, info.title, objectives)
        end
    end
end

-- Native tooltip observation: learns NPC and item names the client itself renders.
local function installTooltipHooks()
    local processor = _G.TooltipDataProcessor
    local types = _G.Enum and _G.Enum.TooltipDataType
    if not (type(processor) == "table" and type(processor.AddTooltipPostCall) == "function"
        and type(types) == "table") then return end

    if types.Unit then
        pcall(processor.AddTooltipPostCall, types.Unit, function(_, data)
            if type(data) ~= "table" or type(data.guid) ~= "string" then return end
            -- Unit GUID: "Creature-0-2083-0-1-<npcId>-0000000000"
            local id = tonumber(data.guid:match("^[^%-]+%-[^%-]+%-[^%-]+%-[^%-]+%-[^%-]+%-(%d+)"))
            if not id or type(data.lines) ~= "table" then return end
            local first = data.lines[1]
            if type(first) == "table" then
                learnSimple("npc", "Npc", id, first.leftText)
            end
        end)
    end

    local function observeNamed(typeKey, kind, datatype)
        if not typeKey then return end
        pcall(processor.AddTooltipPostCall, typeKey, function(_, data)
            if type(data) ~= "table" or type(data.lines) ~= "table" then return end
            local id = type(data.id) == "number" and data.id or nil
            if not id and type(data.hyperlink) == "string" then
                id = tonumber(data.hyperlink:match("%a+:(%d+)"))
            end
            if not id and type(data.guid) == "string" then
                id = tonumber(data.guid:match("^[^%-]+%-[^%-]+%-[^%-]+%-[^%-]+%-[^%-]+%-(%d+)"))
            end
            if not id then return end
            local first = data.lines[1]
            if type(first) == "table" then
                learnSimple(kind, datatype, id, first.leftText)
            end
        end)
    end

    observeNamed(types.Item, "item", "Item")
    -- Some clients expose game-object tooltips as GameObject, others as Object.
    observeNamed(types.GameObject or types.Object, "object", "Object")
end

-- Questie stores English area names in l10n.zoneLookup and uses them for tooltips,
-- the tracker and the Journey. The client's own AreaTable data is localized.
local function applyZones(useAPI)
    if useAPI == nil then useAPI = true end
    local loader = _G.QuestieLoader
    if not (loader and type(loader.ImportModule) == "function") then return false end
    local ok, l10n = pcall(loader.ImportModule, loader, "l10n")
    if not ok or type(l10n) ~= "table" or type(l10n.zoneLookup) ~= "table" then return false end

    local count = 0
    local function replace(container)
        if type(container) ~= "table" then return end
        for areaId, oldName in pairs(container) do
            if type(areaId) == "number" then
                local zh = clean(db.zones[areaId])
                if not zh and useAPI then
                    zh = clean(areaName(areaId))
                    if zh then db.zones[areaId] = zh end
                end
                if zh then
                    container[areaId] = zh
                    count = count + 1
                end
            end
        end
    end

    for _, zones in pairs(l10n.zoneLookup) do replace(zones) end
    if type(l10n.zoneCategoryLookup) == "table" then
        for _, zones in pairs(l10n.zoneCategoryLookup) do replace(zones) end
    end
    stats.zones = count
    return true
end

--------------------------------------------------------------------------------
-- Queues: ids that still have no Chinese in QuestieDB
--------------------------------------------------------------------------------

local function staticHas(st, field)
    if not st then return false end
    if field == "name" then return type(st.name) == "string" and st.name ~= "" end
    return type(st.objectives) == "table" and #st.objectives > 0
end

local function buildQueues()
    questQueue, questIndex, inflight = {}, 1, {}
    for id, mask in pairs(Gaps.quests) do
        local rec = learned.quest[id]
        local st = StaticQuests[id]
        local needName = (mask == 1 or mask == 3) and not (rec and rec.name)
            and not staticHas(st, "name")
        local needObjectives = mask >= 2 and not (rec and rec.objectives)
            and not staticHas(st, "objectives")
        local failed = db.failed[id] or 0
        -- "unavailable" = the client explicitly refused the data (server-side Deny).
        -- "/qcn scan" clears that flag when a forced retry is wanted.
        if (needName or needObjectives) and failed < 3 and not db.unavailable[id] then
            questQueue[#questQueue + 1] = id
        end
    end
    -- Forever's new quests (high ids) are the ones the user actually sees in English.
    table.sort(questQueue, function(a, b) return a > b end)

    itemQueue, itemIndex = {}, 1
    if db.learnItems then
        for id in pairs(Gaps.items) do
            if not learned.item[id] then itemQueue[#itemQueue + 1] = id end
        end
        table.sort(itemQueue, function(a, b) return a > b end)
    end
end

-- One tick: collect prefetched quest data, request a few more, scan a few item names.
local QUEST_BATCH, ITEM_BATCH, MAX_INFLIGHT, TIMEOUT = 4, 20, 12, 30

local function tickQuest()
    local now = GetTime()
    local inFlightCount = 0
    for id, requestedAt in pairs(inflight) do
        inFlightCount = inFlightCount + 1
        local ready = readQuest(id)
        if not ready and now - requestedAt > 5 and now - requestedAt < 5.6 then
            readQuestTooltip(id)
        end
        if ready or now - requestedAt > TIMEOUT then
            inflight[id] = nil
            inFlightCount = inFlightCount - 1
            if not ready then
                db.failed[id] = (db.failed[id] or 0) + 1
            end
        end
    end

    if not C_QuestLog or type(C_QuestLog.GetQuestObjectives) ~= "function" then return end
    local budget = math.min(QUEST_BATCH, MAX_INFLIGHT - inFlightCount)
    while budget > 0 and questIndex <= #questQueue do
        local id = questQueue[questIndex]
        questIndex = questIndex + 1
        -- Prefetch: Questie's own ChatFilter does exactly this for linked quests.
        pcall(C_QuestLog.GetQuestObjectives, id)
        readQuestTooltip(id)
        inflight[id] = now
        stats.requested = stats.requested + 1
        budget = budget - 1
    end
end

local function tickItem()
    if not db.learnItems then return end
    if not (C_Item and type(C_Item.GetItemNameByID) == "function") then return end
    local budget = ITEM_BATCH
    while budget > 0 and itemIndex <= #itemQueue do
        local id = itemQueue[itemIndex]
        itemIndex = itemIndex + 1
        learnSimple("item", "Item", id, call(C_Item.GetItemNameByID, id))
        budget = budget - 1
    end
end

local function tick()
    if paused or not db.enabled or not started then return end
    tickQuest()
    tickItem()
    flush()
end

local function startTicker()
    if ticker then return end
    if C_Timer and type(C_Timer.NewTicker) == "function" then
        ticker = C_Timer.NewTicker(0.5, tick)
    elseif frame then
        local elapsed = 0
        frame:SetScript("OnUpdate", function(_, delta)
            elapsed = elapsed + delta
            if elapsed >= 0.5 then elapsed = 0; tick() end
        end)
    end
end

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

local function localeOK()
    local loc = (type(GetLocale) == "function" and GetLocale()) or ""
    return loc == "zhCN" or _G.DF_CN_FORCE_ACTIVE == true
end

local function tryInit()
    if started or not db then return end
    if not localeOK() then return end

    QDB = _G.LibQuestieDB
    if type(QDB) ~= "table" or type(QDB.l10n) ~= "table"
        or type(QDB.l10n.SetCorrection) ~= "function" then
        return
    end
    local Meta = QDB.Meta
    if type(Meta) ~= "table" then return end
    if not (Meta.Quest and Meta.Quest.keys and Meta.Item and Meta.Item.keys
        and Meta.Npc and Meta.Npc.keys and Meta.Object and Meta.Object.keys) then
        return
    end

    SetCorrection = QDB.l10n.SetCorrection
    QuestKeys, ItemKeys = Meta.Quest.keys, Meta.Item.keys
    NpcKeys, ObjectKeys = Meta.Npc.keys, Meta.Object.keys
    started = true

    flush(true)           -- cached Chinese from previous sessions applies immediately
    buildQueues()
    installTooltipHooks()
    applyZones(false)     -- restore cached area names without a login-time AreaTable sweep
    scanQuestLog()
    startTicker()

    printMsg(string.format(
        "已启用：待补全任务 %d / 物品 %d；已有中文缓存 任务 %d、物品 %d、NPC %d、区域 %d。输入 /qcn 查看进度。",
        #questQueue, #itemQueue, countKeys(db.quest), countKeys(db.item),
        countKeys(db.npc), countKeys(db.zones)))
end

frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_DATA_LOAD_RESULT")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if select(1, ...) ~= ADDON then return end
        initDB()
        self:UnregisterEvent("ADDON_LOADED")
        tryInit()
    elseif event == "PLAYER_LOGIN" then
        tryInit()
        if started then
            scanQuestLog()
            if C_Timer and type(C_Timer.After) == "function" then
                C_Timer.After(0.5, function()
                    if started then applyZones(true) end
                end)
            else
                applyZones(true)
            end
        end
    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_ACCEPTED" then
        if started then scanQuestLog() end
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        local id, success = ...
        if started and type(id) == "number" and inflight and inflight[id] then
            if success == false then
                -- The server refused this quest id. Remember it so /qcn missing can
                -- tell "no official data exists" apart from "not learned yet".
                db.unavailable[id] = true
                db.failed[id] = (db.failed[id] or 0) + 1
                inflight[id] = nil
            elseif readQuest(id) then
                inflight[id] = nil
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

SLASH_QUESTIECN1 = "/qcn"
SlashCmdList.QUESTIECN = function(input)
    local cmd = tostring(input or ""):lower():match("^%s*(.-)%s*$")
    if cmd == "pause" then
        paused = true
        printMsg("已暂停后台学习（已缓存的中文仍然生效）。")
    elseif cmd == "resume" then
        paused = false
        printMsg("已恢复后台学习。")
    elseif cmd == "zones" then
        if started and applyZones() then
            printMsg("已用客户端官方区域名刷新 " .. stats.zones .. " 个区域。")
        else
            printMsg("区域表尚不可用，请登录后重试。")
        end
    elseif cmd == "scan" then
        if started then
            -- Forced retry: forget both per-session timeouts and explicit refusals.
            for k in pairs(db.failed) do db.failed[k] = nil end
            for k in pairs(db.unavailable) do db.unavailable[k] = nil end
            buildQueues()
            printMsg("已清空拒绝记录并重建队列：任务 " .. #questQueue .. " / 物品 " .. #itemQueue .. "。")
        end
    elseif cmd == "missing" then
        if not started then printMsg("尚未启动。"); return end
        local noData, pending, nameOnly = {}, {}, {}
        for id, mask in pairs(Gaps.quests) do
            local rec = learned.quest[id]
            local st = StaticQuests[id]
            local needName = (mask == 1 or mask == 3) and not (rec and rec.name)
                and not staticHas(st, "name")
            local needObjectives = mask >= 2 and not (rec and rec.objectives)
                and not staticHas(st, "objectives")
            if needName then
                if db.unavailable[id] then noData[#noData + 1] = id
                else pending[#pending + 1] = id end
            elseif needObjectives then
                nameOnly[#nameOnly + 1] = id
            end
        end
        local function describe(list)
            table.sort(list, function(a, b) return a > b end)
            local head = {}
            for i = 1, math.min(20, #list) do head[#head + 1] = tostring(list[i]) end
            return table.concat(head, " "), list
        end
        local a, la = describe(noData)
        local b, lb = describe(pending)
        local _, lc = describe(nameOnly)
        printMsg("客户端查不到（服务端拒绝）：" .. #la .. " 个 | " .. a)
        printMsg("待重试或尚未请求：" .. #lb .. " 个 | " .. b)
        printMsg("仅任务名已中文、目标文本仍英文：" .. #lc .. " 个")
        db.missingReport = { noData = la, pending = lb, nameOnly = lc }
        printMsg("完整清单已存入 QuestieCN_RuntimeDB.missingReport（/reload 后写入存档）。")
        printMsg("个别提示仍是英文时先 /reload 重建 Questie 缓存；仍英文即客户端无该任务数据。")
    elseif cmd == "reset" then
        if not db then return end
        for _, t in ipairs({ db.quest, db.item, db.npc, db.object, db.failed, db.unavailable }) do
            for k in pairs(t) do t[k] = nil end
        end
        db.missingReport = nil
        printMsg("已清空学习缓存，输入 /reload 后重新学习。")
    else
        local s = Gaps.stats
        printMsg(string.format(
            "状态：%s | 本轮请求 %d | 新学 任务 %d 物品 %d NPC %d | 区域中文 %d",
            paused and "已暂停" or "运行中", stats.requested,
            stats.learnedQuest, stats.learnedItem, stats.learnedNpc, stats.zones))
        printMsg(string.format(
            "QuestieDB 原有缺口：任务名 %d / 目标文本 %d / 物品名 %d / NPC 名 %d。剩余队列：任务 %d / 物品 %d。",
            s.questNames, s.questObjectives, s.itemNames, s.npcNames,
            started and math.max(0, #questQueue - questIndex + 1) or 0,
            started and math.max(0, #itemQueue - itemIndex + 1) or 0))
        printMsg(string.format(
            "客户端明确拒绝：%d 个任务；静态补表：%d 条（%s）。/qcn missing 看清单，/qcn scan 强制重试。",
            countKeys(db.unavailable), countKeys(StaticQuests),
            (ns.Static and ns.Static.source) or "无"))
        printMsg("命令：/qcn missing | pause | resume | scan | zones | reset")
    end
end
