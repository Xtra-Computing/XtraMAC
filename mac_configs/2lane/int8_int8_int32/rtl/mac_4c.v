`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int8_int8_int32_mac_4c :
// 4-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=0, ADD_LAT=2)
//   Core int32_mac_2lane gives 3-cycle latency (MUL_LAT + MID_STAGES + 1).
//   One extra output register stage brings total latency to 4.
// =============================================================
module int8_int8_int32_mac_4c (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire  [7:0] b8,
    input  wire [63:0] c64,
    output wire [63:0] result
);

  wire [63:0] core_result;

  int32_mac_2lane #(.MUL_LAT(2), .MID_STAGES(0)) u (
    .clk   (clk),
    .a16   (a16),
    .b8    (b8),
    .c64   (c64),
    .result(core_result)
  );

  reg [63:0] result_q;
  always @(posedge clk) result_q <= core_result;
  assign result = result_q;

endmodule
`default_nettype wire
