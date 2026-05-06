`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// fp9_mac  — 2×A lanes × 2×B lanes => 4 lane products per DSP (1|4|4)
//   FP9: [8]=sign, [7:4]=exp(4), [3:0]=frac(4), bias=7
//   S1: unpack/classify, signed exponent sums, pack A/B mantissas (2×2 lanes)
//   DSP: 1-cycle 27×18 -> 45b product => 4×(10-bit) windows (no overlap)
//   S2: capture product
//   S3: align meta & C to product; per-lane finite/special select
//   S4: per-lane add (fp9_add) and final pack
//   Output: {y22, y21, y12, y11} packed as 4×FP9 = 36 bits
//   Total latency (II=1): 4 cycles
// ==========================================================================
module fp9_mac (
    input  wire        clk,
    input  wire [17:0] a18,     // {a2[17:9], a1[8:0]}  two FP9 lanes
    input  wire [17:0] b18,     // {b2[17:9], b1[8:0]}  two FP9 lanes
    input  wire [35:0] c36,     // {c22[35:27], c21[26:18], c12[17:9], c11[8:0]}
    output reg  [35:0] result   // {y22, y21, y12, y11}
);
  // ---- FP9 constants ----
  localparam integer EWIDTH = 4;
  localparam integer FWIDTH = 4;
  localparam integer MBITS  = 1 + FWIDTH;  // 5
  localparam integer BIAS   = 7;
  localparam integer WPROD  = 2*MBITS;     // 10-bit mantissa product per lane

  localparam [8:0] QNAN9  = 9'h0F8;        // qNaN exemplar
  localparam [8:0] PINF9  = 9'h0F0;        // +Inf
  localparam [8:0] NINF9  = 9'h1F0;        // -Inf
  localparam [8:0] PZERO9 = 9'h000;        // +0
  localparam [8:0] NZERO9 = 9'h100;        // -0

  // ---- S1: unpack A/B lanes ----
  wire [8:0] a1 = a18[ 8: 0];
  wire [8:0] a2 = a18[17: 9];
  wire [8:0] b1 = b18[ 8: 0];
  wire [8:0] b2 = b18[17: 9];

  // fields
  wire sa1 = a1[8], sa2 = a2[8];
  wire sb1 = b1[8], sb2 = b2[8];
  wire [EWIDTH-1:0] ea1 = a1[7:4], ea2 = a2[7:4], eb1 = b1[7:4], eb2 = b2[7:4];
  wire [FWIDTH-1:0] fa1 = a1[3:0], fa2 = a2[3:0], fb1 = b1[3:0], fb2 = b2[3:0];

  // classify (FTZ for exp==0)
  wire a1_nan  = (ea1==4'hF) && (fa1!=4'd0);
  wire a2_nan  = (ea2==4'hF) && (fa2!=4'd0);
  wire b1_nan  = (eb1==4'hF) && (fb1!=4'd0);
  wire b2_nan  = (eb2==4'hF) && (fb2!=4'd0);

  wire a1_inf  = (ea1==4'hF) && (fa1==4'd0);
  wire a2_inf  = (ea2==4'hF) && (fa2==4'd0);
  wire b1_inf  = (eb1==4'hF) && (fb1==4'd0);
  wire b2_inf  = (eb2==4'hF) && (fb2==4'd0);

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

  wire [MBITS-1:0] Ma1 = a1_zero ? 5'd0 : {1'b1, fa1};
  wire [MBITS-1:0] Ma2 = a2_zero ? 5'd0 : {1'b1, fa2};
  wire [MBITS-1:0] Mb1 = b1_zero ? 5'd0 : {1'b1, fb1};
  wire [MBITS-1:0] Mb2 = b2_zero ? 5'd0 : {1'b1, fb2};

  // C lanes (c11,c12,c21,c22)
  wire [8:0] c11 = c36[ 8: 0];
  wire [8:0] c12 = c36[17: 9];
  wire [8:0] c21 = c36[26:18];
  wire [8:0] c22 = c36[35:27];

  // Meta registers S1->S2
  reg        s11_s2, s12_s2, s21_s2, s22_s2;
  reg signed [6:0] e11_s2, e12_s2, e21_s2, e22_s2;

  reg a1_nan_s2, a2_nan_s2, b1_nan_s2, b2_nan_s2;
  reg a1_inf_s2, a2_inf_s2, b1_inf_s2, b2_inf_s2;
  reg a1_zero_s2,a2_zero_s2,b1_zero_s2,b2_zero_s2;

  reg [8:0] c11_s2, c12_s2, c21_s2, c22_s2;

  // S1: pack + meta latch
  always @(posedge clk) begin
    // A_pack: Ma1 at [4:0], Ma2 at [24:20] (gap=15 -> SA=20)
    A_pack <= { 2'b00, Ma2, 15'b0, Ma1 };   // FIXED: was 5'b0
    // B_pack: Mb1 at [4:0], Mb2 at [14:10] (gap=5 -> SB=10)
    B_pack <= { 3'b000, Mb2, 5'b0, Mb1 };

    // meta to S2
    s11_s2 <= s11; s12_s2 <= s12; s21_s2 <= s21; s22_s2 <= s22;
    e11_s2 <= e11_s1; e12_s2 <= e12_s1; e21_s2 <= e21_s1; e22_s2 <= e22_s1;

    a1_nan_s2  <= a1_nan;  a2_nan_s2  <= a2_nan;  b1_nan_s2  <= b1_nan;  b2_nan_s2  <= b2_nan;
    a1_inf_s2  <= a1_inf;  a2_inf_s2  <= a2_inf;  b1_inf_s2  <= b1_inf;  b2_inf_s2  <= b2_inf;
    a1_zero_s2 <= a1_zero; a2_zero_s2 <= a2_zero; b1_zero_s2 <= b1_zero; b2_zero_s2 <= b2_zero;

    c11_s2 <= c11; c12_s2 <= c12; c21_s2 <= c21; c22_s2 <= c22;
  end

  // ---- DSP (1 cycle) ----
  wire [44:0] product45;
  (* use_dsp = "yes" *)
  dsp_usage u_dsp9 (
    .clk    (clk),
    .a      (A_pack),   // 27b
    .b      (B_pack),   // 18b
    .product(product45)
  );

  // ---- S2: capture needed bits ----
  reg [39:0] dsp_p;
  always @(posedge clk) begin
    dsp_p <= product45[39:0];  // windows @ [9:0],[19:10],[29:20],[39:30]
  end

  // ---- NEW: S3 meta/C alignment (to match dsp_p timing) ----
  reg        s11_s3, s12_s3, s21_s3, s22_s3;
  reg signed [6:0] e11_s3, e12_s3, e21_s3, e22_s3;

  reg a1_nan_s3, a2_nan_s3, b1_nan_s3, b2_nan_s3;
  reg a1_inf_s3, a2_inf_s3, b1_inf_s3, b2_inf_s3;
  reg a1_zero_s3,a2_zero_s3,b1_zero_s3,b2_zero_s3;

  reg [8:0] c11_s3, c12_s3, c21_s3, c22_s3;

  always @(posedge clk) begin
    s11_s3 <= s11_s2; s12_s3 <= s12_s2; s21_s3 <= s21_s2; s22_s3 <= s22_s2;
    e11_s3 <= e11_s2; e12_s3 <= e12_s2; e21_s3 <= e21_s2; e22_s3 <= e22_s2;

    a1_nan_s3  <= a1_nan_s2;  a2_nan_s3  <= a2_nan_s2;  b1_nan_s3  <= b1_nan_s2;  b2_nan_s3  <= b2_nan_s2;
    a1_inf_s3  <= a1_inf_s2;  a2_inf_s3  <= a2_inf_s2;  b1_inf_s3  <= b1_inf_s2;  b2_inf_s3  <= b2_inf_s2;
    a1_zero_s3 <= a1_zero_s2; a2_zero_s3 <= a2_zero_s2; b1_zero_s3 <= b1_zero_s2; b2_zero_s3 <= b2_zero_s2;

    c11_s3 <= c11_s2; c12_s3 <= c12_s2; c21_s3 <= c21_s2; c22_s3 <= c22_s2;
  end

  // ---- Product windows (10b each): a1*b1, a1*b2, a2*b1, a2*b2 ----
  wire [9:0] P11 = dsp_p[ 9: 0];   // 0
  wire [9:0] P12 = dsp_p[19:10];   // 10
  wire [9:0] P21 = dsp_p[29:20];   // 20
  wire [9:0] P22 = dsp_p[39:30];   // 30

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

  // ---- Per-lane finite pack ----
  // lane 11
  wire        c11_carry = P11[9];
  wire [3:0]  c11_frac4 = c11_carry ? P11[8:5] : P11[7:4];
  wire signed [6:0] c11_es  = e11_s3 + (c11_carry ? 7'sd1 : 7'sd0);
  wire        c11_ovf  = (c11_es < 7'sd0) || (c11_es > 7'sd14);
  wire [8:0]  prod11_fin = c11_ovf ? {s11_s3, 4'hF, 4'h0} : {s11_s3, c11_es[3:0], c11_frac4};

  // lane 12
  wire        c12_carry = P12[9];
  wire [3:0]  c12_frac4 = c12_carry ? P12[8:5] : P12[7:4];
  wire signed [6:0] c12_es  = e12_s3 + (c12_carry ? 7'sd1 : 7'sd0);
  wire        c12_ovf  = (c12_es < 7'sd0) || (c12_es > 7'sd14);
  wire [8:0]  prod12_fin = c12_ovf ? {s12_s3, 4'hF, 4'h0} : {s12_s3, c12_es[3:0], c12_frac4};

  // lane 21
  wire        c21_carry = P21[9];
  wire [3:0]  c21_frac4 = c21_carry ? P21[8:5] : P21[7:4];
  wire signed [6:0] c21_es  = e21_s3 + (c21_carry ? 7'sd1 : 7'sd0);
  wire        c21_ovf  = (c21_es < 7'sd0) || (c21_es > 7'sd14);
  wire [8:0]  prod21_fin = c21_ovf ? {s21_s3, 4'hF, 4'h0} : {s21_s3, c21_es[3:0], c21_frac4};

  // lane 22
  wire        c22_carry = P22[9];
  wire [3:0]  c22_frac4 = c22_carry ? P22[8:5] : P22[7:4];
  wire signed [6:0] c22_es  = e22_s3 + (c22_carry ? 7'sd1 : 7'sd0);
  wire        c22_ovf  = (c22_es < 7'sd0) || (c22_es > 7'sd14);
  wire [8:0]  prod22_fin = c22_ovf ? {s22_s3, 4'hF, 4'h0} : {s22_s3, c22_es[3:0], c22_frac4};

  // final per-lane product (specials dominate)
  wire [8:0] prod11_w = nan_11 ? QNAN9 : inf_11 ? {s11_s3, 4'hF, 4'h0} : (zer_11 ? {s11_s3, 8'h00} : prod11_fin);
  wire [8:0] prod12_w = nan_12 ? QNAN9 : inf_12 ? {s12_s3, 4'hF, 4'h0} : (zer_12 ? {s12_s3, 8'h00} : prod12_fin);
  wire [8:0] prod21_w = nan_21 ? QNAN9 : inf_21 ? {s21_s3, 4'hF, 4'h0} : (zer_21 ? {s21_s3, 8'h00} : prod21_fin);
  wire [8:0] prod22_w = nan_22 ? QNAN9 : inf_22 ? {s22_s3, 4'hF, 4'h0} : (zer_22 ? {s22_s3, 8'h00} : prod22_fin);

  // ---- Per-lane adders (fp9_add has 1 internal reg stage) ----
  wire [8:0] sum11, sum12, sum21, sum22;

  fp9_add u_add11 (.clk(clk), .a9(prod11_w), .b9(c11_s3), .c9(sum11));
  fp9_add u_add12 (.clk(clk), .a9(prod12_w), .b9(c12_s3), .c9(sum12));
  fp9_add u_add21 (.clk(clk), .a9(prod21_w), .b9(c21_s3), .c9(sum21));
  fp9_add u_add22 (.clk(clk), .a9(prod22_w), .b9(c22_s3), .c9(sum22));

  // ---- Final register (S4) ----
  always @(posedge clk) begin
    result <= {sum22, sum21, sum12, sum11};
  end

endmodule