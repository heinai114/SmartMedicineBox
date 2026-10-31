from pathlib import Path
import re,json,hashlib
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parents[1]
O=ROOT/'verification'
pool='温度偏高注意防暑低记得添衣'
raw=(O/'temperature_glyphs.js').read_text(encoding='utf-8')
glyphs={c:[int(v,16) for v in re.findall(r'0x[0-9A-Fa-f]+',rows)] for c,rows in re.findall(r"'(.)': \[([^\]]+)\]",raw)}
original=ROOT/'user_source/hdl_source/rtc/temperature_font.dat'
words=[int(w,2) for w in original.read_text().split()]
assert len(words)==4096 and all(v==0 for v in words[2048:])
combined=words.copy()
for index,c in enumerate(pool):
    rows=glyphs[c];assert len(rows)==32 and any(rows)
    expected=np.array(Image.open(O/'gdi_reference'/f'U{ord(c):04X}.png').convert('RGB')).sum(axis=2)>128
    decoded=np.array([[(row>>(31-x))&1 for x in range(32)] for row in rows],dtype=bool)
    assert np.array_equal(expected,decoded),f'GDI/bit orientation mismatch: {c}'
    for y,row in enumerate(rows):
        for b in range(4):combined[2048+index*128+y*4+b]=(row>>(24-b*8))&255
assert combined[:2048]==words[:2048]
payload='\n'.join(f'{w:08b}' for w in combined)+'\n'
for folder in ['TD','user_source/hdl_source/rtc']:(ROOT/folder/'temperature_hint_font.dat').write_text(payload,encoding='ascii')
report={'pass':True,'font':'SimHei','cell_pixels':32,'pool':pool,'glyphs':len(pool),'hint_byte_offset':2048,
 'hint_bytes':len(pool)*128,'original_lower_2048_bytes_identical':True,
 'independent_gdi_pngs_match':True,'original_font_sha256':hashlib.sha256(original.read_bytes()).hexdigest(),
 'combined_font_sha256':hashlib.sha256(payload.encode('ascii')).hexdigest(),
 'generator_sha256':hashlib.sha256((next(p for p in ROOT.parents if (p/'tools/osd/cjk_render.ps1').is_file())/'tools/osd/cjk_render.ps1').read_bytes()).hexdigest()}
(O/'font_audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(report,ensure_ascii=False,indent=2))
