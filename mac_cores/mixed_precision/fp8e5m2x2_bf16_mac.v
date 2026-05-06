`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// fp8e5m2x2_bf16_mac : 4-lane FP8(E5M2) x FP8(E5M2) -> BF16 accumulation
//
//   Principle: DSP lane-packing count is determined by A*B mantissa widths
//              only, NOT by the accumulator format. FP8(E5M2) has a 3-bit
//              mantissa (1 hidden + 2 explicit), so 2 A-lanes x 2 B-lanes
//              pack into a single DSP48E2 27x18 multiply, yielding 4
//              independent 6-bit product windows. The BF16 accumulator
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
//   FP8(E5M2): sign[7], exp[6:2] (5b, bias=15), frac[1:0] (2b).
//              exp==0x1F with frac==0 is Inf; with frac!=0 is NaN.
//              exp==0 is FTZ zero.
//
//   Pipeline:
//     S1: unpack 4 FP8 inputs, classify (NaN/Inf/zero), compute signed
//         exp sums, pack mantissas into DSP A[26:0]/B[17:0]; register c
//     DSP: combinational 27x18 -> 45b product
//     S2: capture 4 x 6-bit product windows + register meta/c
//     MID_STAGES optional mid-pipeline registers (widened product & c)
//     ADD_LAT: 4 x bf16_add(widened_prod, c_ij)
//     Output is combinational concat of adder outputs -- no extra reg.
//
//   Total latency = 2 (mul) + MID_STAGES + ADD_LAT  (EXACT)
//
//   DSP packing (4 non-overlapping 6-bit product windows):
//     A[26:0] = {12'b0, Ma2, 9'b0, Ma1}
//     B[17:0] = { 9'b0, Mb2, 3'b0, Mb1}
//     Product windows: P11@[5:0], P12@[11:6], P21@[17:12], P22@[23:18]
// ==========================================================================
module fp8e5m2x2_bf16_mac #(
    parameter integer MUL_LAT    = 2,   // mul pipeline stages (min 2 for 4-lane)
    parameter integer MID_STAGES = 0,   // extra latency between widen and add
    parameter integer ADD_LAT    = 3    // forwarded to bf16_add LATENCY (2|3)
) (
    input  wire        clk,
    input  wire [15:0] a16,      // {a2, a1} two FP8(E5M2) A-lanes
    input  wire [15:0] b16,      // {b2, b1} two FP8(E5M2) B-lanes
    input  wire [63:0] c64,      // {c22, c21, c12, c11} four BF16 addends
    output wire [63:0] result    // {y22, y21, y12, y11} four BF16 results
);
  // ---- FP8 E5M2 constants ----
  localparam integer EWIDTH = 5;
  localparam integer FWIDTH = 2;
  localparam integer MBITS  = 1 + FWIDTH; // 3
  localparam integer BIAS   = 15;

  // ---- BF16 special constants ----
  localparam [15:0] BF16_QNAN = 16'h7FC0;
  localparam [15:0] BF16_PINF = 16'h7F80;
  localparam [15:0] BF16_NINF = 16'hFF80;

  // ---- Unpack ----
  wire [7:0] a1 = a16[ 7:0], a2 = a16[15:8];
  wire [7:0] b1 = b16[ 7:0], b2 = b16[15:8];

  wire sa1 = a1[7], sa2 = a2[7];
  wire sb1 = b1[7], sb2 = b2[7];
  wire [EWIDTH-1:0] ea1 = a1[6:2], ea2 = a2[6:2], eb1 = b1[6:2], eb2 = b2[6:2];
  wire [FWIDTH-1:0] fa1 = a1[1:0], fa2 = a2[1:0], fb1 = b1[1:0], fb2 = b2[1:0];

  // ---- Classify ----
  wire a1_nan  = (ea1 == 5'h1F) && (fa1 != 2'd0);
  wire a2_nan  = (ea2 == 5'h1F) && (fa2 != 2'd0);
  wire b1_nan  = (eb1 == 5'h1F) && (fb1 != 2'd0);
  wire b2_nan  = (eb2 == 5'h1F) && (fb2 != 2'd0);

  wire a1_inf  = (ea1 == 5'h1F) && (fa1 == 2'd0);
  wire a2_inf  = (ea2 == 5'h1F) && (fa2 == 2'd0);
  wire b1_inf  = (eb1 == 5'h1F) && (fb1 == 2'd0);
  wire b2_inf  = (eb2 == 5'h1F) && (fb2 == 2'd0);

  wire a1_zero = (ea1 == 5'd0);
  wire a2_zero = (ea2 == 5'd0);
  wire b1_zero = (eb1 == 5'd0);
  wire b2_zero = (eb2 == 5'd0);

  // ---- Product signs ----
  wire s11 = sa1 ^ sb1;
  wire s12 = sa1 ^ sb2;
  wire s21 = sa2 ^ sb1;
  wire s22 = sa2 ^ sb2;

  // ---- Signed exponent sums (unbiased; 8-bit signed) ----
  wire signed [7:0] e11_s1 = $signed({3'd0, ea1}) + $signed({3'd0, eb1}) - $signed(8'd15);
  wire signed [7:0] e12_s1 = $signed({3'd0, ea1}) + $signed({3'd0, eb2}) - $signed(8'd15);
  wire signed [7:0] e21_s1 = $signed({3'd0, ea2}) + $signed({3'd0, eb1}) - $signed(8'd15);
  wire signed [7:0] e22_s1 = $signed({3'd0, ea2}) + $signed({3'd0, eb2}) - $signed(8'd15);

  // ---- Mantissas (hidden bit prepended, FTZ => 0) ----
  wire [MBITS-1:0] Ma1 = a1_zero ? 3'd0 : {1'b1, fa1};
  wire [MBITS-1:0] Ma2 = a2_zero ? 3'd0 : {1'b1, fa2};
  wire [MBITS-1:0] Mb1 = b1_zero ? 3'd0 : {1'b1, fb1};
  wire [MBITS-1:0] Mb2 = b2_zero ? 3'd0 : {1'b1, fb2};

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
  reg signed [7:0] e11_s2, e12_s2, e21_s2, e22_s2;

  reg a1_nan_s2,  a2_nan_s2,  b1_nan_s2,  b2_nan_s2;
  reg a1_inf_s2,  a2_inf_s2,  b1_inf_s2,  b2_inf_s2;
  reg a1_zero_s2, a2_zero_s2, b1_zero_s2, b2_zero_s2;

  reg [15:0] c11_s2, c12_s2, c21_s2, c22_s2;

  always @(posedge clk) begin
    // A_pack: Ma1@[2:0], Ma2@[14:12]  (gap 9)
    A_pack <= {12'b0, Ma2, 9'b0, Ma1};
    // B_pack: Mb1@[2:0], Mb2@[8:6]    (gap 3)
    B_pack <= { 9'b0, Mb2, 3'b0, Mb1};

    s11_s2 <= s11; s12_s2 <= s12; s21_s2 <= s21; s22_s2 <= s22;
    e11_s2 <= e11_s1; e12_s2 <= e12_s1; e21_s2 <= e21_s1; e22_s2 <= e22_s1;

    a1_nan_s2  <= a1_nan;  a2_nan_s2  <= a2_nan;
    b1_nan_s2  <= b1_nan;  b2_nan_s2  <= b2_nan;
    a1_inf_s2  <= a1_inf;  a2_inf_s2  <= a2_inf;
    b1_inf_s2  <= b1_inf;  b2_inf_s2  <= b2_inf;
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
  reg [23:0] dsp_p;

  reg        s11_s3, s12_s3, s21_s3, s22_s3;
  reg signed [7:0] e11_s3, e12_s3, e21_s3, e22_s3;
  reg a1_nan_s3,  a2_nan_s3,  b1_nan_s3,  b2_nan_s3;
  reg a1_inf_s3,  a2_inf_s3,  b1_inf_s3,  b2_inf_s3;
  reg a1_zero_s3, a2_zero_s3, b1_zero_s3, b2_zero_s3;
  reg [15:0] c11_s3, c12_s3, c21_s3, c22_s3;

  always @(posedge clk) begin
    dsp_p <= product45[23:0];

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

  // ---- Product windows (6b each) ----
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

  // ============================================================
  //  Widen FP8(E5M2) product -> BF16
  //    Normalize by carry bit, rebias to BF16 (bias=127), pad frac
  //    from 2b (E5M2) to 7b (BF16). E5M2 has Inf => saturate to Inf.
  // ============================================================
  function automatic [15:0] widen_e5m2_to_bf16;
    input              sign_in;
    input signed [7:0] exp_unb;
    input       [5:0]  prod6;
    input              is_nan;
    input              is_inf;
    input              is_zero;
    reg                carry;
    reg  signed [9:0]  es;
    reg  signed [9:0]  bf16_be;
    reg                ovf_hi, ovf_lo;
    reg  [6:0]         frac7;
    begin
      if (is_nan)
        widen_e5m2_to_bf16 = BF16_QNAN;
      else if (is_inf)
        widen_e5m2_to_bf16 = sign_in ? BF16_NINF : BF16_PINF;
      else if (is_zero)
        widen_e5m2_to_bf16 = {sign_in, 15'd0};
      else begin
        carry   = prod6[5];
        // es = (ea1+eb1-15) + carry; BF16 biased = es + 112 (= +127-15).
        // Equivalently BF16 biased = (ea1+eb1) + 97 + carry.
        es      = $signed({{2{exp_unb[7]}}, exp_unb})
                + (carry ? 10'sd1 : 10'sd0);
        bf16_be = es + 10'sd112;
        // With E5M2 operand range, bf16_be stays well inside [1, 254],
        // so saturation branches should not fire; guard defensively.
        ovf_hi  = (bf16_be > 10'sd254);
        ovf_lo  = (bf16_be < 10'sd1);
        if (ovf_hi)
          widen_e5m2_to_bf16 = sign_in ? BF16_NINF : BF16_PINF;
        else if (ovf_lo)
          widen_e5m2_to_bf16 = {sign_in, 15'd0};
        else begin
          // carry=1: normalized = 1.P[4:0]00 * 2^(exp_unb+1)
          //          frac7 = {P[4:0], 2'b00}
          // carry=0: normalized = 1.P[3:0]000 * 2^(exp_unb)
          //          frac7 = {P[3:0], 3'b000}
          frac7 = carry ? {prod6[4:0], 2'b00} : {prod6[3:0], 3'b000};
          widen_e5m2_to_bf16 = {sign_in, bf16_be[7:0], frac7};
        end
      end
    end
  endfunction

  wire [15:0] prod11_bf16_w = widen_e5m2_to_bf16(s11_s3, e11_s3, P11, nan_11, inf_11, zer_11);
  wire [15:0] prod12_bf16_w = widen_e5m2_to_bf16(s12_s3, e12_s3, P12, nan_12, inf_12, zer_12);
  wire [15:0] prod21_bf16_w = widen_e5m2_to_bf16(s21_s3, e21_s3, P21, nan_21, inf_21, zer_21);
  wire [15:0] prod22_bf16_w = widen_e5m2_to_bf16(s22_s3, e22_s3, P22, nan_22, inf_22, zer_22);

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
