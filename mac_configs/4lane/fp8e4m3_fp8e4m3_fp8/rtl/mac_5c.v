`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp8e4m3_fp8e4m3_fp8_mac_5c :
// 5-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=0, ADD_LAT=3)
//   Delegates to fp8e4m3_mac_4lane.
// =============================================================
module fp8e4m3_fp8e4m3_fp8_mac_5c (
    input  wire        clk,
    input  wire [15:0] a_fp8,
    input  wire [15:0] b_fp8,
    input  wire [31:0] c_fp8,
    output wire [31:0] result
);

  fp8e4m3_mac_4lane #(.MUL_LAT(2), .MID_STAGES(0), .ADD_LAT(3)) u (
    .clk   (clk),
    .a_fp8  (a_fp8),
    .b_fp8  (b_fp8),
    .c_fp8  (c_fp8),
    .result(result)
  );

endmodule
`default_nettype wire
