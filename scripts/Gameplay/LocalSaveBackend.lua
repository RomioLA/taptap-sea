-- F1: 本地文件存档后端（P0 cloud_unavailable 的兜底）。
-- 依赖引擎沙箱文件 API（File / fileSystem / cjson，项目+用户双重隔离，
-- 见 engine-docs/recipes/file-storage.md）。离线测试环境无引擎对象时
-- Available() 返回 false，装配层（Persistence.Dual）自动退化为纯云后端。
local Config = require("config.gameplay")
local Diagnostics = require("Gameplay.Diagnostics")

local LocalSaveBackend = {}

-- 引擎常量在离线测试（lupa）环境不存在；兜底为可区分的字符串，
-- 测试替身按同字面量判断读写分支。真机环境直接使用引擎常量。
local MODE_WRITE = FILE_WRITE or "write"
local MODE_READ = FILE_READ or "read"

local function resolveDeps(deps)
    deps = deps or {}
    return deps.File or File, deps.fileSystem or fileSystem, deps.cjson or cjson
end

-- 引擎可用性探测：File 构造器、fileSystem:FileExists、cjson 编解码缺一不可。
function LocalSaveBackend.Available(deps)
    local file, fileSystem, cjson = resolveDeps(deps)
    if file == nil or cjson == nil or type(cjson.encode) ~= "function"
        or type(cjson.decode) ~= "function" then return false end
    if fileSystem == nil or type(fileSystem.FileExists) ~= "function" then return false end
    return true
end

---@param deps table? 测试注入 { File=, fileSystem=, cjson=, filename= }
function LocalSaveBackend.New(deps)
    local file, fileSystem, cjson = resolveDeps(deps)
    local filename = (deps and deps.filename)
        or (Config.persistence and Config.persistence.localFilename)
        or "sea_loop_save.json"

    local backend = {}

    local function emit(kind, outcome, reason)
        Diagnostics.Event("persistence", "local_file_result", {
            kind = kind, outcome = outcome, reason = reason,
        })
    end

    local function writeSnapshot(snapshot)
        local ok, payload = pcall(cjson.encode, snapshot)
        if not ok then return false, "local_encode_failed" end
        local writeFile = file(filename, MODE_WRITE)
        if writeFile == nil or not writeFile:IsOpen() then return false, "local_file_open_failed" end
        writeFile:WriteString(payload)
        writeFile:Close()
        return true
    end

    -- store 接口：Save(snapshot, done)。本地写是同步的；done 同步回调后返回 true，
    -- 不走 Loop 端"返回 false 时补发 done"的路径，避免双重回调。
    function backend:Save(snapshot, done)
        if type(done) ~= "function" then
            emit("rejected", "failed", "callback_required")
            return false, "callback_required"
        end
        local ok, err = writeSnapshot(snapshot)
        if ok then
            emit("operation", "succeeded", "local_saved")
            done(true, nil)
            return true
        end
        emit("failure", "failed", err)
        done(false, err)
        return true
    end

    -- store 接口：Load(done)。done(true, snapshot)=命中；done(true, nil)=无档；done(false, reason)=损坏/不可读。
    function backend:Load(done)
        if type(done) ~= "function" then
            emit("rejected", "failed", "callback_required")
            return false, "callback_required"
        end
        if not fileSystem:FileExists(filename) then
            emit("operation", "empty", "no_local_file")
            done(true, nil)
            return true
        end
        local readFile = file(filename, MODE_READ)
        if readFile == nil or not readFile:IsOpen() then
            emit("failure", "failed", "local_file_open_failed")
            done(false, "local_file_open_failed")
            return true
        end
        local content = readFile:ReadString()
        readFile:Close()
        local ok, data = pcall(cjson.decode, content)
        if not ok or type(data) ~= "table" then
            emit("failure", "failed", "local_file_corrupt")
            done(false, "local_file_corrupt")
            return true
        end
        emit("operation", "succeeded", "local_loaded")
        done(true, data)
        return true
    end

    return backend
end

return LocalSaveBackend
