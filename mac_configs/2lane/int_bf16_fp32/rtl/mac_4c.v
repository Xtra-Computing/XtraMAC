`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int_bf16_fp32_mac_4c :
// 4-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=0, ADD_LAT=2)
//   Delegates to int_bf16_fp32_mac.
// =============================================================
module int_bf16_fp32_mac_4c (
    input  wire        clk,
    input  wire [15:0] a_int,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);

  int_bf16_fp32_mac #(.INT_WIDTH(8), .MUL_LAT(2), .MID_STAGES(0), .ADD_LAT(2)) u (
    .clk   (clk),
    .a_int (a_int),
    .b16   (b16),
    .c64   (c64),
    .result(result)
  );

endmodule
`default_nettype wire
