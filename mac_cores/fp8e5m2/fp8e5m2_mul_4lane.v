`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// fp8e5m2_mul_4lane -- 4-lane DSP-packed FP8(E5M2) multiplier
//   2 A-lanes x 2 B-lanes = 4 product lanes via a single DSP48E2 27x18.
//   FP8(E5M2): sign[7], exp[6:2] (5-bit, bias=15), frac[1:0] (2-bit)
//   Mantissa = 1+2 = 3 bits.  Product per lane = 6 bits.
//   HAS Infinity (exp=0x1F, frac=0) and NaN (exp=0x1F, frac!=0).
//
//   DSP packing (same as fp8e5m2_mac.v):
//     A_pack: Ma1 @ [2:0],  Ma2 @ [14:12]   (SA=12, gap=9)
//     B_pack: Mb1 @ [2:0],  Mb2 @ [8:6]     (SB=6,  gap=3)
//     Product windows (6b each): P11@[5:0], P12@[11:6],
//                                P21@[17:12], P22@[23:18]
//
//   Pipeline stages (controlled by LATENCY parameter):
//     LATENCY=2 (default):
//       S1 : unpack, classify, exponent sums, DSP A/B packing (registered)
//       DSP: combinational 27x18 multiply (dsp_usage, 0 internal regs)
//       S2 : capture DSP product + align meta (registered)
//       Normalize per-lane products + special-case select (combinational)
//     Total = 2 registered stages = EXACTLY 2 cycles latency.
//
//   Outputs (active after 2 clk edges):
//     prod[31:0]  = {prod22, prod21, prod12, prod11} -- 4 FP8 products
//     c_out[31:0] = {c22, c21, c12, c11} -- C operand aligned to products
// ======================================================================
module fp8e5m2_mul_4lane #(
    parameter integer LATENCY = 2    // fixed at 2 for DSP packing path
) (
    input  wire        clk,
    input  wire [15:0] a16,    // {a2[15:8], a1[7:0]}  two FP8 E5M2 lanes
    input  wire [15:0] b16,    // {b2[15:8], b1[7:0]}  two FP8 E5M2 lanes
    input  wire [31:0] c_in,   // {c22, c21, c12, c11} four FP8 E5M2 addends
    output wire [31:0] prod,   // {prod22, prod21, prod12, prod11}
    output wire [31:0] c_out   // C aligned to prod timing
);

  // ---- FP8 E5M2 constants ----
  localparam integer EWIDTH = 5;
  localparam integer FWIDTH = 2;
  localparam integer MBITS  = 1 + FWIDTH; // 3
  localparam integer BIAS   = 15;

  localparam [7:0] QNAN8  = 8'h7D;  // exp=11111, frac=01

  // ---- S1: unpack A/B lanes ----
  wire [7:0] a1 = a16[ 7: 0];
  wire [7:0] a2 = a16[15: 8];
  wire [7:0] b1 = b16[ 7: 0];
  wire [7:0] b2 = b16[15: 8];

  // fields
  wire sa1 = a1[7], sa2 = a2[7];
  wire sb1 = b1[7], sb2 = b2[7];
  wire [EWIDTH-1:0] ea1 = a1[6:2], ea2 = a2[6:2], eb1 = b1[6:2], eb2 = b2[6:2];
  wire [FWIDTH-1:0] fa1 = a1[1:0], fa2 = a2[1:0], fb1 = b1[1:0], fb2 = b2[1:0];

  // classify
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

  // signs
  wire s11 = sa1 ^ sb1;
  wire s12 = sa1 ^ sb2;
  wire s21 = sa2 ^ sb1;
  wire s22 = sa2 ^ sb2;

  // signed exponent sums
  wire signed [7:0] e11_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb1}) - $signed(8'd15);
  wire signed [7:0] e12_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb2}) - $signed(8'd15);
  wire signed [7:0] e21_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb1}) - $signed(8'd15);
  wire signed [7:0] e22_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb2}) - $signed(8'd15);

  // mantissas (FTZ: exp==0 => mant=0)
  wire [MBITS-1:0] Ma1 = a1_zero ? 3'd0 : {1'b1, fa1};
  wire [MBITS-1:0] Ma2 = a2_zero ? 3'd0 : {1'b1, fa2};
  wire [MBITS-1:0] Mb1 = b1_zero ? 3'd0 : {1'b1, fb1};
  wire [MBITS-1:0] Mb2 = b2_zero ? 3'd0 : {1'b1, fb2};

  // C lanes
  wire [7:0] c11 = c_in[ 7: 0];
  wire [7:0] c12 = c_in[15: 8];
  wire [7:0] c21 = c_in[23:16];
  wire [7:0] c22 = c_in[31:24];

  // ---- S1 registers ----
  reg [26:0] A_pack;
  reg [17:0] B_pack;

  reg        s11_s2, s12_s2, s21_s2, s22_s2;
  reg signed [7:0] e11_s2, e12_s2, e21_s2, e22_s2;

  reg a1_nan_s2, a2_nan_s2, b1_nan_s2, b2_nan_s2;
  reg a1_inf_s2, a2_inf_s2, b1_inf_s2, b2_inf_s2;
  reg a1_zero_s2,a2_zero_s2,b1_zero_s2,b2_zero_s2;

  reg [7:0] c11_s2, c12_s2, c21_s2, c22_s2;

  always @(posedge clk) begin
    // A_pack: Ma1 @ [2:0], Ma2 @ [14:12]  (gap 9)
    A_pack <= { 12'b0, Ma2, 9'b0, Ma1 };
    // B_pack: Mb1 @ [2:0], Mb2 @ [8:6]    (gap 3)
    B_pack <= { 9'b0, Mb2, 3'b0, Mb1 };

    s11_s2 <= s11; s12_s2 <= s12; s21_s2 <= s21; s22_s2 <= s22;
    e11_s2 <= e11_s1; e12_s2 <= e12_s1; e21_s2 <= e21_s1; e22_s2 <= e22_s1;

    a1_nan_s2  <= a1_nan;  a2_nan_s2  <= a2_nan;  b1_nan_s2  <= b1_nan;  b2_nan_s2  <= b2_nan;
    a1_inf_s2  <= a1_inf;  a2_inf_s2  <= a2_inf;  b1_inf_s2  <= b1_inf;  b2_inf_s2  <= b2_inf;
    a1_zero_s2 <= a1_zero; a2_zero_s2 <= a2_zero; b1_zero_s2 <= b1_zero; b2_zero_s2 <= b2_zero;

    c11_s2 <= c11; c12_s2 <= c12; c21_s2 <= c21; c22_s2 <= c22;
  end

  // ---- DSP (combinational) ----
  wire [44:0] product45;
  dsp_usage u_dsp (
    .clk    (clk),
    .a      (A_pack),
    .b      (B_pack),
    .product(product45)
  );

  // ---- S2: capture DSP product + propagate meta/C one more cycle to align ----
  reg [23:0] dsp_p;

  reg        s11_s3, s12_s3, s21_s3, s22_s3;
  reg signed [7:0] e11_s3, e12_s3, e21_s3, e22_s3;

  reg a1_nan_s3, a2_nan_s3, b1_nan_s3, b2_nan_s3;
  reg a1_inf_s3, a2_inf_s3, b1_inf_s3, b2_inf_s3;
  reg a1_zero_s3,a2_zero_s3,b1_zero_s3,b2_zero_s3;

  reg [7:0] c11_s3, c12_s3, c21_s3, c22_s3;

  always @(posedge clk) begin
    dsp_p <= product45[23:0];

    s11_s3 <= s11_s2; s12_s3 <= s12_s2; s21_s3 <= s21_s2; s22_s3 <= s22_s2;
    e11_s3 <= e11_s2; e12_s3 <= e12_s2; e21_s3 <= e21_s2; e22_s3 <= e22_s2;

    a1_nan_s3  <= a1_nan_s2;  a2_nan_s3  <= a2_nan_s2;  b1_nan_s3  <= b1_nan_s2;  b2_nan_s3  <= b2_nan_s2;
    a1_inf_s3  <= a1_inf_s2;  a2_inf_s3  <= a2_inf_s2;  b1_inf_s3  <= b1_inf_s2;  b2_inf_s3  <= b2_inf_s2;
    a1_zero_s3 <= a1_zero_s2; a2_zero_s3 <= a2_zero_s2; b1_zero_s3 <= b1_zero_s2; b2_zero_s3 <= b2_zero_s2;

    c11_s3 <= c11_s2; c12_s3 <= c12_s2; c21_s3 <= c21_s2; c22_s3 <= c22_s2;
  end

  // ---- Product windows (6b each) ----
  wire [5:0] P11 = dsp_p[ 5: 0];
  wire [5:0] P12 = dsp_p[11: 6];
  wire [5:0] P21 = dsp_p[17:12];
  wire [5:0] P22 = dsp_p[23:18];

  // ---- Per-lane specials (use _s3 meta regs aligned with dsp_p) ----
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
  wire        p11_carry = P11[5];
  wire [1:0]  p11_frac2 = p11_carry ? P11[4:3] : P11[3:2];
  wire signed [7:0] p11_es = e11_s3 + (p11_carry ? 8'sd1 : 8'sd0);
  wire        p11_ovf  = (p11_es < 8'sd0) || (p11_es > 8'sd30);
  wire [7:0]  prod11_fin = p11_ovf ? {s11_s3, 5'h1F, 2'b00}
                                   : {s11_s3, p11_es[4:0], p11_frac2};

  // lane 12
  wire        p12_carry = P12[5];
  wire [1:0]  p12_frac2 = p12_carry ? P12[4:3] : P12[3:2];
  wire signed [7:0] p12_es = e12_s3 + (p12_carry ? 8'sd1 : 8'sd0);
  wire        p12_ovf  = (p12_es < 8'sd0) || (p12_es > 8'sd30);
  wire [7:0]  prod12_fin = p12_ovf ? {s12_s3, 5'h1F, 2'b00}
                                   : {s12_s3, p12_es[4:0], p12_frac2};

  // lane 21
  wire        p21_carry = P21[5];
  wire [1:0]  p21_frac2 = p21_carry ? P21[4:3] : P21[3:2];
  wire signed [7:0] p21_es = e21_s3 + (p21_carry ? 8'sd1 : 8'sd0);
  wire        p21_ovf  = (p21_es < 8'sd0) || (p21_es > 8'sd30);
  wire [7:0]  prod21_fin = p21_ovf ? {s21_s3, 5'h1F, 2'b00}
                                   : {s21_s3, p21_es[4:0], p21_frac2};

  // lane 22
  wire        p22_carry = P22[5];
  wire [1:0]  p22_frac2 = p22_carry ? P22[4:3] : P22[3:2];
  wire signed [7:0] p22_es = e22_s3 + (p22_carry ? 8'sd1 : 8'sd0);
  wire        p22_ovf  = (p22_es < 8'sd0) || (p22_es > 8'sd30);
  wire [7:0]  prod22_fin = p22_ovf ? {s22_s3, 5'h1F, 2'b00}
                                   : {s22_s3, p22_es[4:0], p22_frac2};

  // final per-lane product selection (specials dominate)
  wire [7:0] prod11_w = nan_11 ? QNAN8 : inf_11 ? {s11_s3, 5'h1F, 2'b00}
                               : (zer_11 ? {s11_s3, 7'd0} : prod11_fin);
  wire [7:0] prod12_w = nan_12 ? QNAN8 : inf_12 ? {s12_s3, 5'h1F, 2'b00}
                               : (zer_12 ? {s12_s3, 7'd0} : prod12_fin);
  wire [7:0] prod21_w = nan_21 ? QNAN8 : inf_21 ? {s21_s3, 5'h1F, 2'b00}
                               : (zer_21 ? {s21_s3, 7'd0} : prod21_fin);
  wire [7:0] prod22_w = nan_22 ? QNAN8 : inf_22 ? {s22_s3, 5'h1F, 2'b00}
                               : (zer_22 ? {s22_s3, 7'd0} : prod22_fin);

  // ---- Output (combinational; 2-cycle total latency from inputs) ----
  assign prod  = {prod22_w, prod21_w, prod12_w, prod11_w};
  assign c_out = {c22_s3, c21_s3, c12_s3, c11_s3};

endmodule

`default_nettype wire
