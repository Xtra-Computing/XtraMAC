`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// fp8e5m2_16_mac — 2×A lanes × 2×B lanes => 4 lane products per DSP
//   FP8 (E5M2) multiply, accumulate into FP16 lanes.
//   Pipeline mirrors fp8e5m2_mac (4-cycle latency, II=1):
//     S1: unpack/classify, exponent sums, pack mantissas into DSP A/B
//     S2: DSP multiply (dsp_usage wrapper) → capture product windows
//     S3: align meta & C, classify specials and bias exponents
//     S4: expand per-lane products to FP16, add with C, register result
// ==========================================================================
module fp8e5m2_16_mac (
    input  wire        clk,
    input  wire [31:0] a18,      // use a18[15:0] = {a2[15:8], a1[7:0]}
    input  wire [15:0] b18,      // {b2[15:8], b1[7:0]}
    input  wire [63:0] c64,      // {c22,c21,c12,c11} FP16 lanes
    output reg  [63:0] result    // {y22,y21,y12,y11} FP16 lanes
);
  // ---- FP8 E5M2 constants ----
  localparam integer EWIDTH = 5;
  localparam integer FWIDTH = 2;
  localparam integer MBITS  = 1 + FWIDTH;  // 3
  localparam integer BIAS   = 15;

  localparam [7:0] QNAN8  = 8'h7D;
  localparam [7:0] PINF8  = 8'h7C;
  localparam [7:0] NINF8  = 8'hFC;
  localparam [15:0] FP16_QNAN = 16'h7E00;
  localparam [15:0] FP16_PINF = 16'h7C00;
  localparam [15:0] FP16_NINF = 16'hFC00;

  // ---- Lane unpack (use low 16 bits of a18) ----
  wire [7:0] a1 = a18[ 7: 0];
  wire [7:0] a2 = a18[15: 8];
  wire [7:0] b1 = b18[ 7: 0];
  wire [7:0] b2 = b18[15: 8];

  wire sa1 = a1[7], sa2 = a2[7];
  wire sb1 = b1[7], sb2 = b2[7];
  wire [EWIDTH-1:0] ea1 = a1[6:2], ea2 = a2[6:2], eb1 = b1[6:2], eb2 = b2[6:2];
  wire [FWIDTH-1:0] fa1 = a1[1:0], fa2 = a2[1:0], fb1 = b1[1:0], fb2 = b2[1:0];

  // classify (FTZ for exp==0)
  wire a1_nan  = (ea1==5'h1F) && (fa1!=2'd0);
  wire a2_nan  = (ea2==5'h1F) && (fa2!=2'd0);
  wire b1_nan  = (eb1==5'h1F) && (fb1!=2'd0);
  wire b2_nan  = (eb2==5'h1F) && (fb2!=2'd0);

  wire a1_inf  = (ea1==5'h1F) && (fa1==2'd0);
  wire a2_inf  = (ea2==5'h1F) && (fa2==2'd0);
  wire b1_inf  = (eb1==5'h1F) && (fb1==2'd0);
  wire b2_inf  = (eb2==5'h1F) && (fb2==2'd0);

  wire a1_zero = (ea1==5'd0);
  wire a2_zero = (ea2==5'd0);
  wire b1_zero = (eb1==5'd0);
  wire b2_zero = (eb2==5'd0);

  // per-lane signs
  wire        s11 = sa1 ^ sb1;
  wire        s12 = sa1 ^ sb2;
  wire        s21 = sa2 ^ sb1;
  wire        s22 = sa2 ^ sb2;

  // exponent sums (signed) bias corrected
  wire signed [7:0] e11_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb1}) - $signed(8'd15);
  wire signed [7:0] e12_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb2}) - $signed(8'd15);
  wire signed [7:0] e21_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb1}) - $signed(8'd15);
  wire signed [7:0] e22_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb2}) - $signed(8'd15);

  // ---- S1: pack mantissas into DSP inputs ----
  reg [26:0] A_pack;
  reg [17:0] B_pack;

  wire [MBITS-1:0] Ma1 = a1_zero ? 3'd0 : {1'b1, fa1};
  wire [MBITS-1:0] Ma2 = a2_zero ? 3'd0 : {1'b1, fa2};
  wire [MBITS-1:0] Mb1 = b1_zero ? 3'd0 : {1'b1, fb1};
  wire [MBITS-1:0] Mb2 = b2_zero ? 3'd0 : {1'b1, fb2};

  // C lanes (FP16)
  wire [15:0] c11 = c64[15: 0];
  wire [15:0] c12 = c64[31:16];
  wire [15:0] c21 = c64[47:32];
  wire [15:0] c22 = c64[63:48];

  // Metadata regs S1→S2
  reg        s11_s2, s12_s2, s21_s2, s22_s2;
  reg signed [7:0] e11_s2, e12_s2, e21_s2, e22_s2;

  reg a1_nan_s2, a2_nan_s2, b1_nan_s2, b2_nan_s2;
  reg a1_inf_s2, a2_inf_s2, b1_inf_s2, b2_inf_s2;
  reg a1_zero_s2,a2_zero_s2,b1_zero_s2,b2_zero_s2;

  reg [15:0] c11_s2, c12_s2, c21_s2, c22_s2;

  always @(posedge clk) begin
    A_pack <= {12'b0, Ma2, 9'b0, Ma1};
    B_pack <= {9'b0, Mb2, 3'b0, Mb1};

    s11_s2 <= s11; s12_s2 <= s12; s21_s2 <= s21; s22_s2 <= s22;
    e11_s2 <= e11_s1; e12_s2 <= e12_s1; e21_s2 <= e21_s1; e22_s2 <= e22_s1;

    a1_nan_s2  <= a1_nan;  a2_nan_s2  <= a2_nan;  b1_nan_s2  <= b1_nan;  b2_nan_s2  <= b2_nan;
    a1_inf_s2  <= a1_inf;  a2_inf_s2  <= a2_inf;  b1_inf_s2  <= b1_inf;  b2_inf_s2  <= b2_inf;
    a1_zero_s2 <= a1_zero; a2_zero_s2 <= a2_zero; b1_zero_s2 <= b1_zero; b2_zero_s2 <= b2_zero;

    c11_s2 <= c11; c12_s2 <= c12; c21_s2 <= c21; c22_s2 <= c22;
  end

  // ---- S2: DSP multiply ----
  wire [44:0] product45;
  (* use_dsp = "yes" *)
  dsp_usage u_dsp (
    .clk    (clk),
    .a      (A_pack),
    .b      (B_pack),
    .product(product45)
  );

  reg [23:0] dsp_p;  // 4×6-bit windows
  always @(posedge clk) begin
    dsp_p <= product45[23:0];
  end

  // ---- S3: align meta & C ----
  reg        s11_s3, s12_s3, s21_s3, s22_s3;
  reg signed [7:0] e11_s3, e12_s3, e21_s3, e22_s3;

  reg a1_nan_s3, a2_nan_s3, b1_nan_s3, b2_nan_s3;
  reg a1_inf_s3, a2_inf_s3, b1_inf_s3, b2_inf_s3;
  reg a1_zero_s3,a2_zero_s3,b1_zero_s3,b2_zero_s3;

  reg [15:0] c11_s3, c12_s3, c21_s3, c22_s3;

  always @(posedge clk) begin
    s11_s3 <= s11_s2; s12_s3 <= s12_s2; s21_s3 <= s21_s2; s22_s3 <= s22_s2;
    e11_s3 <= e11_s2; e12_s3 <= e12_s2; e21_s3 <= e21_s2; e22_s3 <= e22_s2;

    a1_nan_s3  <= a1_nan_s2;  a2_nan_s3  <= a2_nan_s2;
    b1_nan_s3  <= b1_nan_s2;  b2_nan_s3  <= b2_nan_s2;
    a1_inf_s3  <= a1_inf_s2;  a2_inf_s3  <= a2_inf_s2;
    b1_inf_s3  <= b1_inf_s2;  b2_inf_s3  <= b2_inf_s2;
    a1_zero_s3 <= a1_zero_s2; a2_zero_s3 <= a2_zero_s2;
    b1_zero_s3 <= b1_zero_s2; b2_zero_s3 <= b2_zero_s2;

    c11_s3 <= c11_s2; c12_s3 <= c12_s2; c21_s3 <= c21_s2; c22_s3 <= c22_s2;
  end

  // ---- DSP product windows ----
  wire [5:0] P11 = dsp_p[ 5: 0];
  wire [5:0] P12 = dsp_p[11: 6];
  wire [5:0] P21 = dsp_p[17:12];
  wire [5:0] P22 = dsp_p[23:18];

  // ---- Per-lane specials ----
  wire nan_11 = a1_nan_s3 | b1_nan_s3 | ((a1_inf_s3 & b1_zero_s3) | (a1_zero_s3 & b1_inf_s3));
  wire nan_12 = a1_nan_s3 | b2_nan_s3 | ((a1_inf_s3 & b2_zero_s3) | (a1_zero_s3 & b2_inf_s3));
  wire nan_21 = a2_nan_s3 | b1_nan_s3 | ((a2_inf_s3 & b1_zero_s3) | (a2_zero_s3 & b1_inf_s3));
  wire nan_22 = a2_nan_s3 | b2_nan_s3 | ((a2_inf_s3 & b2_zero_s3) | (a2_zero_s3 & b2_inf_s3));

  wire inf_11 = ~nan_11 & (a1_inf_s3 | b1_inf_s3);
  wire inf_12 = ~nan_12 & (a1_inf_s3 | b2_inf_s3);
  wire inf_21 = ~nan_21 & (a2_inf_s3 | b1_inf_s3);
  wire inf_22 = ~nan_22 & (a2_inf_s3 | b2_inf_s3);

  wire zer_11 = ~nan_11 & ~inf_11 & (a1_zero_s3 | b1_zero_s3);
  wire zer_12 = ~nan_12 & ~inf_12 & (a1_zero_s3 | b2_zero_s3);
  wire zer_21 = ~nan_21 & ~inf_21 & (a2_zero_s3 | b1_zero_s3);
  wire zer_22 = ~nan_22 & ~inf_22 & (a2_zero_s3 | b2_zero_s3);

  // ---- Finite packs ----
  wire        c11_carry = P11[5];
  wire signed [7:0] c11_es  = e11_s3 + (c11_carry ? 8'sd1 : 8'sd0);
  wire        c11_ovf  = (c11_es < 8'sd0) || (c11_es > 8'sd30);
  wire        c12_carry = P12[5];
  wire signed [7:0] c12_es  = e12_s3 + (c12_carry ? 8'sd1 : 8'sd0);
  wire        c12_ovf  = (c12_es < 8'sd0) || (c12_es > 8'sd30);
  wire        c21_carry = P21[5];
  wire signed [7:0] c21_es  = e21_s3 + (c21_carry ? 8'sd1 : 8'sd0);
  wire        c21_ovf  = (c21_es < 8'sd0) || (c21_es > 8'sd30);
  wire        c22_carry = P22[5];
  wire signed [7:0] c22_es  = e22_s3 + (c22_carry ? 8'sd1 : 8'sd0);
  wire        c22_ovf  = (c22_es < 8'sd0) || (c22_es > 8'sd30);
  // ---- Assemble FP16 mantissas from DSP product ----
  wire [10:0] c11_mant_carry    = {P11, 5'b0};
  wire [11:0] c11_mant_nocarry_pre = {P11, 6'b0};
  wire [10:0] c11_mant_norm     = c11_carry ? c11_mant_carry : c11_mant_nocarry_pre[10:0];

  wire [10:0] c12_mant_carry    = {P12, 5'b0};
  wire [11:0] c12_mant_nocarry_pre = {P12, 6'b0};
  wire [10:0] c12_mant_norm     = c12_carry ? c12_mant_carry : c12_mant_nocarry_pre[10:0];

  wire [10:0] c21_mant_carry    = {P21, 5'b0};
  wire [11:0] c21_mant_nocarry_pre = {P21, 6'b0};
  wire [10:0] c21_mant_norm     = c21_carry ? c21_mant_carry : c21_mant_nocarry_pre[10:0];

  wire [10:0] c22_mant_carry    = {P22, 5'b0};
  wire [11:0] c22_mant_nocarry_pre = {P22, 6'b0};
  wire [10:0] c22_mant_norm     = c22_carry ? c22_mant_carry : c22_mant_nocarry_pre[10:0];

  wire [15:0] c11_inf_fp16 = s11_s3 ? FP16_NINF : FP16_PINF;
  wire [15:0] c12_inf_fp16 = s12_s3 ? FP16_NINF : FP16_PINF;
  wire [15:0] c21_inf_fp16 = s21_s3 ? FP16_NINF : FP16_PINF;
  wire [15:0] c22_inf_fp16 = s22_s3 ? FP16_NINF : FP16_PINF;

  wire [15:0] prod11_fp16_w =
      nan_11 ? FP16_QNAN :
      inf_11 ? c11_inf_fp16 :
      zer_11 ? {s11_s3, 15'd0} :
      c11_ovf ? c11_inf_fp16 :
                {s11_s3, c11_es[4:0], c11_mant_norm[9:0]};

  wire [15:0] prod12_fp16_w =
      nan_12 ? FP16_QNAN :
      inf_12 ? c12_inf_fp16 :
      zer_12 ? {s12_s3, 15'd0} :
      c12_ovf ? c12_inf_fp16 :
                {s12_s3, c12_es[4:0], c12_mant_norm[9:0]};

  wire [15:0] prod21_fp16_w =
      nan_21 ? FP16_QNAN :
      inf_21 ? c21_inf_fp16 :
      zer_21 ? {s21_s3, 15'd0} :
      c21_ovf ? c21_inf_fp16 :
                {s21_s3, c21_es[4:0], c21_mant_norm[9:0]};

  wire [15:0] prod22_fp16_w =
      nan_22 ? FP16_QNAN :
      inf_22 ? c22_inf_fp16 :
      zer_22 ? {s22_s3, 15'd0} :
      c22_ovf ? c22_inf_fp16 :
                {s22_s3, c22_es[4:0], c22_mant_norm[9:0]};

  // ---- Helper functions for FP16 addition ----
  wire [15:0] sum11_w, sum12_w, sum21_w, sum22_w;

  fp16_add u_add11 (.clk(clk), .x16(prod11_fp16_w), .y16(c11_s3), .result(sum11_w));
  fp16_add u_add12 (.clk(clk), .x16(prod12_fp16_w), .y16(c12_s3), .result(sum12_w));
  fp16_add u_add21 (.clk(clk), .x16(prod21_fp16_w), .y16(c21_s3), .result(sum21_w));
  fp16_add u_add22 (.clk(clk), .x16(prod22_fp16_w), .y16(c22_s3), .result(sum22_w));

  // ---- S4: final register ----
  always @(posedge clk) begin
    result <= {sum22_w, sum21_w, sum12_w, sum11_w};
  end

endmodule

`default_nettype wire
