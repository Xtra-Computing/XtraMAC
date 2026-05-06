`timescale 1ns/1ps
`default_nettype none

module fp4e2m1_fp16_mac (
    input  wire        clk,
    input  wire [7:0]  a_fp4,    // {hi[7:4], lo[3:0]} FP4 (E2M1) lanes
    input  wire [15:0] b_fp16,   // shared FP16 multiplicand
    input  wire [31:0] c_fp16,   // FP16 addends {hi, lo}
    output wire [31:0] result
);
  localparam [15:0] QNAN16 = 16'h7E00;

  // --------------------------------------------------------------------------
  // Decode FP4(E2M1) lanes
  // --------------------------------------------------------------------------
  wire [3:0] a_lo4 = a_fp4[3:0];
  wire [3:0] a_hi4 = a_fp4[7:4];

  wire        a_lo_sign = a_lo4[3];
  wire [1:0]  a_lo_exp  = a_lo4[2:1];
  wire        a_lo_frac = a_lo4[0];
  wire        a_lo_nan  = (a_lo_exp == 2'b11) && (a_lo_frac == 1'b1);
  wire        a_lo_inf  = (a_lo_exp == 2'b11) && (a_lo_frac == 1'b0);
  wire        a_lo_zero = (a_lo_exp == 2'b00) && (a_lo_frac == 1'b0);
  wire        a_lo_sub  = (a_lo_exp == 2'b00) && (a_lo_frac == 1'b1);
  wire signed [5:0] a_lo_exp_unbias =
      (a_lo_zero || a_lo_nan || a_lo_inf) ? 6'sd0 :
      (a_lo_sub ? -6'sd1 : (a_lo_exp == 2'b01) ? 6'sd0 : 6'sd1);
  wire [1:0] a_lo_mant =
      (a_lo_zero || a_lo_nan || a_lo_inf) ? 2'd0 :
      (a_lo_sub ? 2'b10 : {1'b1, a_lo_frac});

  wire        a_hi_sign = a_hi4[3];
  wire [1:0]  a_hi_exp  = a_hi4[2:1];
  wire        a_hi_frac = a_hi4[0];
  wire        a_hi_nan  = (a_hi_exp == 2'b11) && (a_hi_frac == 1'b1);
  wire        a_hi_inf  = (a_hi_exp == 2'b11) && (a_hi_frac == 1'b0);
  wire        a_hi_zero = (a_hi_exp == 2'b00) && (a_hi_frac == 1'b0);
  wire        a_hi_sub  = (a_hi_exp == 2'b00) && (a_hi_frac == 1'b1);
  wire signed [5:0] a_hi_exp_unbias =
      (a_hi_zero || a_hi_nan || a_hi_inf) ? 6'sd0 :
      (a_hi_sub ? -6'sd1 : (a_hi_exp == 2'b01) ? 6'sd0 : 6'sd1);
  wire [1:0] a_hi_mant =
      (a_hi_zero || a_hi_nan || a_hi_inf) ? 2'd0 :
      (a_hi_sub ? 2'b10 : {1'b1, a_hi_frac});

  // --------------------------------------------------------------------------
  // Shared FP16 operand classification
  // --------------------------------------------------------------------------
  wire        b_sign    = b_fp16[15];
  wire [4:0]  b_exp     = b_fp16[14:10];
  wire [9:0]  b_frac    = b_fp16[9:0];
  wire        b_is_nan  = (b_exp == 5'h1F) && (b_frac != 10'd0);
  wire        b_is_inf  = (b_exp == 5'h1F) && (b_frac == 10'd0);
  wire        b_is_zero = (b_exp == 5'd0);
  wire [10:0] man_b_eff = b_is_zero ? 11'd0 : {1'b1, b_frac};
  wire signed [11:0] b_unbias = $signed({1'b0, b_exp}) - 12'sd15;

  // --------------------------------------------------------------------------
  // Stage S1: pack mantissas and capture metadata
  // --------------------------------------------------------------------------
  reg [26:0] man_a_packed_s1;
  reg [17:0] man_b_packed_s1;
  reg signed [11:0] exp_lo_s1, exp_hi_s1;
  reg        sign_lo_s1, sign_hi_s1;
  reg        a_lo_zero_s1, a_hi_zero_s1;
  reg        a_lo_nan_s1,  a_hi_nan_s1;
  reg        a_lo_inf_s1,  a_hi_inf_s1;
  reg        b_zero_s1, b_nan_s1, b_inf_s1;
  reg [15:0] c_lo_s1, c_hi_s1;

  always @(posedge clk) begin
    man_a_packed_s1 <= {10'd0, a_hi_mant, 13'd0, a_lo_mant};
    man_b_packed_s1 <= {7'd0, man_b_eff};

    exp_lo_s1 <= (a_lo_zero || a_lo_nan || a_lo_inf || b_is_zero || b_is_nan)
                 ? 12'sd0 : ({{6{a_lo_exp_unbias[5]}}, a_lo_exp_unbias} + b_unbias);
    exp_hi_s1 <= (a_hi_zero || a_hi_nan || a_hi_inf || b_is_zero || b_is_nan)
                 ? 12'sd0 : ({{6{a_hi_exp_unbias[5]}}, a_hi_exp_unbias} + b_unbias);

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

    c_lo_s1 <= c_fp16[15:0];
    c_hi_s1 <= c_fp16[31:16];
  end

  // --------------------------------------------------------------------------
  // DSP multiply (shared for both lanes)
  // --------------------------------------------------------------------------
  wire [44:0] product45;
  (* use_dsp = "yes" *)
  dsp_usage u_dsp (
    .clk    (clk),
    .a      (man_a_packed_s1),
    .b      (man_b_packed_s1),
    .product(product45)
  );

  wire [12:0] man_lo_mul_raw = product45[12:0];
  wire [12:0] man_hi_mul_raw = product45[27:15];

  // --------------------------------------------------------------------------
  // Stage S2: capture products and metadata
  // --------------------------------------------------------------------------
  reg [21:0] man_lo_mul_s2, man_hi_mul_s2;
  reg signed [11:0] exp_lo_s2, exp_hi_s2;
  reg        sign_lo_s2, sign_hi_s2;
  reg        a_lo_zero_s2, a_hi_zero_s2;
  reg        a_lo_nan_s2,  a_hi_nan_s2;
  reg        a_lo_inf_s2,  a_hi_inf_s2;
  reg        b_zero_s2, b_nan_s2, b_inf_s2;
  reg [15:0] c_lo_s2, c_hi_s2;

  always @(posedge clk) begin
    man_lo_mul_s2 <= {man_lo_mul_raw, 9'd0};
    man_hi_mul_s2 <= {man_hi_mul_raw, 9'd0};

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
  end

  // --------------------------------------------------------------------------
  // Stage S3: compose FP16 products per lane
  // --------------------------------------------------------------------------
  wire any_nan_lo = a_lo_nan_s2 | b_nan_s2 |
                    ((a_lo_inf_s2 & b_zero_s2) | (a_lo_zero_s2 & b_inf_s2));
  wire any_nan_hi = a_hi_nan_s2 | b_nan_s2 |
                    ((a_hi_inf_s2 & b_zero_s2) | (a_hi_zero_s2 & b_inf_s2));

  wire any_inf_lo = a_lo_inf_s2 | b_inf_s2;
  wire any_inf_hi = a_hi_inf_s2 | b_inf_s2;

  wire [15:0] prod_lo16_w = lane_fp16_mul_result(
                              man_lo_mul_s2,
                              exp_lo_s2,
                              sign_lo_s2,
                              a_lo_zero_s2,
                              b_zero_s2,
                              any_nan_lo,
                              any_inf_lo);

  wire [15:0] prod_hi16_w = lane_fp16_mul_result(
                              man_hi_mul_s2,
                              exp_hi_s2,
                              sign_hi_s2,
                              a_hi_zero_s2,
                              b_zero_s2,
                              any_nan_hi,
                              any_inf_hi);

  // --------------------------------------------------------------------------
  // Stage S4: FP16 adders (3-stage modules) and final packing
  // --------------------------------------------------------------------------
  wire [15:0] sum_lo16;
  wire [15:0] sum_hi16;

  fp16_add u_add_lo (
    .clk    (clk),
    .x16    (prod_lo16_w),
    .y16    (c_lo_s2),
    .result (sum_lo16)
  );

  fp16_add u_add_hi (
    .clk    (clk),
    .x16    (prod_hi16_w),
    .y16    (c_hi_s2),
    .result (sum_hi16)
  );

  assign result = {sum_hi16, sum_lo16};

  // --------------------------------------------------------------------------
  // Helper: compose FP16 product with RN-even rounding
  // --------------------------------------------------------------------------
  function automatic [15:0] lane_fp16_mul_result;
    input      [21:0] mul22;
    input signed [11:0] exp_unbiased_in;
    input               sign;
    input               a_is_zero;
    input               b_is_zero;
    input               any_is_nan;
    input               any_is_inf;
    reg         leading2;
    reg signed [12:0] exp_norm;
    reg signed [12:0] exp_biased;
    reg [21:0]  norm22;
    reg [10:0]  mant_pre;
    reg         guard, round_bit, sticky, lsb;
    reg [11:0]  mant_round;
    reg signed [12:0] exp_final;
    reg [10:0]  mant_final;
    reg         mant_carry;
    begin
      if (any_is_nan || (any_is_inf && (a_is_zero || b_is_zero))) begin
        lane_fp16_mul_result = QNAN16;
      end else if (any_is_inf) begin
        lane_fp16_mul_result = {sign, 5'h1F, 10'd0};
      end else if (a_is_zero || b_is_zero) begin
        lane_fp16_mul_result = {sign, 15'd0};
      end else begin
        leading2  = mul22[21];
        norm22    = leading2 ? (mul22 >> 1) : mul22;
        exp_norm  = exp_unbiased_in + (leading2 ? 13'sd1 : 13'sd0);
        exp_biased= exp_norm + 13'sd15;

        if (exp_biased >= 13'sd31) begin
          lane_fp16_mul_result = {sign, 5'h1F, 10'd0};
        end else if (exp_biased <= 13'sd0) begin
          lane_fp16_mul_result = {sign, 15'd0};
        end else begin
          mant_pre   = norm22[20:10];
          guard      = norm22[9];
          round_bit  = norm22[8];
          sticky     = |norm22[7:0];
          lsb        = mant_pre[0];
          mant_round = {1'b0, mant_pre} + {11'd0, (guard & (round_bit | sticky | lsb))};
          mant_carry = mant_round[11];
          mant_final = mant_carry ? 11'b10000000000 : mant_round[10:0];
          exp_final  = exp_biased + (mant_carry ? 13'sd1 : 13'sd0);

          if (exp_final >= 13'sd31) begin
            lane_fp16_mul_result = {sign, 5'h1F, 10'd0};
          end else begin
            lane_fp16_mul_result = {sign, exp_final[4:0], mant_final[9:0]};
          end
        end
      end
    end
  endfunction
endmodule

`default_nettype wire
