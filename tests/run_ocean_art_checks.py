"""本轮 Lua 回归：复用项目 runner，大小写明确，逐套隔离并限制超时。"""
import argparse
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "outputs/ocean-art-loop-20261005"
DEPS = OUT / "deps"
sys.dont_write_bytecode = True


def one(name):
    spec = importlib.util.spec_from_file_location("existing_review", ROOT / "tests/run_circle1_review.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.LUPA_ROOT = DEPS
    lua, lua_type, recorder = module.prepare_runtime()
    path = ROOT / "scripts/tests" / (name + ".lua")
    suite = {"name": name, "kind": "spec" if name.endswith("Spec") else "run", "file": path.relative_to(ROOT).as_posix()}
    result = module.run_one(suite, lua, lua_type, recorder)
    print(json.dumps(result, ensure_ascii=False))


def all_suites():
    suites = [p.stem for p in sorted((ROOT / "scripts/tests").glob("*.lua")) if p.stem.endswith(("Tests", "Spec"))]
    env = os.environ.copy()
    env["PYTHONPATH"] = str(DEPS)
    def run(name):
        try:
            proc = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--one", name],
                                  env=env, capture_output=True, text=True, timeout=12)
            return json.loads(proc.stdout.splitlines()[-1])
        except subprocess.TimeoutExpired:
            return {"name": name, "passed": False, "error": "逐套 12 秒超时，未判为通过"}
        except Exception as error:
            return {"name": name, "passed": False, "error": str(error)}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(run, suites))
    report = {"suiteCount": len(results), "passedSuiteCount": sum(r["passed"] for r in results), "suites": results}
    (OUT / "regression-final.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for result in results:
        if not result["passed"]:
            print("FAIL", result["name"], result.get("error") or result.get("failures"))
    print("SUITES", report["passedSuiteCount"], "/", report["suiteCount"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--one")
    args = parser.parse_args()
    one(args.one) if args.one else all_suites()
