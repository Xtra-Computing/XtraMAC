`timescale 1ns/1ps
`default_nettype none
// 4c wrapper: instantiates ORIGINAL LUT-optimized implementation (_orig4c modules).
module bf16_int4_shared_mac_4c (
    input  wire        clk,
    input  wire        mode_int4,
    input  wire [31:0] a_data,
    input  wire [15:0] b_bf16,
    input  wire [31:0] c_bf16,
    output wire [31:0] result
);
  // Original ports use a_bf16_int4/b16/c32 names; just remap.
  bf16_int4_shared_mac_orig4c u (
    .clk(clk), .mode_int4(mode_int4),
    .a_bf16_int4(a_data), .b16(b_bf16), .c32(c_bf16), .result(result)
  );
endmodule
`default_nettype wire
