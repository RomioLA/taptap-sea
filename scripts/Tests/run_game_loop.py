"""Run pure Lua rules using isolated Lupa Lua 5.4; no engine/GUI/cloud calls."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / ".tmp" / "game-loop-test-runtime"))
from lupa.lua54 import LuaRuntime

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("package.path = ... .. '/scripts/?.lua;' .. package.path", ROOT.as_posix())
print("Runtime:", lua.eval("_VERSION"), flush=True)
compile_source = lua.eval("function(source, name) local fn, err = load(source, name); assert(fn, err) end")
files = []
for directory in ("Gameplay", "config", "data", "Tests"):
    files.extend((ROOT / "scripts" / directory).glob("*.lua"))
for path in files:
    compile_source(path.read_text(encoding="utf-8-sig"), "@" + str(path))
print("Lua syntax PASS:", len(files), "files", flush=True)
lua.execute((ROOT / "scripts" / "Tests" / "GameLoopSpec.lua").read_text(encoding="utf-8-sig"))
ui_spec = ROOT / "scripts/Tests/GameLoopUISpec.lua"
if ui_spec.exists():
    lua.execute(ui_spec.read_text(encoding="utf-8-sig"))
lua.execute((ROOT / "scripts/Tests/PersistenceRegressionSpec.lua").read_text(encoding="utf-8-sig"))
lua.execute((ROOT / "scripts/Tests/NumericEconomySpec.lua").read_text(encoding="utf-8-sig"))
lua.execute((ROOT / "scripts/Tests/ShopStockSpec.lua").read_text(encoding="utf-8-sig"))

# 平衡目标只允许出现在文档/测试；检查全部B运行源码，避免变成隐藏运行时配额。
import re
for path in files:
    if path.parent.name == "Tests":
        continue
    source = path.read_text(encoding="utf-8-sig")
    for forbidden in ("dailyFishingLimit", "newGamePlusTunaBonus", "newGamePlusIncomeMultiplier",
                      "newGamePlusCatchRate", "eventPoolCount", "tunaChance", "eventReward"):
        assert forbidden not in source, (path, forbidden)
    assert not re.search(r"\b1600\b|0\.25\b|0\.30\b|0\.60\b|0\.70\b", source), path
print("BALANCE_RUNTIME_QUOTA_AUDIT_PASS", flush=True)
