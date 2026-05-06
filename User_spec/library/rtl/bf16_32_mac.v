`timescale 1ns/1ps
`default_nettype none

// =============================================================
// bf16_32_mac : Two-lane BF16 * BF16 + FP32 -> FP32
//   - Shares a single DSP block (packed 27x18 multiply) for both lanes
//   - Overall latency = 4 cycles (S1/S2 multiplier + 2-cycle FP32 adder)
//   - Initiation interval = 1
// =============================================================
module bf16_32_mac (
    input  wire        clk,
    input  wire [31:0] a32,     // BF16 lanes {HI[31:16], LO[15:0]}
    input  wire [15:0] b16,     // shared BF16 multiplier input
    input  wire [63:0] c64,     // FP32 addends {HI[63:32], LO[31:0]}
    output wire [63:0] result   // FP32 results {HI, LO}
);
  localparam [31:0] QNAN32 = 32'h7FC0_0000;
  localparam [7:0]  BF16_BIAS = 8'd127;

  // Split BF16 lanes
  wire [15:0] a_hi16 = a32[31:16];
  wire [15:0] a_lo16 = a32[15:0];

  // Classify operands (FTZ/DAZ behaviour handled in bf16_class)
  wire s_a_hi, s_a_lo, s_b;
  wire [7:0] e_a_hi, e_a_lo, e_b;
  wire [6:0] f_a_hi, f_a_lo, f_b;
  wire a_hi_nan_w, a_lo_nan_w, b_nan_w;
  wire a_hi_inf_w, a_lo_inf_w, b_inf_w;
  wire a_hi_zero_w, a_lo_zero_w, b_zero_w;

  bf16_class u_class_a_hi (.x(a_hi16), .s(s_a_hi), .e(e_a_hi), .f(f_a_hi),
                           .is_nan(a_hi_nan_w), .is_inf(a_hi_inf_w), .is_zero(a_hi_zero_w));
  bf16_class u_class_a_lo (.x(a_lo16), .s(s_a_lo), .e(e_a_lo), .f(f_a_lo),
                           .is_nan(a_lo_nan_w), .is_inf(a_lo_inf_w), .is_zero(a_lo_zero_w));
  bf16_class u_class_b    (.x(b16   ), .s(s_b   ), .e(e_b   ), .f(f_b   ),
                           .is_nan(b_nan_w   ), .is_inf(b_inf_w   ), .is_zero(b_zero_w   ));

  // Effective mantissas (include hidden-1; zeroed if FTZ)
  wire [7:0] ma_hi_eff_w = a_hi_zero_w ? 8'd0 : {1'b1, f_a_hi};
  wire [7:0] ma_lo_eff_w = a_lo_zero_w ? 8'd0 : {1'b1, f_a_lo};
  wire [7:0] mb_eff_w    = b_zero_w    ? 8'd0 : {1'b1, f_b};

  // Unbiased exponents (signed); flush-to-zero forces 0
  wire signed [10:0] ea_hi_unbias_w = a_hi_zero_w ? 11'sd0 : ($signed({1'b0, e_a_hi}) - 11'sd127);
  wire signed [10:0] ea_lo_unbias_w = a_lo_zero_w ? 11'sd0 : ($signed({1'b0, e_a_lo}) - 11'sd127);
  wire signed [10:0] eb_unbias_w    = b_zero_w    ? 11'sd0 : ($signed({1'b0, e_b   }) - 11'sd127);

  // Pack mantissas for the shared DSP (same schema as bf16_mac)
  wire [26:0] man_a_packed_next = {3'b000, ma_hi_eff_w, 8'd0, ma_lo_eff_w};
  wire [17:0] man_b_packed_next = {10'b0, mb_eff_w};

  // --------------------------
  // S1 registers (align to DSP input)
  // --------------------------
  reg [26:0] man_a_packed_s1;
  reg [17:0] man_b_packed_s1;

  reg signed [11:0] exp_hi_s1, exp_lo_s1; // unbiased exponent sums
  reg              sign_hi_s1, sign_lo_s1;

  reg a_hi_nan_s1, a_lo_nan_s1, b_nan_s1;
  reg a_hi_inf_s1, a_lo_inf_s1, b_inf_s1;
  reg a_hi_zero_s1, a_lo_zero_s1, b_zero_s1;

  reg [31:0] c_hi_s1, c_lo_s1;

  always @(posedge clk) begin
    man_a_packed_s1 <= man_a_packed_next;
    man_b_packed_s1 <= man_b_packed_next;

    exp_hi_s1 <= ea_hi_unbias_w + eb_unbias_w;
    exp_lo_s1 <= ea_lo_unbias_w + eb_unbias_w;

    sign_hi_s1 <= s_a_hi ^ s_b;
    sign_lo_s1 <= s_a_lo ^ s_b;

    a_hi_nan_s1  <= a_hi_nan_w;  a_lo_nan_s1  <= a_lo_nan_w;  b_nan_s1  <= b_nan_w;
    a_hi_inf_s1  <= a_hi_inf_w;  a_lo_inf_s1  <= a_lo_inf_w;  b_inf_s1  <= b_inf_w;
    a_hi_zero_s1 <= a_hi_zero_w; a_lo_zero_s1 <= a_lo_zero_w; b_zero_s1 <= b_zero_w;

    c_hi_s1 <= c64[63:32];
    c_lo_s1 <= c64[31:0];
  end

  // --------------------------
  // DSP (1-cycle) : packed dual BF16 mantissas
  // --------------------------
  wire [44:0] product45;

  (* use_dsp = "yes" *)
  dsp_usage u_dsp (
    .clk    (clk),
    .a      (man_a_packed_s1),
    .b      (man_b_packed_s1),
    .product(product45)
  );

  // --------------------------
  // S2 registers: capture DSP product + metadata
  // --------------------------
  reg [44:0] dsp_prod_s2; // full DSP product (captures both lane products)

  reg signed [11:0] exp_hi_s2, exp_lo_s2;
  reg              sign_hi_s2, sign_lo_s2;

  reg a_hi_nan_s2, a_lo_nan_s2, b_nan_s2;
  reg a_hi_inf_s2, a_lo_inf_s2, b_inf_s2;
  reg a_hi_zero_s2, a_lo_zero_s2, b_zero_s2;

  reg [31:0] c_hi_s2, c_lo_s2;

  always @(posedge clk) begin
    dsp_prod_s2 <= product45;

    exp_hi_s2  <= exp_hi_s1;    exp_lo_s2  <= exp_lo_s1;
    sign_hi_s2 <= sign_hi_s1;   sign_lo_s2 <= sign_lo_s1;

    a_hi_nan_s2  <= a_hi_nan_s1;  a_lo_nan_s2  <= a_lo_nan_s1;  b_nan_s2  <= b_nan_s1;
    a_hi_inf_s2  <= a_hi_inf_s1;  a_lo_inf_s2  <= a_lo_inf_s1;  b_inf_s2  <= b_inf_s1;
    a_hi_zero_s2 <= a_hi_zero_s1; a_lo_zero_s2 <= a_lo_zero_s1; b_zero_s2 <= b_zero_s1;

    c_hi_s2 <= c_hi_s1;
    c_lo_s2 <= c_lo_s1;
  end

  // --------------------------
  // S2 -> S3: Convert BF16 products to FP32 (finite path)
  // --------------------------
  wire [15:0] mul_hi16 = dsp_prod_s2[31:16];
  wire [15:0] mul_lo16 = dsp_prod_s2[15:0];

  // HI lane finite path
  wire        hi_leading2 = mul_hi16[15];
  wire [15:0] hi_norm_sig = hi_leading2 ? (mul_hi16 >> 1) : mul_hi16;
  wire signed [11:0] hi_e_norm = exp_hi_s2 + (hi_leading2 ? 12'sd1 : 12'sd0);
  wire signed [11:0] hi_e32_unclamped = hi_e_norm + 12'sd127;
  wire [23:0] hi_sig24 = {1'b1, hi_norm_sig[13:0], 9'd0};

  // LO lane finite path
  wire        lo_leading2 = mul_lo16[15];
  wire [15:0] lo_norm_sig = lo_leading2 ? (mul_lo16 >> 1) : mul_lo16;
  wire signed [11:0] lo_e_norm = exp_lo_s2 + (lo_leading2 ? 12'sd1 : 12'sd0);
  wire signed [11:0] lo_e32_unclamped = lo_e_norm + 12'sd127;
  wire [23:0] lo_sig24 = {1'b1, lo_norm_sig[13:0], 9'd0};

  // No extra remainder bits -> guard/sticky are zero
  wire [23:0] hi_sig_rounded = hi_sig24;
  wire [23:0] lo_sig_rounded = lo_sig24;
  wire signed [11:0] hi_e32_rounded = hi_e32_unclamped;
  wire signed [11:0] lo_e32_rounded = lo_e32_unclamped;

  wire hi_overflow   = (hi_e32_rounded >= 12'sd255);
  wire hi_underflow0 = (hi_e32_rounded <= 12'sd0);
  wire lo_overflow   = (lo_e32_rounded >= 12'sd255);
  wire lo_underflow0 = (lo_e32_rounded <= 12'sd0);

  // Special-case resolution (same precedence as bf16_mac)
  wire hi_nan  = a_hi_nan_s2 | b_nan_s2 | ((a_hi_inf_s2 & b_zero_s2) | (a_hi_zero_s2 & b_inf_s2));
  wire hi_inf  = ~hi_nan  & (a_hi_inf_s2 | b_inf_s2);
  wire hi_zero = ~hi_nan  & ~hi_inf & (a_hi_zero_s2 | b_zero_s2 | hi_underflow0);

  wire lo_nan  = a_lo_nan_s2 | b_nan_s2 | ((a_lo_inf_s2 & b_zero_s2) | (a_lo_zero_s2 & b_inf_s2));
  wire lo_inf  = ~lo_nan  & (a_lo_inf_s2 | b_inf_s2);
  wire lo_zero = ~lo_nan  & ~lo_inf & (a_lo_zero_s2 | b_zero_s2 | lo_underflow0);

  wire [31:0] prod_hi32_w =
      hi_nan           ? QNAN32 :
      (hi_inf|hi_overflow) ? {sign_hi_s2, 8'hFF, 23'd0} :
      hi_zero          ? {sign_hi_s2, 31'd0} :
                         {sign_hi_s2, hi_e32_rounded[7:0], hi_sig_rounded[22:0]};

  wire [31:0] prod_lo32_w =
      lo_nan           ? QNAN32 :
      (lo_inf|lo_overflow) ? {sign_lo_s2, 8'hFF, 23'd0} :
      lo_zero          ? {sign_lo_s2, 31'd0} :
                         {sign_lo_s2, lo_e32_rounded[7:0], lo_sig_rounded[22:0]};

  // --------------------------
  // S3 registers: align with FP32 adder inputs
  // --------------------------
  reg [31:0] prod_hi32_s3, prod_lo32_s3;
  reg [31:0] c_hi_s3, c_lo_s3;

  always @(posedge clk) begin
    prod_hi32_s3 <= prod_hi32_w;
    prod_lo32_s3 <= prod_lo32_w;
    c_hi_s3      <= c_hi_s2;
    c_lo_s3      <= c_lo_s2;
  end

  // --------------------------
  // FP32 adders (2-stage) per lane
  // --------------------------
  wire [31:0] sum_hi32_w;
  wire [31:0] sum_lo32_w;

  fp32_add #(
    .SATURATE_ON_MAX(1'b0),
    .INF_CANCELLATION_TO_NAN(1'b0)
  ) u_add_hi (
    .clk   (clk),
    .x32   (prod_hi32_s3),
    .y32   (c_hi_s3),
    .result(sum_hi32_w)
  );

  fp32_add #(
    .SATURATE_ON_MAX(1'b0),
    .INF_CANCELLATION_TO_NAN(1'b0)
  ) u_add_lo (
    .clk   (clk),
    .x32   (prod_lo32_s3),
    .y32   (c_lo_s3),
    .result(sum_lo32_w)
  );

  assign result = {sum_hi32_w, sum_lo32_w};
endmodule

// =============================================================
// bf16_class : Unpack/classify BF16 (FTZ/DAZ for subnormals)
// =============================================================
module bf16_class (
  input  wire [15:0] x,
  output wire        s,
  output wire [7:0]  e,
  output wire [6:0]  f,
  output wire        is_nan,
  output wire        is_inf,
  output wire        is_zero
);
  assign s = x[15];
  assign e = x[14:7];
  assign f = x[6:0];
  assign is_nan  = (e==8'hFF) && (f!=7'd0);
  assign is_inf  = (e==8'hFF) && (f==7'd0);
  assign is_zero = (e==8'd0); // FTZ/DAZ
endmodule

`default_nettype wire
