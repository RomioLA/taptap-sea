-- F1/F2: LocalSaveBackend + Persistence.Dual + Loop:SellAll + 返港引导 集成测试。
local Flow = require("tests.Circle1BFishingFlowTests")
local LocalSaveBackend = require("Gameplay.LocalSaveBackend")
local Persistence = require("Gameplay.Persistence")
local OceanConfig = require("Ocean.Config")

local Tests = {}

local function eq(actual, expected, label)
    Flow.AssertEqual(actual, expected, label)
end

local function items(actual, expected, label)
    Flow.AssertItems(actual, expected, label)
end

-- cjson 测试替身：同进程引用缓存；非 JSON: 前缀内容视为损坏数据。
local jsonCache, jsonNext = {}, 0
local fakeJson = {
    encode = function(value)
        jsonNext = jsonNext + 1
        jsonCache[jsonNext] = value
        return "JSON:" .. tostring(jsonNext)
    end,
    decode = function(text)
        if type(text) ~= "string" or text:sub(1, 5) ~= "JSON:" then
            return nil
        end
        local id = tonumber(text:sub(6))
        return id and jsonCache[id] or nil
    end,
}

-- 内存文件系统替身，模拟引擎 File / fileSystem 沙箱接口。
local function makeMemFs(options)
    options = options or {}
    local fs = { files = {}, failOpen = false }
    local function openFailed()
        return { IsOpen = function() return false end }
    end
    fs.File = function(path, mode)
        if fs.failOpen then return openFailed() end
        if mode == "write" then
            local file = { chunks = {} }
            function file:IsOpen() return true end
            function file:WriteString(text) file.chunks[#file.chunks + 1] = text end
            function file:Close() fs.files[path] = table.concat(file.chunks) end
            return file
        end
        local content = fs.files[path]
        if content == nil then return openFailed() end
        local file = { data = content }
        function file:IsOpen() return true end
        function file:ReadString() return self.data end
        function file:Close() end
        return file
    end
        fs.fileSystem = {
            -- 引擎以冒号调用（self, path）；替身签名必须带 self。
            FileExists = function(_, path) return fs.files[path] ~= nil end,
        }
    fs.corrupt = function(path) fs.files[path] = "GARBAGE_NOT_JSON" end
    return fs
end

local function memCloud()
    local cloud = { data = nil, unavailable = false, sets = 0 }
    local key = "sea_game_loop_v1"
    function cloud:Set(_, value, callbacks)
        if self.unavailable then callbacks.error("err", "unavailable") return true end
        self.sets = self.sets + 1
        self.data = value
        callbacks.ok({ [key] = value }, nil)
        return true
    end
    function cloud:Get(_, callbacks)
        if self.unavailable then callbacks.error("err", "unavailable") return true end
        local values = {}
        if self.data ~= nil then values[key] = self.data end
        callbacks.ok(values, nil)
        return true
    end
    return cloud
end

local function syncCall(fn)
    local results = { called = false, ok = nil, value = nil }
    fn(function(ok, value)
        results.called = true
        results.ok, results.value = ok, value
    end)
    return results
end

-- ============ LocalSaveBackend ============

function Tests.LocalSaveBackendRoundtrip()
    local fs = makeMemFs()
    local backend = LocalSaveBackend.New({ File = fs.File, fileSystem = fs.fileSystem, cjson = fakeJson })
    local snapshot = { day = 3, money = 250, inventory = { "sardine", "tuna" }, story = {} }
    local saved = syncCall(function(done) backend:Save(snapshot, done) end)
    eq(saved.called, true, "save callback fired")
    eq(saved.ok, true, "save ok")

    local loaded = syncCall(function(done) backend:Load(done) end)
    eq(loaded.ok, true, "load ok")
    eq(loaded.value.day, 3, "load day")
    eq(loaded.value.money, 250, "load money")
    items(loaded.value.inventory, { "sardine", "tuna" }, "load inventory")
end

function Tests.LocalSaveBackendEmptyAndCorrupt()
    local fs = makeMemFs()
    local backend = LocalSaveBackend.New({ File = fs.File, fileSystem = fs.fileSystem, cjson = fakeJson })

    local empty = syncCall(function(done) backend:Load(done) end)
    eq(empty.ok, true, "empty load ok")
    eq(empty.value, nil, "empty load has no data")

    fs.files["sea_loop_save.json"] = "GARBAGE_NOT_JSON"
    local corrupt = syncCall(function(done) backend:Load(done) end)
    eq(corrupt.ok, false, "corrupt load fails")
    eq(corrupt.value, "local_file_corrupt", "corrupt reason")

    fs.failOpen = true
    local blocked = syncCall(function(done) backend:Save({ day = 1 }, done) end)
    eq(blocked.ok, false, "open failure fails save")
    eq(blocked.value, "local_file_open_failed", "open failure reason")
end

function Tests.LocalSaveBackendAvailableProbe()
    local fs = makeMemFs()
    eq(LocalSaveBackend.Available({ File = fs.File, fileSystem = fs.fileSystem, cjson = fakeJson }),
        true, "available with injected deps")
    eq(LocalSaveBackend.Available({ fileSystem = fs.fileSystem, cjson = fakeJson }),
        false, "unavailable without File")
    eq(LocalSaveBackend.Available({ File = fs.File, fileSystem = fs.fileSystem }),
        false, "unavailable without cjson")
end

-- ============ Persistence.Dual ============

function Tests.DualSaveLocalWinsCloudShadows()
    local fs = makeMemFs()
    local backend = LocalSaveBackend.New({ File = fs.File, fileSystem = fs.fileSystem, cjson = fakeJson })
    local cloud = memCloud()
    local store = Persistence.Dual(cloud, backend)

    local snapshot = { day = 2, money = 170, inventory = { "tuna" }, story = {} }
    local result = syncCall(function(done) store:Save(snapshot, done) end)
    eq(result.ok, true, "dual save ok")
    eq(result.value, nil, "dual save value nil")
    eq(cloud.sets, 1, "cloud shadow written once")
    eq(cloud.data.money, 170, "cloud shadow payload")
    eq(fs.fileSystem:FileExists("sea_loop_save.json"), true, "local file written")
end

function Tests.DualSaveFallsBackToCloudWhenLocalFails()
    local fs = makeMemFs()
    fs.failOpen = true
    local backend = LocalSaveBackend.New({ File = fs.File, fileSystem = fs.fileSystem, cjson = fakeJson })
    local cloud = memCloud()
    local store = Persistence.Dual(cloud, backend)

    local result = syncCall(function(done) store:Save({ day = 1, money = 100 }, done) end)
    eq(result.ok, true, "cloud fallback save ok")
    eq(cloud.data.money, 100, "cloud has payload")
end

function Tests.DualSaveCloudUnavailableStillSucceeds()
    -- P0 核心场景：真机 cloud_unavailable，本地写成功即存档成功。
    local fs = makeMemFs()
    local backend = LocalSaveBackend.New({ File = fs.File, fileSystem = fs.fileSystem, cjson = fakeJson })
    local cloud = memCloud()
    cloud.unavailable = true
    local store = Persistence.Dual(cloud, backend)

    local result = syncCall(function(done) store:Save({ day = 1, money = 100 }, done) end)
    eq(result.ok, true, "save succeeds without cloud")
    eq(fs.fileSystem:FileExists("sea_loop_save.json"), true, "local file persisted")
end

function Tests.DualLoadPrefersLocal()
    local fs = makeMemFs()
    local backend = LocalSaveBackend.New({ File = fs.File, fileSystem = fs.fileSystem, cjson = fakeJson })
    local cloud = memCloud()
    cloud.data = { day = 5, money = 900 }  -- 云上是旧档
    local store = Persistence.Dual(cloud, backend)

    local saved = syncCall(function(done) backend:Save({ day = 7, money = 500 }, done) end)
    eq(saved.ok, true, "local seed save")
    local loaded = syncCall(function(done) store:Load(done) end)
    eq(loaded.ok, true, "load ok")
    eq(loaded.value.day, 7, "local snapshot wins over stale cloud")
    eq(loaded.value.money, 500, "local money wins")
end

function Tests.DualLoadFallsBackToCloudAndCaches()
    local fs = makeMemFs()
    local backend = LocalSaveBackend.New({ File = fs.File, fileSystem = fs.fileSystem, cjson = fakeJson })
    local cloud = memCloud()
    cloud.data = { day = 4, money = 320, inventory = { "sardine" }, story = {} }
    local store = Persistence.Dual(cloud, backend)

    local loaded = syncCall(function(done) store:Load(done) end)
    eq(loaded.ok, true, "cloud fallback load ok")
    eq(loaded.value.day, 4, "cloud snapshot loaded")
    eq(fs.fileSystem:FileExists("sea_loop_save.json"), true, "cloud snapshot cached to local")
end

function Tests.DualLoadEmptyWhenNoSaveAnywhere()
    local fs = makeMemFs()
    local backend = LocalSaveBackend.New({ File = fs.File, fileSystem = fs.fileSystem, cjson = fakeJson })
    local cloud = memCloud()
    local store = Persistence.Dual(cloud, backend)

    local loaded = syncCall(function(done) store:Load(done) end)
    eq(loaded.ok, true, "empty load ok")
    eq(loaded.value, nil, "empty load value nil")
end

function Tests.DualDegradesToCloudWithoutEngine()
    -- lupa/离线环境引擎不可用时，Dual(nil, nil) 必须等价于 Cloud(nil)。
    local originalAvailable = LocalSaveBackend.Available
    LocalSaveBackend.Available = function() return false end
    local ok, err = pcall(function()
        local cloud = memCloud()
        cloud.unavailable = true
        local store = Persistence.Dual(cloud, nil)
        local result = syncCall(function(done) store:Save({ day = 1, money = 100 }, done) end)
        assert(result.ok == false, "unavailable cloud should fail save")
        assert(result.value ~= nil, "failure reason present")
    end)
    LocalSaveBackend.Available = originalAvailable
    if not ok then error(err, 0) end
end

-- ============ Loop:SellAll ============

function Tests.SellAllSellsOnlyFishAndSumsIncome()
    local fixture = Flow.Fixture({ items = { "apple", "sardine", "tuna" } })
    local loop, player = fixture.loop, fixture.loop.player
    local before = player.money
    local ok, err = loop:SellAll()
    eq(ok, true, "sell all ok")
    eq(err, nil, "no error")
    eq(player.money, before + 70 + 120, "income sardine 70 + tuna 120")
    items(player.inventory:GetItems(), { "apple" }, "only non-fish remains")
end

function Tests.SellAllEmptyInventoryRejected()
    local fixture = Flow.Fixture({ items = { "apple", "bait" } })
    local ok, reason = fixture.loop:SellAll()
    eq(ok, false, "nothing to sell rejected")
    eq(reason, "nothing_to_sell", "nothing_to_sell reason")
end

function Tests.SellAllAtSeaRejected()
    local fixture = Flow.Fixture({ items = { "sardine" } })
    assert(fixture.loop:Depart())
    local ok, reason = fixture.loop:SellAll()
    eq(ok, false, "at sea rejected")
    eq(reason, "port_required", "port_required reason")
end

-- ============ 返港引导 ============

function Tests.ReturnToPortOutOfRangeGivesCompass()
    local port = OceanConfig.ship.start
    local fixture = Flow.Fixture({
        shipPosition = { x = port.x + 3, y = port.y + 3 },
        items = { "sardine" },
    })
    assert(fixture.loop:Depart())
    -- 出海后把船挪到远离港口处：向东 30 米、向北 5 米（船在港东北，港口在船西南）。
    fixture.runtime.ship.position = { x = port.x + 30, y = port.y + 5 }
    local ok, reason = fixture.loop:ReturnToPort()
    eq(ok, false, "far from port rejected")
    eq(reason, "port_out_of_range", "out of range reason")
    local message = fixture.loop.lastMessage or ""
    assert(message:find("港口在", 1, true), "message mentions direction: " .. message)
    assert(message:find("西南", 1, true), "message compass points SW toward port: " .. message)
    assert(message:find("距港 30", 1, true), "message gives distance: " .. message)
end

function Tests.Run()
    local names = {
        "LocalSaveBackendRoundtrip", "LocalSaveBackendEmptyAndCorrupt", "LocalSaveBackendAvailableProbe",
        "DualSaveLocalWinsCloudShadows", "DualSaveFallsBackToCloudWhenLocalFails",
        "DualSaveCloudUnavailableStillSucceeds", "DualLoadPrefersLocal",
        "DualLoadFallsBackToCloudAndCaches", "DualLoadEmptyWhenNoSaveAnywhere",
        "DualDegradesToCloudWithoutEngine",
        "SellAllSellsOnlyFishAndSumsIncome", "SellAllEmptyInventoryRejected", "SellAllAtSeaRejected",
        "ReturnToPortOutOfRangeGivesCompass",
    }
    -- 返回 { results = ... } 格式：run_circle1_b.py 与 run_sea_view_regression.py 两个 runner 均认。
    local results = {}
    for _, name in ipairs(names) do
        local ok, err = xpcall(Tests[name], debug.traceback)
        results[#results + 1] = {
            name = name, passed = ok, error = ok and "" or tostring(err),
        }
    end
    return { results = results, metrics = {} }
end

return Tests
