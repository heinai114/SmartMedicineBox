// Project-owned memory clock candidate. Official generated sys_pll is unchanged.
// The accepted system PLL uses a 1 GHz VCO with its 100 MHz output as feedback.
// MEM_DIV changes only the two memory outputs. SD remains exactly 100 MHz.
module sdram_timing_pll #(
    parameter MEM_DIV = 12,
    parameter SDR_PHASE = 0
) (
    input refclk,
    input reset,
    output clk0_out,
    output clk1_out,
    output clk2_out
);
    wire clk0_buf;
    wire [4:0] pll_clocks;
    assign clk0_buf = pll_clocks[0];
    assign clk1_out = pll_clocks[1];
    assign clk2_out = pll_clocks[2];
    EG_LOGIC_BUFG bufg_feedback (.i(clk0_buf), .o(clk0_out));
    EG_PHY_PLL #(
        .DPHASE_SOURCE("DISABLE"),
        .DYNCFG("DISABLE"),
        .FIN("50.000000"),
        .FEEDBK_MODE("NORMAL"),
        .FEEDBK_PATH("CLKC0_EXT"),
        .STDBY_ENABLE("DISABLE"),
        .PLLRST_ENA("ENABLE"),
        .SYNC_ENABLE("DISABLE"),
        .GMC_GAIN(4),
        .ICP_CURRENT(29),
        .KVCO(4),
        .LPF_CAPACITOR(1),
        .LPF_RESISTOR(2),
        .REFCLK_DIV(1),
        .FBCLK_DIV(2),
        .CLKC0_ENABLE("ENABLE"),
        .CLKC0_DIV(10),
        .CLKC0_CPHASE(9),
        .CLKC0_FPHASE(0),
        .CLKC1_ENABLE("ENABLE"),
        .CLKC1_DIV(MEM_DIV),
        .CLKC1_CPHASE(MEM_DIV - 1),
        .CLKC1_FPHASE(0),
        .CLKC2_ENABLE("ENABLE"),
        .CLKC2_DIV(MEM_DIV),
        .CLKC2_CPHASE(SDR_PHASE == 180 ? MEM_DIV / 2 - 1 : MEM_DIV - 1),
        .CLKC2_FPHASE(0)
    ) pll_inst (
        .refclk(refclk), .reset(reset), .stdby(1'b0), .fbclk(clk0_out),
        .load_reg(1'b0), .psclk(1'b0), .psdown(1'b0), .psstep(1'b0),
        .psclksel(3'b000), .dclk(1'b0), .dcs(1'b0), .dwe(1'b0),
        .di(8'd0), .daddr(6'd0), .clkc(pll_clocks)
    );
endmodule
