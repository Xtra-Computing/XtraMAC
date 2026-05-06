`timescale 1ns/1ps
`default_nettype none

module fp4e2m1_bf16_mac (
    input  wire        clk,
    input  wire [7:0]  a_fp4,    // {hi[7:4], lo[3:0]} FP4 (E2M1) lanes
    input  wire [15:0] b_bf16,   // shared BF16 multiplicand
    input  wire [31:0] c_bf16,   // BF16 addends {hi, lo}
    output reg  [31:0] result    // registered at S4
);
  localparam [15:0] QNAN_BF16 = 16'h7FC0;

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
  // Shared BF16 operand classification
  // --------------------------------------------------------------------------
  wire        b_sign    = b_bf16[15];
  wire [7:0]  b_exp     = b_bf16[14:7];
  wire [6:0]  b_frac    = b_bf16[6:0];
  wire        b_is_nan  = (b_exp == 8'hFF) && (b_frac != 7'd0);
  wire        b_is_inf  = (b_exp == 8'hFF) && (b_frac == 7'd0);
  wire        b_is_zero = (b_exp == 8'd0);
  wire [7:0]  man_b_eff = b_is_zero ? 8'd0 : {1'b1, b_frac};
  wire signed [10:0] b_unbias = $signed({1'b0, b_exp}) - 11'sd127;

  // --------------------------------------------------------------------------
  // Stage S1: pack mantissas and capture metadata
  // --------------------------------------------------------------------------
  reg [26:0] man_a_packed_s1;
  reg [17:0] man_b_packed_s1;
  reg signed [10:0] exp_lo_s1, exp_hi_s1;
  reg        sign_lo_s1, sign_hi_s1;
  reg        a_lo_zero_s1, a_hi_zero_s1;
  reg        a_lo_nan_s1,  a_hi_nan_s1;
  reg        a_lo_inf_s1,  a_hi_inf_s1;
  reg        b_zero_s1, b_nan_s1, b_inf_s1;
  reg [15:0] c_lo_s1, c_hi_s1;

  always @(posedge clk) begin
    man_a_packed_s1 <= {10'd0, a_hi_mant, 13'd0, a_lo_mant};
    man_b_packed_s1 <= {10'd0, man_b_eff};

    exp_lo_s1 <= (a_lo_zero || a_lo_nan || a_lo_inf || b_is_zero || b_is_nan)
                 ? 11'sd0 : ({{5{a_lo_exp_unbias[5]}}, a_lo_exp_unbias} + b_unbias);
    exp_hi_s1 <= (a_hi_zero || a_hi_nan || a_hi_inf || b_is_zero || b_is_nan)
                 ? 11'sd0 : ({{5{a_hi_exp_unbias[5]}}, a_hi_exp_unbias} + b_unbias);

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

    c_lo_s1 <= c_bf16[15:0];
    c_hi_s1 <= c_bf16[31:16];
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

  wire [9:0] man_lo_mul_raw = product45[9:0];
  wire [9:0] man_hi_mul_raw = product45[24:15];

  // --------------------------------------------------------------------------
  // Stage S2: capture products and metadata
  // --------------------------------------------------------------------------
  reg [21:0] man_lo_mul_s2, man_hi_mul_s2;
  reg signed [10:0] exp_lo_s2, exp_hi_s2;
  reg        sign_lo_s2, sign_hi_s2;
  reg        a_lo_zero_s2, a_hi_zero_s2;
  reg        a_lo_nan_s2,  a_hi_nan_s2;
  reg        a_lo_inf_s2,  a_hi_inf_s2;
  reg        b_zero_s2, b_nan_s2, b_inf_s2;
  reg [15:0] c_lo_s2, c_hi_s2;

  always @(posedge clk) begin
    man_lo_mul_s2 <= {man_lo_mul_raw, 12'd0};
    man_hi_mul_s2 <= {man_hi_mul_raw, 12'd0};

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
  // Stage S3: compose BF16 products per lane
  // --------------------------------------------------------------------------
  wire any_nan_lo = a_lo_nan_s2 | b_nan_s2 |
                    ((a_lo_inf_s2 & b_zero_s2) | (a_lo_zero_s2 & b_inf_s2));
  wire any_nan_hi = a_hi_nan_s2 | b_nan_s2 |
                    ((a_hi_inf_s2 & b_zero_s2) | (a_hi_zero_s2 & b_inf_s2));

  wire any_inf_lo = a_lo_inf_s2 | b_inf_s2;
  wire any_inf_hi = a_hi_inf_s2 | b_inf_s2;

  wire [15:0] prod_lo16_w = lane_bf16_mul_result(
                              man_lo_mul_s2,
                              exp_lo_s2,
                              sign_lo_s2,
                              a_lo_zero_s2,
                              b_zero_s2,
                              any_nan_lo,
                              any_inf_lo);

  wire [15:0] prod_hi16_w = lane_bf16_mul_result(
                              man_hi_mul_s2,
                              exp_hi_s2,
                              sign_hi_s2,
                              a_hi_zero_s2,
                              b_zero_s2,
                              any_nan_hi,
                              any_inf_hi);

  // --------------------------------------------------------------------------
  // Stage S4: BF16 adders + output register
  // --------------------------------------------------------------------------
  wire [15:0] sum_lo16;
  wire [15:0] sum_hi16;

  bf16_add u_add_lo (
    .clk (clk),
    .a16 (prod_lo16_w),
    .b16 (c_lo_s2),
    .c16 (sum_lo16)
  );

  bf16_add u_add_hi (
    .clk (clk),
    .a16 (prod_hi16_w),
    .b16 (c_hi_s2),
    .c16 (sum_hi16)
  );

  always @(posedge clk) begin
    result <= {sum_hi16, sum_lo16};
  end

  // --------------------------------------------------------------------------
  // Helper: compose BF16 product with RN-even rounding
  // --------------------------------------------------------------------------
  function automatic [15:0] lane_bf16_mul_result;
    input      [21:0] mul22;
    input signed [10:0] exp_unbiased_in;
    input               sign;
    input               a_is_zero;
    input               b_is_zero;
    input               any_is_nan;
    input               any_is_inf;
    reg         leading2;
    reg signed [11:0] exp_norm;
    reg signed [11:0] exp_biased;
    reg [21:0]  norm22;
    reg [7:0]   mant_pre;
    reg         guard, round_bit, sticky, lsb;
    reg [8:0]   mant_round;
    reg signed [11:0] exp_final;
    reg [7:0]   mant_final;
    reg         mant_carry;
    begin
      if (any_is_nan || (any_is_inf && (a_is_zero || b_is_zero))) begin
        lane_bf16_mul_result = QNAN_BF16;
      end else if (any_is_inf) begin
        lane_bf16_mul_result = {sign, 8'hFF, 7'd0};
      end else if (a_is_zero || b_is_zero) begin
        lane_bf16_mul_result = {sign, 15'd0};
      end else begin
        leading2   = mul22[21];
        norm22     = leading2 ? (mul22 >> 1) : mul22;
        exp_norm   = exp_unbiased_in + (leading2 ? 12'sd1 : 12'sd0);
        exp_biased = exp_norm + 12'sd127;

        if (exp_biased >= 12'sd255) begin
          lane_bf16_mul_result = {sign, 8'hFF, 7'd0};
        end else if (exp_biased <= 12'sd0) begin
          lane_bf16_mul_result = {sign, 15'd0};
        end else begin
          mant_pre   = norm22[20:13];
          guard      = norm22[12];
          round_bit  = norm22[11];
          sticky     = |norm22[10:0];
          lsb        = mant_pre[0];
          mant_round = {1'b0, mant_pre} + {8'd0, (guard & (round_bit | sticky | lsb))};
          mant_carry = mant_round[8];
          mant_final = mant_carry ? 8'b1000_0000 : mant_round[7:0];
          exp_final  = exp_biased + (mant_carry ? 12'sd1 : 12'sd0);

          if (exp_final >= 12'sd255) begin
            lane_bf16_mul_result = {sign, 8'hFF, 7'd0};
          end else begin
            lane_bf16_mul_result = {sign, exp_final[7:0], mant_final[6:0]};
          end
        end
      end
    end
  endfunction
endmodule


module bf16_add (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    output wire [15:0] c16    // wire (comb S4)
);
  // ---- helpers ----
  function is_nan;
    input [15:0] x;
    begin is_nan = (x[14:7]==8'hFF) && (x[6:0]!=7'd0); end
  endfunction

  function is_inf;
    input [15:0] x;
    begin is_inf = (x[14:7]==8'hFF) && (x[6:0]==7'd0); end
  endfunction

  function is_zero; // FTZ for inputs: subnormals count as zero
    input [15:0] x;
    begin is_zero = (x[14:7]==8'd0); end
  endfunction

  // CLZ for 9-bit lane (0..9; 9 means zero)
  function [3:0] clz9;
      input [8:0] x;
      begin
          casex (x)
              9'b1xxxxxxxx: clz9 = 4'd0;
              9'b01xxxxxxx: clz9 = 4'd1;
              9'b001xxxxxx: clz9 = 4'd2;
              9'b0001xxxxx: clz9 = 4'd3;
              9'b00001xxxx: clz9 = 4'd4;
              9'b000001xxx: clz9 = 4'd5;
              9'b0000001xx: clz9 = 4'd6;
              9'b00000001x: clz9 = 4'd7;
              9'b000000001: clz9 = 4'd8;
              default:       clz9 = 4'd9; // zero
          endcase
      end
  endfunction

  // right shift for 8-bit mantissa (saturating to zero when sh>=8)
  function [7:0] rshift8;
      input [7:0] x; input [3:0] sh;
      begin
          case (sh)
              4'd0 :  rshift8 = x;
              4'd1 :  rshift8 = {1'b0,       x[7:1]};
              4'd2 :  rshift8 = {2'b00,      x[7:2]};
              4'd3 :  rshift8 = {3'b000,     x[7:3]};
              4'd4 :  rshift8 = {4'b0000,    x[7:4]};
              4'd5 :  rshift8 = {5'b00000,   x[7:5]};
              4'd6 :  rshift8 = {6'b000000,  x[7:6]};
              4'd7 :  rshift8 = {7'b0000000, x[7]};
              default: rshift8 = 8'b0; // sh>=8
          endcase
      end
  endfunction

  // sticky for bits shifted out by LEFT-normalization (like fp16 path)
  function sticky_from_norm9;
    input [8:0] x; input [3:0] lz; // 0..9
    reg [8:0] mask;
    begin
      mask = (lz==4'd0) ? 9'd0 : (9'h1FF >> (9 - lz));
      sticky_from_norm9 = |(x & mask);
    end
  endfunction

  localparam [15:0] QNAN16 = 16'h7FC0; // canonical qNaN for BF16 (exp=FF, frac[6]=1)

  // ====================== S3: unpack/order/classify (REG) ======================
  wire sa0 = a16[15];  wire [7:0] ea0 = a16[14:7];  wire [6:0] fa0 = a16[6:0];
  wire sb0 = b16[15];  wire [7:0] eb0 = b16[14:7];  wire [6:0] fb0 = b16[6:0];

  // classify
  wire a_is_nan  = is_nan(a16);
  wire b_is_nan  = is_nan(b16);
  wire a_is_inf  = is_inf(a16);
  wire b_is_inf  = is_inf(b16);
  wire a_is_zero = is_zero(a16); // FTZ (subnormals included)
  wire b_is_zero = is_zero(b16);

  wire special_is_nan_0 =
      a_is_nan | b_is_nan | ((a_is_inf & b_is_inf) & (sa0 ^ sb0)); // +Inf + -Inf

  wire special_is_inf_0 =
      (~special_is_nan_0) &
      ((a_is_inf & ~b_is_inf & ~b_is_nan) |
       (~a_is_inf & ~a_is_nan & b_is_inf) |
       (a_is_inf & b_is_inf & ~(sa0 ^ sb0)));

  wire special_inf_sign_0 =
      (a_is_inf & ~b_is_inf & ~b_is_nan) ? sa0 :
      (~a_is_inf & ~a_is_nan & b_is_inf) ? sb0 :
                                           sa0; // same-sign infs

  wire both_zero_0  = a_is_zero & b_is_zero;
  wire zero_sign_0  = (sa0 & sb0); // only -0 + -0 => -0

  // effective magnitudes (FTZ zeros)
  wire [8:0]  Ea0 = a_is_zero ? 9'd0 : {1'b0, ea0};
  wire [8:0]  Eb0 = b_is_zero ? 9'd0 : {1'b0, eb0};
  wire [7:0]  Ma0 = a_is_zero ? 8'd0 : {1'b1, fa0}; // 1.f
  wire [7:0]  Mb0 = b_is_zero ? 8'd0 : {1'b1, fb0};

  // order by magnitude
  wire swap0 = (Ea0 < Eb0) || ((Ea0 == Eb0) && (Ma0 < Mb0));

  wire        sign_big_1 = swap0 ? sb0 : sa0;
  wire        sign_sml_1 = swap0 ? sa0 : sb0;
  wire [8:0]  E_big_1    = swap0 ? Eb0 : Ea0;
  wire [8:0]  E_sml_1    = swap0 ? Ea0 : Eb0;
  wire [7:0]  M_big_1    = swap0 ? Mb0 : Ma0;
  wire [7:0]  M_sml_1    = swap0 ? Ma0 : Mb0;

  wire [8:0]  dE_1       = (E_big_1 >= E_sml_1) ? (E_big_1 - E_sml_1) : 9'd0;
  wire        diff_sign_1 = (sign_big_1 ^ sign_sml_1);

  // S3 latches
  reg        sign_big_r, diff_sign_r;
  reg [8:0]  E_big_r, dE_r;
  reg [7:0]  M_big_r, M_sml_r;
  reg        short_nan_r, short_inf_r, short_inf_sign_r, short_zero_r, short_zero_sign_r;

  initial begin
    sign_big_r=1'b0; diff_sign_r=1'b0;
    E_big_r=9'd0; dE_r=9'd0; M_big_r=8'd0; M_sml_r=8'd0;
    short_nan_r=1'b0; short_inf_r=1'b0; short_inf_sign_r=1'b0; short_zero_r=1'b0; short_zero_sign_r=1'b0;
  end

  always @(posedge clk) begin
    sign_big_r  <= sign_big_1;
    diff_sign_r <= diff_sign_1;
    E_big_r     <= E_big_1;
    dE_r        <= dE_1;
    M_big_r     <= M_big_1;
    M_sml_r     <= M_sml_1;

    short_nan_r       <= special_is_nan_0;
    short_inf_r       <= special_is_inf_0;
    short_inf_sign_r  <= special_inf_sign_0;
    short_zero_r      <= both_zero_0;
    short_zero_sign_r <= zero_sign_0;
  end

  // ====================== S4: align + add/sub + normalize + RN-even + pack (COMB) ======================
  // Align small to big (single guard; no alignment-sticky, to mirror fp16 design choice)
  wire [3:0] shamt         = (dE_r >= 9'd8) ? 4'd8 : dE_r[3:0];
  wire [7:0] M_sml_aligned = rshift8(M_sml_r, shamt);
  wire       guard_bit     = (shamt == 4'd0) ? 1'b0 : M_sml_r[shamt-1];

  // Add/sub with explicit guard fed into LSB
  wire [8:0] big9   = {M_big_r,        1'b0};
  wire [8:0] sml9_i = {M_sml_aligned,  guard_bit};

  wire [9:0] add_a  = {1'b0, big9};
  wire [9:0] add_bi = {1'b0, sml9_i};
  wire [9:0] add_b  = diff_sign_r ? (~add_bi + 10'd1) : add_bi;

  wire [9:0] sum10  = add_a + add_b;

  wire same_sign = ~diff_sign_r;
  wire add_carry = same_sign & sum10[9];

  // Normalize initial carry (right shift by 1 if carry & same-sign)
  wire [9:0] sumC  = add_carry ? (sum10 >> 1) : sum10;
  wire [8:0] E_n   = add_carry ? (E_big_r + 9'd1) : E_big_r;

  // Left-normalize
  wire [8:0] lane9   = sumC[8:0];
  wire [3:0] lz      = clz9(lane9);
  wire       zero_af = (lz == 4'd9) | (E_n <= lz);

  wire [8:0] laneN   = zero_af ? 9'd0 : (lane9 << lz);
  wire [8:0] E_l     = zero_af ? 9'd0 : (E_n - lz);

  // RN-even (guard/sticky derived after left-normalization, mirroring fp16)
  wire [7:0] mant_trunc = laneN[8:1];  // 1.f -> [8:1] keeps 8 bits (hidden+7 frac)
  wire       guardF     = laneN[0];
  wire       stickyF    = sticky_from_norm9(lane9, lz);

  wire       lsb_bit    = mant_trunc[0];
  wire       round_inc  = guardF & (stickyF | lsb_bit);

  wire [8:0] mant_round_wide = {1'b0, mant_trunc} + {8'd0, round_inc};
  wire       mant_ovf        = mant_round_wide[8];
  wire [7:0] mant_rounded    = mant_ovf ? 8'b1000_0000 : mant_round_wide[7:0];
  wire [8:0] E_rounded       = mant_ovf ? (E_l + 9'd1) : E_l;

  // Pack / special selections
  wire overflow_pack  = (E_rounded > 9'd255);
  wire under_or_zero  = (E_rounded == 9'd0) | (mant_rounded == 8'd0);

  wire [7:0] exp_pack  = E_rounded[7:0];
  wire [6:0] frac_pack = mant_rounded[6:0];
  wire [15:0] finite_out = {sign_big_r, exp_pack, frac_pack};

  assign c16 =
      short_nan_r       ? QNAN16 :
      short_inf_r       ? {short_inf_sign_r, 8'hFF, 7'd0} :
      short_zero_r      ? {short_zero_sign_r, 15'h0000} :
      overflow_pack     ? {sign_big_r, 8'hFF, 7'd0} :    // ±Inf on overflow
      under_or_zero     ? 16'h0000 :                     // DAZ → +0
                          finite_out;

endmodule

`default_nettype wire
