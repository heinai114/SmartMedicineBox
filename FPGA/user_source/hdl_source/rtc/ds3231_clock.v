// Production 25MHz / ~100kHz I2C / 115200 UART. RTC owns real time;
// video never invents elapsed seconds or writes a compile-time timestamp.
module ds3231_clock #(
    parameter integer CLK_HZ=25000000, BUS_HZ=100000, BAUD=115200,
    parameter integer POLL_CYCLES=25000000, PACKET_TIMEOUT=6250000,
    parameter integer I2C_TIMEOUT_QUARTERS=1000,
    parameter integer ENABLE_TEMPERATURE=1,ENABLE_PLAN_EEPROM=0
)(
    input clk,rst,uart_rx, output uart_tx,
    inout rtc_scl,rtc_sda,
    output reg [23:0] time_bcd,date_bcd, output reg [2:0] weekday,
    output reg time_valid,
    // Absolute xxx.xx BCD magnitude; separate sign handles -0.25 correctly.
    output reg [19:0] temperature_bcd,
    output reg temperature_negative,temperature_valid,
    // Optional byte transactions, accepted only between complete RTC polls.
    input plan_request,plan_read,input [6:0] plan_device,
    input [11:0] plan_address,input [7:0] plan_write_data,
    output plan_ready,plan_done,plan_error,output [7:0] plan_read_data
);
localparam integer PB=$clog2(POLL_CYCLES+1), UB=$clog2(PACKET_TIMEOUT+1);
wire rx_valid,rx_error;
wire [7:0] rx_byte;
reg tx_request;
reg [7:0] tx_byte;
wire tx_busy;
rtc_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_rx(
    .clk(clk),.rst(rst),.rx(uart_rx),.valid(rx_valid),.frame_error(rx_error),.data(rx_byte));
rtc_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) u_tx(
    .clk(clk),.rst(rst),.request(tx_request),.data(tx_byte),.tx(uart_tx),.busy(tx_busy));
// Packet: 'RTC1', seven BCD registers in DS3231 order, XOR of preceding 11
// bytes. Replies K=written/read back, E=invalid/fault, B=request already busy.
reg [3:0] packet_pos;
reg [7:0] checksum;
reg [55:0] packet_data,set_data;
reg [UB-1:0] packet_wait;
reg set_pending,calibrating;
function bcd_ok;
    input [7:0] value,limit;
    begin bcd_ok=value[7:4]<=9 && value[3:0]<=9 && value<=limit; end
