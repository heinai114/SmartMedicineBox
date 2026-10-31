// Dedicated open-drain I2C bus. Every high phase waits for synchronized SCL;
// timeout releases both wires. No derived clock, SD/audio dependency or FIFO.
module rtc_i2c_master #(
    parameter integer CLK_HZ=25000000, BUS_HZ=100000,
    parameter integer TIMEOUT_QUARTERS=1000
)(
    input clk, rst, request, input [2:0] command,
    input [7:0] write_data, input read_nack,
    output reg busy, done, error, nack, output reg [7:0] read_data,
    inout scl, sda
);
localparam START=0, STOP=1, WRITE=2, READ=3, RECOVER=4;
localparam integer DIV=(CLK_HZ+BUS_HZ*4-1)/(BUS_HZ*4);
localparam integer CB=DIV>1?$clog2(DIV):1;
localparam integer TB=$clog2(TIMEOUT_QUARTERS+1);
reg scl_low, sda_low;
assign scl=scl_low?1'b0:1'bz;
assign sda=sda_low?1'b0:1'bz;
(* async_reg="true",syn_preserve=1 *) reg [1:0] scl_sync, sda_sync;
always @(posedge clk or posedge rst) begin
    if(rst) begin scl_sync<=3; sda_sync<=3; end
    else begin scl_sync<={scl_sync[0],scl}; sda_sync<={sda_sync[0],sda}; end
end
reg [CB-1:0] divider;
reg [TB-1:0] stretch;
reg [2:0] op;
reg [2:0] phase;
reg [3:0] bit_index;
reg [7:0] tx;
reg last_nack;
wire tick=divider==DIV-1;
wire waiting_high=(op==START && phase==0) || (op==STOP && phase==1) ||
                  ((op==WRITE || op==READ || op==RECOVER) && phase==2);
always @(posedge clk or posedge rst) begin
    if(rst) begin
        busy<=0; done<=0; error<=0; nack<=0; read_data<=0;
        scl_low<=0; sda_low<=0; divider<=0; stretch<=0;
        op<=START; phase<=0; bit_index<=0; tx<=0; last_nack<=1;
    end else begin
        done<=0;
        if(!busy) begin
            divider<=0; stretch<=0;
            if(request) begin
                busy<=1; error<=0; nack<=0; op<=command; phase<=0;
                bit_index<=0; tx<=write_data; last_nack<=read_nack;
                if(command==START) begin scl_low<=0; sda_low<=0; end
                else if(command==STOP) begin scl_low<=1; sda_low<=1; end
                else begin scl_low<=1; sda_low<=0; end
            end
        end else if(tick) begin
            divider<=0;
            if(waiting_high && !scl_sync[1]) begin
                if(stretch==TIMEOUT_QUARTERS-1) begin
                    busy<=0; done<=1; error<=1; scl_low<=0; sda_low<=0;
                end else stretch<=stretch+1'b1;
            end else begin
                stretch<=0;
                case(op)
                    START: case(phase)
                        0: if(!sda_sync[1]) begin
                            busy<=0; done<=1; error<=1; scl_low<=0; sda_low<=0;
                        end else phase<=1;
                        1: begin sda_low<=1; phase<=2; end
                        2: phase<=3; // Standard-mode START hold >= 4us.
                        3: begin scl_low<=1; busy<=0; done<=1; end
                    endcase
                    STOP: case(phase)
                        0: begin scl_low<=0; phase<=1; end
                        1: phase<=2;
                        2: begin sda_low<=0; phase<=3; end
                        3: begin busy<=0; done<=1; end
                    endcase
                    WRITE,READ,RECOVER: case(phase)
                        0: begin
                            if(op==WRITE) sda_low<=bit_index<8?!tx[7-bit_index]:1'b0;
                            else if(op==READ) sda_low<=bit_index==8 && !last_nack;
                            else sda_low<=0;
                            phase<=1; // SDA settles one quarter before SCL rises.
                        end
                        1: begin scl_low<=0; phase<=2; end
                        2: begin
                            if(op==WRITE && bit_index==8) nack<=sda_sync[1];
                            if(op==READ && bit_index<8) read_data<={read_data[6:0],sda_sync[1]};
                            phase<=3;
                        end
                        3: begin
                            scl_low<=1;
                            if(bit_index==8) begin
                                sda_low<=0;
                                if(op==RECOVER) begin op<=STOP; phase<=0; sda_low<=1; end
                                else begin busy<=0; done<=1; end
                            end else begin bit_index<=bit_index+1'b1; phase<=0; end
                        end
                    endcase
                    default: begin busy<=0; done<=1; error<=1; scl_low<=0; sda_low<=0; end
                endcase
            end
        end else divider<=divider+1'b1;
    end
end
endmodule

