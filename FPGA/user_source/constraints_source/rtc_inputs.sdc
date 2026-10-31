# Dedicated asynchronous external inputs: cut only their first synchronizer
# registers. Original timing.sdc, PLL relations and all downstream timing remain.
# TD packs stage 0 into the input PAD FF during physical placement. Its pin
# must be the endpoint then; never cut to stage 1, a bus or a clock domain.
proc rtc_async_first {port regname padpin} {
    set first [get_regs -nowarn $regname]
    if {[llength $first] == 1} {
        set_false_path -from [get_ports $port] -to $first
    } else {
        set firstpad [get_pins -nowarn $padpin]
        if {[llength $firstpad] == 1} {
            set_false_path -from [get_ports $port] -to $firstpad
        } else { puts "RTC first stage not present at this analysis phase: $port" }
    }
}
rtc_async_first rtc_scl {u_rtc_clock/u_bus/u_master/scl_sync[0]} rtc_scl_syn_4.bpad
rtc_async_first rtc_sda {u_rtc_clock/u_bus/u_master/sda_sync[0]} rtc_sda_syn_4.bpad
rtc_async_first rtc_uart_rx {u_rtc_clock/u_rx/rx_sync[0]} rtc_uart_rx_syn_4.ipad
