`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// fp4e2m1_fp8e4m3_mac -- FP4(E2M1) x FP8(E4M3) + FP8 -> FP8 (4-lane)
//   Two FP4(E2M1) A-lanes x two FP8(E4M3) B-lanes => 4 products + C
//
//   FP4(E2M1) format: sign[3], exp[2:1] (2-bit), frac[0] (1-bit).
//     exp==3 => NaN, exp==0 => zero, else biased_exp = exp + 4, frac={frac1, 2'b00}.
//   Conversion to FP8(E4M3): {sign, exp+4, frac1, 2'b00} for normal values.
//
//   Params: MUL_LAT, MID_STAGES, ADD_LAT
// ======================================================================
module fp4e2m1_fp8e4m3_mac #(
    parameter integer MUL_LAT    = 2,
    parameter integer MID_STAGES = 1,
    parameter integer ADD_LAT    = 1
) (
    input  wire        clk,
    input  wire [7:0]  a_fp4,   // {a2[7:4], a1[3:0]} two FP4(E2M1) A-lanes
    input  wire [15:0] b_fp8,   // {b2[15:8], b1[7:0]} two FP8(E4M3) B-lanes
    input  wire [31:0] c_fp8,   // {c22, c21, c12, c11} four FP8(E4M3) addends
    output wire [31:0] result   // {y22, y21, y12, y11}
);

  // ---- FP4(E2M1) -> FP8(E4M3) conversion ----
  // Mirrors fp4_to_fp8_e4m3 from fp4_fp8e4m3_core.v with FP4_MODE=E2M1
  function [7:0] fp4e2m1_to_fp8;
    input [3:0] lane;
    reg        sign;
    reg [1:0]  exp2;
    reg        frac1;
    reg [3:0]  exp_final;
    reg [2:0]  frac_final;
    begin
      sign  = lane[3];
      exp2  = lane[2:1];
      frac1 = lane[0];
      if (exp2 == 2'b11)
        fp4e2m1_to_fp8 = 8'h79;                    // qNaN
      else if (exp2 == 2'b00)
        fp4e2m1_to_fp8 = {sign, 7'd0};             // zero
      else begin
        exp_final  = {2'b00, exp2} + 4'd4;
        frac_final = {frac1, 2'b00};
        fp4e2m1_to_fp8 = {sign, exp_final[3:0], frac_final};
      end
    end
  endfunction

  wire [7:0] a1_fp8 = fp4e2m1_to_fp8(a_fp4[3:0]);
  wire [7:0] a2_fp8 = fp4e2m1_to_fp8(a_fp4[7:4]);

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
