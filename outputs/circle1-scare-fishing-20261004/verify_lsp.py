from pathlib import Path

source_path = Path(__file__).resolve().parents[2] / "tests/check_sea_view_lsp.py"
source = source_path.read_text(encoding="utf-8")
lines = source.splitlines()
for i, line in enumerate(lines):
    if line.startswith("OUTPUT = ROOT"):
        lines[i] = "OUTPUT = ROOT / 'outputs/circle1-scare-fishing-20261004/lsp.json'"
exec(compile("\n".join(lines), str(source_path), "exec"),
     {"__file__": str(source_path), "__name__": "__main__"})
