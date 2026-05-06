`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int4_fp8e5m2_fp8_mac_5c :
// 5-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=0, ADD_LAT=3)
//   Delegates to int4_fp8e5m2_mac.
// =============================================================
module int4_fp8e5m2_fp8_mac_5c (
    input  wire        clk,
    input  wire [7:0] a_int4,
    input  wire [15:0] b_fp8,
    input  wire [31:0] c_fp8,
    output wire [31:0] result
);

  int4_fp8e5m2_mac #(.MUL_LAT(2), .MID_STAGES(0), .ADD_LAT(3)) u (
    .clk   (clk),
    .a_int4  (a_int4),
    .b_fp8  (b_fp8),
    .c_fp8  (c_fp8),
    .result(result)
  );

endmodule
`default_nettype wire
