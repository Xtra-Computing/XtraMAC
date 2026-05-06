`timescale 1ns/1ps
`default_nettype none

// =============================================================
// int_fp16_mac_2lane : 2-lane INT(WIDTH) x FP16 + FP16 -> FP16
//   Parameterized integer width (2..8).  Two INT lanes are packed
//   in a16[WIDTH-1:0] (lo) and a16[2*WIDTH-1:WIDTH] (hi).
//   DSP packing: A={2'b0, mant_hi7, 11'b0, mant_lo7}, B={7'b0, man_b_eff}
//   MUL_LAT  = 1 (pack+DSP in one stage) or 2 (pack | DSP+capture)
//   MID_STAGES = extra pipeline between mul compose and add
//   ADD_LAT  = 2 or 3 (fp16_add latency)
// =============================================================
module int_fp16_mac_2lane #(
    parameter integer WIDTH      = 8,   // integer operand width (2..8)
    parameter integer MUL_LAT    = 1,   // 1 or 2
    parameter integer MID_STAGES = 0,
    parameter integer ADD_LAT    = 3
) (
    input  wire        clk,
    input  wire [15:0] a16,     // packed INT lanes {HI, LO}
    input  wire [15:0] b16,     // shared FP16 multiplicand
    input  wire [31:0] c32,     // FP16 addends {HI, LO}
    output wire [31:0] result   // FP16 outputs {HI, LO}
);
  localparam [15:0] QNAN16 = 16'h7E00;

  // --------------------------------------------------------------------------
  // INT -> FP16 decode (same as int8_fp16_mac)
  // --------------------------------------------------------------------------
  function automatic [12:0] int_decode;
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

        numer = {mag, 6'd0};
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

      int_decode = {sign, zero, exp_u, mant7};
    end
  endfunction

  // Sign-extend narrow int to 8 bits
  wire [7:0] a_lo_ext = {{(8-WIDTH){a16[WIDTH-1]}}, a16[WIDTH-1:0]};
  wire [7:0] a_hi_ext = {{(8-WIDTH){a16[2*WIDTH-1]}}, a16[2*WIDTH-1:WIDTH]};

  wire [12:0] lo_dec = int_decode(a_lo_ext);
  wire [12:0] hi_dec = int_decode(a_hi_ext);

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
  // Lane FP16 product compose (RN-even) -- shared function
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
  // Pipeline
  // --------------------------------------------------------------------------
  localparam integer TOTAL_MUL = MUL_LAT; // 1 or 2 register stages in mul path

  generate
  if (MUL_LAT == 1) begin : gen_mul1
    // ====================================================================
    // MUL_LAT=1 : S1 registers pack mantissas + metadata, DSP runs
    //             combinationally from S1 regs, products composed same cycle
    // ====================================================================
    reg [26:0] man_a_packed_s1;
    reg [17:0] man_b_packed_s1;
    reg signed [11:0] exp_hi_s1, exp_lo_s1;
    reg        sign_hi_s1, sign_lo_s1;
    reg        a_hi_zero_s1, a_lo_zero_s1;
    reg        b_zero_s1, b_nan_s1, b_inf_s1;
    reg [15:0] c_hi_s1, c_lo_s1;

    always @(posedge clk) begin
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

    wire [44:0] product45;
    dsp_usage u_dsp (
      .clk    (clk),
      .a      (man_a_packed_s1),
      .b      (man_b_packed_s1),
      .product(product45)
    );

    wire [17:0] man_lo_mul = product45[17:0];
    wire [17:0] man_hi_mul = product45[35:18];
    wire [21:0] prod_lo_mul_full = {man_lo_mul, 4'b0000};
    wire [21:0] prod_hi_mul_full = {man_hi_mul, 4'b0000};

    wire [15:0] prod_lo16_raw = lane_fp16_mul_result(
                                prod_lo_mul_full, exp_lo_s1, sign_lo_s1,
                                a_lo_zero_s1, b_zero_s1, b_nan_s1, b_inf_s1);
    wire [15:0] prod_hi16_raw = lane_fp16_mul_result(
                                prod_hi_mul_full, exp_hi_s1, sign_hi_s1,
                                a_hi_zero_s1, b_zero_s1, b_nan_s1, b_inf_s1);

    // Mid-stage pipeline
    reg [15:0] prod_lo_mid [0:MID_STAGES];
    reg [15:0] prod_hi_mid [0:MID_STAGES];
    reg [15:0] c_lo_mid    [0:MID_STAGES];
    reg [15:0] c_hi_mid    [0:MID_STAGES];
    always @(*) begin
      prod_lo_mid[0] = prod_lo16_raw;
      prod_hi_mid[0] = prod_hi16_raw;
      c_lo_mid[0]    = c_lo_s1;
      c_hi_mid[0]    = c_hi_s1;
    end

    genvar gm;
    for (gm = 1; gm <= MID_STAGES; gm = gm + 1) begin : gen_mid
      always @(posedge clk) begin
        prod_lo_mid[gm] <= prod_lo_mid[gm-1];
        prod_hi_mid[gm] <= prod_hi_mid[gm-1];
        c_lo_mid[gm]    <= c_lo_mid[gm-1];
        c_hi_mid[gm]    <= c_hi_mid[gm-1];
      end
    end

    wire [15:0] prod_lo_final = prod_lo_mid[MID_STAGES];
    wire [15:0] prod_hi_final = prod_hi_mid[MID_STAGES];
    wire [15:0] c_lo_final    = c_lo_mid[MID_STAGES];
    wire [15:0] c_hi_final    = c_hi_mid[MID_STAGES];

    wire [15:0] sum_lo16, sum_hi16;

    fp16_add #(.LATENCY(ADD_LAT)) u_add_lo (
      .clk(clk), .x16(prod_lo_final), .y16(c_lo_final), .result(sum_lo16)
    );
    fp16_add #(.LATENCY(ADD_LAT)) u_add_hi (
      .clk(clk), .x16(prod_hi_final), .y16(c_hi_final), .result(sum_hi16)
    );

    assign result = {sum_hi16, sum_lo16};

  end else begin : gen_mul2
    // ====================================================================
    // MUL_LAT=2 : S1 pack | S2 DSP capture + product compose
    // ====================================================================
    reg [26:0] man_a_packed_s1;
    reg [17:0] man_b_packed_s1;
    reg signed [11:0] exp_hi_s1, exp_lo_s1;
    reg        sign_hi_s1, sign_lo_s1;
    reg        a_hi_zero_s1, a_lo_zero_s1;
    reg        b_zero_s1, b_nan_s1, b_inf_s1;
    reg [15:0] c_hi_s1, c_lo_s1;

    always @(posedge clk) begin
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

    wire [44:0] product45;
    dsp_usage u_dsp (
      .clk    (clk),
      .a      (man_a_packed_s1),
      .b      (man_b_packed_s1),
      .product(product45)
    );

    // S2 registers
    reg [44:0] prod_s2;
    reg signed [11:0] exp_hi_s2, exp_lo_s2;
    reg        sign_hi_s2, sign_lo_s2;
    reg        a_hi_zero_s2, a_lo_zero_s2;
    reg        b_zero_s2, b_nan_s2, b_inf_s2;
    reg [15:0] c_hi_s2, c_lo_s2;

    always @(posedge clk) begin
      prod_s2    <= product45;
      exp_hi_s2  <= exp_hi_s1;
      exp_lo_s2  <= exp_lo_s1;
      sign_hi_s2 <= sign_hi_s1;
      sign_lo_s2 <= sign_lo_s1;
      a_hi_zero_s2 <= a_hi_zero_s1;
      a_lo_zero_s2 <= a_lo_zero_s1;
      b_zero_s2    <= b_zero_s1;
      b_nan_s2     <= b_nan_s1;
      b_inf_s2     <= b_inf_s1;
      c_hi_s2 <= c_hi_s1;
      c_lo_s2 <= c_lo_s1;
    end

    wire [17:0] man_lo_mul = prod_s2[17:0];
    wire [17:0] man_hi_mul = prod_s2[35:18];
    wire [21:0] prod_lo_mul_full = {man_lo_mul, 4'b0000};
    wire [21:0] prod_hi_mul_full = {man_hi_mul, 4'b0000};

    wire [15:0] prod_lo16_raw = lane_fp16_mul_result(
                                prod_lo_mul_full, exp_lo_s2, sign_lo_s2,
                                a_lo_zero_s2, b_zero_s2, b_nan_s2, b_inf_s2);
    wire [15:0] prod_hi16_raw = lane_fp16_mul_result(
                                prod_hi_mul_full, exp_hi_s2, sign_hi_s2,
                                a_hi_zero_s2, b_zero_s2, b_nan_s2, b_inf_s2);

    // Mid-stage pipeline
    reg [15:0] prod_lo_mid [0:MID_STAGES];
    reg [15:0] prod_hi_mid [0:MID_STAGES];
    reg [15:0] c_lo_mid    [0:MID_STAGES];
    reg [15:0] c_hi_mid    [0:MID_STAGES];
    always @(*) begin
      prod_lo_mid[0] = prod_lo16_raw;
      prod_hi_mid[0] = prod_hi16_raw;
      c_lo_mid[0]    = c_lo_s2;
      c_hi_mid[0]    = c_hi_s2;
    end

    genvar gm;
    for (gm = 1; gm <= MID_STAGES; gm = gm + 1) begin : gen_mid
      always @(posedge clk) begin
        prod_lo_mid[gm] <= prod_lo_mid[gm-1];
        prod_hi_mid[gm] <= prod_hi_mid[gm-1];
        c_lo_mid[gm]    <= c_lo_mid[gm-1];
        c_hi_mid[gm]    <= c_hi_mid[gm-1];
      end
    end

    wire [15:0] prod_lo_final = prod_lo_mid[MID_STAGES];
    wire [15:0] prod_hi_final = prod_hi_mid[MID_STAGES];
    wire [15:0] c_lo_final    = c_lo_mid[MID_STAGES];
    wire [15:0] c_hi_final    = c_hi_mid[MID_STAGES];

    wire [15:0] sum_lo16, sum_hi16;

    fp16_add #(.LATENCY(ADD_LAT)) u_add_lo (
      .clk(clk), .x16(prod_lo_final), .y16(c_lo_final), .result(sum_lo16)
    );
    fp16_add #(.LATENCY(ADD_LAT)) u_add_hi (
      .clk(clk), .x16(prod_hi_final), .y16(c_hi_final), .result(sum_hi16)
    );

    assign result = {sum_hi16, sum_lo16};
  end
  endgenerate

endmodule

`default_nettype wire
