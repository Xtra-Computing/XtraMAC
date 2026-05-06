`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp4e2m1_fp8e4m3_fp8_mac_4c :
// 4-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=0, ADD_LAT=2)
//   Delegates to fp4e2m1_fp8e4m3_mac.
// =============================================================
module fp4e2m1_fp8e4m3_fp8_mac_4c (
    input  wire        clk,
    input  wire [7:0] a_fp4,
    input  wire [15:0] b_fp8,
    input  wire [31:0] c_fp8,
    output wire [31:0] result
);

  fp4e2m1_fp8e4m3_mac #(.MUL_LAT(2), .MID_STAGES(0), .ADD_LAT(2)) u (
    .clk   (clk),
    .a_fp4  (a_fp4),
    .b_fp8  (b_fp8),
    .c_fp8  (c_fp8),
    .result(result)
  );

endmodule
`default_nettype wire
