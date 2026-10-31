"""Check the GitHub copy without building or accessing hardware.

--prepare-project sets only the TD project's root path for its current location.
--media additionally checks TF卡素材.zip downloaded into the repository root.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import quoteattr
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BIT_HASH = '0c5745ba20e62ad42a73875f82fb984d5210627f06e1f84fb4f0a05269241c8a'

def digest(data):
    return hashlib.sha256(data).hexdigest()

def sha(path):
    return digest(path.read_bytes())

def load(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))

def require(ok, message):
    if not ok:
        raise ValueError(message)

def project_tree(path):
    return ET.fromstring(path.read_text(encoding='utf-8-sig').replace('UsedInP&R', 'UsedInP&amp;R'))

def project_hash(path):
    tree = project_tree(path)
    tree.attrib.pop('Path', None)
    return digest(ET.tostring(tree, encoding='utf-8'))

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--prepare-project', action='store_true')
    ap.add_argument('--media', action='store_true')
    args = ap.parse_args()
    project = ROOT/'FPGA/TD/SmartMedicineBox.al'
    if args.prepare_project:
        data = project.read_text(encoding='utf-8')
        data = re.sub(r'(<Project\b[^>]*?)\s+Path="[^"]*"', r'\1', data, count=1)
        data = data.replace('<Project ', '<Project Path='+quoteattr(project.parent.as_posix())+' ', 1)
        with project.open('w', encoding='utf-8', newline='\n') as stream:
            stream.write(data)

    protected = load(ROOT/'docs/源码校验.json')
    require(len(protected) == 180, 'Unexpected protected input inventory')
    for name, expected in protected.items():
        p = ROOT/'FPGA'/name
        require(p.is_file() and sha(p) == expected, 'Protected input mismatch: '+name)
    bit = ROOT/'SmartMedicineBox.bit'
    require(bit.stat().st_size == 716924 and sha(bit) == BIT_HASH, 'Main bit mismatch')

    tree = project_tree(project)
    refs = tree.findall('.//File')
    for item in refs:
        value = item.get('Path')
        require(value and not Path(value).is_absolute(), 'Non-relative project input: '+str(value))
        p = (project.parent/value).resolve()
        require(p.is_relative_to((ROOT/'FPGA').resolve()) and p.is_file(), 'Missing/external project input: '+value)
    expected_params = {'syn_1': [('gate', 'pack_effort', 'high')],
                       'phy_1': [('place', 'seed', '1'), ('place', 'pack_mode', 'more_lut_pair'),
                                 ('route', 'effort', 'routability')]}
    for run_name, params in expected_params.items():
        run = tree.find('Runs/Run[@Name="'+run_name+'"]')
        require(run is not None, 'Missing run strategy: '+run_name)
        commands = [p.text for p in run.findall('UserParams/param')]
        for stage, key, value in params:
            node = run.find('Strategy/'+stage.title()+'Property/'+key)
            require(node is not None and node.text == value, 'Strategy mismatch: '+key)
            require('set_param '+stage+' '+key+' '+value in commands, 'UserParams mismatch: '+key)

    manifest = load(ROOT/'docs/发布文件清单.json')
    for name, expected in manifest['files'].items():
        p = ROOT/name
        require(p.is_file(), 'Missing repository file: '+name)
        actual = project_hash(p) if name == 'FPGA/TD/SmartMedicineBox.al' else sha(p)
        require(actual == expected, 'Repository file mismatch: '+name)
    if args.media:
        source = ROOT/'TF卡素材.zip'
        require(source.is_file(), 'Download TF卡素材.zip from Releases into the repository root')
        media = load(ROOT/'docs/TF素材校验.json')
        with zipfile.ZipFile(source) as z:
            require(z.testzip() is None and set(z.namelist()) == set(media), 'TF archive inventory/CRC mismatch')
            for name, expected in media.items():
                require(digest(z.read(name)) == expected, 'TF media mismatch: '+name)
        print('PASS: 25 TF media files match the accepted archive.')
    print(f'PASS: {len(protected)} protected inputs, main bit, {len(refs)} relative project references and build strategies.')
    print(f'PASS: {len(manifest["files"])} repository files; no build or hardware access performed.')

if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    try:
        main()
    except Exception as exc:
        print('FAIL:', exc)
        sys.exit(1)
