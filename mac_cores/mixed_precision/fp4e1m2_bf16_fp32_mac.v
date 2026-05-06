`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp4e1m2_bf16_fp32_mac : FP4(E1M2) x BF16 + FP32 -> FP32 (2-lane)
//   - Converts FP4 E1M2 input to BF16, then calls bf16_fp32_mac_2lane
//   - FP4 E1M2: {sign[3], exp[2](1b, bias=0), man[1:0](2b)}
//   - Two FP4 lanes packed in a_fp4[7:0] = {hi[7:4], lo[3:0]}
// =============================================================
module fp4e1m2_bf16_fp32_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 1,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire [7:0]  a_fp4,   // packed FP4 E1M2 {hi[7:4], lo[3:0]}
    input  wire [15:0] b16,     // shared BF16
    input  wire [63:0] c64,     // FP32 addends {hi, lo}
    output wire [63:0] result   // FP32 results {hi, lo}
);

  // Convert FP4 E1M2 to BF16
  // FP4 E1M2: sign(1) | exp(1, bias=0) | man(2)
  // Mapping: bf16_exp = fp4_exp - 0 + 127 = fp4_exp + 127
  //          bf16_man = {fp4_man, 5'b00000}
  // Special: exp=0 -> zero (FTZ)
  //          exp=1 is the only normal exponent (no all-ones special case
  //          since max exp=1 with bias=0 -> unbiased=1, which is normal)
  // With 1-bit exponent: exp=0 -> zero/subnormal (FTZ), exp=1 -> normal

  function [15:0] fp4e1m2_to_bf16;
    input [3:0] fp4;
    reg       s;
    reg       e;
    reg [1:0] m;
    begin
      s = fp4[3];
      e = fp4[2];
      m = fp4[1:0];
      if (e == 1'b0) begin
        fp4e1m2_to_bf16 = {s, 15'd0}; // zero (FTZ)
      end else begin
        // exp=1: biased BF16 exp = 1 + 127 = 128
        fp4e1m2_to_bf16 = {s, 8'd128, m, 5'b00000};
      end
    end
  endfunction

  wire [15:0] a_hi_bf16 = fp4e1m2_to_bf16(a_fp4[7:4]);
  wire [15:0] a_lo_bf16 = fp4e1m2_to_bf16(a_fp4[3:0]);
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
