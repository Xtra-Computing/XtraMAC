`timescale 1ns/1ps
`default_nettype none
// =============================================================
// bf16_bf16_bf16_mac_5c :
// 5-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=0, ADD_LAT=3)
//   Delegates to bf16_mac_2lane.
// =============================================================
module bf16_bf16_bf16_mac_5c (
    input  wire        clk,
    input  wire [31:0] a32,
    input  wire [15:0] b16,
    input  wire [31:0] c32,
    output wire [31:0] result
);

  bf16_mac_2lane #(.MUL_LAT(2), .MID_STAGES(0), .ADD_LAT(3)) u (
    .clk   (clk),
    .a32   (a32),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

endmodule
`default_nettype wire
