"""Independent isolated follow-up of the eight nonpassing art-final suites."""
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path('/workspace')
OUT = ROOT / 'outputs/ocean-art-loop-20261005/review'


def load_module():
    spec = importlib.util.spec_from_file_location('original_review', ROOT / 'tests/run_circle1_review.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.LUPA_ROOT = ROOT / 'outputs/ocean-art-loop-20261005/deps'
    return module


def child(name, mode):
    module = load_module()
    LuaRuntime, lua_type, capture = module.prepare_runtime()
    original_bind = module.bind_recorder
    logs = []
    def bind(lua, recorder, table, cap):
        original_bind(lua, recorder, table, cap)
        lua.globals().__reviewSearcherLog = lambda original, target: logs.append({'requested': original, 'resolved': target})
        lua.execute('''
            table.insert(package.searchers, 1, function(name)
                if name == "Ocean.ImageArt" then
                    error("REVIEW_ASSERT: SeaRuntimeTests unexpectedly requested Ocean.ImageArt")
                end
                return ""
            end)
        ''' if name == 'SeaRuntimeTests' else '')
        if mode == 'case-adapted':
            lua.execute('''
                table.insert(package.searchers, 1, function(name)
                    if name:sub(1, 6) ~= "Tests." then return "" end
                    local target = "tests." .. name:sub(7)
                    __reviewSearcherLog(name, target)
                    return function() return require(target) end
                end)
            ''')
    module.bind_recorder = bind
    suite = {'name': name, 'kind': 'spec' if name.endswith('Spec') else 'run', 'file': 'scripts/tests/' + name + '.lua'}
    result = module.run_one(suite, LuaRuntime, lua_type, capture)
    result['reviewMode'] = mode
    result['explicitSearcherAdaptations'] = logs
    result['imageArtRequireGuardEnabled'] = name == 'SeaRuntimeTests'
    print(json.dumps(result, ensure_ascii=False, indent=2))


def parent():
    names = ['Circle1A3ExperienceTests', 'Circle1A3RecognitionTests', 'Circle1A3StabilityTests', 'SeaStabilityTests', 'Circle1B3SevenDaysTests', 'Circle1HUDReviewTests', 'GameLoopUISpec', 'SeaRuntimeTests']
    tasks = [(name, 'original') for name in names]
    tasks += [(name, 'case-adapted') for name in ['Circle1B3SevenDaysTests', 'Circle1HUDReviewTests', 'GameLoopUISpec']]
    results = []
    for name, mode in tasks:
        try:
            process = subprocess.run([sys.executable, __file__, '--child', name, mode], capture_output=True, text=True, timeout=60)
            (OUT / f'{name}.{mode}.stdout.log').write_text(process.stdout)
            (OUT / f'{name}.{mode}.stderr.log').write_text(process.stderr)
            result = json.loads(process.stdout) if process.returncode == 0 else {'name': name, 'reviewMode': mode, 'passed': False, 'exitCode': process.returncode, 'stderr': process.stderr}
        except subprocess.TimeoutExpired as error:
            result = {'name': name, 'reviewMode': mode, 'passed': False, 'timeoutSeconds': 60}
        (OUT / f'{name}.{mode}.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        results.append(result)
        print(name, mode, 'PASS' if result['passed'] else 'FAIL', result.get('subtestCount'), result.get('durationMs'), flush=True)
    (OUT / 'nonpassing-followup.json').write_text(json.dumps({'timeoutPerProcessSeconds': 60, 'results': results}, ensure_ascii=False, indent=2) + '\n')

if __name__ == '__main__':
    if '--child' in sys.argv:
        child(sys.argv[2], sys.argv[3])
    else:
        parent()
