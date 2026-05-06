`timescale 1ns/1ps
`default_nettype none

// =============================================================
// int8_fp16_32_mac : Dual-lane INT8 * FP16 + FP32 -> FP32
//   - Shares a single DSP by packing two INT8 lanes
//   - Latency = 4 cycles, II = 1
// =============================================================
module int8_fp16_32_mac (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  localparam [31:0] QNAN32 = 32'h7FC0_0000;
  localparam [15:0] QNAN16 = 16'h7E00;

  // Decode INT8 lanes to sign/zero/unbiased exponent/compact mantissa
  wire [12:0] lo_dec = int8_decode(a16[7:0]);
  wire [12:0] hi_dec = int8_decode(a16[15:8]);

  wire        a_lo_sign = lo_dec[12];
  wire        a_lo_zero = lo_dec[11];
  wire [3:0]  a_lo_exp_u = lo_dec[10:7]; // unbiased exponent (0..7)
  wire [6:0]  a_lo_mant7 = lo_dec[6:0];  // 1.6 format mantissa

  wire        a_hi_sign = hi_dec[12];
  wire        a_hi_zero = hi_dec[11];
  wire [3:0]  a_hi_exp_u = hi_dec[10:7];
  wire [6:0]  a_hi_mant7 = hi_dec[6:0];

  // Shared FP16 operand classification
  wire        b_sign   = b16[15];
  wire [4:0]  b_exp    = b16[14:10];
  wire [9:0]  b_frac   = b16[9:0];
  wire        b_is_nan = (b_exp == 5'h1F) && (b_frac != 10'd0);
  wire        b_is_inf = (b_exp == 5'h1F) && (b_frac == 10'd0);
  wire        b_is_zero= (b_exp == 5'd0);
  wire [10:0] man_b_eff = b_is_zero ? 11'd0 : {1'b1, b_frac};

  // ------------------------- Stage S1 -------------------------
  reg [26:0] man_a_packed_s1;
  reg [17:0] man_b_packed_s1;
  reg signed [11:0] exp_lo_s1, exp_hi_s1;
  reg        sign_lo_s1, sign_hi_s1;
  reg        a_lo_zero_s1, a_hi_zero_s1;
  reg        b_zero_s1, b_nan_s1, b_inf_s1;
  reg [31:0] c_lo_s1, c_hi_s1;

  always @(posedge clk) begin
    man_a_packed_s1 <= {2'b00, a_hi_mant7, 11'd0, a_lo_mant7};
    man_b_packed_s1 <= {7'd0, man_b_eff};

    exp_lo_s1 <= (a_lo_zero || b_is_zero) ? 12'sd0 :
                 ($signed({8'd0, a_lo_exp_u}) + ($signed({1'b0, b_exp}) - 12'sd15));
    exp_hi_s1 <= (a_hi_zero || b_is_zero) ? 12'sd0 :
                 ($signed({8'd0, a_hi_exp_u}) + ($signed({1'b0, b_exp}) - 12'sd15));

    sign_lo_s1 <= a_lo_sign ^ b_sign;
    sign_hi_s1 <= a_hi_sign ^ b_sign;

    a_lo_zero_s1 <= a_lo_zero;
    a_hi_zero_s1 <= a_hi_zero;
    b_zero_s1    <= b_is_zero;
    b_nan_s1     <= b_is_nan;
    b_inf_s1     <= b_is_inf;

    c_lo_s1 <= c64[31:0];
    c_hi_s1 <= c64[63:32];
  end

  // ------------------------- DSP multiply -------------------------
  wire [44:0] product45;
  dsp_usage u_dsp (
    .clk    (clk),
    .a      (man_a_packed_s1),
    .b      (man_b_packed_s1),
    .product(product45)
  );

  // ------------------------- Stage S2 -------------------------
  reg signed [11:0] exp_lo_s2, exp_hi_s2;
  reg        sign_lo_s2, sign_hi_s2;
  reg        a_lo_zero_s2, a_hi_zero_s2;
  reg        b_zero_s2, b_nan_s2, b_inf_s2;
  reg [31:0] c_lo_s2, c_hi_s2;
  reg [21:0] man_lo_mul_s2, man_hi_mul_s2;
  wire [17:0] man_lo_mul_raw = product45[17:0];
  wire [17:0] man_hi_mul_raw = product45[35:18];

  always @(posedge clk) begin
    exp_lo_s2  <= exp_lo_s1;
    exp_hi_s2  <= exp_hi_s1;
    sign_lo_s2 <= sign_lo_s1;
    sign_hi_s2 <= sign_hi_s1;

    a_lo_zero_s2 <= a_lo_zero_s1;
    a_hi_zero_s2 <= a_hi_zero_s1;
    b_zero_s2    <= b_zero_s1;
    b_nan_s2     <= b_nan_s1;
    b_inf_s2     <= b_inf_s1;

    c_lo_s2 <= c_lo_s1;
    c_hi_s2 <= c_hi_s1;

    // Restore the 4 fractional guard bits dropped during DSP packing (mantissa * 16)
    man_lo_mul_s2 <= {man_lo_mul_raw, 4'b0000};
    man_hi_mul_s2 <= {man_hi_mul_raw, 4'b0000};
  end

  // ------------------------- Stage S3 -------------------------
  wire [31:0] prod_lo32_w = lane_fp16_mul_to_fp32(
                              man_lo_mul_s2,
                              exp_lo_s2,
                              sign_lo_s2,
                              a_lo_zero_s2,
                              b_zero_s2,
                              b_nan_s2,
                              b_inf_s2);

  wire [31:0] prod_hi32_w = lane_fp16_mul_to_fp32(
                              man_hi_mul_s2,
                              exp_hi_s2,
                              sign_hi_s2,
                              a_hi_zero_s2,
                              b_zero_s2,
                              b_nan_s2,
                              b_inf_s2);

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
  // Helpers
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
          sig_ext = {norm22, 3'b000}; // append zeros to align 23-bit mantissa
          sig24   = sig_ext[23:0];
          lane_fp16_mul_to_fp32 = {sign, exp_biased[7:0], sig24[22:0]};
        end
      end
    end
  endfunction

  function automatic [15:0] int8_to_fp16;
    input [7:0] x;
    reg        sign;
    reg [7:0]  mag;
    reg [4:0]  exp_fp16;
    reg [9:0]  frac_fp16;
    reg [17:0] mant_shift;
    reg [17:0] mant_norm;
    integer    k;
    begin
      sign = x[7];
      mag  = sign ? (~x + 8'd1) : x;
      if (mag == 8'd0) begin
        int8_to_fp16 = {sign, 15'd0};
      end else begin
        casex (mag)
          8'b1???????: k = 7;
          8'b01??????: k = 6;
          8'b001?????: k = 5;
          8'b0001????: k = 4;
          8'b00001???: k = 3;
          8'b000001??: k = 2;
          8'b0000001?: k = 1;
          default:      k = 0;
        endcase
        exp_fp16   = k + 5'd15;
        mant_shift = mag << (10 - k);
        mant_norm  = mant_shift - 18'd1024;
        frac_fp16  = mant_norm[9:0];
        int8_to_fp16 = {sign, exp_fp16, frac_fp16};
      end
    end
  endfunction

  // Compact decode: sign | zero | exponent | mant7
  function automatic [12:0] int8_decode;
    input [7:0] x;
    reg        sign;
    reg [7:0]  mag;
    reg        zero;
    reg [3:0]  exp_u;
    reg [6:0]  mant7;
    integer    k;
    reg [13:0] numer;
    reg [13:0] quotient;
    reg [13:0] remainder;
    reg        round_up;
    reg [7:0]  mant_ext;
    begin
      sign = x[7];
      mag  = sign ? (~x + 8'd1) : x;
      zero = (mag == 8'd0);
      exp_u = 4'd0;
      mant7 = 7'd0;

      if (!zero) begin
        casex (mag)
          8'b1???????: k = 7;
          8'b01??????: k = 6;
          8'b001?????: k = 5;
          8'b0001????: k = 4;
          8'b00001???: k = 3;
          8'b000001??: k = 2;
          8'b0000001?: k = 1;
          default:      k = 0;
        endcase
        exp_u = k[3:0];

        numer = {mag, 6'd0}; // mag * 64
        if (k == 0) begin
          quotient  = numer;
          remainder = 14'd0;
        end else begin
          quotient  = numer >> k;
          remainder = numer & ((14'd1 << k) - 14'd1);
        end
        if (quotient > 14'd127)
          quotient = 14'd127;

        if (k == 0) begin
          round_up = 1'b0;
        end else begin
          round_up = (remainder > (14'd1 << (k-1))) ||
                     ((remainder == (14'd1 << (k-1))) && quotient[0]);
        end

        mant_ext = {1'b0, quotient[6:0]} + {7'd0, round_up};
        if (mant_ext[7]) begin
          mant_ext = {1'b0, mant_ext[7:1]};
          if (exp_u != 4'd7)
            exp_u = exp_u + 4'd1;
        end
        if (~mant_ext[6])
          mant_ext[6] = 1'b1;
        mant7 = mant_ext[6:0];
      end

      int8_decode = {sign, zero, exp_u, mant7};
    end
  endfunction
endmodule

`default_nettype wire
