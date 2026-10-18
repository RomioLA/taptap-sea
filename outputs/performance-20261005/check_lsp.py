"""Reuse the existing headless LSP check, including the performance changes."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
original = ROOT / 'scripts/tests/Circle1B3Lsp.py'
source = original.read_text(encoding='utf-8-sig')
source = source.replace('EXE = Path.home() / ".taptap-maker/lua-lsp-venv/Lib/site-packages/maker_lua_lsp/bin/emmylua_ls.exe"',
    'EXE = Path(r"C:\\Users\\Administrator.DESKTOP-NS4I6RF\\.taptap-maker\\lua-lsp-venv\\Lib\\site-packages\\maker_lua_lsp\\bin\\emmylua_ls.exe")')
source = source.replace('files += [ROOT / "scripts/Game/Game.lua"]', '''files += [ROOT / "scripts/Game/Game.lua"]
files += [ROOT / ("scripts/Ocean/" + name + ".lua") for name in ("Projection", "ProjectedGeometry", "SeaViewArt")]
files += [ROOT / ("scripts/Tests/" + name + ".lua") for name in ("SeaHorizonOcclusionTests", "Circle1HUDReviewTests", "SeaMotionEffectsTests")]''')
source = source.replace('ROOT / "outputs/circle1-b3/lsp-result.json"', 'ROOT / "outputs/performance-20261005/lsp-final.json"')
exec(compile(source, str(original), 'exec'), {'__file__': str(original), '__name__': '__main__'})
