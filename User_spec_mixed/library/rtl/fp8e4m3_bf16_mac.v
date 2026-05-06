`timescale 1ns/1ps
`default_nettype none

module fp8e4m3_bf16_mac (
    input  wire        clk,
    input  wire [31:0] a18,
    input  wire [15:0] b18,
    input  wire [63:0] c64,
    output reg  [63:0] result
);
  localparam [15:0] BF16_QNAN = 16'h7FC0;

  wire [7:0] a1 = a18[7:0];
  wire [7:0] a2 = a18[15:8];
  wire [7:0] b1 = b18[7:0];
  wire [7:0] b2 = b18[15:8];

  wire sa1 = a1[7], sa2 = a2[7];
  wire sb1 = b1[7], sb2 = b2[7];
  wire [3:0] ea1 = a1[6:3], ea2 = a2[6:3], eb1 = b1[6:3], eb2 = b2[6:3];
  wire [2:0] fa1 = a1[2:0], fa2 = a2[2:0], fb1 = b1[2:0], fb2 = b2[2:0];

  wire a1_nan = (ea1 == 4'hF);
  wire a2_nan = (ea2 == 4'hF);
  wire b1_nan = (eb1 == 4'hF);
  wire b2_nan = (eb2 == 4'hF);

  wire a1_zero = (ea1 == 4'd0);
  wire a2_zero = (ea2 == 4'd0);
  wire b1_zero = (eb1 == 4'd0);
  wire b2_zero = (eb2 == 4'd0);

  wire        s11 = sa1 ^ sb1;
  wire        s12 = sa1 ^ sb2;
  wire        s21 = sa2 ^ sb1;
  wire        s22 = sa2 ^ sb2;

  wire signed [6:0] e11_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb1}) - 7'sd7;
  wire signed [6:0] e12_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb2}) - 7'sd7;
  wire signed [6:0] e21_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb1}) - 7'sd7;
  wire signed [6:0] e22_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb2}) - 7'sd7;

  wire [3:0] Ma1 = a1_zero ? 4'd0 : {1'b1, fa1};
  wire [3:0] Ma2 = a2_zero ? 4'd0 : {1'b1, fa2};
  wire [3:0] Mb1 = b1_zero ? 4'd0 : {1'b1, fb1};
  wire [3:0] Mb2 = b2_zero ? 4'd0 : {1'b1, fb2};

  reg [26:0] A_pack;
  reg [17:0] B_pack;
  always @(posedge clk) begin
    A_pack <= {7'b0, Ma2, 12'b0, Ma1};
    B_pack <= {6'b0, Mb2, 4'b0, Mb1};
  end

  reg        s11_s2, s12_s2, s21_s2, s22_s2;
  reg signed [6:0] e11_s2, e12_s2, e21_s2, e22_s2;
  reg        a1_nan_s2, a2_nan_s2, b1_nan_s2, b2_nan_s2;
  reg        a1_zero_s2,a2_zero_s2,b1_zero_s2,b2_zero_s2;
  reg [15:0] c11_s2, c12_s2, c21_s2, c22_s2;
  always @(posedge clk) begin
    s11_s2 <= s11; s12_s2 <= s12; s21_s2 <= s21; s22_s2 <= s22;
    e11_s2 <= e11_s1; e12_s2 <= e12_s1; e21_s2 <= e21_s1; e22_s2 <= e22_s1;
    a1_nan_s2 <= a1_nan; a2_nan_s2 <= a2_nan; b1_nan_s2 <= b1_nan; b2_nan_s2 <= b2_nan;
    a1_zero_s2 <= a1_zero; a2_zero_s2 <= a2_zero; b1_zero_s2 <= b1_zero; b2_zero_s2 <= b2_zero;
    c11_s2 <= c64[15:0];
    c12_s2 <= c64[31:16];
    c21_s2 <= c64[47:32];
    c22_s2 <= c64[63:48];
  end

  wire [44:0] product45;
  (* use_dsp = "yes" *)
  dsp_usage u_dsp (
      .clk    (clk),
      .a      (A_pack),
      .b      (B_pack),
      .product(product45)
  );

  reg [31:0] dsp_p_s3;
  always @(posedge clk) begin
    dsp_p_s3 <= product45[31:0];
  end

  reg        s11_s3, s12_s3, s21_s3, s22_s3;
  reg signed [6:0] e11_s3, e12_s3, e21_s3, e22_s3;
  reg        a1_nan_s3, a2_nan_s3, b1_nan_s3, b2_nan_s3;
  reg        a1_zero_s3,a2_zero_s3,b1_zero_s3,b2_zero_s3;
  reg [15:0] c11_s3, c12_s3, c21_s3, c22_s3;
  always @(posedge clk) begin
    s11_s3 <= s11_s2; s12_s3 <= s12_s2; s21_s3 <= s21_s2; s22_s3 <= s22_s2;
    e11_s3 <= e11_s2; e12_s3 <= e12_s2; e21_s3 <= e21_s2; e22_s3 <= e22_s2;
    a1_nan_s3 <= a1_nan_s2; a2_nan_s3 <= a2_nan_s2; b1_nan_s3 <= b1_nan_s2; b2_nan_s3 <= b2_nan_s2;
    a1_zero_s3 <= a1_zero_s2; a2_zero_s3 <= a2_zero_s2; b1_zero_s3 <= b1_zero_s2; b2_zero_s3 <= b2_zero_s2;
    c11_s3 <= c11_s2; c12_s3 <= c12_s2; c21_s3 <= c21_s2; c22_s3 <= c22_s2;
  end

  wire [7:0] P11 = dsp_p_s3[ 7: 0];
  wire [7:0] P12 = dsp_p_s3[15: 8];
  wire [7:0] P21 = dsp_p_s3[23:16];
  wire [7:0] P22 = dsp_p_s3[31:24];

  wire nan_11 = a1_nan_s3 | b1_nan_s3;
  wire nan_12 = a1_nan_s3 | b2_nan_s3;
  wire nan_21 = a2_nan_s3 | b1_nan_s3;
  wire nan_22 = a2_nan_s3 | b2_nan_s3;

  wire zer_11 = ~nan_11 & (a1_zero_s3 | b1_zero_s3);
  wire zer_12 = ~nan_12 & (a1_zero_s3 | b2_zero_s3);
  wire zer_21 = ~nan_21 & (a2_zero_s3 | b1_zero_s3);
  wire zer_22 = ~nan_22 & (a2_zero_s3 | b2_zero_s3);

  wire        c11_carry = P11[7];
  wire        c12_carry = P12[7];
  wire        c21_carry = P21[7];
  wire        c22_carry = P22[7];

  wire [10:0] c11_mant_carry = {P11, 3'b0};
  wire [11:0] c11_mant_nocarry = {P11, 4'b0};
  wire [10:0] c11_mant_norm = c11_carry ? c11_mant_carry : c11_mant_nocarry[10:0];

  wire [10:0] c12_mant_carry = {P12, 3'b0};
  wire [11:0] c12_mant_nocarry = {P12, 4'b0};
  wire [10:0] c12_mant_norm = c12_carry ? c12_mant_carry : c12_mant_nocarry[10:0];

  wire [10:0] c21_mant_carry = {P21, 3'b0};
  wire [11:0] c21_mant_nocarry = {P21, 4'b0};
  wire [10:0] c21_mant_norm = c21_carry ? c21_mant_carry : c21_mant_nocarry[10:0];

  wire [10:0] c22_mant_carry = {P22, 3'b0};
  wire [11:0] c22_mant_nocarry = {P22, 4'b0};
  wire [10:0] c22_mant_norm = c22_carry ? c22_mant_carry : c22_mant_nocarry[10:0];

  wire signed [6:0] c11_es = e11_s3 + (c11_carry ? 7'sd1 : 7'sd0);
  wire signed [6:0] c12_es = e12_s3 + (c12_carry ? 7'sd1 : 7'sd0);
  wire signed [6:0] c21_es = e21_s3 + (c21_carry ? 7'sd1 : 7'sd0);
  wire signed [6:0] c22_es = e22_s3 + (c22_carry ? 7'sd1 : 7'sd0);

  function automatic [15:0] fp8_prod_to_bf16;
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

  wire [15:0] prod11_bf16 = fp8_prod_to_bf16(s11_s3, c11_es, c11_mant_norm, nan_11, zer_11);
  wire [15:0] prod12_bf16 = fp8_prod_to_bf16(s12_s3, c12_es, c12_mant_norm, nan_12, zer_12);
  wire [15:0] prod21_bf16 = fp8_prod_to_bf16(s21_s3, c21_es, c21_mant_norm, nan_21, zer_21);
  wire [15:0] prod22_bf16 = fp8_prod_to_bf16(s22_s3, c22_es, c22_mant_norm, nan_22, zer_22);

  wire [15:0] sum11_bf16, sum12_bf16, sum21_bf16, sum22_bf16;

  bf16_add u_add11 (.clk(clk), .a16(prod11_bf16), .b16(c11_s3), .c16(sum11_bf16));
  bf16_add u_add12 (.clk(clk), .a16(prod12_bf16), .b16(c12_s3), .c16(sum12_bf16));
  bf16_add u_add21 (.clk(clk), .a16(prod21_bf16), .b16(c21_s3), .c16(sum21_bf16));
  bf16_add u_add22 (.clk(clk), .a16(prod22_bf16), .b16(c22_s3), .c16(sum22_bf16));

  always @(posedge clk) begin
    result <= {sum22_bf16, sum21_bf16, sum12_bf16, sum11_bf16};
  end
endmodule

`default_nettype wire
