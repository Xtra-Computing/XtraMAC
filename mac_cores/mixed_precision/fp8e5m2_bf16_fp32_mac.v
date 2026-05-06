`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp8e5m2_bf16_fp32_mac : FP8(E5M2) x BF16 + FP32 -> FP32 (2-lane)
//   - Converts FP8 E5M2 input to BF16, then calls bf16_fp32_mac_2lane
//   - FP8 E5M2: {sign[7], exp[6:2](5b, bias=15), man[1:0](2b)}
//   - Two FP8 lanes packed in a_fp8[15:0] = {hi[15:8], lo[7:0]}
// =============================================================
module fp8e5m2_bf16_fp32_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 1,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire [15:0] a_fp8,   // packed FP8 E5M2 {hi[15:8], lo[7:0]}
    input  wire [15:0] b16,     // shared BF16
    input  wire [63:0] c64,     // FP32 addends {hi, lo}
    output wire [63:0] result   // FP32 results {hi, lo}
);

  // Convert FP8 E5M2 to BF16
  // FP8 E5M2: sign(1) | exp(5, bias=15) | man(2)
  // BF16:     sign(1) | exp(8, bias=127) | man(7)
  // Mapping: bf16_exp = fp8_exp - 15 + 127 = fp8_exp + 112
  //          bf16_man = {fp8_man, 5'b00000}
  // Special: exp=0 -> zero (FTZ); exp=31,man!=0 -> NaN; exp=31,man=0 -> Inf

  function [15:0] fp8e5m2_to_bf16;
    input [7:0] fp8;
    reg       s;
    reg [4:0] e;
    reg [1:0] m;
    begin
      s = fp8[7];
      e = fp8[6:2];
      m = fp8[1:0];
      if (e == 5'd0) begin
        // Zero (FTZ/DAZ)
        fp8e5m2_to_bf16 = {s, 15'd0};
      end else if (e == 5'd31 && m != 2'd0) begin
        // NaN
        fp8e5m2_to_bf16 = 16'h7FC0; // canonical BF16 qNaN
      end else if (e == 5'd31 && m == 2'd0) begin
        // Inf
        fp8e5m2_to_bf16 = {s, 8'hFF, 7'd0};
      end else begin
        // Normal: rebias exponent, zero-pad mantissa
        fp8e5m2_to_bf16 = {s, ({3'b000, e} + 8'd112), m, 5'b00000};
      end
    end
  endfunction

  wire [15:0] a_hi_bf16 = fp8e5m2_to_bf16(a_fp8[15:8]);
  wire [15:0] a_lo_bf16 = fp8e5m2_to_bf16(a_fp8[7:0]);
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
