`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp4e2m1_bf16_fp32_mac : FP4(E2M1) x BF16 + FP32 -> FP32 (2-lane)
//   - Converts FP4 E2M1 input to BF16, then calls bf16_fp32_mac_2lane
//   - FP4 E2M1: {sign[3], exp[2:1](2b, bias=1), man[0](1b)}
//   - Two FP4 lanes packed in a_fp4[7:0] = {hi[7:4], lo[3:0]}
// =============================================================
module fp4e2m1_bf16_fp32_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 1,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire [7:0]  a_fp4,   // packed FP4 E2M1 {hi[7:4], lo[3:0]}
    input  wire [15:0] b16,     // shared BF16
    input  wire [63:0] c64,     // FP32 addends {hi, lo}
    output wire [63:0] result   // FP32 results {hi, lo}
);

  // Convert FP4 E2M1 to BF16
  // FP4 E2M1: sign(1) | exp(2, bias=1) | man(1)
  // Mapping: bf16_exp = fp4_exp - 1 + 127 = fp4_exp + 126
  //          bf16_man = {fp4_man, 6'b000000}
  // Special: exp=0 -> zero (FTZ); exp=3,man=1 -> NaN; exp=3,man=0 -> Inf

  function [15:0] fp4e2m1_to_bf16;
    input [3:0] fp4;
    reg       s;
    reg [1:0] e;
    reg       m;
    begin
      s = fp4[3];
      e = fp4[2:1];
      m = fp4[0];
      if (e == 2'd0) begin
        fp4e2m1_to_bf16 = {s, 15'd0};
      end else if (e == 2'd3 && m == 1'b1) begin
        fp4e2m1_to_bf16 = 16'h7FC0; // NaN
      end else if (e == 2'd3 && m == 1'b0) begin
        fp4e2m1_to_bf16 = {s, 8'hFF, 7'd0}; // Inf
      end else begin
        fp4e2m1_to_bf16 = {s, ({6'b000000, e} + 8'd126), m, 6'b000000};
      end
    end
  endfunction

  wire [15:0] a_hi_bf16 = fp4e2m1_to_bf16(a_fp4[7:4]);
  wire [15:0] a_lo_bf16 = fp4e2m1_to_bf16(a_fp4[3:0]);
  wire [31:0] a32_bf16  = {a_hi_bf16, a_lo_bf16};

  bf16_fp32_mac_2lane #(
    .MUL_LAT   (MUL_LAT),
    .MID_STAGES(MID_STAGES),
    .ADD_LAT   (ADD_LAT)
  ) u_mac (
    .clk   (clk),
    .a32   (a32_bf16),
    .b16   (b16),
    .c64   (c64),
    .result(result)
  );

endmodule
`default_nettype wire
