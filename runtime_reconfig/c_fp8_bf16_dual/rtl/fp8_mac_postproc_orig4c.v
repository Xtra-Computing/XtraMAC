`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp8_mac_postproc_orig4c
//   Stage-2 post-processing for FP8e4m3 × FP8e4m3 products.
//   Consumes S1 metadata and shared DSP output, produces four BF16
//   products plus aligned C lanes for downstream BF16 adders.
// =============================================================
module fp8_mac_postproc_orig4c (
    input  wire        clk,
    input  wire        s11_s1,
    input  wire        s12_s1,
    input  wire        s21_s1,
    input  wire        s22_s1,
    input  wire signed [6:0] e11_s1,
    input  wire signed [6:0] e12_s1,
    input  wire signed [6:0] e21_s1,
    input  wire signed [6:0] e22_s1,
    input  wire        a1_nan_s1,
    input  wire        a2_nan_s1,
    input  wire        b1_nan_s1,
    input  wire        b2_nan_s1,
    input  wire        a1_zero_s1,
    input  wire        a2_zero_s1,
    input  wire        b1_zero_s1,
    input  wire        b2_zero_s1,
    input  wire [15:0] c11_s1,
    input  wire [15:0] c12_s1,
    input  wire [15:0] c21_s1,
    input  wire [15:0] c22_s1,
    input  wire [44:0] product45,

    output reg [15:0] prod_lane0_s2,
    output reg [15:0] prod_lane1_s2,
    output reg [15:0] prod_lane2_s2,
    output reg [15:0] prod_lane3_s2,
    output reg [15:0] c_lane0_s2,
    output reg [15:0] c_lane1_s2,
    output reg [15:0] c_lane2_s2,
    output reg [15:0] c_lane3_s2
);
  localparam [15:0] BF16_QNAN = 16'h7FC0;

  wire [7:0] P11 = product45[ 7: 0];
  wire [7:0] P12 = product45[15: 8];
  wire [7:0] P21 = product45[23:16];
  wire [7:0] P22 = product45[31:24];

  wire        c11_carry = P11[7];
  wire        c12_carry = P12[7];
  wire        c21_carry = P21[7];
  wire        c22_carry = P22[7];

  wire [11:0] c11_mant_nocarry = {P11, 4'b0};
  wire [11:0] c12_mant_nocarry = {P12, 4'b0};
  wire [11:0] c21_mant_nocarry = {P21, 4'b0};
  wire [11:0] c22_mant_nocarry = {P22, 4'b0};

  wire [10:0] c11_mant_norm = c11_carry ? {P11, 3'b0} : c11_mant_nocarry[10:0];
  wire [10:0] c12_mant_norm = c12_carry ? {P12, 3'b0} : c12_mant_nocarry[10:0];
  wire [10:0] c21_mant_norm = c21_carry ? {P21, 3'b0} : c21_mant_nocarry[10:0];
  wire [10:0] c22_mant_norm = c22_carry ? {P22, 3'b0} : c22_mant_nocarry[10:0];

  wire signed [6:0] c11_es = e11_s1 + (c11_carry ? 7'sd1 : 7'sd0);
  wire signed [6:0] c12_es = e12_s1 + (c12_carry ? 7'sd1 : 7'sd0);
  wire signed [6:0] c21_es = e21_s1 + (c21_carry ? 7'sd1 : 7'sd0);
  wire signed [6:0] c22_es = e22_s1 + (c22_carry ? 7'sd1 : 7'sd0);

  wire nan_11 = a1_nan_s1 | b1_nan_s1;
  wire nan_12 = a1_nan_s1 | b2_nan_s1;
  wire nan_21 = a2_nan_s1 | b1_nan_s1;
  wire nan_22 = a2_nan_s1 | b2_nan_s1;

  wire zer_11 = ~nan_11 & (a1_zero_s1 | b1_zero_s1);
  wire zer_12 = ~nan_12 & (a1_zero_s1 | b2_zero_s1);
  wire zer_21 = ~nan_21 & (a2_zero_s1 | b1_zero_s1);
  wire zer_22 = ~nan_22 & (a2_zero_s1 | b2_zero_s1);

  function [15:0] fp8_prod_to_bf16;
    input        sign_in;
    input signed [6:0] exp_unbias;
    input [10:0] mant_norm;
    input        nan_in;
    input        zero_in;
    reg [6:0] frac_pre;
    reg guard_bit, sticky_bits, round_up;
    reg [7:0] frac_round;
    reg frac_carry;
    reg [6:0] frac_final;
    reg signed [8:0] exp_adj;
    reg signed [9:0] exp_biased;
    begin
      if (nan_in) begin
        fp8_prod_to_bf16 = BF16_QNAN;
      end else if (zero_in) begin
        fp8_prod_to_bf16 = {sign_in, 15'd0};
      end else begin
        frac_pre   = mant_norm[9:3];
        guard_bit  = mant_norm[2];
        sticky_bits= |mant_norm[1:0];
        round_up   = guard_bit & (sticky_bits | frac_pre[0]);
        frac_round = {1'b0, frac_pre} + {7'd0, round_up};
        frac_carry = frac_round[7];
        frac_final = frac_carry ? 7'd0 : frac_round[6:0];
        exp_adj    = exp_unbias + (frac_carry ? 9'sd1 : 9'sd0);
        exp_biased = exp_adj + 10'sd127;
        if (exp_biased >= 10'sd255)
          fp8_prod_to_bf16 = {sign_in, 8'hFF, 7'd0};
        else if (exp_biased <= 10'sd0)
          fp8_prod_to_bf16 = {sign_in, 15'd0};
        else
          fp8_prod_to_bf16 = {sign_in, exp_biased[7:0], frac_final};
      end
    end
  endfunction

  always @(posedge clk) begin
    prod_lane0_s2 <= fp8_prod_to_bf16(s11_s1, c11_es, c11_mant_norm, nan_11, zer_11);
    prod_lane1_s2 <= fp8_prod_to_bf16(s12_s1, c12_es, c12_mant_norm, nan_12, zer_12);
    prod_lane2_s2 <= fp8_prod_to_bf16(s21_s1, c21_es, c21_mant_norm, nan_21, zer_21);
    prod_lane3_s2 <= fp8_prod_to_bf16(s22_s1, c22_es, c22_mant_norm, nan_22, zer_22);

    c_lane0_s2 <= c11_s1;
    c_lane1_s2 <= c12_s1;
    c_lane2_s2 <= c21_s1;
    c_lane3_s2 <= c22_s1;
  end
endmodule

`default_nettype wire
