-- Circle 1B3 clientCloud adapter protocol tests; these use a local SDK double.
local Tests = {}

local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function runCase(results, name, body)
    local ok, err = pcall(body)
    local result = { name = name, passed = ok }
    if not ok then result.error = tostring(err) end
    results[#results + 1] = result
end

function Tests.Run(Persistence)
    Persistence = Persistence or require("Gameplay.Persistence")
    local key = require("config.gameplay").persistence.key
    local results = {}

    runCase(results, "Get reads the requested value from the values callback argument", function()
        local expected = { schemaVersion = 1, inventory = { "apple" } }
        local backend = {}
        function backend:Get(requestedKey, events)
            equal(self, backend, "Get receiver")
            equal(requestedKey, key, "Get key")
            events.ok({ [requestedKey] = expected }, { [requestedKey] = "wrong table" })
        end

        local calls = 0
        local accepted = Persistence.Cloud(backend):Load(function(ok, value)
            calls = calls + 1
            equal(ok, true, "load result")
            equal(value, expected, "loaded value")
        end)
        equal(accepted, true, "request accepted")
        equal(calls, 1, "completion count")
    end)

    runCase(results, "Get reports a missing key as an empty successful load", function()
        local backend = {}
        function backend:Get(requestedKey, events)
            equal(requestedKey, key, "Get key")
            events.ok({}, {})
        end

        local calls = 0
        Persistence.Cloud(backend):Load(function(ok, value)
            calls = calls + 1
            equal(ok, true, "load result")
            equal(value, nil, "missing save")
        end)
        equal(calls, 1, "completion count")
    end)

    runCase(results, "Get rejects a non-table values response", function()
        local responses = { "malformed", false, 42 }
        local backend = {}
        local responseIndex = 0
        function backend:Get(_, events)
            responseIndex = responseIndex + 1
            if responseIndex == 1 then events.ok(nil, {})
            else events.ok(responses[responseIndex - 1], {}) end
        end

        local reasons = {}
        for index = 1, #responses + 1 do
            local accepted = Persistence.Cloud(backend):Load(function(ok, reason)
                equal(ok, false, "load result")
                reasons[index] = reason
            end)
            equal(accepted, true, "request accepted")
        end
        for index = 1, #responses + 1 do
            equal(reasons[index], "cloud_invalid_response", "invalid response reason")
        end
    end)

    runCase(results, "Set sends a copied snapshot and accepts only the first callback", function()
        local snapshot = { inventory = { "apple" }, progress = { day = 3 } }
        local backend = {}
        function backend:Set(requestedKey, value, events)
            equal(self, backend, "Set receiver")
            equal(requestedKey, key, "Set key")
            equal(value == snapshot, false, "snapshot copy")
            equal(value.inventory == snapshot.inventory, false, "nested copy")
            self.events = events
            self.value = value
        end

        local calls = 0
        local accepted = Persistence.Cloud(backend):Save(snapshot, function(ok, reason)
            calls = calls + 1
            equal(ok, true, "save result")
            equal(reason, nil, "save reason")
        end)
        equal(accepted, true, "request accepted")
        equal(calls, 0, "async completion before callback")
        backend.events.ok()
        backend.events.error(-1, "late error")
        backend.events.timeout()
        backend.events.ok()
        equal(calls, 1, "completion count")
    end)

    runCase(results, "Timeout wins and late success cannot complete twice", function()
        local backend = {}
        function backend:Get(_, events) self.events = events end

        local calls, result, reason = 0, nil, nil
        Persistence.Cloud(backend):Load(function(ok, value)
            calls = calls + 1
            result, reason = ok, value
        end)
        backend.events.timeout()
        backend.events.ok({ [key] = { day = 99 } }, {})
        backend.events.error(-1, "late error")
        equal(calls, 1, "completion count")
        equal(result, false, "timeout result")
        equal(reason, "cloud_timeout", "timeout reason")
    end)

    runCase(results, "SDK error callback preserves code and reason", function()
        local backend = {}
        function backend:Get(_, events) events.error(-429, "send failed") end

        local calls, result, reason = 0, nil, nil
        Persistence.Cloud(backend):Load(function(ok, value)
            calls = calls + 1
            result, reason = ok, value
        end)
        equal(calls, 1, "completion count")
        equal(result, false, "error result")
        equal(reason, "-429:send failed", "error details")
    end)

    runCase(results, "Synchronous false return rejects both Get and Set", function()
        local backend = {
            Get = function() return false end,
            Set = function() return false end,
        }
        local store = Persistence.Cloud(backend)

        local loadCalls, loadOk, loadReason = 0, nil, nil
        local loadAccepted, loadError = store:Load(function(ok, reason)
            loadCalls = loadCalls + 1
            loadOk, loadReason = ok, reason
        end)
        equal(loadAccepted, false, "Get accepted")
        equal(loadError, "cloud_request_rejected", "Get immediate error")
        equal(loadCalls, 1, "Get completion count")
        equal(loadOk, false, "Get completion result")
        equal(loadReason, loadError, "Get completion reason")

        local saveCalls, saveOk, saveReason = 0, nil, nil
        local saveAccepted, saveError = store:Save({}, function(ok, reason)
            saveCalls = saveCalls + 1
            saveOk, saveReason = ok, reason
        end)
        equal(saveAccepted, false, "Set accepted")
        equal(saveError, "cloud_request_rejected", "Set immediate error")
        equal(saveCalls, 1, "Set completion count")
        equal(saveOk, false, "Set completion result")
        equal(saveReason, saveError, "Set completion reason")
    end)

    runCase(results, "SDK exceptions fail once and return an immediate error", function()
        local backend = {}
        function backend:Get() error("sdk exploded") end

        local calls, result, reason = 0, nil, nil
        local accepted, immediateError = Persistence.Cloud(backend):Load(function(ok, value)
            calls = calls + 1
            result, reason = ok, value
        end)
        equal(accepted, false, "request accepted")
        equal(string.find(immediateError, "sdk exploded", 1, true) ~= nil, true, "immediate exception")
        equal(calls, 1, "completion count")
        equal(result, false, "exception result")
        equal(string.find(reason, "sdk exploded", 1, true) ~= nil, true, "callback exception")
    end)

    runCase(results, "Missing backend completes as unavailable", function()
        local calls, result, reason = 0, nil, nil
        local accepted, immediateError = Persistence.Cloud(false):Load(function(ok, value)
            calls = calls + 1
            result, reason = ok, value
        end)
        equal(accepted, false, "request accepted")
        equal(immediateError, "cloud_unavailable", "immediate error")
        equal(calls, 1, "completion count")
        equal(result, false, "completion result")
        equal(reason, "cloud_unavailable", "completion reason")
    end)

    runCase(results, "Completion callback exceptions do not escape the SDK callback", function()
        local backend = {}
        function backend:Get(_, events) self.events = events end
        local calls = 0
        Persistence.Cloud(backend):Load(function()
            calls = calls + 1
            error("consumer callback failed")
        end)

        local callbackOk = pcall(backend.events.ok, { [key] = {} }, {})
        equal(callbackOk, true, "SDK callback escaped")
        equal(calls, 1, "completion count")
    end)

    return { results = results }
end

return Tests
