`timescale 1ns/1ps
`default_nettype none
// 4c wrapper: instantiates ORIGINAL LUT-optimized implementation (_orig4c modules).
module fp8_bf16_dual_mac_4c (
    input  wire        clk,
    input  wire        mode_fp8,
    input  wire [31:0] a32,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  fp8_bf16_dual_mac_orig4c u (
    .clk(clk), .mode_fp8(mode_fp8), .a32(a32), .b16(b16), .c64(c64), .result(result)
  );
endmodule
`default_nettype wire
