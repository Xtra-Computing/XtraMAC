`timescale 1ns/1ps
`default_nettype none
// =============================================================
// bf16_fp32_mul_2lane : 2-lane BF16 x BF16 -> FP32 multiplier
//   - Packs two BF16 mantissa multiplications into one 27x18 DSP
//   - A[26:0] = {3'b0, {1,f_hi}[7:0], 8'b0, {1,f_lo}[7:0]}
//   - B[17:0] = {10'b0, {1,f_b}[7:0]}
//   - Product composed into FP32 per lane
//   - Latency: MUL_LAT cycles (1 or 2)
//     MUL_LAT=1 : S1 regs + comb DSP (no S2 capture)
//     MUL_LAT=2 : S1 regs + DSP + S2 capture
//   - II = 1
// =============================================================
module bf16_fp32_mul_2lane #(
    parameter MUL_LAT = 2  // 1 or 2
)(
    input  wire        clk,
    input  wire [31:0] a32,     // BF16 lanes {HI[31:16], LO[15:0]}
    input  wire [15:0] b16,     // shared BF16 multiplier
    output wire [31:0] prod_hi, // FP32 product for hi lane
    output wire [31:0] prod_lo  // FP32 product for lo lane
);

  localparam [31:0] QNAN32    = 32'h7FC0_0000;
  localparam [7:0]  BF16_BIAS = 8'd127;

  // ----------------------------------------------------------------
  // Classify operands
  // ----------------------------------------------------------------
  wire [15:0] a_hi16 = a32[31:16];
  wire [15:0] a_lo16 = a32[15:0];

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
  wire [7:0] ma_hi_eff = a_hi_zero_w ? 8'd0 : {1'b1, f_a_hi};
  wire [7:0] ma_lo_eff = a_lo_zero_w ? 8'd0 : {1'b1, f_a_lo};
  wire [7:0] mb_eff    = b_zero_w    ? 8'd0 : {1'b1, f_b};

  // Unbiased exponents (signed)
  wire signed [10:0] ea_hi_unbias = a_hi_zero_w ? 11'sd0 : ($signed({1'b0, e_a_hi}) - 11'sd127);
  wire signed [10:0] ea_lo_unbias = a_lo_zero_w ? 11'sd0 : ($signed({1'b0, e_a_lo}) - 11'sd127);
  wire signed [10:0] eb_unbias    = b_zero_w    ? 11'sd0 : ($signed({1'b0, e_b   }) - 11'sd127);

  // Pack mantissas for DSP
  wire [26:0] man_a_packed_next = {3'b000, ma_hi_eff, 8'd0, ma_lo_eff};
  wire [17:0] man_b_packed_next = {10'b0, mb_eff};

  // ----------------------------------------------------------------
  // S1 registers
  // ----------------------------------------------------------------
  reg [26:0] man_a_packed_s1;
  reg [17:0] man_b_packed_s1;
  reg signed [11:0] exp_hi_s1, exp_lo_s1;
  reg        sign_hi_s1, sign_lo_s1;
  reg        a_hi_nan_s1, a_lo_nan_s1, b_nan_s1;
  reg        a_hi_inf_s1, a_lo_inf_s1, b_inf_s1;
  reg        a_hi_zero_s1, a_lo_zero_s1, b_zero_s1;

  always @(posedge clk) begin
    man_a_packed_s1 <= man_a_packed_next;
    man_b_packed_s1 <= man_b_packed_next;
    exp_hi_s1       <= ea_hi_unbias + eb_unbias;
    exp_lo_s1       <= ea_lo_unbias + eb_unbias;
    sign_hi_s1      <= s_a_hi ^ s_b;
    sign_lo_s1      <= s_a_lo ^ s_b;
    a_hi_nan_s1     <= a_hi_nan_w;  a_lo_nan_s1  <= a_lo_nan_w;  b_nan_s1  <= b_nan_w;
    a_hi_inf_s1     <= a_hi_inf_w;  a_lo_inf_s1  <= a_lo_inf_w;  b_inf_s1  <= b_inf_w;
    a_hi_zero_s1    <= a_hi_zero_w; a_lo_zero_s1 <= a_lo_zero_w; b_zero_s1 <= b_zero_w;
  end

  // ----------------------------------------------------------------
  // DSP: combinational 27x18 unsigned multiply
  // ----------------------------------------------------------------
  wire [44:0] product45;

  (* use_dsp = "yes" *)
  dsp_usage u_dsp (
    .clk    (clk),
    .a      (man_a_packed_s1),
    .b      (man_b_packed_s1),
    .product(product45)
  );

  // ----------------------------------------------------------------
  // S2 / output: compose FP32 products
  // ----------------------------------------------------------------
  generate
    if (MUL_LAT == 1) begin : gen_lat1
      // No S2 capture; compose FP32 from combinational DSP output
      wire [15:0] mul_hi16 = product45[31:16];
      wire [15:0] mul_lo16 = product45[15:0];

      // HI lane finite
      wire        hi_l2      = mul_hi16[15];
      wire [15:0] hi_ns      = hi_l2 ? (mul_hi16 >> 1) : mul_hi16;
      wire signed [11:0] hi_en = exp_hi_s1 + (hi_l2 ? 12'sd1 : 12'sd0);
      wire signed [11:0] hi_e32u = hi_en + 12'sd127;
      wire [23:0] hi_sig24   = {1'b1, hi_ns[13:0], 9'd0};

      wire hi_ovf  = (hi_e32u >= 12'sd255);
      wire hi_udf  = (hi_e32u <= 12'sd0);
      wire hi_nan  = a_hi_nan_s1 | b_nan_s1 | ((a_hi_inf_s1 & b_zero_s1) | (a_hi_zero_s1 & b_inf_s1));
      wire hi_inf  = ~hi_nan & (a_hi_inf_s1 | b_inf_s1);
      wire hi_zero = ~hi_nan & ~hi_inf & (a_hi_zero_s1 | b_zero_s1 | hi_udf);

      assign prod_hi = hi_nan              ? QNAN32 :
                        (hi_inf | hi_ovf)  ? {sign_hi_s1, 8'hFF, 23'd0} :
                        hi_zero            ? {sign_hi_s1, 31'd0} :
                                             {sign_hi_s1, hi_e32u[7:0], hi_sig24[22:0]};

      // LO lane finite
      wire        lo_l2      = mul_lo16[15];
      wire [15:0] lo_ns      = lo_l2 ? (mul_lo16 >> 1) : mul_lo16;
      wire signed [11:0] lo_en = exp_lo_s1 + (lo_l2 ? 12'sd1 : 12'sd0);
      wire signed [11:0] lo_e32u = lo_en + 12'sd127;
      wire [23:0] lo_sig24   = {1'b1, lo_ns[13:0], 9'd0};

      wire lo_ovf  = (lo_e32u >= 12'sd255);
      wire lo_udf  = (lo_e32u <= 12'sd0);
      wire lo_nan  = a_lo_nan_s1 | b_nan_s1 | ((a_lo_inf_s1 & b_zero_s1) | (a_lo_zero_s1 & b_inf_s1));
      wire lo_inf  = ~lo_nan & (a_lo_inf_s1 | b_inf_s1);
      wire lo_zero = ~lo_nan & ~lo_inf & (a_lo_zero_s1 | b_zero_s1 | lo_udf);

      assign prod_lo = lo_nan              ? QNAN32 :
                        (lo_inf | lo_ovf)  ? {sign_lo_s1, 8'hFF, 23'd0} :
                        lo_zero            ? {sign_lo_s1, 31'd0} :
                                             {sign_lo_s1, lo_e32u[7:0], lo_sig24[22:0]};

    end else begin : gen_lat2
      // S2 capture
      reg [44:0] dsp_prod_s2;
      reg signed [11:0] exp_hi_s2, exp_lo_s2;
      reg        sign_hi_s2, sign_lo_s2;
      reg        a_hi_nan_s2, a_lo_nan_s2, b_nan_s2;
      reg        a_hi_inf_s2, a_lo_inf_s2, b_inf_s2;
      reg        a_hi_zero_s2, a_lo_zero_s2, b_zero_s2;

      always @(posedge clk) begin
        dsp_prod_s2  <= product45;
        exp_hi_s2    <= exp_hi_s1;    exp_lo_s2    <= exp_lo_s1;
        sign_hi_s2   <= sign_hi_s1;   sign_lo_s2   <= sign_lo_s1;
        a_hi_nan_s2  <= a_hi_nan_s1;  a_lo_nan_s2  <= a_lo_nan_s1;  b_nan_s2  <= b_nan_s1;
        a_hi_inf_s2  <= a_hi_inf_s1;  a_lo_inf_s2  <= a_lo_inf_s1;  b_inf_s2  <= b_inf_s1;
        a_hi_zero_s2 <= a_hi_zero_s1; a_lo_zero_s2 <= a_lo_zero_s1; b_zero_s2 <= b_zero_s1;
      end

      wire [15:0] mul_hi16 = dsp_prod_s2[31:16];
      wire [15:0] mul_lo16 = dsp_prod_s2[15:0];

      // HI lane
      wire        hi_l2      = mul_hi16[15];
      wire [15:0] hi_ns      = hi_l2 ? (mul_hi16 >> 1) : mul_hi16;
      wire signed [11:0] hi_en = exp_hi_s2 + (hi_l2 ? 12'sd1 : 12'sd0);
      wire signed [11:0] hi_e32u = hi_en + 12'sd127;
      wire [23:0] hi_sig24   = {1'b1, hi_ns[13:0], 9'd0};

      wire hi_ovf  = (hi_e32u >= 12'sd255);
      wire hi_udf  = (hi_e32u <= 12'sd0);
      wire hi_nan  = a_hi_nan_s2 | b_nan_s2 | ((a_hi_inf_s2 & b_zero_s2) | (a_hi_zero_s2 & b_inf_s2));
      wire hi_inf  = ~hi_nan & (a_hi_inf_s2 | b_inf_s2);
      wire hi_zero = ~hi_nan & ~hi_inf & (a_hi_zero_s2 | b_zero_s2 | hi_udf);

      assign prod_hi = hi_nan              ? QNAN32 :
                        (hi_inf | hi_ovf)  ? {sign_hi_s2, 8'hFF, 23'd0} :
                        hi_zero            ? {sign_hi_s2, 31'd0} :
                                             {sign_hi_s2, hi_e32u[7:0], hi_sig24[22:0]};

      // LO lane
      wire        lo_l2      = mul_lo16[15];
      wire [15:0] lo_ns      = lo_l2 ? (mul_lo16 >> 1) : mul_lo16;
      wire signed [11:0] lo_en = exp_lo_s2 + (lo_l2 ? 12'sd1 : 12'sd0);
      wire signed [11:0] lo_e32u = lo_en + 12'sd127;
      wire [23:0] lo_sig24   = {1'b1, lo_ns[13:0], 9'd0};

      wire lo_ovf  = (lo_e32u >= 12'sd255);
      wire lo_udf  = (lo_e32u <= 12'sd0);
      wire lo_nan  = a_lo_nan_s2 | b_nan_s2 | ((a_lo_inf_s2 & b_zero_s2) | (a_lo_zero_s2 & b_inf_s2));
      wire lo_inf  = ~lo_nan & (a_lo_inf_s2 | b_inf_s2);
      wire lo_zero = ~lo_nan & ~lo_inf & (a_lo_zero_s2 | b_zero_s2 | lo_udf);

      assign prod_lo = lo_nan              ? QNAN32 :
                        (lo_inf | lo_ovf)  ? {sign_lo_s2, 8'hFF, 23'd0} :
                        lo_zero            ? {sign_lo_s2, 31'd0} :
                                             {sign_lo_s2, lo_e32u[7:0], lo_sig24[22:0]};
    end
  endgenerate

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
