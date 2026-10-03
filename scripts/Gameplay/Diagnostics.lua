-- Jam operation diagnostics only: no game state, buffers, files or network IO.
-- Every formatter/output failure is isolated from the observed operation.
local Diagnostics = {}

local function redact(value)
    local text = tostring(value)
    text = text:gsub('([Bb]earer%s+)[%w%._%-]+', '%1<redacted>')
    for _, name in ipairs({ '[%w_]*[Tt]oken', '[Pp]assword', '[Ss]ecret',
        '[Aa][Pp][Ii][_-]?[Kk]ey', '[Uu]ser[_-]?[Ii][Dd]', '[Aa]ccount[_-]?[Ii][Dd]' }) do
        text = text:gsub('(' .. name .. [=[[%"']?%s*[=:]%s*[%"']?)[^%s,%"';}]+]=], '%1<redacted>')
    end
    text = text:gsub('([Aa]uthorization%s*[=:]%s*)[^\r\n]+', '%1<redacted>')
    return text
end

local function sensitiveKey(key)
    local lower = key:lower()
    return lower:find('password', 1, true) or lower:find('secret', 1, true)
        or lower:find('credential', 1, true) or lower:find('authorization', 1, true)
        or lower:find('account', 1, true) or lower:find('userid', 1, true)
        or lower:find('snapshot', 1, true) or lower == 'payload' or lower == 'values'
        or lower == 'access_token' or lower == 'refresh_token' or lower == 'api_key' or lower == 'pat'
end

function Diagnostics.Event(area, event, fields)
    pcall(function()
        if type(print) ~= 'function' then return end
        local parts = { '[Jam][' .. tostring(area) .. '][' .. tostring(event) .. ']' }
        local keys = {}
        for key in pairs(fields or {}) do
            if type(key) == 'string' and not sensitiveKey(key) then keys[#keys + 1] = key end
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local value = fields[key]
            local kind = type(value)
            -- Never expand tables (save data, player state, cloud response, etc.).
            if kind == 'string' or kind == 'number' or kind == 'boolean' then
                local limit = key == 'stack' and 6000 or key == 'error' and 2000 or 1200
                local scalar = redact(value):sub(1, limit)
                scalar = scalar:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\r', '\\r'):gsub('\n', '\\n')
                parts[#parts + 1] = key .. '="' .. scalar .. '"'
            end
        end
        print(table.concat(parts, ' '))
    end)
end

-- Also usable from an existing xpcall handler with a bounded diagnostic latch.
function Diagnostics.Exception(area, event, err)
    pcall(function()
        local stack = 'unavailable'
        if debug and type(debug.traceback) == 'function' then
            local traceback = debug.traceback --[[@as fun(message: string, level: integer): string]]
            local ok, trace = pcall(traceback, '', 2)
            if ok and type(trace) == 'string' then stack = trace end
        end
        local text = type(err) == 'string' or type(err) == 'number'
        Diagnostics.Event(area, event, { kind = 'exception', error = text and err or '<non-scalar error>', stack = stack })
    end)
    return err
end

-- Same return convention and original error value as pcall. Obtain the traceback
-- inside xpcall's handler, before the failed operation's stack is unwound.
function Diagnostics.Call(area, event, fn, ...)
    return xpcall(fn, function(err)
        return Diagnostics.Exception(area, event, err)
    end, ...)
end

return Diagnostics
