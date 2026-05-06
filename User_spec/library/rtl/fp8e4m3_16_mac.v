`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// fp8e4m3_16_mac — 2×A lanes × 2×B lanes => 4 lane products per DSP
//   FP8 (E4M3) multiply, accumulate into FP16 lanes.
//   Replicates fp8e4m3_mac pipeline (4-cycle latency, II=1):
//     S1: unpack/classify, exponent sums, pack mantissas into DSP A/B
//     S2: DSP multiply (dsp_usage wrapper) → capture windows
//     S3: align meta & C, classify specials and bias exponents
//     S4: expand per-lane products to FP16, add with C, register result
// ==========================================================================
module fp8e4m3_16_mac (
    input  wire        clk,
    input  wire [31:0] a18,      // use a18[15:0] = {a2[15:8], a1[7:0]}
    input  wire [15:0] b18,      // {b2[15:8], b1[7:0]}
    input  wire [63:0] c64,      // {c22,c21,c12,c11} FP16 lanes
    output reg  [63:0] result    // {y22,y21,y12,y11} FP16 lanes
);
  // ---- FP8 E4M3 constants ----
  localparam integer EWIDTH = 4;
  localparam integer FWIDTH = 3;
  localparam integer MBITS  = 1 + FWIDTH;  // 4
  localparam integer BIAS   = 7;

  localparam [7:0] QNAN8      = 8'h79;                     // exp=1111 => NaN
  localparam [7:0] MAXFIN_POS = {1'b0, 4'hE, 3'b111};
  localparam [7:0] MAXFIN_NEG = {1'b1, 4'hE, 3'b111};
  localparam [15:0] FP16_QNAN        = 16'h7E00;
  localparam [15:0] FP16_MAXFIN_POS  = 16'h5B80;  // 240.0
  localparam [15:0] FP16_MAXFIN_NEG  = 16'hDB80;

  // ---- Lane unpack (use low 16 bits of a18) ----
  wire [7:0] a1 = a18[ 7: 0];
  wire [7:0] a2 = a18[15: 8];
  wire [7:0] b1 = b18[ 7: 0];
  wire [7:0] b2 = b18[15: 8];

  wire sa1 = a1[7], sa2 = a2[7];
  wire sb1 = b1[7], sb2 = b2[7];
  wire [EWIDTH-1:0] ea1 = a1[6:3], ea2 = a2[6:3], eb1 = b1[6:3], eb2 = b2[6:3];
  wire [FWIDTH-1:0] fa1 = a1[2:0], fa2 = a2[2:0], fb1 = b1[2:0], fb2 = b2[2:0];

  // classify (FTZ for exp==0). exp=1111 encodes NaN (no Inf for E4M3)
  wire a1_nan  = (ea1==4'hF);
  wire a2_nan  = (ea2==4'hF);
  wire b1_nan  = (eb1==4'hF);
  wire b2_nan  = (eb2==4'hF);

  wire a1_zero = (ea1==4'd0);
  wire a2_zero = (ea2==4'd0);
  wire b1_zero = (eb1==4'd0);
  wire b2_zero = (eb2==4'd0);

  // per-lane signs (finite path)
  wire        s11 = sa1 ^ sb1;
  wire        s12 = sa1 ^ sb2;
  wire        s21 = sa2 ^ sb1;
  wire        s22 = sa2 ^ sb2;

  // exponent sums (signed) bias corrected
  wire signed [6:0] e11_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb1}) - $signed(7'd7);
  wire signed [6:0] e12_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb2}) - $signed(7'd7);
  wire signed [6:0] e21_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb1}) - $signed(7'd7);
  wire signed [6:0] e22_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb2}) - $signed(7'd7);

  // ---- S1: pack mantissas into DSP inputs ----
  reg [26:0] A_pack;
  reg [17:0] B_pack;

  wire [MBITS-1:0] Ma1 = a1_zero ? 4'd0 : {1'b1, fa1};
  wire [MBITS-1:0] Ma2 = a2_zero ? 4'd0 : {1'b1, fa2};
  wire [MBITS-1:0] Mb1 = b1_zero ? 4'd0 : {1'b1, fb1};
  wire [MBITS-1:0] Mb2 = b2_zero ? 4'd0 : {1'b1, fb2};

  // C lanes (FP16)
  wire [15:0] c11 = c64[15: 0];
  wire [15:0] c12 = c64[31:16];
  wire [15:0] c21 = c64[47:32];
  wire [15:0] c22 = c64[63:48];

  // Metadata regs S1→S2
  reg        s11_s2, s12_s2, s21_s2, s22_s2;
  reg signed [6:0] e11_s2, e12_s2, e21_s2, e22_s2;

  reg a1_nan_s2, a2_nan_s2, b1_nan_s2, b2_nan_s2;
  reg a1_zero_s2,a2_zero_s2,b1_zero_s2,b2_zero_s2;

  reg [15:0] c11_s2, c12_s2, c21_s2, c22_s2;

  always @(posedge clk) begin
    A_pack <= {7'b0, Ma2, 12'b0, Ma1};
    B_pack <= {6'b0, Mb2, 4'b0, Mb1};

    s11_s2 <= s11; s12_s2 <= s12; s21_s2 <= s21; s22_s2 <= s22;
    e11_s2 <= e11_s1; e12_s2 <= e12_s1; e21_s2 <= e21_s1; e22_s2 <= e22_s1;

    a1_nan_s2  <= a1_nan;  a2_nan_s2  <= a2_nan;  b1_nan_s2  <= b1_nan;  b2_nan_s2  <= b2_nan;
    a1_zero_s2 <= a1_zero; a2_zero_s2 <= a2_zero; b1_zero_s2 <= b1_zero; b2_zero_s2 <= b2_zero;

    c11_s2 <= c11; c12_s2 <= c12; c21_s2 <= c21; c22_s2 <= c22;
  end

  // ---- S2: DSP multiply (1 cycle latency inside wrapper) ----
  wire [44:0] product45;
  (* use_dsp = "yes" *)
  dsp_usage u_dsp (
    .clk    (clk),
    .a      (A_pack),
    .b      (B_pack),
    .product(product45)
  );

  reg [31:0] dsp_p;  // 4×8-bit windows
  always @(posedge clk) begin
    dsp_p <= product45[31:0];
  end

  // ---- S3: align meta & C with DSP product ----
  reg        s11_s3, s12_s3, s21_s3, s22_s3;
  reg signed [6:0] e11_s3, e12_s3, e21_s3, e22_s3;

  reg a1_nan_s3, a2_nan_s3, b1_nan_s3, b2_nan_s3;
  reg a1_zero_s3,a2_zero_s3,b1_zero_s3,b2_zero_s3;

  reg [15:0] c11_s3, c12_s3, c21_s3, c22_s3;

  always @(posedge clk) begin
    s11_s3 <= s11_s2; s12_s3 <= s12_s2; s21_s3 <= s21_s2; s22_s3 <= s22_s2;
    e11_s3 <= e11_s2; e12_s3 <= e12_s2; e21_s3 <= e21_s2; e22_s3 <= e22_s2;

    a1_nan_s3  <= a1_nan_s2;  a2_nan_s3  <= a2_nan_s2;
    b1_nan_s3  <= b1_nan_s2;  b2_nan_s3  <= b2_nan_s2;
    a1_zero_s3 <= a1_zero_s2; a2_zero_s3 <= a2_zero_s2;
    b1_zero_s3 <= b1_zero_s2; b2_zero_s3 <= b2_zero_s2;

    c11_s3 <= c11_s2; c12_s3 <= c12_s2; c21_s3 <= c21_s2; c22_s3 <= c22_s2;
  end

  // ---- DSP product windows ----
  wire [7:0] P11 = dsp_p[ 7: 0];
  wire [7:0] P12 = dsp_p[15: 8];
  wire [7:0] P21 = dsp_p[23:16];
  wire [7:0] P22 = dsp_p[31:24];

  // ---- Per-lane specials ----
  wire nan_11 = a1_nan_s3 | b1_nan_s3;
  wire nan_12 = a1_nan_s3 | b2_nan_s3;
  wire nan_21 = a2_nan_s3 | b1_nan_s3;
  wire nan_22 = a2_nan_s3 | b2_nan_s3;

  wire zer_11 = ~nan_11 & (a1_zero_s3 | b1_zero_s3);
  wire zer_12 = ~nan_12 & (a1_zero_s3 | b2_zero_s3);
  wire zer_21 = ~nan_21 & (a2_zero_s3 | b1_zero_s3);
  wire zer_22 = ~nan_22 & (a2_zero_s3 | b2_zero_s3);

  // ---- Finite packs (bias/normalize) ----
  wire        c11_carry = P11[7];
  wire signed [6:0] c11_es  = e11_s3 + (c11_carry ? 7'sd1 : 7'sd0);
  wire        c11_ovf  = (c11_es < 7'sd0) || (c11_es > 7'sd14);
  wire        c12_carry = P12[7];
  wire signed [6:0] c12_es  = e12_s3 + (c12_carry ? 7'sd1 : 7'sd0);
  wire        c12_ovf  = (c12_es < 7'sd0) || (c12_es > 7'sd14);
  wire        c21_carry = P21[7];
  wire signed [6:0] c21_es  = e21_s3 + (c21_carry ? 7'sd1 : 7'sd0);
  wire        c21_ovf  = (c21_es < 7'sd0) || (c21_es > 7'sd14);
  wire        c22_carry = P22[7];
  wire signed [6:0] c22_es  = e22_s3 + (c22_carry ? 7'sd1 : 7'sd0);
  wire        c22_ovf  = (c22_es < 7'sd0) || (c22_es > 7'sd14);
  // ---- Assemble FP16 mantissas directly from DSP product ----
  wire [10:0] c11_mant_carry    = {P11, 3'b0};
  wire [11:0] c11_mant_nocarry_pre = {P11, 4'b0};
  wire [10:0] c11_mant_norm     = c11_carry ? c11_mant_carry : c11_mant_nocarry_pre[10:0];
  wire [4:0]  c11_exp16         = c11_es[4:0] + 5'd8;

  wire [10:0] c12_mant_carry    = {P12, 3'b0};
  wire [11:0] c12_mant_nocarry_pre = {P12, 4'b0};
  wire [10:0] c12_mant_norm     = c12_carry ? c12_mant_carry : c12_mant_nocarry_pre[10:0];
  wire [4:0]  c12_exp16         = c12_es[4:0] + 5'd8;

  wire [10:0] c21_mant_carry    = {P21, 3'b0};
  wire [11:0] c21_mant_nocarry_pre = {P21, 4'b0};
  wire [10:0] c21_mant_norm     = c21_carry ? c21_mant_carry : c21_mant_nocarry_pre[10:0];
  wire [4:0]  c21_exp16         = c21_es[4:0] + 5'd8;

  wire [10:0] c22_mant_carry    = {P22, 3'b0};
  wire [11:0] c22_mant_nocarry_pre = {P22, 4'b0};
  wire [10:0] c22_mant_norm     = c22_carry ? c22_mant_carry : c22_mant_nocarry_pre[10:0];
  wire [4:0]  c22_exp16         = c22_es[4:0] + 5'd8;

  wire [15:0] prod11_fp16_w =
      nan_11 ? FP16_QNAN :
      zer_11 ? {s11_s3, 15'd0} :
      c11_ovf ? (s11_s3 ? FP16_MAXFIN_NEG : FP16_MAXFIN_POS) :
                {s11_s3, c11_exp16, c11_mant_norm[9:0]};

  wire [15:0] prod12_fp16_w =
      nan_12 ? FP16_QNAN :
      zer_12 ? {s12_s3, 15'd0} :
      c12_ovf ? (s12_s3 ? FP16_MAXFIN_NEG : FP16_MAXFIN_POS) :
                {s12_s3, c12_exp16, c12_mant_norm[9:0]};

  wire [15:0] prod21_fp16_w =
      nan_21 ? FP16_QNAN :
      zer_21 ? {s21_s3, 15'd0} :
      c21_ovf ? (s21_s3 ? FP16_MAXFIN_NEG : FP16_MAXFIN_POS) :
                {s21_s3, c21_exp16, c21_mant_norm[9:0]};

  wire [15:0] prod22_fp16_w =
      nan_22 ? FP16_QNAN :
      zer_22 ? {s22_s3, 15'd0} :
      c22_ovf ? (s22_s3 ? FP16_MAXFIN_NEG : FP16_MAXFIN_POS) :
                {s22_s3, c22_exp16, c22_mant_norm[9:0]};

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
