"""Offline probe: actual movement to a float versus authored port; no source changes."""
import importlib.util
import json
from pathlib import Path

OUT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('runner', OUT.parent / 'run_final_checks.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
lua = runner._lua_runtime()
result = lua.execute('''
    local Runtime = require("Ocean.SeaRuntime")
    local Loop = require("Gameplay.Loop")
    local Config = require("Ocean.Config")
    local function voyage(target)
        local runtime = Runtime.New({ departure = {x=30, y=0} })
        local loop = setmetatable({runtime = runtime}, {__index = Loop})
        runtime.movement:SetTarget(target)
        for i = 1, 600 do runtime:Update(1/60, 0, 0) end
        local ship, port = runtime:GetShipPosition(), runtime:GetPortPosition()
        local accepted, reason = loop:CanAccessPort()
        return {ship=ship, port=port, target=target, navigationFinished=runtime.movement.target==nil,
            distance=math.sqrt((ship.x-port.x)^2+(ship.y-port.y)^2),
            accepted=accepted, reason=reason or "", radius=Config.interaction.portDistance}
    end
    return {floatDestination=voyage({x=10,y=0}), portDestination=voyage(Config.ship.start)}
''')
report = {'sourceOnlyCurrentTree': True, 'fixture': 'Actual Runtime and normal fish count; manual departure/target, 600 frames at 1/60. CanAccessPort is real Loop method, no fake distance predicate.',
    'nativeUserSessionReproduced': False, 'results': runner._lua_to_python(result)}
(OUT / 'offline-probe.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
log = Path('C:/Users/80739/.taptap-maker/preview/2bed5a4a76dcbaf94d6f7afb1d99cabdc7b672d25909b5f3339cc9e23cfee9e0/sessions/f5d82139-8fba-4e13-bbb7-e66fd587943f/0/runtime.log')
rows = []
for line in log.read_text(encoding='utf-8-sig').splitlines():
    row = json.loads(line)
    if any(term in row.get('text','') for term in ('[SeaV1]', 'Graphics resized:', '[Layout Warning]', '[ScrollView Warning]', 'Game started successfully')):
        rows.append(row)
(OUT / 'native-log-excerpt.json').write_text(json.dumps({'session':'f5d82139-8fba-4e13-bbb7-e66fd587943f','sourceLog':str(log),'rows':rows}, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
print(json.dumps(report['results'], ensure_ascii=False))
