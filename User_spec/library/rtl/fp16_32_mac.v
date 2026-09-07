`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp16_32_mac : FP16 * FP16 + FP32 -> FP32
//   Latency = 4 cycles (M1-M2 + A1-A2), II = 1
// =============================================================
module fp16_32_mac (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [31:0] c32,
    output wire [31:0] result
);
  wire [31:0] prod32_w;

  // Align C with 2-cycle multiplier latency
  reg [31:0] c32_d1, c32_d2;
  always @(posedge clk) begin
    c32_d1 <= c32;
    c32_d2 <= c32_d1;
  end

  fp16x16_to_fp32_mul u_mul32 (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .prod32(prod32_w)
  );

  fp32_add u_add32 (
    .clk   (clk),
    .x32   (prod32_w),
    .y32   (c32_d2),
    .result(result)
  );
endmodule

// =============================================================
// fp16_class : Unpack/classify FP16 (FTZ/DAZ for subnormals)
// =============================================================
module fp16_class (
  input  wire [15:0] x,
  output wire        s,
  output wire [4:0]  e,
  output wire [9:0]  f,
  output wire        is_nan,
  output wire        is_inf,
  output wire        is_zero
);
  assign s = x[15];
  assign e = x[14:10];
  assign f = x[9:0];
  assign is_nan  = (e==5'h1F) && (f!=10'd0);
  assign is_inf  = (e==5'h1F) && (f==10'd0);
  assign is_zero = (e==5'd0); // FTZ/DAZ
endmodule

// =============================================================
// fp16x16_to_fp32_mul : 2-stage FP16×FP16 -> FP32 (RN-even)
//   - Handles NaN/Inf/Zero precedence; FTZ/DAZ on inputs
//   - Latency: 2 cycles, II=1
// =============================================================
module fp16x16_to_fp32_mul (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    output reg  [31:0] prod32
);
  localparam [31:0] QNAN32 = 32'h7FC0_0000;

  // Unpack/classify
  wire sa, sb;
  wire [4:0] ea, eb;
  wire [9:0] fa, fb;
  wire a_nan, a_inf, a_zero, b_nan, b_inf, b_zero;

  fp16_class ca(.x(a16), .s(sa), .e(ea), .f(fa), .is_nan(a_nan), .is_inf(a_inf), .is_zero(a_zero));
  fp16_class cb(.x(b16), .s(sb), .e(eb), .f(fb), .is_nan(b_nan), .is_inf(b_inf), .is_zero(b_zero));

  // -------- Stage M1 registers --------
  reg        s1_sign;
  reg [5:0]  s1_ea_eff, s1_eb_eff;       // 0 if zero (FTZ), else exponent
  reg [10:0] s1_ma_eff, s1_mb_eff;       // 0 if zero, else {1, frac}
  reg        s1_has_nan, s1_has_inf, s1_has_zero, s1_inf_and_zero;

  always @(posedge clk) begin
    s1_sign   <= sa ^ sb;
    s1_ea_eff <= a_zero ? 6'd0 : {1'b0, ea};
    s1_eb_eff <= b_zero ? 6'd0 : {1'b0, eb};
    s1_ma_eff <= a_zero ? 11'd0 : {1'b1, fa};
    s1_mb_eff <= b_zero ? 11'd0 : {1'b1, fb};

    s1_has_nan      <= (a_nan | b_nan);
    s1_has_inf      <= (a_inf | b_inf);
    s1_has_zero     <= (a_zero | b_zero);
    s1_inf_and_zero <= (a_inf | b_inf) & (a_zero | b_zero); // Inf*0 -> NaN
  end

  // -------- Stage M2: multiply, normalize, round, pack FP32 --------
  wire [21:0] mul22 = s1_ma_eff * s1_mb_eff;

  // Exponent in FP16 unbiased domain
  // Subtract both FP16 biases (15 each) to enter the unbiased domain
  wire signed [9:0] e_sum_16 = $signed({1'b0,s1_ea_eff}) + $signed({1'b0,s1_eb_eff}) - 10'sd30;

  // Normalize to [1,2)
  wire        leading2 = mul22[21];
  wire [21:0] norm_sig = leading2 ? (mul22 >> 1) : mul22;
  wire signed [9:0] e_norm_16 = leading2 ? (e_sum_16 + 10'sd1) : e_sum_16;

  // Map to FP32 biased
  wire signed [10:0] e32_unclamped = e_norm_16 + 10'sd127;

  // Exact map to 1+23 bits; FP16 product has 20 fractional bits so append 3 zeros
  wire [24:0] sig_ext = {norm_sig, 3'b000};
  wire [23:0] sig24   = sig_ext[23:0];
  wire        guard   = 1'b0;
  wire        sticky  = 1'b0;

  // RN-even
  wire        lsb = sig24[0];
  wire        round_inc = guard & (sticky | lsb);
  wire [24:0] sig_round_wide = {1'b0, sig24} + {24'd0, round_inc};
  wire        sig_ovf = sig_round_wide[24];
  wire [23:0] sig_rounded = sig_ovf ? 24'h800000 : sig_round_wide[23:0];
  wire signed [10:1] dummy_unused = 10'sd0; // avoid tool warnings
  wire signed [10:0] e32_rounded = sig_ovf ? (e32_unclamped + 11'sd1) : e32_unclamped;

  wire overflow   = (e32_rounded >= 11'sd255);
  wire underflow0 = (e32_rounded <= 11'sd0);

  wire is_nan  = s1_has_nan | s1_inf_and_zero;
  wire is_inf  = ~is_nan & s1_has_inf & ~s1_has_zero;
  wire is_zero = ~is_nan & ~is_inf & (s1_has_zero | underflow0);

  wire [31:0] finite_out = { s1_sign, e32_rounded[7:0], sig_rounded[22:0] };

  always @(posedge clk) begin
    prod32 <= is_nan            ? QNAN32 :
              (is_inf|overflow) ? {s1_sign, 8'hFF, 23'd0} :
              is_zero           ? {s1_sign, 31'd0} :
                                  finite_out;
  end
endmodule

// =============================================================
// fp32_add : 2-stage FP32 adder (RN-even)
//   - Stage A1: classify/order/align/addsub (preserve G/R/S)
//   - Stage A2: normalize/round/pack (FTZ on subnormal result)
//   - DAZ on inputs (exp==0 treated as zero)
//   - Latency: 2 cycles, II=1
// =============================================================
module fp32_add #(
    parameter SATURATE_ON_MAX = 1'b1,
    parameter INF_CANCELLATION_TO_NAN = 1'b1
) (
    input  wire        clk,
    input  wire [31:0] x32,
    input  wire [31:0] y32,
    output reg  [31:0] result
);
  localparam [31:0] QNAN32 = 32'h7FC0_0000;

  // helpers
  function is_nan32;  input [31:0] x; begin is_nan32 = (x[30:23]==8'hFF) && (x[22:0]!=23'd0); end endfunction
  function is_inf32;  input [31:0] x; begin is_inf32 = (x[30:23]==8'hFF) && (x[22:0]==23'd0); end endfunction
  function is_zero32; input [31:0] x; begin is_zero32= (x[30:23]==8'd0); end endfunction

  // CLZ up to 26 bits
  function [4:0] clz26;
    input [25:0] v;
    reg  [12:0] hi; reg [12:0] lo;
    reg  [3:0]  clz13_hi, clz13_lo;
    begin
      hi = v[25:13]; lo = v[12:0];
      clz13_hi =
        (hi[12])?4'd0:(hi[11])?4'd1:(hi[10])?4'd2:(hi[9])?4'd3:(hi[8])?4'd4:
        (hi[7])?4'd5:(hi[6])?4'd6:(hi[5])?4'd7:(hi[4])?4'd8:(hi[3])?4'd9:
        (hi[2])?4'd10:(hi[1])?4'd11:(hi[0])?4'd12:4'd13;
      clz13_lo =
        (lo[12])?4'd0:(lo[11])?4'd1:(lo[10])?4'd2:(lo[9])?4'd3:(lo[8])?4'd4:
        (lo[7])?4'd5:(lo[6])?4'd6:(lo[5])?4'd7:(lo[4])?4'd8:(lo[3])?4'd9:
        (lo[2])?4'd10:(lo[1])?4'd11:(lo[0])?4'd12:4'd13;
      clz26 = (hi!=13'd0) ? {1'b0, clz13_hi} : (5'd13 + {1'b0, clz13_lo});
    end
  endfunction

  // Unpack
  wire sx = x32[31]; wire [7:0] ex = x32[30:23]; wire [22:0] fx = x32[22:0];
  wire sy = y32[31]; wire [7:0] ey = y32[30:23]; wire [22:0] fy = y32[22:0];

  wire x_nan=is_nan32(x32), y_nan=is_nan32(y32);
  wire x_inf=is_inf32(x32), y_inf=is_inf32(y32);
  wire x_zero=is_zero32(x32), y_zero=is_zero32(y32);

  // DAZ on inputs
  wire [8:0]  Ex_eff = x_zero ? 9'd0 : {1'b0, ex};
  wire [8:0]  Ey_eff = y_zero ? 9'd0 : {1'b0, ey};
  wire [23:0] Mx_eff = x_zero ? 24'd0 : {1'b1, fx};
  wire [23:0] My_eff = y_zero ? 24'd0 : {1'b1, fy};

  // Order by magnitude
  wire swap0 = (Ex_eff < Ey_eff) || ((Ex_eff==Ey_eff) && (Mx_eff < My_eff));
  wire        sbig  = swap0 ? sy      : sx;
  wire        ssml  = swap0 ? sx      : sy;
  wire [8:0]  Ebig  = swap0 ? Ey_eff  : Ex_eff;
  wire [8:0]  Esml  = swap0 ? Ex_eff  : Ey_eff;
  wire [23:0] Mbig  = swap0 ? My_eff  : Mx_eff;
  wire [23:0] Msml  = swap0 ? Mx_eff  : My_eff;
  wire        diff_sign = (sbig ^ ssml);

  // Special cases
  wire inf_cancel_cneg  = INF_CANCELLATION_TO_NAN ? (swap0 & y_inf & sy & ~x_inf & ~ssml) : 1'b0;
  wire special_nan      = x_nan | y_nan | ((x_inf & y_inf) & (sx^sy)) | inf_cancel_cneg; // inf - inf (+ special cases)
  wire special_inf      = ~special_nan & ( (x_inf & ~y_nan & ~y_inf) |
                                           (y_inf & ~x_nan & ~x_inf) |
                                           (x_inf & y_inf & ~(sx^sy)) );
  wire special_inf_sign = (x_inf & ~y_inf) ? sx : (y_inf & ~x_inf) ? sy : sbig;
  wire both_zero        = x_zero & y_zero;
  wire zero_sign_both   = (sx & sy); // -0 only if both -0

  wire big_is_maxnorm   = (Ebig == 9'd254) && (Mbig == 24'hFFFFFF);
  wire small_has_mag    = (Msml != 24'd0);
  wire sat_add_to_inf_raw = ~special_nan & ~special_inf & ~both_zero &
                            ~diff_sign & big_is_maxnorm & small_has_mag;
  wire sat_add_to_inf   = SATURATE_ON_MAX ? sat_add_to_inf_raw : 1'b0;

  // -------- Stage A1: align with GRS and add/sub (combinational) --------
  // 27-bit lanes: {carry, 24-bit mant, G,R,S} = 1 + 24 + 2 = 27
  wire [8:0]  shamt0      = (Ebig > Esml) ? (Ebig - Esml) : 9'd0;
  wire [5:0]  shamt       = (shamt0 > 9'd27) ? 6'd27 : shamt0[5:0];

  wire [26:0] Big_ext     = {1'b0, Mbig, 3'b000};
  wire [26:0] Sml_ext_pre = {1'b0, Msml, 3'b000};

  // Compute sticky of bits shifted out using a mask (legal in Verilog-2001)
  wire [26:0] dropped_mask = (shamt==6'd0) ? 27'd0 : (27'h7FFFFFF >> (27 - shamt));
  wire        sticky_sml   = |(Sml_ext_pre & dropped_mask);

  wire [26:0] Sml_shift    = (shamt==6'd0) ? Sml_ext_pre : (Sml_ext_pre >> shamt);
  wire [26:0] Sml_ext      = { Sml_shift[26:1], (Sml_shift[0] | sticky_sml) };

  wire [27:0] Sum_ext      = diff_sign ? ({1'b0, Big_ext} - {1'b0, Sml_ext})
                                       : ({1'b0, Big_ext} + {1'b0, Sml_ext});

  // -------- Stage A1 registers --------
  reg        r_short_nan, r_short_inf, r_short_inf_sign, r_both_zero, r_zero_sign_both;
  reg        r_sign_big, r_diff_sign, r_sat_add_inf;
  reg [8:0]  r_Ebig;
  reg [27:0] r_sum28;

  always @(posedge clk) begin
    r_short_nan        <= special_nan;
    r_short_inf        <= special_inf;
    r_short_inf_sign   <= special_inf_sign;
    r_both_zero        <= both_zero;
    r_zero_sign_both   <= zero_sign_both;

    r_sign_big  <= sbig;
    r_diff_sign <= diff_sign;
    if (SATURATE_ON_MAX) begin
      r_sat_add_inf <= sat_add_to_inf;
    end else begin
      r_sat_add_inf <= 1'b0;
    end
    r_Ebig      <= Ebig;
    r_sum28     <= Sum_ext;
  end

  // -------- Stage A2: normalize/round/pack --------
  wire        add_carry = ~r_diff_sign & r_sum28[27];
  wire [27:0] sumC_wide = add_carry ? {1'b0, r_sum28[27:2], (r_sum28[1] | r_sum28[0])} : r_sum28;
  wire [26:0] sumC      = sumC_wide[26:0];
  wire [8:0]  En        = add_carry ? (r_Ebig + 9'd1) : r_Ebig;

  // Count leading zeros on 25-bit lane (1 + 24)
  wire [24:0] lane25   = sumC[26:2];
  wire [4:0]  lz       = clz26({lane25,1'b0});
  wire        zero_af  = (lane25==25'd0) | (En <= lz);

  wire [26:0] laneN    = zero_af ? 27'd0 : (sumC << lz);
  wire [8:0]  E_l      = zero_af ? 9'd0  : (En - lz);

  // Extract mantissa and G/R/S after left normalization
  wire [23:0] mant_trunc = laneN[26:3];
  wire        guardF     = laneN[2];
  wire        roundF     = laneN[1];
  wire        stickyF    = laneN[0];

  // RN-even (ties to even)
  wire        lsb_bit    = mant_trunc[0];
  wire        round_inc  = guardF & ((roundF | stickyF) | lsb_bit);
  wire [24:0] mant_wide  = {1'b0, mant_trunc} + {24'd0, round_inc};
  wire        mant_ovf   = mant_wide[24];
  wire [23:0] mant_round = mant_ovf ? 24'h800000 : mant_wide[23:0];
  wire [8:0]  E_round    = mant_ovf ? (E_l + 9'd1) : E_l;

  // Overflow/underflow and pack
  wire overflow_pack  = (E_round >= 9'd255) | (SATURATE_ON_MAX ? r_sat_add_inf : 1'b0);
  wire under_or_zero  = (E_round==9'd0) | (mant_round==24'd0);

  wire [31:0] finite_out= {r_sign_big, E_round[7:0], mant_round[22:0]};

  always @(posedge clk) begin
    if (r_short_nan) begin
      result <= QNAN32;
    end else if (r_short_inf) begin
      result <= {r_short_inf_sign, 8'hFF, 23'd0};
    end else if (r_both_zero) begin
      result <= {r_zero_sign_both, 31'd0};
    end else begin
      result <= overflow_pack ? {r_sign_big, 8'hFF, 23'd0} :
                under_or_zero ? 32'h0000_0000 :
                                finite_out;
    end
  end
endmodule

`default_nettype wire
