`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp8e4m3_bf16_fp32_mac_5c :
// 5-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=0, ADD_LAT=3)
//   Delegates to fp8e4m3_bf16_fp32_mac.
// =============================================================
module fp8e4m3_bf16_fp32_mac_5c (
    input  wire        clk,
    input  wire [15:0] a_fp8,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);

  fp8e4m3_bf16_fp32_mac #(.MUL_LAT(2), .MID_STAGES(0), .ADD_LAT(3)) u (
    .clk   (clk),
    .a_fp8 (a_fp8),
    .b16   (b16),
    .c64   (c64),
    .result(result)
  );

endmodule
`default_nettype wire