endfunction
function calendar_ok;
    input [55:0] value;
    reg [7:0] max_day;
    reg [1:0] leap_mod;
    begin
        leap_mod=value[49:48]+(value[52]?2'd2:2'd0);
        case(value[47:40])
            8'h02:max_day=leap_mod==0?8'h29:8'h28;
            8'h04,8'h06,8'h09,8'h11:max_day=8'h30;
            default:max_day=8'h31;
        endcase
        calendar_ok=bcd_ok(value[7:0],8'h59) && bcd_ok(value[15:8],8'h59) &&
            bcd_ok(value[23:16],8'h23) && value[31:24]>=1 && value[31:24]<=7 &&
            bcd_ok(value[39:32],max_day) && value[39:32]!=0 &&
            bcd_ok(value[47:40],8'h12) && value[47:40]!=0 && bcd_ok(value[55:48],8'h99);
    end
endfunction
// Accept a previously configured 12-hour RTC and normalize for the screen.
function [7:0] hour24;
    input [7:0] h;
    reg [4:0] bin_h;
    begin
        if(!h[6]) hour24=h;
        else begin
            bin_h={1'b0,h[3:0]}+(h[4]?5'd10:5'd0);
            if(h[7]||h[3:0]>9||bin_h<1||bin_h>12) hour24=8'hFF;
            else begin
                if(bin_h==12) bin_h=0;
                if(h[5]) bin_h=bin_h+5'd12;
                hour24=bin_h>=20?8'h20+(bin_h-20):bin_h>=10?8'h10+(bin_h-10):bin_h;
            end
        end
    end
endfunction
reg eng_request,eng_read;
reg [7:0] eng_address;
reg [3:0] eng_length;
reg [55:0] eng_write;
wire eng_busy,eng_done,eng_error;
wire [55:0] eng_data;
localparam IDLE=0,CONTROL=1,SET_TIME=2,SET_CONTROL=3,READ_TIME=4,READ_TEMP=5,TEMP_DECIMAL=6;
reg [2:0] state;
reg [PB-1:0] poll_count;
reg poll_due;
generate if(ENABLE_PLAN_EEPROM)begin:g_plan_bus
 wire bus_busy,bus_done,bus_error;wire [55:0] bus_data;
 reg owner;
 assign plan_ready=state==IDLE&&!poll_due&&!set_pending&&!eng_request&&!bus_busy&&!owner;
 wire accept_plan=plan_request&&plan_ready;
 always @(posedge clk or posedge rst)begin
  if(rst)owner<=0;
  else if(accept_plan)owner<=1;
  else if(bus_done)owner<=0;
 end
 assign eng_busy=bus_busy||owner;
 assign eng_done=bus_done&&!owner;
 assign eng_error=bus_error;assign eng_data=bus_data;
 assign plan_done=bus_done&&owner;assign plan_error=bus_error;assign plan_read_data=bus_data[7:0];
 rtc_i2c_registers #(.CLK_HZ(CLK_HZ),.BUS_HZ(BUS_HZ),.TIMEOUT_QUARTERS(I2C_TIMEOUT_QUARTERS),.EEPROM_SUPPORT(1)) u_bus(
  .clk(clk),.rst(rst),.request(eng_request||accept_plan),.is_read(accept_plan?plan_read:eng_read),
  .address(accept_plan?{4'd0,plan_address[11:8]}:eng_address),.address_low(plan_address[7:0]),
  .wide_address(accept_plan),.device_address(accept_plan?plan_device:7'h68),
  .length(accept_plan?4'd1:eng_length),.write_data(accept_plan?{48'd0,plan_write_data}:eng_write),
  .busy(bus_busy),.done(bus_done),.error(bus_error),.read_data(bus_data),.scl(rtc_scl),.sda(rtc_sda));
end else begin:g_original_bus
 assign plan_ready=0;assign plan_done=0;assign plan_error=0;assign plan_read_data=0;
rtc_i2c_registers #(.CLK_HZ(CLK_HZ),.BUS_HZ(BUS_HZ),.TIMEOUT_QUARTERS(I2C_TIMEOUT_QUARTERS)) u_bus(
    .clk(clk),.rst(rst),.request(eng_request),.is_read(eng_read),.address(eng_address),
    .length(eng_length),.write_data(eng_write),.busy(eng_busy),.done(eng_done),
    .error(eng_error),.read_data(eng_data),.scl(rtc_scl),.sda(rtc_sda));
end endgenerate
reg [7:0] temp_binary;
reg [11:0] temp_decimal;
reg [2:0] temp_step;
reg [1:0] temp_fraction;
reg temp_sign;
wire [9:0] temp_quarters={eng_data[7:0],eng_data[15:14]};
wire [9:0] temp_magnitude=temp_quarters[9]?(~temp_quarters+10'd1):temp_quarters;
reg [11:0] temp_adjusted;
always @* begin
    temp_adjusted=temp_decimal;
    if(temp_decimal[3:0]>=5)temp_adjusted[3:0]=temp_decimal[3:0]+4'd3;
    if(temp_decimal[7:4]>=5)temp_adjusted[7:4]=temp_decimal[7:4]+4'd3;
    if(temp_decimal[11:8]>=5)temp_adjusted[11:8]=temp_decimal[11:8]+4'd3;
end
function [7:0] fraction_bcd;
    input [1:0] quarters;
    begin case(quarters)
        0:fraction_bcd=8'h00;1:fraction_bcd=8'h25;
        2:fraction_bcd=8'h50;3:fraction_bcd=8'h75;
    endcase end
endfunction
// Converter working registers are always loaded before entering TEMP_DECIMAL.
// They need no asynchronous reset; validity and all externally visible values
// retain their reset. Reset during conversion aborts via the command state.
always @(posedge clk)begin
    if(state==READ_TEMP&&eng_done&&!eng_error&&!status[2]&&eng_data[13:8]==0)begin
        temp_binary<=temp_magnitude[9:2];temp_fraction<=temp_magnitude[1:0];
        temp_sign<=temp_quarters[9];temp_decimal<=0;temp_step<=0;
    end else if(state==TEMP_DECIMAL)begin
        temp_decimal<={temp_adjusted[10:0],temp_binary[7]};
        temp_binary<={temp_binary[6:0],1'b0};temp_step<=temp_step+1'b1;
    end
end
reg [7:0] control,status;
wire [55:0] normalized={eng_data[55:24],hour24(eng_data[23:16]),eng_data[15:0]};
always @(posedge clk or posedge rst) begin
    if(rst) begin
        packet_pos<=0; checksum<=0; packet_data<=0; set_data<=0; packet_wait<=0;
        set_pending<=0; calibrating<=0; tx_request<=0; tx_byte<=0;
        eng_request<=0; eng_read<=1; eng_address<=0; eng_length<=2; eng_write<=0;
        state<=IDLE; poll_count<=0; poll_due<=1; control<=0; status<=8'h80;
        time_bcd<=0; date_bcd<=0; weekday<=0; time_valid<=0;
        temperature_bcd<=0;temperature_negative<=0;temperature_valid<=0;
    end else begin
        tx_request<=0; eng_request<=0;
        if(poll_count==POLL_CYCLES-1) begin poll_count<=0; poll_due<=1; end
        else poll_count<=poll_count+1'b1;
        if(packet_pos!=0) begin
            if(packet_wait==PACKET_TIMEOUT-1) begin packet_pos<=0; packet_wait<=0; end
            else packet_wait<=packet_wait+1'b1;
        end
        if(rx_error) begin packet_pos<=0; packet_wait<=0; end
        else if(rx_valid) begin
            packet_wait<=0;
            case(packet_pos)
                0: if(rx_byte=="R") begin packet_pos<=1; checksum<=rx_byte; end
                1: if(rx_byte=="T") begin packet_pos<=2; checksum<=checksum^rx_byte; end
                   else begin packet_pos<=rx_byte=="R"?1:0; checksum<=rx_byte; end
                2: if(rx_byte=="C") begin packet_pos<=3; checksum<=checksum^rx_byte; end
                   else begin packet_pos<=rx_byte=="R"?1:0; checksum<=rx_byte; end
                3: if(rx_byte=="1") begin packet_pos<=4; checksum<=checksum^rx_byte; end
                   else begin packet_pos<=rx_byte=="R"?1:0; checksum<=rx_byte; end
                11: begin
                    packet_pos<=0;
                    if(rx_byte!=checksum || !calendar_ok(packet_data)) begin tx_byte<="E"; tx_request<=!tx_busy; end
                    else if(set_pending||calibrating) begin tx_byte<="B"; tx_request<=!tx_busy; end
                    else begin set_data<=packet_data; set_pending<=1; end
                end
                default: begin
                    packet_data<={rx_byte,packet_data[55:8]}; checksum<=checksum^rx_byte;
                    packet_pos<=packet_pos+1'b1;
                end
            endcase
        end
        case(state)
            IDLE: if((poll_due||set_pending) && !eng_busy) begin
                eng_request<=1; eng_read<=1; eng_address<=8'h0E; eng_length<=2;
                state<=CONTROL; poll_due<=0;
            end
            CONTROL: if(eng_done) begin
                if(eng_error) begin
                    time_valid<=0;temperature_valid<=0; state<=IDLE;
                    if(set_pending||calibrating) begin tx_byte<="E"; tx_request<=!tx_busy; set_pending<=0; calibrating<=0; end
                end else begin
                    control<=eng_data[7:0]; status<=eng_data[15:8];
                    eng_request<=1;
                    if(set_pending) begin
                        eng_read<=0; eng_address<=0; eng_length<=7; eng_write<=set_data;
                        set_pending<=0; calibrating<=1; time_valid<=0;temperature_valid<=0; state<=SET_TIME;
                    end else begin eng_read<=1; eng_address<=0; eng_length<=7; state<=READ_TIME; end
                end
            end
            SET_TIME: if(eng_done) begin
                if(eng_error) begin time_valid<=0;temperature_valid<=0; state<=IDLE; calibrating<=0; tx_byte<="E"; tx_request<=!tx_busy; end
                else begin
                    // Enable battery oscillator; preserve other control bits.
                    // Clear OSF, retain EN32kHz; writing 1 preserves alarm flags.
                    eng_request<=1; eng_read<=0; eng_address<=8'h0E; eng_length<=2;
                    eng_write<={40'd0,((status & 8'h7C)|8'h03),(control & 8'h7F)};
                    state<=SET_CONTROL;
                end
            end
            SET_CONTROL: if(eng_done) begin
                if(eng_error) begin time_valid<=0;temperature_valid<=0; state<=IDLE; calibrating<=0; tx_byte<="E"; tx_request<=!tx_busy; end
                else begin
                    eng_request<=1; eng_read<=1; eng_address<=8'h0E; eng_length<=2;
                    state<=CONTROL;
                end
            end
            READ_TIME: if(eng_done) begin
                state<=IDLE;
                if(eng_error || status[7] || control[7] || !calendar_ok(normalized)) begin
                    time_valid<=0;temperature_valid<=0;
                    if(calibrating) begin tx_byte<="E"; tx_request<=!tx_busy; end
                end else begin
                    // Publish one coherent seven-register RTC burst together.
                    time_bcd<={normalized[23:16],normalized[15:8],normalized[7:0]};
                    date_bcd<=normalized[55:32]; weekday<=normalized[26:24]; time_valid<=1;
                    if(calibrating) begin tx_byte<="K"; tx_request<=!tx_busy; end
                    // Read-only extension: no CONV/control writes, and no delay
                    // to time publication or the existing serial K response.
                    if(ENABLE_TEMPERATURE)begin
                        eng_request<=1;eng_read<=1;eng_address<=8'h11;eng_length<=2;
                        state<=READ_TEMP;
                    end
                end
                calibrating<=0;
            end
            READ_TEMP: if(eng_done) begin
                state<=IDLE;
                // Initial conversion (BSY) and corrupt reserved bits never
                // publish a fabricated 0C. Temperature faults leave time valid.
                if(eng_error||status[2]||eng_data[13:8]!=0)temperature_valid<=0;
                else begin
                    state<=TEMP_DECIMAL;
                end
            end
            TEMP_DECIMAL: begin
                // Eight enabled pixel-clock steps avoid a wide divide/modulo
                // network; magnitude and sign publish together only at the end.
                if(temp_step==7)begin
                    temperature_bcd<={temp_adjusted[10:0],temp_binary[7],fraction_bcd(temp_fraction)};
                    temperature_negative<=temp_sign;temperature_valid<=1;state<=IDLE;
                end
            end
        endcase
    end
end
endmodule
