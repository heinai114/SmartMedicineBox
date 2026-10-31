from pathlib import Path
import array
import hashlib
import json
import re
import subprocess
import time
import wave
import ctypes
import sys
import shutil
import os

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
H = ROOT / 'user_source/hdl_source'
O = ROOT / 'verification'
IV = REPO / 'tools/rtl_sim/icarus/app/bin/iverilog.exe'
VP = IV.with_name('vvp.exe')
LIB = REPO / 'tools/rtl_sim/icarus/app/lib/ivl'
if not VP.is_file() or not (LIB/'ivl.exe').is_file():
    raise FileNotFoundError(
        'Missing portable Icarus runtime. Extract RTL仿真工具.zip from the release '
        'into the repository root (tools/rtl_sim/icarus/app/...). '
        'See tools/rtl_sim/README.md.')
# Use a temporary local runtime if this Windows build cannot accept spaces.
import tempfile
temp_base = os.environ.get('FPGA_SIM_TEMP') or None
short = ctypes.create_unicode_buffer(4096)
assert ctypes.windll.kernel32.GetShortPathNameW(str(LIB), short, len(short))
LIB = Path(short.value)
_runtime_tmp = None
if ' ' in str(LIB):
    _runtime_tmp = tempfile.TemporaryDirectory(prefix='fpga_ivl_', dir=temp_base)
    runtime = Path(_runtime_tmp.name)/'ivl'
    shutil.copytree(LIB, runtime)
    assert ctypes.windll.kernel32.GetShortPathNameW(str(runtime), short, len(short))
    LIB = Path(short.value)
assert ' ' not in str(LIB), 'Icarus requires a runtime path without spaces'
_compile_tmp = tempfile.TemporaryDirectory(prefix='fpga_ivl_tmp_', dir=temp_base)
assert ctypes.windll.kernel32.GetShortPathNameW(_compile_tmp.name, short, len(short))
assert ' ' not in short.value, 'Icarus requires a temporary path without spaces'

test_env = dict(os.environ, TMP=short.value, TEMP=short.value, TMPDIR=short.value)
results = json.loads((O/'tests.json').read_text()) if (O/'tests.json').exists() else {}

def run(name, sources, top):
    start = time.time()
    output = O / (name + '.vvp')
    rel = lambda p: os.path.relpath(p, ROOT/'TD')
    # Invoke the same native preprocessing/compiler helpers directly. This
    # avoids this old Windows driver's access violation during final cleanup.
    listing = O/(name+'.files')
    listing.write_text('\n'.join(map(rel,sources))+'\n',encoding='ascii')
    config = O/(name+'.cfg')
    lines = [f'basedir:{LIB}',f'root:{top}','generation:2012','generation:no-specify',
        'generation:assertions','generation:xtypes','generation:icarus-misc',
        'warnings:n','ignore_missing_modules:false',f'out:{rel(output)}','iwidth:32','widthcap:65536']
    lines += [f'module:{LIB/(n+".vpi")}' for n in ['system','vhdl_sys','vhdl_textio','v2005_math','va_math','v2009']]
    config.write_text('\n'.join(lines)+'\n',encoding='ascii')
    pp = subprocess.run([str(LIB/'ivlpp.exe'),'-L','-f',rel(listing)],cwd=ROOT/'TD',capture_output=True,env=test_env)
    assert pp.returncode==0, pp.stderr
    commands = [[str(LIB/'ivl.exe'),'-C',rel(config),'-C',str(LIB/'vvp.conf'),'--','-'],
                [str(VP),str(output)]]
    for cmd, suffix in zip(commands,['compile','test']):
        p = subprocess.run(cmd, cwd=ROOT / 'TD', input=pp.stdout if suffix=='compile' else None,
            capture_output=True, timeout=900, env=test_env)
        text = (p.stdout + p.stderr).decode('utf-8', errors='replace')
        (O / f'{name}_{suffix}.log').write_text(text, encoding='utf-8')
        if p.returncode or re.search(r'^ERROR:|FATAL:', text, re.M):
            raise RuntimeError(f'return code {p.returncode}: '+text)
    assert 'PASS' in text, text
    print(text.strip(), flush=True)
    results[name] = {'pass': True, 'seconds': round(time.time()-start, 2),
                     'inputs': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
    (O / 'tests.json').write_text(json.dumps(results, indent=2), encoding='utf-8')

