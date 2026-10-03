"""Check this project's new Lua modules with the installed EmmyLua binary."""
import json
import queue
import subprocess
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXE = Path.home() / ".taptap-maker/lua-lsp-venv/Lib/site-packages/maker_lua_lsp/bin/emmylua_ls.exe"
files = sorted((ROOT / "scripts/Gameplay").glob("*.lua"))
files += sorted((ROOT / "scripts/config").glob("*.lua"))
files += sorted((ROOT / "scripts/data").glob("*.lua"))
files += sorted((ROOT / "scripts/Integration").glob("*.lua"))
files += [ROOT / "scripts/Game/Game.lua"]
# Keep the installed server's embedded Lua standard library. An empty override
# directory makes require/type/math disappear on the receiving computer.
proc = subprocess.Popen([str(EXE), "--log-level", "error"],
                        cwd=ROOT / "scripts", stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
messages = queue.Queue()

def receive():
    while True:
        headers = {}
        while True:
            line = proc.stdout.readline()
            if not line:
                return
            if line == b"\r\n":
                break
            key, value = line.decode().split(":", 1)
            headers[key.lower()] = value.strip()
        messages.put(json.loads(proc.stdout.read(int(headers["content-length"]))))

threading.Thread(target=receive, daemon=True).start()

def send(message):
    payload = json.dumps({"jsonrpc": "2.0", **message}).encode()
    proc.stdin.write(f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload)
    proc.stdin.flush()

diagnostics = {}
try:
    send({"id": 1, "method": "initialize", "params": {
        "processId": None, "rootUri": (ROOT / "scripts").as_uri(),
        "workspaceFolders": [{"uri": (ROOT / "scripts").as_uri(), "name": "scripts"}],
        "capabilities": {"workspace": {"configuration": True},
                         "textDocument": {"publishDiagnostics": {"relatedInformation": True}}}}})
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        msg = messages.get(timeout=2)
        if msg.get("id") == 1:
            if "error" in msg:
                raise RuntimeError(msg["error"])
            break
    else:
        raise RuntimeError("LSP initialize timed out")
    send({"method": "initialized", "params": {}})
    config = json.loads((ROOT / "scripts/.luarc.json").read_text(encoding="utf-8-sig"))
    config["runtime"]["version"] = "Lua5.4"
    config["workspace"]["library"] = [str(ROOT / ".emmylua")]
    config["workspace"]["packages"] = [str(ROOT / "urhox-libs")]
    config["diagnostics"]["severity"] = {key: value.lower() for key, value in config["diagnostics"]["severity"].items()}
    expected = {path.as_uri() for path in files}
    for path in files:
        send({"method": "textDocument/didOpen", "params": {"textDocument": {
            "uri": path.as_uri(), "languageId": "lua", "version": 1,
            "text": path.read_text(encoding="utf-8-sig")}}})
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        try:
            msg = messages.get(timeout=1)
        except queue.Empty:
            continue
        if msg.get("method") == "workspace/configuration":
            send({"id": msg["id"], "result": [config for _ in msg["params"]["items"]]})
            continue
        if "id" in msg and "method" in msg:
            send({"id": msg["id"], "result": None})
            continue
        if msg.get("method") == "textDocument/publishDiagnostics":
            data = msg["params"]
            if data["uri"] in expected:
                diagnostics[data["uri"]] = data["diagnostics"]
    # Reanalyze import users after all modules have opened. The initial scan can
    # otherwise retain unresolved dependency warnings from startup ordering.
    for path in files:
        send({"method": "textDocument/didChange", "params": {
            "textDocument": {"uri": path.as_uri(), "version": 2},
            "contentChanges": [{"text": path.read_text(encoding="utf-8-sig")}]}})
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            msg = messages.get(timeout=1)
        except queue.Empty:
            continue
        if msg.get("method") == "workspace/configuration":
            send({"id": msg["id"], "result": [config for _ in msg["params"]["items"]]})
        elif "id" in msg and "method" in msg:
            send({"id": msg["id"], "result": None})
        elif msg.get("method") == "textDocument/publishDiagnostics":
            data = msg["params"]
            if data["uri"] in expected:
                diagnostics[data["uri"]] = data["diagnostics"]
    missing = expected - diagnostics.keys()
    errors = []
    warnings = []
    for uri, entries in diagnostics.items():
        for entry in entries:
            record = {"file": uri, "line": entry["range"]["start"]["line"] + 1,
                      "code": entry.get("code"), "message": entry["message"]}
            if entry.get("severity", 1) == 1:
                errors.append(record)
            elif entry.get("severity") == 2:
                warnings.append(record)
    output = {"filesExpected": len(expected), "filesDiagnosed": len(diagnostics),
              "missing": sorted(missing), "errors": errors, "warnings": warnings}
    destination = ROOT / "outputs/circle1-b2/lsp-result.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"filesExpected":len(expected),"filesDiagnosed":len(diagnostics),
                      "missing":sorted(missing),"errorCount":len(errors),"warningCount":len(warnings),
                      "errors":errors[:10],"warnings":warnings[:8],"fullResult":str(destination)},
                     ensure_ascii=False)[:5000])
    raise SystemExit(1 if errors or missing else 0)
finally:
    if proc.poll() is None:
        proc.terminate()
        proc.wait(timeout=5)
