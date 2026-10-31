from sim_utils import run,H,O
run('hint_integration',[O/'tb_hint_integration.v',O/'eg_bram32k_model.v',
    H/'rtc/temperature_hint_control.v',H/'rtc/video_rtc_overlay.v'],'tb_hint_integration')
