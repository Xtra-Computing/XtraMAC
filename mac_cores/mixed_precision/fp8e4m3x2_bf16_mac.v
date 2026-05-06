`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// fp8e4m3x2_bf16_mac : 4-lane FP8(E4M3) x FP8(E4M3) -> BF16 accumulation
//
//   Principle: DSP lane-packing count is determined by A*B mantissa widths
//              only, NOT by the accumulator format. FP8(E4M3) has a 4-bit
//              mantissa (1 hidden + 3 explicit), so 2 A-lanes x 2 B-lanes
//              pack into a single DSP48E2 27x18 multiply, yielding 4
//              independent 8-bit product windows. The BF16 accumulator
//              only decides which adder to use after widening.
//
//   Inputs:
//     a16[15:0] = {a2[15:8], a1[7:0]}        -- 2 FP8 A-operands
//     b16[15:0] = {b2[15:8], b1[7:0]}        -- 2 FP8 B-operands
//     c64[63:0] = {c22, c21, c12, c11}       -- 4 BF16 addends (16b each)
//   Output:
//     result[63:0] = {y22, y21, y12, y11}    -- 4 BF16 results
//
//   Per-lane computation (cross-products, 4 independent):
//     y_ij = (a_i * b_j) + c_ij  for i,j in {1,2}
//
//   FP8(E4M3): sign[7], exp[6:3] (4b, bias=7), frac[2:0] (3b).
//              exp==0xF is NaN (no Inf in E4M3); exp==0 is FTZ zero.
//
//   Pipeline:
//     S1: unpack 4 FP8 inputs, classify (NaN/zero), compute signed exp
//         sums, pack mantissas into DSP A[26:0]/B[17:0]; register c_ij
//     DSP: combinational 27x18 -> 45b product
//     S2: capture 4 x 8-bit product windows + register meta/c_ij
//     MID_STAGES optional mid-pipeline registers (widened product & c)
//     ADD_LAT: 4 x bf16_add(widened_prod, c_ij)
//     Output is combinational concat of adder outputs -- no extra reg.
//
//   Total latency = 2 (mul) + MID_STAGES + ADD_LAT  (EXACT)
//
//   DSP packing (4 non-overlapping 8-bit product windows):
//     A[26:0] = {7'b0, Ma2, 12'b0, Ma1}
//     B[17:0] = {6'b0, Mb2,  4'b0, Mb1}
//     Product windows: P11@[7:0], P12@[15:8], P21@[23:16], P22@[31:24]
// ==========================================================================
module fp8e4m3x2_bf16_mac #(
    parameter integer MUL_LAT    = 2,   // mul pipeline stages (min 2 for 4-lane)
    parameter integer MID_STAGES = 0,   // extra latency between widen and add
    parameter integer ADD_LAT    = 3    // forwarded to bf16_add LATENCY (2|3)
) (
    input  wire        clk,
    input  wire [15:0] a16,      // {a2, a1} two FP8(E4M3) A-lanes
    input  wire [15:0] b16,      // {b2, b1} two FP8(E4M3) B-lanes
    input  wire [63:0] c64,      // {c22, c21, c12, c11} four BF16 addends
    output wire [63:0] result    // {y22, y21, y12, y11} four BF16 results
);
  // ---- FP8 E4M3 constants ----
  localparam integer EWIDTH = 4;
  localparam integer FWIDTH = 3;
  localparam integer MBITS  = 1 + FWIDTH; // 4
  localparam integer BIAS   = 7;

  // ---- BF16 special constants ----
  localparam [15:0] BF16_QNAN       = 16'h7FC0;
  localparam [15:0] BF16_MAXFIN_POS = 16'h7F7F;   // {0, 8'hFE, 7'h7F}
  localparam [15:0] BF16_MAXFIN_NEG = 16'hFF7F;   // {1, 8'hFE, 7'h7F}

  // ---- Unpack ----
  wire [7:0] a1 = a16[ 7:0], a2 = a16[15:8];
  wire [7:0] b1 = b16[ 7:0], b2 = b16[15:8];

  wire sa1 = a1[7], sa2 = a2[7];
  wire sb1 = b1[7], sb2 = b2[7];
  wire [EWIDTH-1:0] ea1 = a1[6:3], ea2 = a2[6:3], eb1 = b1[6:3], eb2 = b2[6:3];
  wire [FWIDTH-1:0] fa1 = a1[2:0], fa2 = a2[2:0], fb1 = b1[2:0], fb2 = b2[2:0];

  // ---- Classify (FTZ for exp==0, NaN for exp==0xF; no Inf in E4M3) ----
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

  // ---- Signed exponent sums (unbiased; 7-bit signed is plenty) ----
  wire signed [6:0] e11_s1 = $signed({3'd0, ea1}) + $signed({3'd0, eb1}) - $signed(7'd7);
  wire signed [6:0] e12_s1 = $signed({3'd0, ea1}) + $signed({3'd0, eb2}) - $signed(7'd7);
  wire signed [6:0] e21_s1 = $signed({3'd0, ea2}) + $signed({3'd0, eb1}) - $signed(7'd7);
  wire signed [6:0] e22_s1 = $signed({3'd0, ea2}) + $signed({3'd0, eb2}) - $signed(7'd7);

  // ---- Mantissas (hidden bit prepended, FTZ => 0) ----
  wire [MBITS-1:0] Ma1 = a1_zero ? 4'd0 : {1'b1, fa1};
  wire [MBITS-1:0] Ma2 = a2_zero ? 4'd0 : {1'b1, fa2};
  wire [MBITS-1:0] Mb1 = b1_zero ? 4'd0 : {1'b1, fb1};
  wire [MBITS-1:0] Mb2 = b2_zero ? 4'd0 : {1'b1, fb2};

  // ---- C lanes ----
  wire [15:0] c11 = c64[15: 0];
  wire [15:0] c12 = c64[31:16];
  wire [15:0] c21 = c64[47:32];
  wire [15:0] c22 = c64[63:48];

  // ============================================================
  //  S1: Register pack + meta + c
  // ============================================================
  reg [26:0] A_pack;
  reg [17:0] B_pack;

  reg        s11_s2, s12_s2, s21_s2, s22_s2;
  reg signed [6:0] e11_s2, e12_s2, e21_s2, e22_s2;

  reg a1_nan_s2,  a2_nan_s2,  b1_nan_s2,  b2_nan_s2;
  reg a1_zero_s2, a2_zero_s2, b1_zero_s2, b2_zero_s2;

  reg [15:0] c11_s2, c12_s2, c21_s2, c22_s2;

  always @(posedge clk) begin
    A_pack <= {7'b0, Ma2, 12'b0, Ma1};
    B_pack <= {6'b0, Mb2,  4'b0, Mb1};

    s11_s2 <= s11; s12_s2 <= s12; s21_s2 <= s21; s22_s2 <= s22;
    e11_s2 <= e11_s1; e12_s2 <= e12_s1; e21_s2 <= e21_s1; e22_s2 <= e22_s1;

    a1_nan_s2  <= a1_nan;  a2_nan_s2  <= a2_nan;
    b1_nan_s2  <= b1_nan;  b2_nan_s2  <= b2_nan;
    a1_zero_s2 <= a1_zero; a2_zero_s2 <= a2_zero;
    b1_zero_s2 <= b1_zero; b2_zero_s2 <= b2_zero;

    c11_s2 <= c11; c12_s2 <= c12; c21_s2 <= c21; c22_s2 <= c22;
  end

  // ============================================================
  //  DSP (combinational: 27x18 signed-unsigned multiply)
  // ============================================================
  wire [44:0] product45;
  (* use_dsp = "yes" *)
  dsp_usage u_dsp (
    .clk     (clk),
    .a       (A_pack),
    .b       (B_pack),
    .product (product45)
  );

  // ============================================================
  //  S2: Capture product windows + align meta/c
  // ============================================================
  reg [31:0] dsp_p;

  reg        s11_s3, s12_s3, s21_s3, s22_s3;
  reg signed [6:0] e11_s3, e12_s3, e21_s3, e22_s3;
  reg a1_nan_s3,  a2_nan_s3,  b1_nan_s3,  b2_nan_s3;
  reg a1_zero_s3, a2_zero_s3, b1_zero_s3, b2_zero_s3;
  reg [15:0] c11_s3, c12_s3, c21_s3, c22_s3;

  always @(posedge clk) begin
    dsp_p <= product45[31:0];

    s11_s3 <= s11_s2; s12_s3 <= s12_s2; s21_s3 <= s21_s2; s22_s3 <= s22_s2;
    e11_s3 <= e11_s2; e12_s3 <= e12_s2; e21_s3 <= e21_s2; e22_s3 <= e22_s2;

    a1_nan_s3  <= a1_nan_s2;  a2_nan_s3  <= a2_nan_s2;
    b1_nan_s3  <= b1_nan_s2;  b2_nan_s3  <= b2_nan_s2;
    a1_zero_s3 <= a1_zero_s2; a2_zero_s3 <= a2_zero_s2;
    b1_zero_s3 <= b1_zero_s2; b2_zero_s3 <= b2_zero_s2;

    c11_s3 <= c11_s2; c12_s3 <= c12_s2; c21_s3 <= c21_s2; c22_s3 <= c22_s2;
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

  // ============================================================
  //  Widen FP8(E4M3) product -> BF16
  //    Normalize by carry bit, rebias to BF16 (bias=127), pad frac
  //    from 3b (E4M3) to 7b (BF16). No Inf => saturate to MAXFIN.
  // ============================================================
  function automatic [15:0] widen_e4m3_to_bf16;
    input              sign_in;
    input signed [6:0] exp_unb;
    input       [7:0]  prod8;
    input              is_nan;
    input              is_zero;
    reg                carry;
    reg  signed [8:0]  es;        // widened exp_unb + carry
    reg                ovf_hi, ovf_lo;
    reg  signed [8:0]  bf16_be;   // BF16 biased exp (signed for range check)
    reg  [6:0]         frac7;
    begin
      if (is_nan)
        widen_e4m3_to_bf16 = BF16_QNAN;
      else if (is_zero)
        widen_e4m3_to_bf16 = {sign_in, 15'd0};
      else begin
        carry   = prod8[7];
        // es = (ea1+eb1-7) + carry; BF16 biased = es + 120 (= +127-7).
        // Equivalently BF16 biased = (ea1+eb1) + 113 + carry.
        es      = $signed({{2{exp_unb[6]}}, exp_unb})
                + (carry ? 9'sd1 : 9'sd0);
        bf16_be = es + 9'sd120;
        // With E4M3 operand range, bf16_be in [115, 142] (carry-dependent),
        // so neither branch ever actually fires, but guard defensively.
        ovf_hi  = (bf16_be > 9'sd254);
        ovf_lo  = (bf16_be < 9'sd1);
        if (ovf_hi)
          widen_e4m3_to_bf16 = sign_in ? BF16_MAXFIN_NEG : BF16_MAXFIN_POS;
        else if (ovf_lo)
          widen_e4m3_to_bf16 = {sign_in, 15'd0};
        else begin
          // carry=1: normalized product = 1.P[6:0] * 2^(exp_unb+1)
          //          frac7 = P[6:0]  (all 7 bits fit exactly)
          // carry=0: normalized product = 1.P[5:0]0 * 2^(exp_unb)
          //          frac7 = {P[5:0], 1'b0}
          frac7 = carry ? prod8[6:0] : {prod8[5:0], 1'b0};
          widen_e4m3_to_bf16 = {sign_in, bf16_be[7:0], frac7};
        end
      end
    end
  endfunction

  wire [15:0] prod11_bf16_w = widen_e4m3_to_bf16(s11_s3, e11_s3, P11, nan_11, zer_11);
  wire [15:0] prod12_bf16_w = widen_e4m3_to_bf16(s12_s3, e12_s3, P12, nan_12, zer_12);
  wire [15:0] prod21_bf16_w = widen_e4m3_to_bf16(s21_s3, e21_s3, P21, nan_21, zer_21);
  wire [15:0] prod22_bf16_w = widen_e4m3_to_bf16(s22_s3, e22_s3, P22, nan_22, zer_22);

  // ============================================================
  //  Mid pipeline (optional): register widened products + c
  // ============================================================
  reg [15:0] p11_m [0:MID_STAGES];
  reg [15:0] p12_m [0:MID_STAGES];
  reg [15:0] p21_m [0:MID_STAGES];
  reg [15:0] p22_m [0:MID_STAGES];
  reg [15:0] c11_m [0:MID_STAGES];
  reg [15:0] c12_m [0:MID_STAGES];
  reg [15:0] c21_m [0:MID_STAGES];
  reg [15:0] c22_m [0:MID_STAGES];

  always @(*) begin
    p11_m[0] = prod11_bf16_w; p12_m[0] = prod12_bf16_w;
    p21_m[0] = prod21_bf16_w; p22_m[0] = prod22_bf16_w;
    c11_m[0] = c11_s3; c12_m[0] = c12_s3;
    c21_m[0] = c21_s3; c22_m[0] = c22_s3;
  end

  generate
    genvar gm;
    for (gm = 1; gm <= MID_STAGES; gm = gm + 1) begin : gen_mid
      always @(posedge clk) begin
        p11_m[gm] <= p11_m[gm-1]; p12_m[gm] <= p12_m[gm-1];
        p21_m[gm] <= p21_m[gm-1]; p22_m[gm] <= p22_m[gm-1];
        c11_m[gm] <= c11_m[gm-1]; c12_m[gm] <= c12_m[gm-1];
        c21_m[gm] <= c21_m[gm-1]; c22_m[gm] <= c22_m[gm-1];
      end
    end
  endgenerate

  // ============================================================
  //  Four BF16 adders: y_ij = widened_prod_ij + c_ij
  // ============================================================
  wire [15:0] sum11_w, sum12_w, sum21_w, sum22_w;

  bf16_add #(.LATENCY(ADD_LAT)) u_add11 (
    .clk(clk), .a16(p11_m[MID_STAGES]), .b16(c11_m[MID_STAGES]), .c16(sum11_w));
  bf16_add #(.LATENCY(ADD_LAT)) u_add12 (
    .clk(clk), .a16(p12_m[MID_STAGES]), .b16(c12_m[MID_STAGES]), .c16(sum12_w));
  bf16_add #(.LATENCY(ADD_LAT)) u_add21 (
    .clk(clk), .a16(p21_m[MID_STAGES]), .b16(c21_m[MID_STAGES]), .c16(sum21_w));
  bf16_add #(.LATENCY(ADD_LAT)) u_add22 (
    .clk(clk), .a16(p22_m[MID_STAGES]), .b16(c22_m[MID_STAGES]), .c16(sum22_w));

  // ============================================================
  //  Final output (combinational concat; no extra register)
  // ============================================================
  assign result = {sum22_w, sum21_w, sum12_w, sum11_w};

endmodule

`default_nettype wire
