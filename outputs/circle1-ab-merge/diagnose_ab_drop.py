"""In-memory instrumentation of an explicit headless test fixture only."""
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location("final_review", Path(__file__).with_name("run_final_checks.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
lua = runner._lua_runtime()
logs = []
lua.globals().print = lambda *args: logs.append(" ".join(map(str, args)))
source = (runner.ROOT / "scripts/Tests/ABIntegrationTests.lua").read_text(encoding="utf-8")
source = source.replace("assert(sea.loop:DropItem(1))", '''
local oldSpawn = sea.runtime.spawnDroppedItem
sea.runtime.spawnDroppedItem = function(self, payload, position)
    local ok, entity, reason = pcall(oldSpawn, self, payload, position)
    print("DROP_DIAG", ok, tostring(entity), tostring(reason), payload.itemId,
        tostring(payload.worldEffect), position.x, position.y, self.ship.position.x, self.ship.position.y)
    if not ok then error(entity) end
    return entity, reason
end
local target = sea.loop.actions:GetDropTarget()
print("TARGET_DIAG", target and target.x, target and target.y)
assert(sea.loop:DropItem(1))
''')
module = lua.execute(source)
result = {"kind": "in-memory test-fixture instrumentation, not production or native evidence",
          "logs": logs, "report": runner._lua_to_python(module.Run())}
Path(__file__).with_name("ab-drop-diagnostic.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps({"logs": logs}, ensure_ascii=False))
