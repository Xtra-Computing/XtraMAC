`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// fp8e5m2_mac — 2×A lanes × 2×B lanes => 4 lane products per DSP (1|2|2)
//   FP8 (E5M2): [7]=sign, [6:2]=exp(5), [1:0]=frac(2), bias=15
//   S1: unpack/classify, signed exponent sums, pack A/B mantissas (2×2 lanes)
//   DSP: 1-cycle 27×18 -> 45b product => 4×(6-bit) windows (no overlap)
//   S2: capture product
//   S3: align product with meta & C; per-lane finite/special select
//   S4: per-lane add (fp8e5m2_add) and final register
//   Output: {y22, y21, y12, y11} packed as 4×FP8 = 32 bits
//   Total latency (II=1): 4 cycles
// ==========================================================================
module fp8e5m2_mac (
    input  wire        clk,
    input  wire [31:0] a18,     // USE a18[15:0]: {a2[15:8], a1[7:0]} two FP8 lanes (upper bits ignored)
    input  wire [15:0] b18,     // {b2[15:8], b1[7:0]}  two FP8 lanes
    input  wire [31:0] c36,     // {c22[31:24], c21[23:16], c12[15:8], c11[7:0]}
    output reg  [31:0] result   // {y22, y21, y12, y11}
);
  // ---- FP8 E5M2 constants ----
  localparam integer EWIDTH = 5;
  localparam integer FWIDTH = 2;
  localparam integer MBITS  = 1 + FWIDTH;  // 3
  localparam integer BIAS   = 15;
  localparam integer WPROD  = 2*MBITS;     // 6-bit mantissa product per lane

  // qNaN exemplar & special values
  localparam [7:0] QNAN8  = 8'h7D;         // exp=11111, frac=01 (sign doesn't matter)
  localparam [7:0] PINF8  = 8'h7C;         // +Inf  (exp=11111, frac=00, s=0)
  localparam [7:0] NINF8  = 8'hFC;         // -Inf  (exp=11111, frac=00, s=1)
  localparam [7:0] PZERO8 = 8'h00;         // +0
  localparam [7:0] NZERO8 = 8'h80;         // -0

  // ---- S1: unpack A/B lanes (use only a18[15:0]) ----
  wire [7:0] a1 = a18[ 7: 0];
  wire [7:0] a2 = a18[15: 8];
  wire [7:0] b1 = b18[ 7: 0];
  wire [7:0] b2 = b18[15: 8];

  // fields
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

  // signs and signed exponent sums (finite path)
  wire        s11 = sa1 ^ sb1;
  wire        s12 = sa1 ^ sb2;
  wire        s21 = sa2 ^ sb1;
  wire        s22 = sa2 ^ sb2;

  // generous signed width
  wire signed [7:0] e11_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb1}) - $signed(8'd15);
  wire signed [7:0] e12_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb2}) - $signed(8'd15);
  wire signed [7:0] e21_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb1}) - $signed(8'd15);
  wire signed [7:0] e22_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb2}) - $signed(8'd15);

  // ---- S1: pack mantissas into DSP A/B (2×2 lanes)
  reg  [26:0] A_pack;
  reg  [17:0] B_pack;

  wire [MBITS-1:0] Ma1 = a1_zero ? 3'd0 : {1'b1, fa1}; // 1+2
  wire [MBITS-1:0] Ma2 = a2_zero ? 3'd0 : {1'b1, fa2};
  wire [MBITS-1:0] Mb1 = b1_zero ? 3'd0 : {1'b1, fb1};
  wire [MBITS-1:0] Mb2 = b2_zero ? 3'd0 : {1'b1, fb2};

  // C lanes (c11,c12,c21,c22)
  wire [7:0] c11 = c36[ 7: 0];
  wire [7:0] c12 = c36[15: 8];
  wire [7:0] c21 = c36[23:16];
  wire [7:0] c22 = c36[31:24];

  // Meta registers S1->S2
  reg        s11_s2, s12_s2, s21_s2, s22_s2;
  reg signed [7:0] e11_s2, e12_s2, e21_s2, e22_s2;

  reg a1_nan_s2, a2_nan_s2, b1_nan_s2, b2_nan_s2;
  reg a1_inf_s2, a2_inf_s2, b1_inf_s2, b2_inf_s2;
  reg a1_zero_s2,a2_zero_s2,b1_zero_s2,b2_zero_s2;

  reg [7:0] c11_s2, c12_s2, c21_s2, c22_s2;

  // S1: pack + meta latch
  always @(posedge clk) begin
    // A_pack: Ma1 @ [2:0], Ma2 @ [14:12]  -> SA=12 (gap 9)
    A_pack <= { 12'b0, Ma2, 9'b0, Ma1 };
    // B_pack: Mb1 @ [2:0], Mb2 @ [8:6]    -> SB=6  (gap 3)
    B_pack <= { 9'b0, Mb2, 3'b0, Mb1 };

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
  dsp_usage u_dsp8 (
    .clk    (clk),
    .a      (A_pack),   // 27b
    .b      (B_pack),   // 18b
    .product(product45)
  );

  // ---- S2: capture windows ----
  reg [23:0] dsp_p;  // we only need 4×6 = 24 low bits
  always @(posedge clk) begin
    dsp_p <= product45[23:0];
  end

  // ---- NEW: S3 meta/C alignment (to match dsp_p timing) ----
  reg        s11_s3, s12_s3, s21_s3, s22_s3;
  reg signed [7:0] e11_s3, e12_s3, e21_s3, e22_s3;

  reg a1_nan_s3, a2_nan_s3, b1_nan_s3, b2_nan_s3;
  reg a1_inf_s3, a2_inf_s3, b1_inf_s3, b2_inf_s3;
  reg a1_zero_s3,a2_zero_s3,b1_zero_s3,b2_zero_s3;

  reg [7:0] c11_s3, c12_s3, c21_s3, c22_s3;

  always @(posedge clk) begin
    s11_s3 <= s11_s2; s12_s3 <= s12_s2; s21_s3 <= s21_s2; s22_s3 <= s22_s2;
    e11_s3 <= e11_s2; e12_s3 <= e12_s2; e21_s3 <= e21_s2; e22_s3 <= e22_s2;

    a1_nan_s3  <= a1_nan_s2;  a2_nan_s3  <= a2_nan_s2;  b1_nan_s3  <= b1_nan_s2;  b2_nan_s3  <= b2_nan_s2;
    a1_inf_s3  <= a1_inf_s2;  a2_inf_s3  <= a2_inf_s2;  b1_inf_s3  <= b1_inf_s2;  b2_inf_s3  <= b2_inf_s2;
    a1_zero_s3 <= a1_zero_s2; a2_zero_s3 <= a2_zero_s2; b1_zero_s3 <= b1_zero_s2; b2_zero_s3 <= b2_zero_s2;

    c11_s3 <= c11_s2; c12_s3 <= c12_s2; c21_s3 <= c21_s2; c22_s3 <= c22_s2;
  end

  // ---- Product windows (6b each): a1*b1, a1*b2, a2*b1, a2*b2 ----
  wire [5:0] P11 = dsp_p[ 5: 0];   // 0
  wire [5:0] P12 = dsp_p[11: 6];   // 6
  wire [5:0] P21 = dsp_p[17:12];   // 12
  wire [5:0] P22 = dsp_p[23:18];   // 18

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
  // carry, fraction, exponent bump, overflow check (es < 0 || es > 30)

  // lane 11
  wire        c11_carry = P11[5];
  wire [1:0]  c11_frac2 = c11_carry ? P11[4:3] : P11[3:2];
  wire signed [7:0] c11_es  = e11_s3 + (c11_carry ? 8'sd1 : 8'sd0);
  wire        c11_ovf  = (c11_es < 8'sd0) || (c11_es > 8'sd30);
  wire [7:0]  prod11_fin = c11_ovf ? {s11_s3, 5'h1F, 2'b00} : {s11_s3, c11_es[4:0], c11_frac2};

  // lane 12
  wire        c12_carry = P12[5];
  wire [1:0]  c12_frac2 = c12_carry ? P12[4:3] : P12[3:2];
  wire signed [7:0] c12_es  = e12_s3 + (c12_carry ? 8'sd1 : 8'sd0);
  wire        c12_ovf  = (c12_es < 8'sd0) || (c12_es > 8'sd30);
  wire [7:0]  prod12_fin = c12_ovf ? {s12_s3, 5'h1F, 2'b00} : {s12_s3, c12_es[4:0], c12_frac2};

  // lane 21
  wire        c21_carry = P21[5];
  wire [1:0]  c21_frac2 = c21_carry ? P21[4:3] : P21[3:2];
  wire signed [7:0] c21_es  = e21_s3 + (c21_carry ? 8'sd1 : 8'sd0);
  wire        c21_ovf  = (c21_es < 8'sd0) || (c21_es > 8'sd30);
  wire [7:0]  prod21_fin = c21_ovf ? {s21_s3, 5'h1F, 2'b00} : {s21_s3, c21_es[4:0], c21_frac2};

  // lane 22
  wire        c22_carry = P22[5];
  wire [1:0]  c22_frac2 = c22_carry ? P22[4:3] : P22[3:2];
  wire signed [7:0] c22_es  = e22_s3 + (c22_carry ? 8'sd1 : 8'sd0);
  wire        c22_ovf  = (c22_es < 8'sd0) || (c22_es > 8'sd30);
  wire [7:0]  prod22_fin = c22_ovf ? {s22_s3, 5'h1F, 2'b00} : {s22_s3, c22_es[4:0], c22_frac2};

  // final per-lane product (specials dominate; zero keeps XOR sign)
  wire [7:0] prod11_w = nan_11 ? QNAN8 : inf_11 ? {s11_s3, 5'h1F, 2'b00} : (zer_11 ? {s11_s3, 7'b0, 1'b0} : prod11_fin);
  wire [7:0] prod12_w = nan_12 ? QNAN8 : inf_12 ? {s12_s3, 5'h1F, 2'b00} : (zer_12 ? {s12_s3, 7'b0, 1'b0} : prod12_fin);
  wire [7:0] prod21_w = nan_21 ? QNAN8 : inf_21 ? {s21_s3, 5'h1F, 2'b00} : (zer_21 ? {s21_s3, 7'b0, 1'b0} : prod21_fin);
  wire [7:0] prod22_w = nan_22 ? QNAN8 : inf_22 ? {s22_s3, 5'h1F, 2'b00} : (zer_22 ? {s22_s3, 7'b0, 1'b0} : prod22_fin);

  // ---- Per-lane adders (one internal reg stage each) ----
  wire [7:0] sum11, sum12, sum21, sum22;

  fp8e5m2_add u_add11 (.clk(clk), .a8(prod11_w), .b8(c11_s3), .c8(sum11));
  fp8e5m2_add u_add12 (.clk(clk), .a8(prod12_w), .b8(c12_s3), .c8(sum12));
  fp8e5m2_add u_add21 (.clk(clk), .a8(prod21_w), .b8(c21_s3), .c8(sum21));
  fp8e5m2_add u_add22 (.clk(clk), .a8(prod22_w), .b8(c22_s3), .c8(sum22));

  // ---- Final register (S4) ----
  always @(posedge clk) begin
    result <= {sum22, sum21, sum12, sum11};
  end

endmodule