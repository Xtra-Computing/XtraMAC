`timescale 1ns/1ps
`default_nettype none
// =============================================================
// bf16_bf16_fp32_mac_6c :
// 6-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=1, ADD_LAT=3)
//   Delegates to bf16_fp32_mac_2lane.
// =============================================================
module bf16_bf16_fp32_mac_6c (
    input  wire        clk,
    input  wire [31:0] a32,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);

  bf16_fp32_mac_2lane #(.MUL_LAT(2), .MID_STAGES(1), .ADD_LAT(3)) u (
    .clk   (clk),
    .a32   (a32),
    .b16   (b16),
    .c64   (c64),
    .result(result)
  );

endmodule
`default_nettype wire
