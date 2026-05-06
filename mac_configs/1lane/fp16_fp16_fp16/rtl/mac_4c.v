`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp16_fp16_fp16_mac_4c :
// 4-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=0, ADD_LAT=2)
//   Delegates to fp16_mac_1lane.
// =============================================================
module fp16_fp16_fp16_mac_4c (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [15:0] c16,
    output wire [15:0] result
);

  fp16_mac_1lane #(.MUL_LAT(2), .MID_STAGES(0), .ADD_LAT(2)) u (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .c16   (c16),
    .result(result)
  );

endmodule
`default_nettype wire
