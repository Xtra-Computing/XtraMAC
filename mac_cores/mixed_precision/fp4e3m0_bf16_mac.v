`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp4e3m0_bf16_mac : 2-lane FP4(E3M0) x BF16 + BF16 -> BF16
//   - Input a_fp4[7:0] holds two 4-bit lanes {HI[7:4], LO[3:0]}
//   - FP4(E3M0): 1 sign + 3 exp + 0 mantissa bits
//       * exp==7 => NaN
//       * exp==0 => signed zero (FTZ)
//       * else   => value = (-1)^s * 2^(exp-bias), mantissa=1.0 (no frac)
//   - Conversion path: FP4 -> FP8(E4M3) -> BF16 -> bf16_mac_2lane
//   - FP4->FP8 mapping: exp_fp8 = exp_fp4 + 1, frac=000
// =============================================================
module fp4e3m0_bf16_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 0,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire [7:0]  a_fp4,    // {hi[7:4], lo[3:0]} FP4 E3M0
    input  wire [15:0] b16,      // shared BF16
    input  wire [31:0] c32,      // BF16 addends {hi, lo}
    output wire [31:0] result    // BF16 results {hi, lo}
);

  // ---- FP4(E3M0) -> FP8(E4M3) conversion ----
  function automatic [7:0] fp4e3m0_to_fp8e4m3;
    input [3:0] lane;
    reg       sign;
    reg [2:0] exp3;
    reg [3:0] exp_final;
    begin
      sign = lane[3];
      exp3 = lane[2:0];
      if (exp3 == 3'd7)
        fp4e3m0_to_fp8e4m3 = 8'h79;                    // NaN -> E4M3 NaN (0x79)
      else if (exp3 == 3'd0)
        fp4e3m0_to_fp8e4m3 = {sign, 7'd0};             // signed zero
      else begin
        exp_final = exp3 + 4'd1;                        // bias adjust E3->E4
        fp4e3m0_to_fp8e4m3 = {sign, exp_final[3:0], 3'b000};
      end
    end
  endfunction

  wire [7:0] a_lo8 = fp4e3m0_to_fp8e4m3(a_fp4[3:0]);
  wire [7:0] a_hi8 = fp4e3m0_to_fp8e4m3(a_fp4[7:4]);
  wire [15:0] a_fp8 = {a_hi8, a_lo8};

  fp8e4m3_bf16_mac #(
    .MUL_LAT   (MUL_LAT),
    .MID_STAGES(MID_STAGES),
    .ADD_LAT   (ADD_LAT)
  ) u_mac (
    .clk   (clk),
    .a16   (a_fp8),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

endmodule

`default_nettype wire
