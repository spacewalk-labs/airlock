#!/usr/bin/env python3
"""Fresh caller selection/order/source contracts with real config and ledger readers."""
from pathlib import Path
import json, os, shutil, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = Path(os.environ.get('AIRLOCK_SELECTED_TEST_SCRATCH', str(Path.home()/'scratch/airlock-test-install-selected')))
BASE.mkdir(parents=True, exist_ok=True)
BASE = BASE.resolve()
with tempfile.TemporaryDirectory(dir=BASE) as directory:
    base = Path(directory)
    root = base/'checkout'
    for name in ['bin', 'install', 'apps', 'state', 'home', 'personal']:
        (root/name).mkdir(parents=True)
    for name in ['lib.sh', 'preflight.sh']:
        shutil.copy2(ROOT/'install'/name, root/'install'/name)
    shutil.copy2(ROOT/'bin/airlock-config', root/'bin/airlock-config')
    shutil.copy2(ROOT/'bin/airlock-ledger', root/'bin/ledger-engine')
    (root/'install/airlock-install.sh').write_text('echo platform >> "$AIRLOCK_TEST_EVENTS"\nexit "${AIRLOCK_TEST_PLATFORM_RC:-0}"\n')
    (root/'bin/airlock-ledger').write_text('''#!/usr/bin/env python3
from importlib.machinery import SourceFileLoader
from pathlib import Path
import json, os, subprocess, sys
engine = SourceFileLoader("fixture_ledger", str(Path(__file__).with_name("ledger-engine"))).load_module()
globals().update({k:v for k,v in vars(engine).items() if not k.startswith("__")})
if __name__ == "__main__":
    command, ids, explicit, _ = parse_cli(sys.argv[1:])
    app=ids[0]
    source=resolve_source(app, {}, explicit)
    read_dir_package(app, source["dir"])
    with open(os.environ["AIRLOCK_TEST_EVENTS"],"a") as f:
        f.write(json.dumps({"app":app,"source":source["dir"],"explicit":explicit})+"\\n")
    rc=subprocess.call(["bash",str(Path(source["dir"])/"install.sh")])
    if rc == 0:
        rows=load_installed()
        rows[app]={"repo":source["dir"],"commit":"","artifacts":[]}
        (Path(os.environ["AIRLOCK_STATE_DIR"])/"installed-apps.json").write_text(json.dumps(rows))
    raise SystemExit(rc)
''')
    def package(app, deps=(), personal=False, body='exit 0\n'):
        folder=root/('personal' if personal else 'apps')/app
        folder.mkdir(parents=True)
        # Same notepad -> publish edge as the shipped manifests. Use the real parser.
        (folder/'airlock-app.toml').write_text('contract = 1\nid = '+json.dumps(app)+'\n[dependencies]\napps = '+json.dumps(list(deps))+'\n')
        (folder/'install.sh').write_text(body)
        return folder
    publish=package('publish')
    notepad=package('notepad',['publish'],body='test -f "$AIRLOCK_STATE_DIR/installed-apps.json" && python3 -B -c \'import json,os; assert "publish" in json.load(open(os.environ["AIRLOCK_STATE_DIR"]+"/installed-apps.json"))\'\n')
    personal=package('fileview', personal=True)
    package('fileview',body='exit 91\n')
    hello=package('hello-example',personal=True)
    events=root/'events'
    env={k:v for k,v in os.environ.items() if not k.startswith(('AIRLOCK_', 'GIT_'))}
    env.update({'HOME':str(root/'home'),'AIRLOCK_CONFIG':str(root/'airlock.toml'),
                'AIRLOCK_STATE_DIR':str(root/'state'),'AIRLOCK_TEST_EVENTS':str(events),
                'PYTHONDONTWRITEBYTECODE':'1','GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1'})
    def run(config, rows=None, extra='', platform_rc=0):
        (root/'airlock.toml').write_text(config)
        (root/'state/installed-apps.json').write_text(json.dumps(rows or {}))
        events.write_text('')
        result=subprocess.run(['bash','-c','. "$1/install/lib.sh"; airlock_install_selected '+extra,'fixture',str(root)],env={**env,'AIRLOCK_TEST_PLATFORM_RC':str(platform_rc)},capture_output=True,text=True)
        records=[json.loads(line) for line in events.read_text().splitlines() if line.startswith('{')]
        assert events.read_text().splitlines()[0]=='platform'
        return result,records,json.loads((root/'state/installed-apps.json').read_text())
    row={'repo':str(personal),'commit':'','artifacts':[]}
    result,records,rows=run('[apps.notepad]\n[apps.publish]\n[apps.hub]\n',{'fileview':row})
    assert result.returncode==0,result.stderr
    assert [r['app'] for r in records]==['publish','notepad'],records
    assert rows['fileview']==row
    print('PASS fresh notepad before publish input applies publish first; selection excludes installed-only Personal fileview')
    result,records,rows=run('[apps.publish]\n[apps.fileview]\n',{'fileview':row})
    assert result.returncode==0,result.stderr
    assert records[1]['source']==str(personal) and records[1]['explicit']==''
    assert rows['fileview']==row
    print('PASS selected existing Personal fileview keeps recorded source instead of checkout source')
    (publish/'install.sh').write_text('exit 17\n')
    result,records,rows=run('[apps.publish]\n[apps.notepad]\n[apps.hello-example]\n',extra='hello-example "'+str(hello)+'"')
    assert result.returncode==1,result.stderr
    assert [r['app'] for r in records]==['publish','notepad','hello-example'],records
    assert 'hello-example' in rows and rows['hello-example']['repo']==str(hello)
    print('PASS failed app continues to remaining apps, aggregates failure, and honors live hello-example explicit path')
    (publish/'install.sh').write_text('exit 0\n')
    result,records,rows=run('[apps.publish]\n',platform_rc=23)
    assert result.returncode==23 and [r['app'] for r in records]==['publish']
    print('PASS platform failure still applies selected app and retains nonzero status')
    result,records,rows=run('[apps.missing]\n[apps.publish]\n')
    assert result.returncode==1,result.stderr
    assert [r['app'] for r in records]==['publish'] and 'publish' in rows
    assert 'not a directory' in result.stderr
    print('PASS missing source reports failure, continues to selected publish, and aggregates nonzero status')
    result,records,rows=run('[apps.publish]\n',{'bad-source':{'repo':None},'--bad-id':{}})
    assert result.returncode==0,result.stderr
    assert [r['app'] for r in records]==['publish']
    assert rows['bad-source']=={'repo':None} and rows['--bad-id']=={}
    print('PASS unrelated malformed installed source rows do not block selected fresh apply')
    option=package('--source')
    result,records,rows=run('[apps."--source"]\n[apps.publish]\n')
    assert result.returncode==0,result.stderr
    assert [r['app'] for r in records]==['--source','publish'],records
    assert rows['--source']['repo']==str(option)
    print('PASS option-shaped app ID crosses real CLI parser as an ID and retains explicit source')
    result,records,rows=run('[apps.fileview]\n[apps.publish]\n',{'fileview':{'repo':None}})
    assert result.returncode==1,result.stderr
    assert [r['app'] for r in records]==['publish'] and 'publish' in rows
    print('PASS selected malformed source reaches apply failure without blocking later selected app')