// Atomic register burst at fixed 7-bit address 0x68. A failed byte leads to
// STOP, never partial publication. Nine recovery clocks run at boot/after error.
module rtc_i2c_registers #(
    parameter integer CLK_HZ=25000000, BUS_HZ=100000, TIMEOUT_QUARTERS=1000,
    parameter integer EEPROM_SUPPORT=0
)(
    input clk,rst,request,is_read, input [7:0] address,
    input [3:0] length, input [55:0] write_data,
    output reg busy,done,error, output reg [55:0] read_data,
    input [6:0] device_address,input wide_address,input [7:0] address_low,
    inout scl,sda
);
localparam CLEAR=0,S_BEGIN=1,ADDR_W=2,REG_ADDR=3,S_RESTART=4,ADDR_R=5,
           DATA_W=6,DATA_R=7,S_END=8,REG_LOW=9;
reg [3:0] state,index,count;
reg direction, inflight, recovery;
reg [7:0] reg_address;
reg [6:0] slave_address;
reg two_address_bytes;
reg [7:0] low_address;
reg [55:0] payload;
reg cmd_request;
reg [2:0] cmd;
reg [7:0] byte_tx;
reg byte_nack;
wire m_busy,m_done,m_error,m_nack;
wire [7:0] byte_rx;
rtc_i2c_master #(.CLK_HZ(CLK_HZ),.BUS_HZ(BUS_HZ),.TIMEOUT_QUARTERS(TIMEOUT_QUARTERS)) u_master(
    .clk(clk),.rst(rst),.request(cmd_request),.command(cmd),.write_data(byte_tx),
    .read_nack(byte_nack),.busy(m_busy),.done(m_done),.error(m_error),.nack(m_nack),
    .read_data(byte_rx),.scl(scl),.sda(sda)
);
always @(posedge clk or posedge rst) begin
    if(rst) begin
        busy<=0; done<=0; error<=0; read_data<=0; state<=CLEAR;
        index<=0; count<=0; direction<=0; inflight<=0; recovery<=1;
        reg_address<=0; payload<=0; cmd_request<=0; cmd<=0; byte_tx<=0; byte_nack<=1;
        slave_address<=7'h68;two_address_bytes<=0;low_address<=0;
    end else begin
        done<=0; cmd_request<=0;
        if(!busy) begin
            if(request) begin
                busy<=1; error<=0; read_data<=0; index<=0; inflight<=0;
                count<=length; direction<=is_read; reg_address<=address; payload<=write_data;
                slave_address<=EEPROM_SUPPORT?device_address:7'h68;
                two_address_bytes<=EEPROM_SUPPORT&&wide_address;low_address<=address_low;
                state<=recovery?CLEAR:S_BEGIN;
            end
        end else if(!inflight && !m_busy) begin
            inflight<=1; cmd_request<=1; byte_nack<=index==count-1;
            case(state)
                CLEAR: cmd<=4;
                S_BEGIN,S_RESTART: cmd<=0;
                ADDR_W: begin cmd<=2; byte_tx<={slave_address,1'b0}; end
                REG_ADDR: begin cmd<=2; byte_tx<=reg_address; end
                REG_LOW: begin cmd<=2; byte_tx<=low_address; end
                ADDR_R: begin cmd<=2; byte_tx<={slave_address,1'b1}; end
                DATA_W: begin cmd<=2; byte_tx<=payload[7:0]; end
                DATA_R: cmd<=3;
                default: cmd<=1;
            endcase
        end else if(inflight && m_done) begin
            inflight<=0;
            if(state==S_END) begin
                busy<=0; done<=1; error<=error||m_error;
                recovery<=error||m_error;
            end else if(m_error ||
                ((state==ADDR_W||state==REG_ADDR||state==REG_LOW||state==ADDR_R||state==DATA_W)&&m_nack)) begin
                error<=1; state<=S_END;
            end else case(state)
                CLEAR: begin recovery<=0; state<=S_BEGIN; end
                S_BEGIN: state<=ADDR_W;
                ADDR_W: state<=REG_ADDR;
                REG_ADDR: state<=two_address_bytes?REG_LOW:(direction?S_RESTART:DATA_W);
                REG_LOW: state<=direction?S_RESTART:DATA_W;
                S_RESTART: state<=ADDR_R;
                ADDR_R: state<=DATA_R;
                DATA_W: begin
                    payload<={8'd0,payload[55:8]};
                    if(index==count-1) state<=S_END;
                    else index<=index+1'b1;
                end
                DATA_R: begin
                    read_data[index*8 +: 8]<=byte_rx;
                    if(index==count-1) state<=S_END;
                    else index<=index+1'b1;
                end
                default: state<=S_END;
            endcase
        end
    end
end
endmodule
