`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int_bf16_bf16_mac_5c :
// 5-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=0, ADD_LAT=3)
//   Delegates to int_bf16_mac.
// =============================================================
module int_bf16_bf16_mac_5c (
    input  wire        clk,
    input  wire [15:0] a_int,
    input  wire [15:0] b16,
    input  wire [31:0] c32,
    output wire [31:0] result
);

  int_bf16_mac #(.WIDTH(8), .MUL_LAT(2), .MID_STAGES(0), .ADD_LAT(3)) u (
    .clk   (clk),
    .a_int (a_int),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

endmodule
`default_nettype wire
