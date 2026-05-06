`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp8e5m2_fp8e5m2_fp16_mac_4c :
// 4-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=0, ADD_LAT=2)
//   Delegates to fp8e5m2_16_mac_4lane.
// =============================================================
module fp8e5m2_fp8e5m2_fp16_mac_4c (
    input  wire        clk,
    input  wire [31:0] a18,
    input  wire [15:0] b18,
    input  wire [63:0] c64,
    output wire [63:0] result
);

  fp8e5m2_16_mac_4lane #(.MUL_LAT(2), .MID_STAGES(0), .ADD_LAT(2)) u (
    .clk   (clk),
    .a18   (a18),
    .b18   (b18),
    .c64   (c64),
    .result(result)
  );

endmodule
`default_nettype wire
