`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// fp4e1m2_fp8e4m3_mac -- FP4(E1M2) x FP8(E4M3) + FP8 -> FP8 (4-lane)
//   Two FP4(E1M2) A-lanes x two FP8(E4M3) B-lanes => 4 products + C
//
//   FP4(E1M2) format: sign[3], exp[2] (1-bit), frac[1:0] (2-bit).
//     exp_bit==1 => NaN.
//     exp_bit==0, frac==00 => zero.
//     exp_bit==0, frac!=00 => biased_exp=6, mantissa_frac = {frac, 1'b0}.
//   Conversion to FP8(E4M3): {sign, 4'd6, frac[1:0], 1'b0} for normal values.
//
//   Params: MUL_LAT, MID_STAGES, ADD_LAT
// ======================================================================
module fp4e1m2_fp8e4m3_mac #(
    parameter integer MUL_LAT    = 2,
    parameter integer MID_STAGES = 1,
    parameter integer ADD_LAT    = 1
) (
    input  wire        clk,
    input  wire [7:0]  a_fp4,   // {a2[7:4], a1[3:0]} two FP4(E1M2) A-lanes
    input  wire [15:0] b_fp8,   // {b2[15:8], b1[7:0]} two FP8(E4M3) B-lanes
    input  wire [31:0] c_fp8,   // {c22, c21, c12, c11} four FP8(E4M3) addends
    output wire [31:0] result   // {y22, y21, y12, y11}
);

  // ---- FP4(E1M2) -> FP8(E4M3) conversion ----
  // Mirrors fp4_to_fp8_e4m3 from fp4_fp8e4m3_core.v with FP4_MODE=E1M2
  function [7:0] fp4e1m2_to_fp8;
    input [3:0] lane;
    reg        sign;
    reg [1:0]  frac2;
    begin
      sign  = lane[3];
      // exp_bit = lane[2]; frac = lane[1:0]
      if (lane[2] == 1'b1)
        fp4e1m2_to_fp8 = 8'h79;                    // qNaN (exp_bit==1)
      else begin
        frac2 = lane[1:0];
        if (frac2 == 2'b00)
          fp4e1m2_to_fp8 = {sign, 7'd0};           // zero
        else
          fp4e1m2_to_fp8 = {sign, 4'd6, frac2, 1'b0};
      end
    end
  endfunction

  wire [7:0] a1_fp8 = fp4e1m2_to_fp8(a_fp4[3:0]);
  wire [7:0] a2_fp8 = fp4e1m2_to_fp8(a_fp4[7:4]);

  // ---- Instantiate mac_4lane ----
  fp8e4m3_mac_4lane #(
    .MUL_LAT    (MUL_LAT),
    .MID_STAGES (MID_STAGES),
    .ADD_LAT    (ADD_LAT)
  ) u_mac (
    .clk    (clk),
    .a_fp8  ({a2_fp8, a1_fp8}),
    .b_fp8  (b_fp8),
    .c_fp8  (c_fp8),
    .result (result)
  );

endmodule

`default_nettype wire
