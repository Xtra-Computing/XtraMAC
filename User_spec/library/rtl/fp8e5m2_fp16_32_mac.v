`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp8e5m2_fp16_32_mac : Dual FP8(E5M2) lanes * FP16 + FP32 -> FP32
//   - a16 packs two FP8 lanes {HI[15:8], LO[7:0]}
//   - Shared FP16 multiplicand b16
//   - FP32 addends packed in c64 {HI[63:32], LO[31:0]}
//   - Uses a single DSP48 for both lane multiplies
//   - Latency = 4 cycles, II = 1
// =============================================================
module fp8e5m2_fp16_32_mac (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  localparam [31:0] QNAN32 = 32'h7FC0_0000;

  // ------------------------------------------------------------------
  // FP8 lane decode (E5M2)
  // ------------------------------------------------------------------
  wire [7:0] a_lo8 = a16[7:0];
  wire [7:0] a_hi8 = a16[15:8];

  wire        a_lo_sign = a_lo8[7];
  wire [4:0]  a_lo_exp  = a_lo8[6:2];
  wire [1:0]  a_lo_frac = a_lo8[1:0];
  wire        a_lo_nan  = (a_lo_exp == 5'h1F) && (a_lo_frac != 2'd0);
  wire        a_lo_inf  = (a_lo_exp == 5'h1F) && (a_lo_frac == 2'd0);
  wire        a_lo_zero = (a_lo_exp == 5'd0);
  wire signed [11:0] a_lo_exp_unbias = $signed({1'b0, a_lo_exp}) - 12'sd15;
  wire [2:0]  a_lo_mant = (a_lo_zero || a_lo_nan || a_lo_inf) ? 3'd0 : {1'b1, a_lo_frac};

  wire        a_hi_sign = a_hi8[7];
  wire [4:0]  a_hi_exp  = a_hi8[6:2];
  wire [1:0]  a_hi_frac = a_hi8[1:0];
  wire        a_hi_nan  = (a_hi_exp == 5'h1F) && (a_hi_frac != 2'd0);
  wire        a_hi_inf  = (a_hi_exp == 5'h1F) && (a_hi_frac == 2'd0);
  wire        a_hi_zero = (a_hi_exp == 5'd0);
  wire signed [11:0] a_hi_exp_unbias = $signed({1'b0, a_hi_exp}) - 12'sd15;
  wire [2:0]  a_hi_mant = (a_hi_zero || a_hi_nan || a_hi_inf) ? 3'd0 : {1'b1, a_hi_frac};

  // ------------------------------------------------------------------
  // FP16 multiplicand classification
  // ------------------------------------------------------------------
  wire        b_sign    = b16[15];
  wire [4:0]  b_exp     = b16[14:10];
  wire [9:0]  b_frac    = b16[9:0];
  wire        b_is_nan  = (b_exp == 5'h1F) && (b_frac != 10'd0);
  wire        b_is_inf  = (b_exp == 5'h1F) && (b_frac == 10'd0);
  wire        b_is_zero = (b_exp == 5'd0);
  wire [10:0] man_b_eff = b_is_zero ? 11'd0 : {1'b1, b_frac};
  wire signed [11:0] b_unbias = $signed({1'b0, b_exp}) - 12'sd15;

  // ------------------------------------------------------------------
  // Stage S1 : pack mantissas / metadata
  // ------------------------------------------------------------------
  reg [26:0] man_a_packed_s1;
  reg [17:0] man_b_packed_s1;
  reg signed [11:0] exp_lo_s1, exp_hi_s1;
  reg        sign_lo_s1, sign_hi_s1;
  reg        a_lo_zero_s1, a_hi_zero_s1;
  reg        a_lo_nan_s1,  a_hi_nan_s1;
  reg        a_lo_inf_s1,  a_hi_inf_s1;
  reg        b_zero_s1, b_nan_s1, b_inf_s1;
  reg [31:0] c_lo_s1, c_hi_s1;

  always @(posedge clk) begin
    man_a_packed_s1 <= {9'd0, a_hi_mant, 12'd0, a_lo_mant};
    man_b_packed_s1 <= {7'd0, man_b_eff};

    exp_lo_s1 <= (a_lo_zero || a_lo_nan || a_lo_inf || b_is_zero || b_is_nan)
                 ? 12'sd0 : (a_lo_exp_unbias + b_unbias);
    exp_hi_s1 <= (a_hi_zero || a_hi_nan || a_hi_inf || b_is_zero || b_is_nan)
                 ? 12'sd0 : (a_hi_exp_unbias + b_unbias);

    sign_lo_s1 <= a_lo_sign ^ b_sign;
    sign_hi_s1 <= a_hi_sign ^ b_sign;

    a_lo_zero_s1 <= a_lo_zero;
    a_hi_zero_s1 <= a_hi_zero;
    a_lo_nan_s1  <= a_lo_nan;
    a_hi_nan_s1  <= a_hi_nan;
    a_lo_inf_s1  <= a_lo_inf;
    a_hi_inf_s1  <= a_hi_inf;

    b_zero_s1 <= b_is_zero;
    b_nan_s1  <= b_is_nan;
    b_inf_s1  <= b_is_inf;

    c_lo_s1 <= c64[31:0];
    c_hi_s1 <= c64[63:32];
  end

  // ------------------------------------------------------------------
  // Shared DSP multiply
  // ------------------------------------------------------------------
  wire [44:0] product45;
  dsp_usage u_dsp (
    .clk    (clk),
    .a      (man_a_packed_s1),
    .b      (man_b_packed_s1),
    .product(product45)
  );

  // ------------------------------------------------------------------
  // Stage S2 : propagate metadata + promote Q2.12 products to Q2.20
  // ------------------------------------------------------------------
  reg signed [11:0] exp_lo_s2, exp_hi_s2;
  reg        sign_lo_s2, sign_hi_s2;
  reg        a_lo_zero_s2, a_hi_zero_s2;
  reg        a_lo_nan_s2,  a_hi_nan_s2;
  reg        a_lo_inf_s2,  a_hi_inf_s2;
  reg        b_zero_s2, b_nan_s2, b_inf_s2;
  reg [31:0] c_lo_s2, c_hi_s2;
  reg [21:0] man_lo_mul_s2, man_hi_mul_s2;

  wire [13:0] man_lo_mul_raw = product45[13:0];
  wire [13:0] man_hi_mul_raw = product45[28:15];

  always @(posedge clk) begin
    exp_lo_s2  <= exp_lo_s1;
    exp_hi_s2  <= exp_hi_s1;
    sign_lo_s2 <= sign_lo_s1;
    sign_hi_s2 <= sign_hi_s1;

    a_lo_zero_s2 <= a_lo_zero_s1;
    a_hi_zero_s2 <= a_hi_zero_s1;
    a_lo_nan_s2  <= a_lo_nan_s1;
    a_hi_nan_s2  <= a_hi_nan_s1;
    a_lo_inf_s2  <= a_lo_inf_s1;
    a_hi_inf_s2  <= a_hi_inf_s1;

    b_zero_s2 <= b_zero_s1;
    b_nan_s2  <= b_nan_s1;
    b_inf_s2  <= b_inf_s1;

    c_lo_s2 <= c_lo_s1;
    c_hi_s2 <= c_hi_s1;

    man_lo_mul_s2 <= {man_lo_mul_raw, 8'd0};
    man_hi_mul_s2 <= {man_hi_mul_raw, 8'd0};
  end

  // ------------------------------------------------------------------
  // Stage S3 : FP32 lane products + accumulation
  // ------------------------------------------------------------------
  wire [31:0] prod_lo32_w = lane_fp16_mul_to_fp32(
                              man_lo_mul_s2,
                              exp_lo_s2,
                              sign_lo_s2,
                              a_lo_zero_s2,
                              b_zero_s2,
                              b_nan_s2 | a_lo_nan_s2,
                              b_inf_s2 | a_lo_inf_s2);

  wire [31:0] prod_hi32_w = lane_fp16_mul_to_fp32(
                              man_hi_mul_s2,
                              exp_hi_s2,
                              sign_hi_s2,
                              a_hi_zero_s2,
                              b_zero_s2,
                              b_nan_s2 | a_hi_nan_s2,
                              b_inf_s2 | a_hi_inf_s2);

  wire [31:0] sum_lo32;
  wire [31:0] sum_hi32;

  fp32_add u_add_lo (
    .clk   (clk),
    .x32   (prod_lo32_w),
    .y32   (c_lo_s2),
    .result(sum_lo32)
  );

  fp32_add u_add_hi (
    .clk   (clk),
    .x32   (prod_hi32_w),
    .y32   (c_hi_s2),
    .result(sum_hi32)
  );

  assign result = {sum_hi32, sum_lo32};

  // ------------------------------------------------------------------
  // Helper : lane FP16 product -> FP32 (RN-even)
  // ------------------------------------------------------------------
  function automatic [31:0] lane_fp16_mul_to_fp32;
    input      [21:0] mul22;
    input signed [11:0] exp_unbiased_in;
    input               sign;
    input               a_is_zero;
    input               b_is_zero;
    input               b_is_nan;
    input               b_is_inf;
    reg         leading2;
    reg signed [12:0] exp_norm;
    reg signed [12:0] exp_biased;
    reg [21:0]  norm22;
    reg [24:0]  sig_ext;
    reg [23:0]  sig24;
    begin
      if (b_is_nan || (b_is_inf && (a_is_zero || b_is_zero))) begin
        lane_fp16_mul_to_fp32 = QNAN32;
      end else if (b_is_inf) begin
        lane_fp16_mul_to_fp32 = {sign, 8'hFF, 23'd0};
      end else if (a_is_zero || b_is_zero) begin
        lane_fp16_mul_to_fp32 = {sign, 31'd0};
      end else begin
        leading2 = mul22[21];
        norm22   = leading2 ? (mul22 >> 1) : mul22;
        exp_norm = exp_unbiased_in + (leading2 ? 13'sd1 : 13'sd0);
        exp_biased = exp_norm + 13'sd127;

        if (exp_biased >= 13'sd255) begin
          lane_fp16_mul_to_fp32 = {sign, 8'hFF, 23'd0};
        end else if (exp_biased <= 13'sd0) begin
          lane_fp16_mul_to_fp32 = {sign, 31'd0};
        end else begin
          sig_ext = {norm22, 3'b000};
          sig24   = sig_ext[23:0];
          lane_fp16_mul_to_fp32 = {sign, exp_biased[7:0], sig24[22:0]};
        end
      end
    end
  endfunction
endmodule

`default_nettype wire
