`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp8e4m3_bf16_bf16_mac_4c :
// 4-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=0, ADD_LAT=2)
//   Delegates to fp8e4m3_bf16_mac.
// =============================================================
module fp8e4m3_bf16_bf16_mac_4c (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [31:0] c32,
    output wire [31:0] result
);

  fp8e4m3_bf16_mac #(.MUL_LAT(2), .MID_STAGES(0), .ADD_LAT(2)) u (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

endmodule
`default_nettype wire
