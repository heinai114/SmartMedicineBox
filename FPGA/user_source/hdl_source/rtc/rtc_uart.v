// 8N1; separate baud counters on the existing pixel clock, no generated clock.
module rtc_uart_rx #(parameter integer CLK_HZ=25000000,BAUD=115200)(
    input clk,rst,rx, output reg valid,frame_error, output reg [7:0] data
);
localparam integer DIV=(CLK_HZ+BAUD/2)/BAUD;
localparam integer CB=$clog2(DIV+1);
(* async_reg="true",syn_preserve=1 *) reg [1:0] rx_sync;
reg [1:0] state;
reg [CB-1:0] count;
reg [2:0] bit_index;
reg [7:0] work;
always @(posedge clk or posedge rst) begin
    if(rst) begin rx_sync<=3; state<=0; count<=0; bit_index<=0; work<=0; valid<=0; frame_error<=0; data<=0; end
    else begin
        rx_sync<={rx_sync[0],rx}; valid<=0; frame_error<=0;
        case(state)
            0: if(!rx_sync[1]) begin count<=DIV/2-1; state<=1; end
            1: if(count!=0) count<=count-1'b1;
               else if(rx_sync[1]) state<=0;
               else begin count<=DIV-1; state<=2; bit_index<=0; end
            2: if(count!=0) count<=count-1'b1;
               else begin
                   work[bit_index]<=rx_sync[1]; count<=DIV-1;
                   if(bit_index==7) state<=3; else bit_index<=bit_index+1'b1;
               end
            3: if(count!=0) count<=count-1'b1;
               else begin
                   state<=0;
                   if(rx_sync[1]) begin data<=work; valid<=1; end
                   else frame_error<=1;
               end
        endcase
    end
end
endmodule

module rtc_uart_tx #(parameter integer CLK_HZ=25000000,BAUD=115200)(
    input clk,rst,request, input [7:0] data, output reg tx,busy
);
localparam integer DIV=(CLK_HZ+BAUD/2)/BAUD;
localparam integer CB=$clog2(DIV+1);
reg [CB-1:0] count;
reg [3:0] index;
reg [9:0] shift;
always @(posedge clk or posedge rst) begin
    if(rst) begin count<=0; index<=0; shift<=10'h3FF; tx<=1; busy<=0; end
    else if(!busy) begin
        if(request) begin shift<={1'b1,data,1'b0}; tx<=0; busy<=1; count<=DIV-1; index<=0; end
    end else if(count!=0) count<=count-1'b1;
    else if(index==9) begin busy<=0; tx<=1; end
    else begin shift<={1'b1,shift[9:1]}; tx<=shift[1]; index<=index+1'b1; count<=DIV-1; end
end
endmodule
