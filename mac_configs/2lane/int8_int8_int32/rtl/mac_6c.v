`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int8_int8_int32_mac_6c :
// 6-cycle MAC: a * b + c (params: MUL_LAT=2, MID_STAGES=1, ADD_LAT=3)
//   Core int32_mac_2lane gives 4-cycle latency (MUL_LAT + MID_STAGES + 1).
//   Two extra output register stages bring total latency to 6.
// =============================================================
module int8_int8_int32_mac_6c (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire  [7:0] b8,
    input  wire [63:0] c64,
    output wire [63:0] result
);

  wire [63:0] core_result;

  int32_mac_2lane #(.MUL_LAT(2), .MID_STAGES(1)) u (
    .clk   (clk),
    .a16   (a16),
    .b8    (b8),
    .c64   (c64),
    .result(core_result)
  );

  reg [63:0] result_q1, result_q2;
  always @(posedge clk) begin
    result_q1 <= core_result;
    result_q2 <= result_q1;
  end
  assign result = result_q2;

endmodule
`default_nettype wire
