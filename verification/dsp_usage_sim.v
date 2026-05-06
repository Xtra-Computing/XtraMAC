`timescale 1ns/1ps
`default_nettype none
// =============================================================
// Behavioral stub for Xilinx DSP48E2 used by int/fp multipliers.
// Replaces common/dsp_usage.v in simulation (iverilog has no DSP48E2).
// Product is purely combinational (same cycle).
// =============================================================
module dsp_usage (
    input  wire        clk,
    input  wire [26:0] a,
    input  wire [17:0] b,
    output wire [44:0] product
);
    /* verilator lint_off UNUSED */
    wire _unused_clk = clk;
    /* verilator lint_on UNUSED */
    assign product = $signed(a) * $signed(b);
endmodule
`default_nettype wire
