"""Build through the installed, unmodified TD DefaultFlow without GUI scheduling."""
from pathlib import Path
import copy
import hashlib
import json
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
import time
import sys

ROOT = Path(__file__).resolve().parent
TD = ROOT/'TD'
tool = Path(shutil.which('td') or 'D:/fpga/bin/td.exe').parent
cli = tool/'td_commands_prompt.exe'
flow = tool.parent/'doc/scripts/DefaultFlow.tcl'
assert cli.exists() and flow.exists()
# TD GUI may save a bare ampersand in this attribute name. Normalize only
# that known serialization token in memory; do not rewrite an open GUI project.
doc = ET.fromstring((TD/'SmartMedicineBox.al').read_text(encoding='utf-8').replace('UsedInP&R','UsedInP&amp;R'))
settings_common = '''set ADCList {"../../../user_source/constraints_source/pin.adc" "../../../user_source/constraints_source/sdram_io.adc" "../../../user_source/constraints_source/reminder_outputs.adc" "../../../user_source/constraints_source/keypad_io.adc"}
set IpSDCList { rfifo_32_32_512 ../../../user_source/hdl_source/IP/afifo_32_16_256.tcl wfifo_32_32_512 ../../../user_source/hdl_source/IP/afifo_16_32_256.tcl }
set SDCList {"../../../user_source/constraints_source/timing.sdc" "../../../user_source/constraints_source/rtc_inputs.sdc"}
set area_option -packarea
set device_name eagle_s20.db
set package_name EG4S20BG256
set prj_name {SmartMedicineBox}
set top_model_name {top}
'''
for name in ['syn_1','phy_1']:
    if name=='syn_1' and '--physical-only' in sys.argv:
        continue
    run = TD/'SmartMedicineBox_Runs'/name
    run.mkdir(parents=True, exist_ok=True)
    prj = copy.deepcopy(doc)
    prj.attrib.pop('Path', None)
    for tag in ['Runs','Project_Settings']:
        node = prj.find(tag)
        if node is not None:
            prj.remove(node)
    for node in prj.findall('.//File'):
        node.set('Path', (TD/node.get('Path')).resolve().as_posix())
    tree = ET.ElementTree(prj)
    ET.indent(tree, space='    ')
    tree.write(run/'SmartMedicineBox.prj', encoding='UTF-8', xml_declaration=True)
    # Resolve all ROMs in the run directory as well as the GUI project root.
    for asset in TD.iterdir():
        if asset.suffix.lower() in ['.dat','.hex','.mif']:
            shutil.copy2(asset, run/asset.name)
    specific = ('set end_step opt_gate\nset run_type syn\nset start_step read_design\n' if name=='syn_1' else
                'set arr_filter false\nset drHoldFix on\nset end_step bitgen\nset parent ../syn_1\nset run_type phy\nset start_step opt_place\n')
    if name=='syn_1':
        specific+='set synWildParams {gate pack_effort high}\n'
    if name=='phy_1':
        specific+='set phyWildParams {place seed 1 place pack_mode more_lut_pair route effort routability}\n'
    (run/'settings.cfg').write_text(settings_common+specific, encoding='ascii')
    wrapper = f'source {{{flow.as_posix()}}}\n'
    if name=='phy_1':
        wrapper += f'write_verilog {{{(ROOT/"verification/temperature_routed.v").as_posix()}}}\n'
    wrapper += 'exit\n'
    (run/'SmartMedicineBox.tcl').write_text(wrapper,encoding='utf-8')
    print('Building', name, flush=True)
    started = time.time()
    with (run/'direct.log').open('wb') as log:
        p = subprocess.run([str(cli),'SmartMedicineBox.tcl'],cwd=run,stdout=log,stderr=subprocess.STDOUT)
    marker = run/('.opt_gate.end.f' if name=='syn_1' else '.bitgen.end.f')
    output = run/('SmartMedicineBox_gate.db' if name=='syn_1' else 'SmartMedicineBox.bit')
    assert p.returncode==0 and marker.exists() and output.exists() and output.stat().st_mtime>=started-2, f'Failed {name}: see {run}/direct.log'
    if name=='phy_1':
        timing=(run/'SmartMedicineBox_phy.ts').read_text()
        assert 'STNS: 0.000ns' in timing and 'HTNS: 0.000ns' in timing, f'Timing failed: {timing}'
        assert float(re.search(r'SWNS: ([\d.-]+)ns',timing)[1])>=0
        assert float(re.search(r'HWNS: ([\d.-]+)ns',timing)[1])>=0
    print('Completed', name, flush=True)
bit = TD/'SmartMedicineBox_Runs/phy_1/SmartMedicineBox.bit'
shutil.copy2(bit, ROOT.parent/'SmartMedicineBox.bit')
(ROOT/'verification/build_tool.json').write_text(json.dumps({
    'cli':str(cli),'default_flow_sha256':hashlib.sha256(flow.read_bytes()).hexdigest(),
    'bit_sha256':hashlib.sha256(bit.read_bytes()).hexdigest(),
    'flow':'Unmodified DefaultFlow; gate pack_effort high; place seed 1; place pack_mode more_lut_pair; route effort routability; arr_filter false; no separate post-route fix_hold command'
},indent=2),encoding='utf-8')
print('Built', ROOT.parent/'SmartMedicineBox.bit', flush=True)
