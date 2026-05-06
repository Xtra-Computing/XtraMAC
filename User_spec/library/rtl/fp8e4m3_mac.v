`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// fp8e4m3_mac — 2×A lanes × 2×B lanes => 4 lane products per DSP (1|3|3)
//   FP8 (E4M3): [7]=sign, [6:3]=exp(4), [2:0]=frac(3), bias=7
//   NOTE: E4M3 encodes NO Infinity (exp=1111 => NaN). Overflows saturate to max finite.
//   S1: unpack/classify, signed exponent sums, pack A/B mantissas (2×2 lanes)
//   DSP: 1-cycle 27×18 -> 45b product => 4×(8-bit) windows (no overlap)
//   S2: capture product
//   S3: align product with meta & C; per-lane finite/special select
//   S4: per-lane add (fp8e4m3_add) and final register
//   Output: {y22, y21, y12, y11} packed as 4×FP8 = 32 bits
//   Total latency (II=1): 4 cycles
// ==========================================================================
module fp8e4m3_mac (
    input  wire        clk,
    input  wire [31:0] a18,     // USE a18[15:0]: {a2[15:8], a1[7:0]} two FP8 lanes (upper bits ignored)
    input  wire [15:0] b18,     // {b2[15:8], b1[7:0]}  two FP8 lanes
    input  wire [31:0] c36,     // {c22[31:24], c21[23:16], c12[15:8], c11[7:0]}
    output reg  [31:0] result   // {y22, y21, y12, y11}
);
  // ---- FP8 E4M3 constants ----
  localparam integer EWIDTH = 4;
  localparam integer FWIDTH = 3;
  localparam integer MBITS  = 1 + FWIDTH;  // 4
  localparam integer BIAS   = 7;
  localparam integer WPROD  = 2*MBITS;     // 8-bit mantissa product per lane

  // qNaN exemplar & special values (no Infinity in E4M3)
  localparam [7:0] QNAN8  = 8'h79;         // exp=1111, frac!=0 (sign doesn't matter)
  localparam [7:0] PZERO8 = 8'h00;         // +0
  localparam [7:0] NZERO8 = 8'h80;         // -0

  // Max finite (exp=14, frac=111)
  localparam [7:0] MAXFIN_POS = {1'b0, 4'hE, 3'b111};
  localparam [7:0] MAXFIN_NEG = {1'b1, 4'hE, 3'b111};

  // ---- S1: unpack A/B lanes (use only a18[15:0]) ----
  wire [7:0] a1 = a18[ 7: 0];
  wire [7:0] a2 = a18[15: 8];
  wire [7:0] b1 = b18[ 7: 0];
  wire [7:0] b2 = b18[15: 8];

  // fields
  wire sa1 = a1[7], sa2 = a2[7];
  wire sb1 = b1[7], sb2 = b2[7];
  wire [EWIDTH-1:0] ea1 = a1[6:3], ea2 = a2[6:3], eb1 = b1[6:3], eb2 = b2[6:3];
  wire [FWIDTH-1:0] fa1 = a1[2:0], fa2 = a2[2:0], fb1 = b1[2:0], fb2 = b2[2:0];

  // classify (FTZ for exp==0). No Inf: exp==1111 is NaN (even with frac==0).
  wire a1_nan  = (ea1==4'hF); // any exp=1111 => NaN
  wire a2_nan  = (ea2==4'hF);
  wire b1_nan  = (eb1==4'hF);
  wire b2_nan  = (eb2==4'hF);

  wire a1_zero = (ea1==4'd0);
  wire a2_zero = (ea2==4'd0);
  wire b1_zero = (eb1==4'd0);
  wire b2_zero = (eb2==4'd0);

  // signs and signed exponent sums (finite path)
  wire        s11 = sa1 ^ sb1;
  wire        s12 = sa1 ^ sb2;
  wire        s21 = sa2 ^ sb1;
  wire        s22 = sa2 ^ sb2;

  // generous signed width
  wire signed [6:0] e11_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb1}) - $signed(7'd7);
  wire signed [6:0] e12_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb2}) - $signed(7'd7);
  wire signed [6:0] e21_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb1}) - $signed(7'd7);
  wire signed [6:0] e22_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb2}) - $signed(7'd7);

  // ---- S1: pack mantissas into DSP A/B (2×2 lanes)
  reg  [26:0] A_pack;
  reg  [17:0] B_pack;

  wire [MBITS-1:0] Ma1 = a1_zero ? 4'd0 : {1'b1, fa1}; // 1+3
  wire [MBITS-1:0] Ma2 = a2_zero ? 4'd0 : {1'b1, fa2};
  wire [MBITS-1:0] Mb1 = b1_zero ? 4'd0 : {1'b1, fb1};
  wire [MBITS-1:0] Mb2 = b2_zero ? 4'd0 : {1'b1, fb2};

  // C lanes (c11,c12,c21,c22)
  wire [7:0] c11 = c36[ 7: 0];
  wire [7:0] c12 = c36[15: 8];
  wire [7:0] c21 = c36[23:16];
  wire [7:0] c22 = c36[31:24];

  // Meta registers S1->S2
  reg        s11_s2, s12_s2, s21_s2, s22_s2;
  reg signed [6:0] e11_s2, e12_s2, e21_s2, e22_s2;

  reg a1_nan_s2, a2_nan_s2, b1_nan_s2, b2_nan_s2;
  reg a1_zero_s2,a2_zero_s2,b1_zero_s2,b2_zero_s2;

  reg [7:0] c11_s2, c12_s2, c21_s2, c22_s2;

  // S1: pack + meta latch
  always @(posedge clk) begin
    // A_pack: Ma1 @ [3:0], Ma2 @ [19:16]  -> SA=16 (gap 12)
    A_pack <= { 7'b0, Ma2, 12'b0, Ma1 };
    // B_pack: Mb1 @ [3:0], Mb2 @ [11:8]   -> SB=8  (gap 4)
    B_pack <= { 6'b0, Mb2, 4'b0, Mb1 };

    // meta to S2
    s11_s2 <= s11; s12_s2 <= s12; s21_s2 <= s21; s22_s2 <= s22;
    e11_s2 <= e11_s1; e12_s2 <= e12_s1; e21_s2 <= e21_s1; e22_s2 <= e22_s1;

    a1_nan_s2  <= a1_nan;  a2_nan_s2  <= a2_nan;  b1_nan_s2  <= b1_nan;  b2_nan_s2  <= b2_nan;
    a1_zero_s2 <= a1_zero; a2_zero_s2 <= a2_zero; b1_zero_s2 <= b1_zero; b2_zero_s2 <= b2_zero;

    c11_s2 <= c11; c12_s2 <= c12; c21_s2 <= c21; c22_s2 <= c22;
  end

  // ---- DSP (1 cycle) ----
  wire [44:0] product45;
  (* use_dsp = "yes" *)
  dsp_usage u_dsp8e4m3 (
    .clk    (clk),
    .a      (A_pack),   // 27b
    .b      (B_pack),   // 18b
    .product(product45)
  );

  // ---- S2: capture windows ----
  reg [31:0] dsp_p;  // 4×8 = 32 low bits
  always @(posedge clk) begin
    dsp_p <= product45[31:0];
  end

  // ---- NEW: S3 meta/C alignment (to match dsp_p timing) ----
  reg        s11_s3, s12_s3, s21_s3, s22_s3;
  reg signed [6:0] e11_s3, e12_s3, e21_s3, e22_s3;

  reg a1_nan_s3, a2_nan_s3, b1_nan_s3, b2_nan_s3;
  reg a1_zero_s3,a2_zero_s3,b1_zero_s3,b2_zero_s3;

  reg [7:0] c11_s3, c12_s3, c21_s3, c22_s3;

  always @(posedge clk) begin
    s11_s3 <= s11_s2; s12_s3 <= s12_s2; s21_s3 <= s21_s2; s22_s3 <= s22_s2;
    e11_s3 <= e11_s2; e12_s3 <= e12_s2; e21_s3 <= e21_s2; e22_s3 <= e22_s2;

    a1_nan_s3  <= a1_nan_s2;  a2_nan_s3  <= a2_nan_s2;  b1_nan_s3  <= b1_nan_s2;  b2_nan_s3  <= b2_nan_s2;
    a1_zero_s3 <= a1_zero_s2; a2_zero_s3 <= a2_zero_s2; b1_zero_s3 <= b1_zero_s2; b2_zero_s3 <= b2_zero_s2;

    c11_s3 <= c11_s2; c12_s3 <= c12_s2; c21_s3 <= c21_s2; c22_s3 <= c22_s2;
  end

  // ---- Product windows (8b each): a1*b1, a1*b2, a2*b1, a2*b2 ----
  wire [7:0] P11 = dsp_p[ 7: 0];   // 0
  wire [7:0] P12 = dsp_p[15: 8];   // 8
  wire [7:0] P21 = dsp_p[23:16];   // 16
  wire [7:0] P22 = dsp_p[31:24];   // 24

  // ---- Per-lane specials (no Inf in E4M3) ----
  wire nan_11 = a1_nan_s3 | b1_nan_s3;
  wire nan_12 = a1_nan_s3 | b2_nan_s3;
  wire nan_21 = a2_nan_s3 | b1_nan_s3;
  wire nan_22 = a2_nan_s3 | b2_nan_s3;

  wire zer_11 = ~nan_11 & (a1_zero_s3 | b1_zero_s3);
  wire zer_12 = ~nan_12 & (a1_zero_s3 | b2_zero_s3);
  wire zer_21 = ~nan_21 & (a2_zero_s3 | b1_zero_s3);
  wire zer_22 = ~nan_22 & (a2_zero_s3 | b2_zero_s3);

  // ---- Per-lane finite pack ----
  // carry, fraction, exponent bump, overflow check (es < 0 || es > 14)
  // lane 11
  wire        c11_carry = P11[7];
  wire [2:0]  c11_frac3 = c11_carry ? P11[6:4] : P11[5:3];
  wire signed [6:0] c11_es  = e11_s3 + (c11_carry ? 7'sd1 : 7'sd0);
  wire        c11_ovf  = (c11_es < 7'sd0) || (c11_es > 7'sd14);
  wire [7:0]  prod11_fin = c11_ovf ? (s11_s3 ? MAXFIN_NEG : MAXFIN_POS)
                                   : {s11_s3, c11_es[3:0], c11_frac3};

  // lane 12
  wire        c12_carry = P12[7];
  wire [2:0]  c12_frac3 = c12_carry ? P12[6:4] : P12[5:3];
  wire signed [6:0] c12_es  = e12_s3 + (c12_carry ? 7'sd1 : 7'sd0);
  wire        c12_ovf  = (c12_es < 7'sd0) || (c12_es > 7'sd14);
  wire [7:0]  prod12_fin = c12_ovf ? (s12_s3 ? MAXFIN_NEG : MAXFIN_POS)
                                   : {s12_s3, c12_es[3:0], c12_frac3};

  // lane 21
  wire        c21_carry = P21[7];
  wire [2:0]  c21_frac3 = c21_carry ? P21[6:4] : P21[5:3];
  wire signed [6:0] c21_es  = e21_s3 + (c21_carry ? 7'sd1 : 7'sd0);
  wire        c21_ovf  = (c21_es < 7'sd0) || (c21_es > 7'sd14);
  wire [7:0]  prod21_fin = c21_ovf ? (s21_s3 ? MAXFIN_NEG : MAXFIN_POS)
                                   : {s21_s3, c21_es[3:0], c21_frac3};

  // lane 22
  wire        c22_carry = P22[7];
  wire [2:0]  c22_frac3 = c22_carry ? P22[6:4] : P22[5:3];
  wire signed [6:0] c22_es  = e22_s3 + (c22_carry ? 7'sd1 : 7'sd0);
  wire        c22_ovf  = (c22_es < 7'sd0) || (c22_es > 7'sd14);
  wire [7:0]  prod22_fin = c22_ovf ? (s22_s3 ? MAXFIN_NEG : MAXFIN_POS)
                                   : {s22_s3, c22_es[3:0], c22_frac3};

  // final per-lane product (specials dominate; zero keeps XOR sign → adder outputs +0)
  wire [7:0] prod11_w = nan_11 ? QNAN8 : (zer_11 ? {s11_s3,7'd0} : prod11_fin);
  wire [7:0] prod12_w = nan_12 ? QNAN8 : (zer_12 ? {s12_s3,7'd0} : prod12_fin);
  wire [7:0] prod21_w = nan_21 ? QNAN8 : (zer_21 ? {s21_s3,7'd0} : prod21_fin);
  wire [7:0] prod22_w = nan_22 ? QNAN8 : (zer_22 ? {s22_s3,7'd0} : prod22_fin);

  // ---- Per-lane adders (one internal reg stage each) ----
  wire [7:0] sum11, sum12, sum21, sum22;

  fp8e4m3_add u_add11 (.clk(clk), .a8(prod11_w), .b8(c11_s3), .c8(sum11));
  fp8e4m3_add u_add12 (.clk(clk), .a8(prod12_w), .b8(c12_s3), .c8(sum12));
  fp8e4m3_add u_add21 (.clk(clk), .a8(prod21_w), .b8(c21_s3), .c8(sum21));
  fp8e4m3_add u_add22 (.clk(clk), .a8(prod22_w), .b8(c22_s3), .c8(sum22));

  // ---- Final register (S4) ----
  always @(posedge clk) begin
    result <= {sum22, sum21, sum12, sum11};
  end

endmodule
