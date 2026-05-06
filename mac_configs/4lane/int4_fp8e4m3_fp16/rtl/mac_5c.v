`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int4_fp8e4m3_fp16_mac_5c :
// 5-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=0, ADD_LAT=3)
//   Delegates to int4_fp8e4m3_16_mac.
// =============================================================
module int4_fp8e4m3_fp16_mac_5c (
    input  wire        clk,
    input  wire [7:0]  a_int4,
    input  wire [15:0] b_fp8,
    input  wire [63:0] c_fp16,
    output wire [63:0] result
);

  int4_fp8e4m3_16_mac #(.MUL_LAT(2), .MID_STAGES(0), .ADD_LAT(3)) u (
    .clk    (clk),
    .a_int4 (a_int4),
    .b_fp8  (b_fp8),
    .c_fp16 (c_fp16),
    .result (result)
  );

endmodule
`default_nettype wire
