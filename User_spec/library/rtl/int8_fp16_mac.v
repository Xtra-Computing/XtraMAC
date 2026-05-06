`timescale 1ns/1ps
`default_nettype none

// =============================================================
// int8_fp16_mac : Dual-lane INT8 * FP16 + FP16 -> FP16
//   - Converts INT8 lanes to FP16 once (combinational)
//   - Packs two 11-bit mantissas into one DSP48 A-port with leading zero
//   - Latency = 4 cycles, II = 1 (compatible with fp16_mac)
// =============================================================
module int8_fp16_mac (
    input  wire        clk,
    input  wire [15:0] a16,   // packed INT8 lanes {HI[15:8], LO[7:0]}
    input  wire [15:0] b16,   // shared FP16 multiplicand
    input  wire [31:0] c32,   // FP16 addends {HI, LO}
    output wire [31:0] result // FP16 outputs {HI, LO}
);
  localparam [15:0] QNAN16 = 16'h7E00;

  // --------------------------------------------------------------------------
  // Lane conversion: INT8 -> FP16 (exact, matches golden path)
  // --------------------------------------------------------------------------
  wire [12:0] lo_dec = int8_decode(a16[7:0]);
  wire [12:0] hi_dec = int8_decode(a16[15:8]);

  wire        a_lo_sign = lo_dec[12];
  wire        a_lo_zero = lo_dec[11];
  wire [3:0]  exp_lo_unbias = lo_dec[10:7];
  wire [6:0]  mant_lo7 = lo_dec[6:0];

  wire        a_hi_sign = hi_dec[12];
  wire        a_hi_zero = hi_dec[11];
  wire [3:0]  exp_hi_unbias = hi_dec[10:7];
  wire [6:0]  mant_hi7 = hi_dec[6:0];

  // --------------------------------------------------------------------------
  // Shared FP16 operand classification
  // --------------------------------------------------------------------------
  wire        b_sign   = b16[15];
  wire [4:0]  b_exp    = b16[14:10];
  wire [9:0]  b_frac   = b16[9:0];
  wire        b_is_nan = (b_exp == 5'h1F) && (b_frac != 10'd0);
  wire        b_is_inf = (b_exp == 5'h1F) && (b_frac == 10'd0);
  wire        b_is_zero= (b_exp == 5'd0);

  wire [10:0] man_b_eff = b_is_zero ? 11'd0 : {1'b1, b_frac};
  wire signed [11:0] b_unbias = $signed({1'b0, b_exp}) - 12'sd15;

  // --------------------------------------------------------------------------
  // S1 registers: pack mantissas / exponent sums / metadata
  // --------------------------------------------------------------------------
  reg [26:0] man_a_packed_s1;
  reg [17:0] man_b_packed_s1;

  reg signed [11:0] exp_hi_s1, exp_lo_s1;
  reg        sign_hi_s1, sign_lo_s1;

  reg        a_hi_zero_s1, a_lo_zero_s1;
  reg        b_zero_s1, b_nan_s1, b_inf_s1;

  reg [15:0] c_hi_s1, c_lo_s1;

  always @(posedge clk) begin
    // Layout: { 0, man_hi[6:0], gap[11:0], man_lo[6:0] }
    man_a_packed_s1 <= {2'b00, mant_hi7, 11'd0, mant_lo7};
    man_b_packed_s1 <= {7'd0, man_b_eff};

    exp_hi_s1 <= (a_hi_zero || b_is_zero) ? 12'sd0 :
                 ($signed({8'd0, exp_hi_unbias}) + b_unbias);
    exp_lo_s1 <= (a_lo_zero || b_is_zero) ? 12'sd0 :
                 ($signed({8'd0, exp_lo_unbias}) + b_unbias);

    sign_hi_s1 <= a_hi_sign ^ b_sign;
    sign_lo_s1 <= a_lo_sign ^ b_sign;

    a_hi_zero_s1 <= a_hi_zero;
    a_lo_zero_s1 <= a_lo_zero;
    b_zero_s1    <= b_is_zero;
    b_nan_s1     <= b_is_nan;
    b_inf_s1     <= b_is_inf;

    c_hi_s1 <= c32[31:16];
    c_lo_s1 <= c32[15:0];

  end

  // --------------------------------------------------------------------------
  // DSP multiply (shared for both lanes)
  // --------------------------------------------------------------------------
  wire [44:0] product45;

  dsp_usage u_dsp (
    .clk    (clk),
    .a      (man_a_packed_s1),
    .b      (man_b_packed_s1),
    .product(product45)
  );

  // --------------------------------------------------------------------------
  // S2 registers: capture DSP product + propagate metadata
  // --------------------------------------------------------------------------
  reg [44:0] prod_s2;
  reg signed [11:0] exp_hi_s2, exp_lo_s2;
  reg        sign_hi_s2, sign_lo_s2;
  reg        a_hi_zero_s2, a_lo_zero_s2;
  reg        b_zero_s2, b_nan_s2, b_inf_s2;
  reg [15:0] c_hi_s2, c_lo_s2;

  always @(posedge clk) begin
    prod_s2    <= product45;

    exp_hi_s2   <= exp_hi_s1;
    exp_lo_s2   <= exp_lo_s1;
    sign_hi_s2  <= sign_hi_s1;
    sign_lo_s2  <= sign_lo_s1;

    a_hi_zero_s2 <= a_hi_zero_s1;
    a_lo_zero_s2 <= a_lo_zero_s1;
    b_zero_s2    <= b_zero_s1;
    b_nan_s2     <= b_nan_s1;
    b_inf_s2     <= b_inf_s1;

    c_hi_s2 <= c_hi_s1;
    c_lo_s2 <= c_lo_s1;
  end

  // --------------------------------------------------------------------------
  // S3: compose FP16 products per lane
  // --------------------------------------------------------------------------
  wire [17:0] man_lo_mul = prod_s2[17:0];
  wire [17:0] man_hi_mul = prod_s2[35:18];

  wire [21:0] prod_lo_mul_full = {man_lo_mul, 4'b0000};
  wire [21:0] prod_hi_mul_full = {man_hi_mul, 4'b0000};

  wire [15:0] prod_lo16_w = lane_fp16_mul_result(
                              prod_lo_mul_full,
                              exp_lo_s2,
                              sign_lo_s2,
                              a_lo_zero_s2,
                              b_zero_s2,
                              b_nan_s2,
                              b_inf_s2);

  wire [15:0] prod_hi16_w = lane_fp16_mul_result(
                              prod_hi_mul_full,
                              exp_hi_s2,
                              sign_hi_s2,
                              a_hi_zero_s2,
                              b_zero_s2,
                              b_nan_s2,
                              b_inf_s2);

  // --------------------------------------------------------------------------
  // FP16 Adders (2-stage each)
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
  // Lane helper: compose FP16 product with RN-even rounding
  // --------------------------------------------------------------------------
  function automatic [15:0] lane_fp16_mul_result;
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
    reg [10:0]  mant_pre;
    reg         guard, round_bit, sticky, lsb;
    reg [11:0]  mant_round;
    reg signed [12:0] exp_final;
    reg [10:0]  mant_final;
    reg         mant_carry;
    begin
      if (b_is_nan || (b_is_inf && (a_is_zero || b_is_zero))) begin
        lane_fp16_mul_result = QNAN16;
      end else if (b_is_inf) begin
        lane_fp16_mul_result = {sign, 5'h1F, 10'd0};
      end else if (a_is_zero || b_is_zero) begin
        lane_fp16_mul_result = {sign, 15'd0};
      end else begin
        leading2 = mul22[21];
        norm22   = leading2 ? (mul22 >> 1) : mul22;
        exp_norm = exp_unbiased_in + (leading2 ? 13'sd1 : 13'sd0);
        exp_biased = exp_norm + 13'sd15;

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

  // --------------------------------------------------------------------------
  // Helper: INT8 decode -> {sign, is_zero, exponent (0..7), mantissa (1.6 bits)}
  // --------------------------------------------------------------------------
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
