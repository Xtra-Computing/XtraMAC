`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp8e4m3_fp16_32_mac : Dual FP8(E4M3) lanes * FP16 + FP32 -> FP32
//   - Two FP8 lanes in a16 {HI[15:8], LO[7:0]}
//   - Shared FP16 multiplicand b16
//   - FP32 addends packed in c64 {HI[63:32], LO[31:0]}
//   - Uses one DSP48 by packing FP8 mantissas onto the A-port
//   - Latency = 4 cycles, II = 1
// =============================================================
module fp8e4m3_fp16_32_mac (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  localparam [31:0] QNAN32 = 32'h7FC0_0000;

  // ------------------------------------------------------------------
  // FP8 lane decode (E4M3)
  // ------------------------------------------------------------------
  wire [7:0] a_lo8 = a16[7:0];
  wire [7:0] a_hi8 = a16[15:8];

  wire        a_lo_sign = a_lo8[7];
  wire [3:0]  a_lo_exp  = a_lo8[6:3];
  wire [2:0]  a_lo_frac = a_lo8[2:0];
  wire        a_lo_nan  = (a_lo_exp == 4'hF);
  wire        a_lo_zero = (a_lo_exp == 4'd0);
  wire signed [11:0] a_lo_exp_unbias = $signed({1'b0, a_lo_exp}) - 12'sd7;
  wire [3:0]  a_lo_mant = (a_lo_zero || a_lo_nan) ? 4'd0 : {1'b1, a_lo_frac};

  wire        a_hi_sign = a_hi8[7];
  wire [3:0]  a_hi_exp  = a_hi8[6:3];
  wire [2:0]  a_hi_frac = a_hi8[2:0];
  wire        a_hi_nan  = (a_hi_exp == 4'hF);
  wire        a_hi_zero = (a_hi_exp == 4'd0);
  wire signed [11:0] a_hi_exp_unbias = $signed({1'b0, a_hi_exp}) - 12'sd7;
  wire [3:0]  a_hi_mant = (a_hi_zero || a_hi_nan) ? 4'd0 : {1'b1, a_hi_frac};

  // ------------------------------------------------------------------
  // FP16 multiplicand classification (shared)
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
  // Stage S1 : pack mantissas and capture metadata
  // ------------------------------------------------------------------
  reg [26:0] man_a_packed_s1;
  reg [17:0] man_b_packed_s1;
  reg signed [11:0] exp_lo_s1, exp_hi_s1;
  reg        sign_lo_s1, sign_hi_s1;
  reg        a_lo_zero_s1, a_hi_zero_s1;
  reg        a_lo_nan_s1,  a_hi_nan_s1;
  reg        b_zero_s1, b_nan_s1, b_inf_s1;
  reg [31:0] c_lo_s1, c_hi_s1;

  always @(posedge clk) begin
    man_a_packed_s1 <= {8'd0, a_hi_mant, 11'd0, a_lo_mant};
    man_b_packed_s1 <= {7'd0, man_b_eff};

    exp_lo_s1 <= (a_lo_zero || a_lo_nan || b_is_zero || b_is_nan)
                 ? 12'sd0 : (a_lo_exp_unbias + b_unbias);
    exp_hi_s1 <= (a_hi_zero || a_hi_nan || b_is_zero || b_is_nan)
                 ? 12'sd0 : (a_hi_exp_unbias + b_unbias);

    sign_lo_s1 <= a_lo_sign ^ b_sign;
    sign_hi_s1 <= a_hi_sign ^ b_sign;

    a_lo_zero_s1 <= a_lo_zero;
    a_hi_zero_s1 <= a_hi_zero;
    a_lo_nan_s1  <= a_lo_nan;
    a_hi_nan_s1  <= a_hi_nan;

    b_zero_s1 <= b_is_zero;
    b_nan_s1  <= b_is_nan;
    b_inf_s1  <= b_is_inf;

    c_lo_s1 <= c64[31:0];
    c_hi_s1 <= c64[63:32];
  end

  // ------------------------------------------------------------------
  // DSP multiply (shared)
  // ------------------------------------------------------------------
  wire [44:0] product45;
  dsp_usage u_dsp (
    .clk    (clk),
    .a      (man_a_packed_s1),
    .b      (man_b_packed_s1),
    .product(product45)
  );

  // ------------------------------------------------------------------
  // Stage S2 : propagate metadata and promote Q2.13 -> Q2.20 products
  // ------------------------------------------------------------------
  reg signed [11:0] exp_lo_s2, exp_hi_s2;
  reg        sign_lo_s2, sign_hi_s2;
  reg        a_lo_zero_s2, a_hi_zero_s2;
  reg        a_lo_nan_s2,  a_hi_nan_s2;
  reg        b_zero_s2, b_nan_s2, b_inf_s2;
  reg [31:0] c_lo_s2, c_hi_s2;
  reg [21:0] man_lo_mul_s2, man_hi_mul_s2;

  wire [14:0] man_lo_mul_raw = product45[14:0];
  wire [14:0] man_hi_mul_raw = product45[29:15];

  always @(posedge clk) begin
    exp_lo_s2  <= exp_lo_s1;
    exp_hi_s2  <= exp_hi_s1;
    sign_lo_s2 <= sign_lo_s1;
    sign_hi_s2 <= sign_hi_s1;

    a_lo_zero_s2 <= a_lo_zero_s1;
    a_hi_zero_s2 <= a_hi_zero_s1;
    a_lo_nan_s2  <= a_lo_nan_s1;
    a_hi_nan_s2  <= a_hi_nan_s1;

    b_zero_s2 <= b_zero_s1;
    b_nan_s2  <= b_nan_s1;
    b_inf_s2  <= b_inf_s1;

    c_lo_s2 <= c_lo_s1;
    c_hi_s2 <= c_hi_s1;

    man_lo_mul_s2 <= {man_lo_mul_raw, 7'd0};
    man_hi_mul_s2 <= {man_hi_mul_raw, 7'd0};
  end

  // ------------------------------------------------------------------
  // Stage S3 : convert to FP32 lanes and add C
  // ------------------------------------------------------------------
  wire lane_lo_nan = a_lo_nan_s2;
  wire lane_hi_nan = a_hi_nan_s2;
  wire lane_lo_inf = 1'b0;
  wire lane_hi_inf = 1'b0;

  wire [31:0] prod_lo32_w = lane_fp16_mul_to_fp32(
                              man_lo_mul_s2,
                              exp_lo_s2,
                              sign_lo_s2,
                              a_lo_zero_s2,
                              b_zero_s2,
                              b_nan_s2 | lane_lo_nan,
                              b_inf_s2 | lane_lo_inf);

  wire [31:0] prod_hi32_w = lane_fp16_mul_to_fp32(
                              man_hi_mul_s2,
                              exp_hi_s2,
                              sign_hi_s2,
                              a_hi_zero_s2,
                              b_zero_s2,
                              b_nan_s2 | lane_hi_nan,
                              b_inf_s2 | lane_hi_inf);

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
