`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// int4_fp8e4m3_mac
//   - Two signed INT4 lanes (two's complement) × two FP8(E4M3) lanes
//   - Shared INT4 normalization helper converts to sign + 4-bit exponent + 3-bit mantissa
//   - DSP packing/post-processing mirrors fp8e4m3_mac (latency 4 cycles, II=1)
// ==========================================================================
module int4_fp8e4m3_mac (
    input  wire        clk,
    input  wire [7:0]  a_int4,   // {a2[7:4], a1[3:0]} signed INT4 lanes
    input  wire [15:0] b_fp8,    // {b2[15:8], b1[7:0]} FP8(E4M3)
    input  wire [31:0] c_fp8,    // {c22,c21,c12,c11}  FP8(E4M3)
    output reg  [31:0] result    // {y22,y21,y12,y11}
);
  `include "int4_fp8_common.vh"
  `DECL_INT4_DECODE_FP8_FIELDS
  // ---- FP8 E4M3 constants ----
  localparam integer EWIDTH = 4;
  localparam integer FWIDTH = 3;
  localparam integer MBITS  = 1 + FWIDTH;  // 4 (hidden + frac)
  localparam integer BIAS   = 7;

  localparam [7:0] QNAN8      = 8'h79;
  localparam [7:0] PZERO8     = 8'h00;
  localparam [7:0] NZERO8     = 8'h80;
  localparam [7:0] MAXFIN_POS = {1'b0, 4'hE, 3'b111};
  localparam [7:0] MAXFIN_NEG = {1'b1, 4'hE, 3'b111};

  // ---- INT4 lanes ----
  wire [8:0] a1_core = int4_decode_fp8_fields(a_int4[3:0]);
  wire [8:0] a2_core = int4_decode_fp8_fields(a_int4[7:4]);

  wire a1_zero = a1_core[8];
  wire a2_zero = a2_core[8];
  wire sa1     = a1_core[7];
  wire sa2     = a2_core[7];
  wire [3:0] ea1_unb = a1_core[6:3];
  wire [3:0] ea2_unb = a2_core[6:3];
  wire [2:0] fa1_core = a1_core[2:0];
  wire [2:0] fa2_core = a2_core[2:0];

  wire [4:0] ea1_bias = {1'b0, ea1_unb} + 5'd7;
  wire [4:0] ea2_bias = {1'b0, ea2_unb} + 5'd7;
  wire [EWIDTH-1:0] ea1 = a1_zero ? 4'd0 : ea1_bias[3:0];
  wire [EWIDTH-1:0] ea2 = a2_zero ? 4'd0 : ea2_bias[3:0];

  wire [MBITS-1:0] Ma1 = a1_zero ? 4'd0 : {1'b1, fa1_core};
  wire [MBITS-1:0] Ma2 = a2_zero ? 4'd0 : {1'b1, fa2_core};

  // ---- FP8 lanes for B (unchanged) ----
  wire [7:0] b1 = b_fp8[7:0];
  wire [7:0] b2 = b_fp8[15:8];

  wire sb1 = b1[7];
  wire sb2 = b2[7];
  wire [EWIDTH-1:0] eb1 = b1[6:3];
  wire [EWIDTH-1:0] eb2 = b2[6:3];
  wire [FWIDTH-1:0] fb1 = b1[2:0];
  wire [FWIDTH-1:0] fb2 = b2[2:0];

  wire b1_nan  = (eb1 == 4'hF);
  wire b2_nan  = (eb2 == 4'hF);
  wire b1_zero = (eb1 == 4'd0);
  wire b2_zero = (eb2 == 4'd0);

  // ---- Signs & exponent sums ----
  wire s11 = sa1 ^ sb1;
  wire s12 = sa1 ^ sb2;
  wire s21 = sa2 ^ sb1;
  wire s22 = sa2 ^ sb2;

  wire signed [6:0] e11_s1 = $signed({3'd0, ea1}) + $signed({3'd0, eb1}) - $signed(7'd7);
  wire signed [6:0] e12_s1 = $signed({3'd0, ea1}) + $signed({3'd0, eb2}) - $signed(7'd7);
  wire signed [6:0] e21_s1 = $signed({3'd0, ea2}) + $signed({3'd0, eb1}) - $signed(7'd7);
  wire signed [6:0] e22_s1 = $signed({3'd0, ea2}) + $signed({3'd0, eb2}) - $signed(7'd7);

  // ---- C lanes (unchanged) ----
  wire [7:0] c11 = c_fp8[7:0];
  wire [7:0] c12 = c_fp8[15:8];
  wire [7:0] c21 = c_fp8[23:16];
  wire [7:0] c22 = c_fp8[31:24];

  // ---- S1 registers ----
  reg [26:0] A_pack;
  reg [17:0] B_pack;

  reg        s11_s2, s12_s2, s21_s2, s22_s2;
  reg signed [6:0] e11_s2, e12_s2, e21_s2, e22_s2;

  reg a1_zero_s2, a2_zero_s2;
  reg b1_zero_s2, b2_zero_s2;
  reg b1_nan_s2,  b2_nan_s2;

  reg [7:0] c11_s2, c12_s2, c21_s2, c22_s2;

  always @(posedge clk) begin
    // INT4 mantissas already normalized (Ma=0 for zero lanes)
    A_pack <= {7'b0, Ma2, 12'b0, Ma1};
    B_pack <= {6'b0, (b2_zero ? 4'd0 : {1'b1, fb2}), 4'b0, (b1_zero ? 4'd0 : {1'b1, fb1})};

    s11_s2 <= s11;  s12_s2 <= s12;  s21_s2 <= s21;  s22_s2 <= s22;
    e11_s2 <= e11_s1; e12_s2 <= e12_s1; e21_s2 <= e21_s1; e22_s2 <= e22_s1;

    a1_zero_s2 <= a1_zero;
    a2_zero_s2 <= a2_zero;
    b1_zero_s2 <= b1_zero;
    b2_zero_s2 <= b2_zero;
    b1_nan_s2  <= b1_nan;
    b2_nan_s2  <= b2_nan;

    c11_s2 <= c11; c12_s2 <= c12; c21_s2 <= c21; c22_s2 <= c22;
  end

  // ---- DSP multiply ----
  wire [44:0] product45;
  (* use_dsp = "yes" *)
  dsp_usage u_dsp (
      .clk    (clk),
      .a      (A_pack),
      .b      (B_pack),
      .product(product45)
  );

  reg [31:0] dsp_p;
  always @(posedge clk) begin
    dsp_p <= product45[31:0];
  end

  // ---- S3: align meta ----
  reg        s11_s3, s12_s3, s21_s3, s22_s3;
  reg signed [6:0] e11_s3, e12_s3, e21_s3, e22_s3;

  reg a1_zero_s3, a2_zero_s3;
  reg b1_zero_s3, b2_zero_s3;
  reg b1_nan_s3,  b2_nan_s3;

  reg [7:0] c11_s3, c12_s3, c21_s3, c22_s3;

  always @(posedge clk) begin
    s11_s3 <= s11_s2; s12_s3 <= s12_s2; s21_s3 <= s21_s2; s22_s3 <= s22_s2;
    e11_s3 <= e11_s2; e12_s3 <= e12_s2; e21_s3 <= e21_s2; e22_s3 <= e22_s2;

    a1_zero_s3 <= a1_zero_s2;
    a2_zero_s3 <= a2_zero_s2;
    b1_zero_s3 <= b1_zero_s2;
    b2_zero_s3 <= b2_zero_s2;
    b1_nan_s3  <= b1_nan_s2;
    b2_nan_s3  <= b2_nan_s2;

    c11_s3 <= c11_s2; c12_s3 <= c12_s2; c21_s3 <= c21_s2; c22_s3 <= c22_s2;
  end

  // ---- Product windows ----
  wire [7:0] P11 = dsp_p[7:0];
  wire [7:0] P12 = dsp_p[15:8];
  wire [7:0] P21 = dsp_p[23:16];
  wire [7:0] P22 = dsp_p[31:24];

  // ---- Special-case detection ----
  wire nan_11 = b1_nan_s3;
  wire nan_12 = b2_nan_s3;
  wire nan_21 = b1_nan_s3;
  wire nan_22 = b2_nan_s3;

  wire zer_11 = ~nan_11 & (a1_zero_s3 | b1_zero_s3);
  wire zer_12 = ~nan_12 & (a1_zero_s3 | b2_zero_s3);
  wire zer_21 = ~nan_21 & (a2_zero_s3 | b1_zero_s3);
  wire zer_22 = ~nan_22 & (a2_zero_s3 | b2_zero_s3);

  // ---- Finite packing ----
  wire        c11_carry = P11[7];
  wire [2:0]  c11_frac3 = c11_carry ? P11[6:4] : P11[5:3];
  wire signed [6:0] c11_es  = e11_s3 + (c11_carry ? 7'sd1 : 7'sd0);
  wire        c11_ovf  = (c11_es < 7'sd0) || (c11_es > 7'sd14);
  wire [7:0]  prod11_fin = c11_ovf ? (s11_s3 ? MAXFIN_NEG : MAXFIN_POS)
                                   : {s11_s3, c11_es[3:0], c11_frac3};

  wire        c12_carry = P12[7];
  wire [2:0]  c12_frac3 = c12_carry ? P12[6:4] : P12[5:3];
  wire signed [6:0] c12_es  = e12_s3 + (c12_carry ? 7'sd1 : 7'sd0);
  wire        c12_ovf  = (c12_es < 7'sd0) || (c12_es > 7'sd14);
  wire [7:0]  prod12_fin = c12_ovf ? (s12_s3 ? MAXFIN_NEG : MAXFIN_POS)
                                   : {s12_s3, c12_es[3:0], c12_frac3};

  wire        c21_carry = P21[7];
  wire [2:0]  c21_frac3 = c21_carry ? P21[6:4] : P21[5:3];
  wire signed [6:0] c21_es  = e21_s3 + (c21_carry ? 7'sd1 : 7'sd0);
  wire        c21_ovf  = (c21_es < 7'sd0) || (c21_es > 7'sd14);
  wire [7:0]  prod21_fin = c21_ovf ? (s21_s3 ? MAXFIN_NEG : MAXFIN_POS)
                                   : {s21_s3, c21_es[3:0], c21_frac3};

  wire        c22_carry = P22[7];
  wire [2:0]  c22_frac3 = c22_carry ? P22[6:4] : P22[5:3];
  wire signed [6:0] c22_es  = e22_s3 + (c22_carry ? 7'sd1 : 7'sd0);
  wire        c22_ovf  = (c22_es < 7'sd0) || (c22_es > 7'sd14);
  wire [7:0]  prod22_fin = c22_ovf ? (s22_s3 ? MAXFIN_NEG : MAXFIN_POS)
                                   : {s22_s3, c22_es[3:0], c22_frac3};

  wire [7:0] prod11_w = nan_11 ? QNAN8 : (zer_11 ? {s11_s3, 7'd0} : prod11_fin);
  wire [7:0] prod12_w = nan_12 ? QNAN8 : (zer_12 ? {s12_s3, 7'd0} : prod12_fin);
  wire [7:0] prod21_w = nan_21 ? QNAN8 : (zer_21 ? {s21_s3, 7'd0} : prod21_fin);
  wire [7:0] prod22_w = nan_22 ? QNAN8 : (zer_22 ? {s22_s3, 7'd0} : prod22_fin);

  // ---- Per-lane adders ----
  wire [7:0] sum11, sum12, sum21, sum22;

  fp8e4m3_add u_add11 (.clk(clk), .a8(prod11_w), .b8(c11_s3), .c8(sum11));
  fp8e4m3_add u_add12 (.clk(clk), .a8(prod12_w), .b8(c12_s3), .c8(sum12));
  fp8e4m3_add u_add21 (.clk(clk), .a8(prod21_w), .b8(c21_s3), .c8(sum21));
  fp8e4m3_add u_add22 (.clk(clk), .a8(prod22_w), .b8(c22_s3), .c8(sum22));

  // ---- Final register ----
  always @(posedge clk) begin
    result <= {sum22, sum21, sum12, sum11};
  end

endmodule

`default_nettype wire
