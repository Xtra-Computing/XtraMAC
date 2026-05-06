`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// fp8e4m3_mul_4lane -- 4-lane DSP-packed FP8(E4M3) multiplier
//   2xA lanes x 2xB lanes => 4 products per DSP (LATENCY=2)
//
//   FP8(E4M3): sign[7], exp[6:3] (4-bit, bias=7), frac[2:0] (3-bit)
//   Mantissa = 1 + 3 = 4 bits. NO Infinity (exp=0xF is always NaN).
//   Overflow saturates to max finite (+/-{4'hE,3'b111}).
//
//   Pipeline:
//     S1 (input reg): unpack 2xA and 2xB, classify (NaN/zero), compute
//         signed exponent sums, pack mantissas into DSP A[26:0]/B[17:0]
//     DSP (combinational): 27x18 -> 45-bit product
//     S2 (capture reg): latch 4x8-bit product windows + decode to FP8
//
//   DSP packing (4 non-overlapping 8-bit windows):
//     A[26:0] = {7'b0, Ma2[3:0], 12'b0, Ma1[3:0]}
//     B[17:0] = {6'b0, Mb2[3:0],  4'b0, Mb1[3:0]}
//     Product windows: P11@[7:0], P12@[15:8], P21@[23:16], P22@[31:24]
//
//   Outputs: 4x packed FP8 products + metadata (signs, exponents, flags)
// ======================================================================
module fp8e4m3_mul_4lane #(
    parameter integer LATENCY = 2  // fixed at 2 (S1 reg + DSP + S2 reg)
) (
    input  wire        clk,
    input  wire [15:0] a_fp8,   // {a2[15:8], a1[7:0]} two FP8 A-lanes
    input  wire [15:0] b_fp8,   // {b2[15:8], b1[7:0]} two FP8 B-lanes

    // Per-lane FP8 products (special-case resolved)
    output wire [7:0]  prod11,  // a1*b1
    output wire [7:0]  prod12,  // a1*b2
    output wire [7:0]  prod21,  // a2*b1
    output wire [7:0]  prod22,  // a2*b2

    // Per-lane product signs (for downstream use)
    output wire        sign11,
    output wire        sign12,
    output wire        sign21,
    output wire        sign22
);
  // ---- FP8 E4M3 constants ----
  localparam integer EWIDTH = 4;
  localparam integer FWIDTH = 3;
  localparam integer MBITS  = 1 + FWIDTH;  // 4
  localparam integer BIAS   = 7;

  localparam [7:0] QNAN8      = 8'h79;
  localparam [7:0] MAXFIN_POS = {1'b0, 4'hE, 3'b111};
  localparam [7:0] MAXFIN_NEG = {1'b1, 4'hE, 3'b111};

  // ---- Unpack A/B lanes ----
  wire [7:0] a1 = a_fp8[ 7:0];
  wire [7:0] a2 = a_fp8[15:8];
  wire [7:0] b1 = b_fp8[ 7:0];
  wire [7:0] b2 = b_fp8[15:8];

  wire sa1 = a1[7], sa2 = a2[7];
  wire sb1 = b1[7], sb2 = b2[7];
  wire [EWIDTH-1:0] ea1 = a1[6:3], ea2 = a2[6:3], eb1 = b1[6:3], eb2 = b2[6:3];
  wire [FWIDTH-1:0] fa1 = a1[2:0], fa2 = a2[2:0], fb1 = b1[2:0], fb2 = b2[2:0];

  // ---- Classify (FTZ for exp==0, NaN for exp==15) ----
  wire a1_nan  = (ea1 == 4'hF);
  wire a2_nan  = (ea2 == 4'hF);
  wire b1_nan  = (eb1 == 4'hF);
  wire b2_nan  = (eb2 == 4'hF);

  wire a1_zero = (ea1 == 4'd0);
  wire a2_zero = (ea2 == 4'd0);
  wire b1_zero = (eb1 == 4'd0);
  wire b2_zero = (eb2 == 4'd0);

  // ---- Product signs ----
  wire s11 = sa1 ^ sb1;
  wire s12 = sa1 ^ sb2;
  wire s21 = sa2 ^ sb1;
  wire s22 = sa2 ^ sb2;

  // ---- Signed exponent sums (generous 7-bit signed width) ----
  wire signed [6:0] e11_s1 = $signed({3'd0, ea1}) + $signed({3'd0, eb1}) - $signed(7'd7);
  wire signed [6:0] e12_s1 = $signed({3'd0, ea1}) + $signed({3'd0, eb2}) - $signed(7'd7);
  wire signed [6:0] e21_s1 = $signed({3'd0, ea2}) + $signed({3'd0, eb1}) - $signed(7'd7);
  wire signed [6:0] e22_s1 = $signed({3'd0, ea2}) + $signed({3'd0, eb2}) - $signed(7'd7);

  // ---- Mantissas (hidden bit prepended, zero for FTZ) ----
  wire [MBITS-1:0] Ma1 = a1_zero ? 4'd0 : {1'b1, fa1};
  wire [MBITS-1:0] Ma2 = a2_zero ? 4'd0 : {1'b1, fa2};
  wire [MBITS-1:0] Mb1 = b1_zero ? 4'd0 : {1'b1, fb1};
  wire [MBITS-1:0] Mb2 = b2_zero ? 4'd0 : {1'b1, fb2};

  // ============================================================
  //  S1: Register pack + meta
  // ============================================================
  reg [26:0] A_pack;
  reg [17:0] B_pack;

  reg        s11_s2, s12_s2, s21_s2, s22_s2;
  reg signed [6:0] e11_s2, e12_s2, e21_s2, e22_s2;

  reg a1_nan_s2, a2_nan_s2, b1_nan_s2, b2_nan_s2;
  reg a1_zero_s2, a2_zero_s2, b1_zero_s2, b2_zero_s2;

  always @(posedge clk) begin
    A_pack <= {7'b0, Ma2, 12'b0, Ma1};
    B_pack <= {6'b0, Mb2,  4'b0, Mb1};

    s11_s2 <= s11; s12_s2 <= s12; s21_s2 <= s21; s22_s2 <= s22;
    e11_s2 <= e11_s1; e12_s2 <= e12_s1; e21_s2 <= e21_s1; e22_s2 <= e22_s1;

    a1_nan_s2  <= a1_nan;  a2_nan_s2  <= a2_nan;
    b1_nan_s2  <= b1_nan;  b2_nan_s2  <= b2_nan;
    a1_zero_s2 <= a1_zero; a2_zero_s2 <= a2_zero;
    b1_zero_s2 <= b1_zero; b2_zero_s2 <= b2_zero;
  end

  // ============================================================
  //  DSP (combinational: AREG=BREG=MREG=PREG=0)
  // ============================================================
  wire [44:0] product45;

  dsp_usage u_dsp (
    .clk     (clk),
    .a       (A_pack),
    .b       (B_pack),
    .product (product45)
  );

  // ============================================================
  //  S2: Capture product windows + decode to FP8
  // ============================================================
  reg [31:0] dsp_p;
  always @(posedge clk) begin
    dsp_p <= product45[31:0];
  end

  // Align meta with dsp_p (one extra cycle for DSP capture)
  reg        s11_s3, s12_s3, s21_s3, s22_s3;
  reg signed [6:0] e11_s3, e12_s3, e21_s3, e22_s3;
  reg a1_nan_s3, a2_nan_s3, b1_nan_s3, b2_nan_s3;
  reg a1_zero_s3, a2_zero_s3, b1_zero_s3, b2_zero_s3;

  always @(posedge clk) begin
    s11_s3 <= s11_s2; s12_s3 <= s12_s2; s21_s3 <= s21_s2; s22_s3 <= s22_s2;
    e11_s3 <= e11_s2; e12_s3 <= e12_s2; e21_s3 <= e21_s2; e22_s3 <= e22_s2;

    a1_nan_s3  <= a1_nan_s2;  a2_nan_s3  <= a2_nan_s2;
    b1_nan_s3  <= b1_nan_s2;  b2_nan_s3  <= b2_nan_s2;
    a1_zero_s3 <= a1_zero_s2; a2_zero_s3 <= a2_zero_s2;
    b1_zero_s3 <= b1_zero_s2; b2_zero_s3 <= b2_zero_s2;
  end

  // ---- Product windows (8b each) ----
  wire [7:0] P11 = dsp_p[ 7: 0];
  wire [7:0] P12 = dsp_p[15: 8];
  wire [7:0] P21 = dsp_p[23:16];
  wire [7:0] P22 = dsp_p[31:24];

  // ---- Per-lane specials (no Inf in E4M3) ----
  wire nan_11 = a1_nan_s3 | b1_nan_s3;
  wire nan_12 = a1_nan_s3 | b2_nan_s3;
  wire nan_21 = a2_nan_s3 | b1_nan_s3;
  wire nan_22 = a2_nan_s3 | b2_nan_s3;

  wire zer_11 = ~nan_11 & (a1_zero_s3 | b1_zero_s3);
  wire zer_12 = ~nan_12 & (a1_zero_s3 | b2_zero_s3);
  wire zer_21 = ~nan_21 & (a2_zero_s3 | b1_zero_s3);
  wire zer_22 = ~nan_22 & (a2_zero_s3 | b2_zero_s3);

  // ---- Per-lane finite pack (carry normalization) ----
  // Lane 11
  wire        c11_carry = P11[7];
  wire [2:0]  c11_frac3 = c11_carry ? P11[6:4] : P11[5:3];
  wire signed [6:0] c11_es = e11_s3 + (c11_carry ? 7'sd1 : 7'sd0);
  wire        c11_ovf = (c11_es < 7'sd0) || (c11_es > 7'sd14);
  wire [7:0]  prod11_fin = c11_ovf ? (s11_s3 ? MAXFIN_NEG : MAXFIN_POS)
                                   : {s11_s3, c11_es[3:0], c11_frac3};

  // Lane 12
  wire        c12_carry = P12[7];
  wire [2:0]  c12_frac3 = c12_carry ? P12[6:4] : P12[5:3];
  wire signed [6:0] c12_es = e12_s3 + (c12_carry ? 7'sd1 : 7'sd0);
  wire        c12_ovf = (c12_es < 7'sd0) || (c12_es > 7'sd14);
  wire [7:0]  prod12_fin = c12_ovf ? (s12_s3 ? MAXFIN_NEG : MAXFIN_POS)
                                   : {s12_s3, c12_es[3:0], c12_frac3};

  // Lane 21
  wire        c21_carry = P21[7];
  wire [2:0]  c21_frac3 = c21_carry ? P21[6:4] : P21[5:3];
  wire signed [6:0] c21_es = e21_s3 + (c21_carry ? 7'sd1 : 7'sd0);
  wire        c21_ovf = (c21_es < 7'sd0) || (c21_es > 7'sd14);
  wire [7:0]  prod21_fin = c21_ovf ? (s21_s3 ? MAXFIN_NEG : MAXFIN_POS)
                                   : {s21_s3, c21_es[3:0], c21_frac3};

  // Lane 22
  wire        c22_carry = P22[7];
  wire [2:0]  c22_frac3 = c22_carry ? P22[6:4] : P22[5:3];
  wire signed [6:0] c22_es = e22_s3 + (c22_carry ? 7'sd1 : 7'sd0);
  wire        c22_ovf = (c22_es < 7'sd0) || (c22_es > 7'sd14);
  wire [7:0]  prod22_fin = c22_ovf ? (s22_s3 ? MAXFIN_NEG : MAXFIN_POS)
                                   : {s22_s3, c22_es[3:0], c22_frac3};

  // ---- Final per-lane product (specials dominate) ----
  assign prod11 = nan_11 ? QNAN8 : (zer_11 ? {s11_s3, 7'd0} : prod11_fin);
  assign prod12 = nan_12 ? QNAN8 : (zer_12 ? {s12_s3, 7'd0} : prod12_fin);
  assign prod21 = nan_21 ? QNAN8 : (zer_21 ? {s21_s3, 7'd0} : prod21_fin);
  assign prod22 = nan_22 ? QNAN8 : (zer_22 ? {s22_s3, 7'd0} : prod22_fin);

  assign sign11 = s11_s3;
  assign sign12 = s12_s3;
  assign sign21 = s21_s3;
  assign sign22 = s22_s3;

endmodule

`default_nettype wire
