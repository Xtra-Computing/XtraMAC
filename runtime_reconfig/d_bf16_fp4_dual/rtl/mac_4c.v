`timescale 1ns/1ps
`default_nettype none
// 4-cycle wrapper: instantiates the ORIGINAL implementation (LUT-optimized).
// The original RTL lives in *_orig4c.v files (modules suffixed _orig4c).
module bf16_fp4_dual_mac_4c (
    input  wire        clk,
    input  wire        mode_fp4,
    input  wire [31:0] a_data,
    input  wire [15:0] b_bf16,
    input  wire [31:0] c_bf16,
    output wire [31:0] result
);
  bf16_fp4_dual_mac_orig4c u (
    .clk(clk), .mode_fp4(mode_fp4), .a_data(a_data),
    .b_bf16(b_bf16), .c_bf16(c_bf16), .result(result)
  );
endmodule
`default_nettype wire
