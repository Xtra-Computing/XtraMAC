`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp8_bf16_dual_mac_orig4c
//   mode_fp8 = 1'b1 : FP8e4m3 × FP8e4m3 → BF16 accumulations (4 lanes)
//   mode_fp8 = 1'b0 : BF16 × BF16 → BF16 (2 lanes)
//   Shared pipeline (II=1):
//     S1 mapper  : fp8_mac_s1_prep_orig4c / bf16_mac_s1_prep_orig4c
//     S2 postproc: fp8_mac_postproc_orig4c / mac_postproc_bf16
//     S3 adders  : shared bf16_add_orig4c instances
//     S4 reg     : final output register
// =============================================================
module fp8_bf16_dual_mac_orig4c (
    input  wire        clk,
    input  wire        mode_fp8,  // 1 -> FP8 path, 0 -> BF16 path
    input  wire [31:0] a32,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output reg  [63:0] result
);
  // ----------------------------
  // Mode pipeline (S1..S3)
  // ----------------------------
  reg mode_s1, mode_s2, mode_s3;
  always @(posedge clk) begin
    mode_s1 <= mode_fp8;
    mode_s2 <= mode_s1;
    mode_s3 <= mode_s2;
  end

  // ===========================================================
  // S1: mappers (BF16 + FP8)
  // ===========================================================
  wire [26:0] bf16_dsp_a_s1;
  wire [17:0] bf16_dsp_b_s1;
  wire signed [8:0] exp_hi_bf16_s1, exp_lo_bf16_s1;
  wire        sign_hi_bf16_s1, sign_lo_bf16_s1;
  wire        a_hi_nan_s1, a_lo_nan_s1, b_nan_s1;
  wire        a_hi_inf_s1, a_lo_inf_s1, b_inf_s1;
  wire        a_hi_zero_s1, a_lo_zero_s1, b_zero_s1;
  wire [15:0] c_lo_bf16_s1, c_hi_bf16_s1;

  bf16_mac_s1_prep_orig4c u_bf16_s1 (
      .clk         (clk),
      .a32         (a32),
      .b16         (b16),
      .c32         (c64[31:0]),
      .man_a_packed(bf16_dsp_a_s1),
      .man_b_packed(bf16_dsp_b_s1),
      .exp_hi_s1   (exp_hi_bf16_s1),
      .exp_lo_s1   (exp_lo_bf16_s1),
      .sign_hi_s1  (sign_hi_bf16_s1),
      .sign_lo_s1  (sign_lo_bf16_s1),
      .a_hi_nan_s1 (a_hi_nan_s1),
      .a_lo_nan_s1 (a_lo_nan_s1),
      .b_nan_s1    (b_nan_s1),
      .a_hi_inf_s1 (a_hi_inf_s1),
      .a_lo_inf_s1 (a_lo_inf_s1),
      .b_inf_s1    (b_inf_s1),
      .a_hi_zero_s1(a_hi_zero_s1),
      .a_lo_zero_s1(a_lo_zero_s1),
      .b_zero_s1   (b_zero_s1),
      .c_lo_s1     (c_lo_bf16_s1),
      .c_hi_s1     (c_hi_bf16_s1)
  );

  wire [26:0] fp8_dsp_a_s1;
  wire [17:0] fp8_dsp_b_s1;
  wire        s11_s1, s12_s1, s21_s1, s22_s1;
  wire signed [6:0] e11_s1, e12_s1, e21_s1, e22_s1;
  wire        a1_nan_fp8_s1, a2_nan_fp8_s1, b1_nan_fp8_s1, b2_nan_fp8_s1;
  wire        a1_zero_fp8_s1, a2_zero_fp8_s1, b1_zero_fp8_s1, b2_zero_fp8_s1;
  wire [15:0] c11_fp8_s1, c12_fp8_s1, c21_fp8_s1, c22_fp8_s1;

  fp8_mac_s1_prep_orig4c u_fp8_s1 (
      .clk        (clk),
      .a32        (a32),
      .b16        (b16),
      .c64        (c64),
      .a_pack     (fp8_dsp_a_s1),
      .b_pack     (fp8_dsp_b_s1),
      .s11_s1     (s11_s1),
      .s12_s1     (s12_s1),
      .s21_s1     (s21_s1),
      .s22_s1     (s22_s1),
      .e11_s1     (e11_s1),
      .e12_s1     (e12_s1),
      .e21_s1     (e21_s1),
      .e22_s1     (e22_s1),
      .a1_nan_s1  (a1_nan_fp8_s1),
      .a2_nan_s1  (a2_nan_fp8_s1),
      .b1_nan_s1  (b1_nan_fp8_s1),
      .b2_nan_s1  (b2_nan_fp8_s1),
      .a1_zero_s1 (a1_zero_fp8_s1),
      .a2_zero_s1 (a2_zero_fp8_s1),
      .b1_zero_s1 (b1_zero_fp8_s1),
      .b2_zero_s1 (b2_zero_fp8_s1),
      .c11_s1     (c11_fp8_s1),
      .c12_s1     (c12_fp8_s1),
      .c21_s1     (c21_fp8_s1),
      .c22_s1     (c22_fp8_s1)
  );

  wire [26:0] dsp_a_s1 = mode_s1 ? fp8_dsp_a_s1  : bf16_dsp_a_s1;
  wire [17:0] dsp_b_s1 = mode_s1 ? fp8_dsp_b_s1  : bf16_dsp_b_s1;

  wire [44:0] product45;
  dsp_usage_orig4c u_dsp (
      .clk    (clk),
      .a      (dsp_a_s1),
      .b      (dsp_b_s1),
      .product(product45)
  );

  // ===========================================================
  // S2: post-processing
  // ===========================================================
  wire [15:0] bf16_prod_lo_s2, bf16_prod_hi_s2;
  wire [15:0] bf16_c_lo_s2, bf16_c_hi_s2;

  mac_postproc_bf16 u_bf16_pp (
      .clk             (clk),
      .exp_hi_bf16_s1  (exp_hi_bf16_s1),
      .exp_lo_bf16_s1  (exp_lo_bf16_s1),
      .sign_hi_bf16_s1 (sign_hi_bf16_s1),
      .sign_lo_bf16_s1 (sign_lo_bf16_s1),
      .a_hi_nan_s1     (a_hi_nan_s1),
      .a_lo_nan_s1     (a_lo_nan_s1),
      .b_nan_s1        (b_nan_s1),
      .a_hi_inf_s1     (a_hi_inf_s1),
      .a_lo_inf_s1     (a_lo_inf_s1),
      .b_inf_s1        (b_inf_s1),
      .a_hi_zero_s1    (a_hi_zero_s1),
      .a_lo_zero_s1    (a_lo_zero_s1),
      .b_zero_s1       (b_zero_s1),
      .c_lo_bf16_s1    (c_lo_bf16_s1),
      .c_hi_bf16_s1    (c_hi_bf16_s1),
      .product45       (product45),
      .prod_lo16_bf16  (bf16_prod_lo_s2),
      .prod_hi16_bf16  (bf16_prod_hi_s2),
      .c_lo_bf16_s2    (bf16_c_lo_s2),
      .c_hi_bf16_s2    (bf16_c_hi_s2)
  );

  wire [15:0] fp8_prod0_s2, fp8_prod1_s2, fp8_prod2_s2, fp8_prod3_s2;
  wire [15:0] fp8_c0_s2, fp8_c1_s2, fp8_c2_s2, fp8_c3_s2;

  fp8_mac_postproc_orig4c u_fp8_pp (
      .clk          (clk),
      .s11_s1       (s11_s1),
      .s12_s1       (s12_s1),
      .s21_s1       (s21_s1),
      .s22_s1       (s22_s1),
      .e11_s1       (e11_s1),
      .e12_s1       (e12_s1),
      .e21_s1       (e21_s1),
      .e22_s1       (e22_s1),
      .a1_nan_s1    (a1_nan_fp8_s1),
      .a2_nan_s1    (a2_nan_fp8_s1),
      .b1_nan_s1    (b1_nan_fp8_s1),
      .b2_nan_s1    (b2_nan_fp8_s1),
      .a1_zero_s1   (a1_zero_fp8_s1),
      .a2_zero_s1   (a2_zero_fp8_s1),
      .b1_zero_s1   (b1_zero_fp8_s1),
      .b2_zero_s1   (b2_zero_fp8_s1),
      .c11_s1       (c11_fp8_s1),
      .c12_s1       (c12_fp8_s1),
      .c21_s1       (c21_fp8_s1),
      .c22_s1       (c22_fp8_s1),
      .product45    (product45),
      .prod_lane0_s2(fp8_prod0_s2),
      .prod_lane1_s2(fp8_prod1_s2),
      .prod_lane2_s2(fp8_prod2_s2),
      .prod_lane3_s2(fp8_prod3_s2),
      .c_lane0_s2   (fp8_c0_s2),
      .c_lane1_s2   (fp8_c1_s2),
      .c_lane2_s2   (fp8_c2_s2),
      .c_lane3_s2   (fp8_c3_s2)
  );

  // ===========================================================
  // S3: shared BF16 adders (bf16_add_orig4c has internal register)
  // ===========================================================
  wire [15:0] sum_lane0_s3, sum_lane1_s3, sum_lane2_s3, sum_lane3_s3;

  wire [15:0] add_a0 = mode_s2 ? fp8_prod0_s2 : bf16_prod_lo_s2;
  wire [15:0] add_a1 = mode_s2 ? fp8_prod1_s2 : bf16_prod_hi_s2;
  wire [15:0] add_a2 = mode_s2 ? fp8_prod2_s2 : 16'h0000;
  wire [15:0] add_a3 = mode_s2 ? fp8_prod3_s2 : 16'h0000;

  wire [15:0] add_b0 = mode_s2 ? fp8_c0_s2 : bf16_c_lo_s2;
  wire [15:0] add_b1 = mode_s2 ? fp8_c1_s2 : bf16_c_hi_s2;
  wire [15:0] add_b2 = mode_s2 ? fp8_c2_s2 : 16'h0000;
  wire [15:0] add_b3 = mode_s2 ? fp8_c3_s2 : 16'h0000;

  bf16_add_orig4c u_add0 (.clk(clk), .a16(add_a0), .b16(add_b0), .c16(sum_lane0_s3));
  bf16_add_orig4c u_add1 (.clk(clk), .a16(add_a1), .b16(add_b1), .c16(sum_lane1_s3));
  bf16_add_orig4c u_add2 (.clk(clk), .a16(add_a2), .b16(add_b2), .c16(sum_lane2_s3));
  bf16_add_orig4c u_add3 (.clk(clk), .a16(add_a3), .b16(add_b3), .c16(sum_lane3_s3));

  // ===========================================================
  // S4: output register
  // ===========================================================
  always @(posedge clk) begin
    if (mode_s3) begin
      result <= {sum_lane3_s3, sum_lane2_s3, sum_lane1_s3, sum_lane0_s3};
    end else begin
      result <= {32'd0, sum_lane1_s3, sum_lane0_s3};
    end
  end
endmodule

`default_nettype wire
