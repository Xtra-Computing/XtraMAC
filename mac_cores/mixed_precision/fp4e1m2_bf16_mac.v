`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp4e1m2_bf16_mac : 2-lane FP4(E1M2) x BF16 + BF16 -> BF16
//   - Input a_fp4[7:0] holds two 4-bit lanes {HI[7:4], LO[3:0]}
//   - FP4(E1M2): 1 sign + 1 exp + 2 mantissa bits
//       * exp==1 & frac!=0 => NaN  (all-ones exp with nonzero frac)
//       * exp==1 & frac==0 => Infinity  (but effectively NaN sentinel
//         in the reference FP4(E1M2)->FP8 mapping; mapped to FP8 NaN 0x79)
//       * exp==0 & frac==00 => signed zero
//       * exp==0 & frac!=0  => subnormal, value = frac/4
//   - Conversion path: FP4 -> FP8(E4M3) -> BF16 -> bf16_mac_2lane
//     (matches the reference fp4e1m2_bf16_mac.v conversion)
// =============================================================
module fp4e1m2_bf16_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 0,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire [7:0]  a_fp4,    // {hi[7:4], lo[3:0]} FP4 E1M2
    input  wire [15:0] b16,      // shared BF16
    input  wire [31:0] c32,      // BF16 addends {hi, lo}
    output wire [31:0] result    // BF16 results {hi, lo}
);

  // ---- FP4(E1M2) -> FP8(E4M3) conversion ----
  // Reference mapping (from fp4e1m2_bf16_mac.v in User_spec):
  //   exp_bit==1 => FP8 NaN (0x79)
  //   exp_bit==0, frac==00 => signed zero
  //   exp_bit==0, frac!=0  => {sign, 4'd6, frac, 1'b0}
  //     i.e. FP8 E4M3 with exp=6, mantissa = {frac[1:0], 0}
  function automatic [7:0] fp4e1m2_to_fp8e4m3;
    input [3:0] lane;
    reg       sign;
    reg [1:0] frac2;
    begin
      sign  = lane[3];
      frac2 = lane[1:0];
      if (lane[2] == 1'b1)
        fp4e1m2_to_fp8e4m3 = 8'h79;                     // NaN
      else begin
        if (frac2 == 2'b00)
          fp4e1m2_to_fp8e4m3 = {sign, 7'd0};            // signed zero
        else
          fp4e1m2_to_fp8e4m3 = {sign, 4'd6, frac2, 1'b0};
      end
    end
  endfunction

  wire [7:0] a_lo8 = fp4e1m2_to_fp8e4m3(a_fp4[3:0]);
  wire [7:0] a_hi8 = fp4e1m2_to_fp8e4m3(a_fp4[7:4]);
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
