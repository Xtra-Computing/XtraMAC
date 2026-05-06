`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp8e5m2_bf16_mac : 2-lane FP8(E5M2) x BF16 + BF16 -> BF16
//   - Input a16 holds two FP8(E5M2) lanes {HI[15:8], LO[7:0]}
//   - Shared BF16 multiplicand b16
//   - BF16 addends c32 {HI[31:16], LO[15:0]}
//   - Result packed as two BF16 lanes {HI, LO}
//   - FP8(E5M2) handling:
//       * FTZ: exp==0 => signed zero
//       * exp==5'h1F & frac!=0 => qNaN
//       * exp==5'h1F & frac==0 => +/-Infinity
//       * Normalized: exp_bf16 = exp_fp8 + 112  (bias shift 127-15)
//   - Delegates to bf16_mac_2lane after widening.
// =============================================================
module fp8e5m2_bf16_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 0,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire [15:0] a16,    // {a_hi[15:8], a_lo[7:0]} FP8 E5M2
    input  wire [15:0] b16,    // shared BF16
    input  wire [31:0] c32,    // BF16 addends {hi, lo}
    output wire [31:0] result  // BF16 results {hi, lo}
);

  localparam [15:0] QNAN16 = 16'h7FC0;

  // ---- Lane conversion: FP8(E5M2) -> BF16 ----
  function automatic [15:0] fp8e5m2_to_bf16;
    input [7:0] fp8;
    reg        sign;
    reg [4:0]  exp_fp8;
    reg [1:0]  frac_fp8;
    reg [7:0]  exp_bf16;
    reg [6:0]  frac_bf16;
    begin
      sign     = fp8[7];
      exp_fp8  = fp8[6:2];
      frac_fp8 = fp8[1:0];

      if ((exp_fp8 == 5'h1F) && (frac_fp8 != 2'd0)) begin
        fp8e5m2_to_bf16 = QNAN16;
      end else if ((exp_fp8 == 5'h1F) && (frac_fp8 == 2'd0)) begin
        fp8e5m2_to_bf16 = sign ? 16'hFF80 : 16'h7F80;   // +/-Inf
      end else if (exp_fp8 == 5'd0) begin
        fp8e5m2_to_bf16 = {sign, 15'd0};                 // signed zero (FTZ)
      end else begin
        exp_bf16  = {3'd0, exp_fp8} + 8'd112;            // bias: 127 - 15 = 112
        frac_bf16 = {frac_fp8, 5'b0};                    // 2-bit frac -> 7-bit
        fp8e5m2_to_bf16 = {sign, exp_bf16, frac_bf16};
      end
    end
  endfunction

  wire [7:0]  a_lo8 = a16[7:0];
  wire [7:0]  a_hi8 = a16[15:8];

  wire [15:0] a_lo_bf16 = fp8e5m2_to_bf16(a_lo8);
  wire [15:0] a_hi_bf16 = fp8e5m2_to_bf16(a_hi8);
  wire [31:0] a_bf16    = {a_hi_bf16, a_lo_bf16};

  bf16_mac_2lane #(
    .MUL_LAT   (MUL_LAT),
    .MID_STAGES(MID_STAGES),
    .ADD_LAT   (ADD_LAT)
  ) u_mac (
    .clk   (clk),
    .a32   (a_bf16),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

endmodule

`default_nettype wire
