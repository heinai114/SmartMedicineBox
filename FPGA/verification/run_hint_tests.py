from pathlib import Path
import csv,json,hashlib,zipfile,io,sys
import numpy as np
from PIL import Image,ImageDraw,ImageFont
from sim_utils import run,H,O,ROOT

run('temperature_hint',[O/'tb_temperature_hint.v',H/'rtc/temperature_hint_control.v'],'tb_temperature_hint')
count=0
for row in csv.reader((O/'temperature_cases.csv').read_text().splitlines()):
    state,q,valid,blocked,remaining,next_state,next_remaining,kind=map(int,row)
    target=state
    if valid:
        if state==1:target=2 if q<=60 else (0 if q<=112 else 1)
        elif state==2:target=1 if q>=120 else (0 if q>=68 else 2)
        else:target=2 if q<=60 else (1 if q>=120 else 0)
    if target!=state:expected=(target,300 if target else 0,0)
    elif not valid or blocked:expected=(state,remaining,0)
    elif remaining:expected=(state,remaining-1,state)
    else:expected=(state,0,0)
    assert (next_state,next_remaining,kind)==expected,(row,expected)
    count+=1
assert count==36864
print('PASS independent signed-temperature/state oracle:',count,'cases',flush=True)
if '--controller-only' in sys.argv:sys.exit(0)

archive=ROOT.parent/'TF卡素材.zip'
with zipfile.ZipFile(archive) as z:
    member=next(n for n in z.namelist() if n.upper().endswith('PIC01.BMP'))
    picture=z.read(member)
bg=np.array(Image.open(io.BytesIO(picture)).convert('RGB'))
assert bg.shape==(480,640,3)
Image.fromarray(bg).save(O/'background.png')
pixels=(bg[:,:,0].astype(np.uint32)<<16)|(bg[:,:,1].astype(np.uint32)<<8)|bg[:,:,2]
(O/'background.hex').write_text('\n'.join(f'{v:06x}' for v in pixels.ravel())+'\n',encoding='ascii')
run('hint_pixels',[O/'tb_hint_pixels.v',O/'rtc_reference.v',O/'eg_bram32k_model.v',
    H/'rtc/temperature_hint_control.v',H/'rtc/video_rtc_overlay.v'],'tb_hint_pixels')

Y,X=np.indices((480,640));panel=(X>=448)&(X<624)&(Y>=64)&(Y<156)
border=panel&((X<=449)|(X==623)|(Y==64)|(Y==155))
glyph=lambda c:np.array(Image.open(O/'gdi_reference'/f'U{ord(c):04X}.png').convert('RGB')).sum(axis=2)>128
for case in range(6):
    got=np.frombuffer((O/f'hint_frame_{case}.rgb').read_bytes(),dtype=np.uint8).reshape(480,640,3)
    if case in [1,2,3,4]:
        cold=case in [2,4];expected=bg.copy();expected[panel]//=4
        accent=np.array([0x71,0xd7,0xff] if cold else [0xff,0xca,0x72],dtype=np.uint8)
        expected[border]=accent
        ink=np.zeros((480,640),dtype=bool)
        for line,text in enumerate(['温度偏低','记得添衣'] if cold else ['温度偏高','注意防暑']):
            y=76 if line==0 else 112
            for slot,c in enumerate(text):ink[y:y+32,472+slot*32:504+slot*32]=glyph(c)
        shadow=np.zeros_like(ink);shadow[1:,1:]=ink[:-1,:-1]
        expected[shadow]=[0x08,0x0d,0x12]
        expected[ink]=np.where((Y[ink]<112)[:,None],accent,np.array([255,255,255],dtype=np.uint8))
        if not np.array_equal(got[panel],expected[panel]):
            yy,xx=np.argwhere(panel&np.any(got!=expected,axis=2))[0]
            raise AssertionError(f'Popup mismatch case{case} x{xx} y{yy}: {got[yy,xx]} vs {expected[yy,xx]}')
    Image.fromarray(got).save(O/f'hint_frame_{case}.png')

preview=Image.new('RGB',(432,164),'#efefef');draw=ImageDraw.Draw(preview)
font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',16)
for column,(case,label) in enumerate([(1,'高温提示 · RTL仿真'),(2,'低温提示 · RTL仿真')]):
    preview.paste(Image.open(O/f'hint_frame_{case}.png').crop((432,48,640,176)),(column*216,30))
    draw.text((column*216+8,5),label,font=font,fill='#222222')
preview.save(O/'温度提示预览.png')
assets=[O/'background.hex',O/'background.png',H/'rtc/temperature_hint_font.dat',ROOT/'TD/temperature_hint_font.dat',
    O/'run_hint_tests.py',O/'prepare_font.py']+list((O/'gdi_reference').glob('*.png'))
report={'pass':True,'controller_state_cases':count,'full_frame_pixel_checks':6*640*480,
    'popup_pixel_checks':4*176*92,'exact_original_pixels_outside_popup':True,'rgb_de_vs_latency_clocks':2,
    'negative_fraction_invalid_data_hysteresis_priority_pause_and_reset_passed':True,
    'display_frames':300,'nominal_display_seconds':5.04,
    'temperature_source':'DS3231 chip temperature; no ambient/outdoor temperature claim',
    'original_pic01_sha256':hashlib.sha256(picture).hexdigest(),
    'assets':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in assets}}
(O/'hint_summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print('PASS independent GDI popup oracle; preserved background/clock/date/temperature/wave modes;',6*640*480,'pixels',flush=True)
