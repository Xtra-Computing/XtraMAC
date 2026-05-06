`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp32_add : Parameterized FP32 adder (RN-even)
//   - Stage A1: classify/order/align/addsub (preserve G/R/S)
//   - Stage A2: normalize/round/pack (FTZ on subnormal result)
//   - DAZ on inputs (exp==0 treated as zero)
//   - LATENCY: 2 cycles (default) or 3 cycles (extra output reg)
//   - II = 1
// =============================================================
module fp32_add #(
    parameter LATENCY              = 2,   // 2 or 3
    parameter SATURATE_ON_MAX      = 1'b1,
    parameter INF_CANCELLATION_TO_NAN = 1'b1
)(
    input  wire        clk,
    input  wire [31:0] x32,
    input  wire [31:0] y32,
    output wire [31:0] result
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
  wire special_nan      = x_nan | y_nan | ((x_inf & y_inf) & (sx^sy)) | inf_cancel_cneg;
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
  wire [5:0]  shamt0      = (Ebig > Esml) ? (Ebig - Esml) : 6'd0;
  wire [5:0]  shamt       = (shamt0 > 6'd27) ? 6'd27 : shamt0;

  wire [26:0] Big_ext     = {Mbig, 3'b000};
  wire [26:0] Sml_ext_pre = {Msml, 3'b000};

  // Compute sticky of bits shifted out
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
    r_sat_add_inf <= SATURATE_ON_MAX ? sat_add_to_inf : 1'b0;
    r_Ebig      <= Ebig;
    r_sum28     <= Sum_ext;
  end

  // -------- Stage A2: normalize/round/pack --------
  wire        add_carry = ~r_diff_sign & r_sum28[27];
  wire [27:0] sumC_wide = add_carry ? (r_sum28 >> 1) : r_sum28;
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

  // A2 result (combinational before optional output reg)
  reg [31:0] a2_result;
  always @(*) begin
    if (r_short_nan)
      a2_result = QNAN32;
    else if (r_short_inf)
      a2_result = {r_short_inf_sign, 8'hFF, 23'd0};
    else if (r_both_zero)
      a2_result = {r_zero_sign_both, 31'd0};
    else if (overflow_pack)
      a2_result = {r_sign_big, 8'hFF, 23'd0};
    else if (under_or_zero)
      a2_result = 32'h0000_0000;
    else
      a2_result = finite_out;
  end

  // -------- Output stage: LATENCY=2 vs 3 --------
  generate
    if (LATENCY <= 2) begin : gen_lat2
      reg [31:0] result_r;
      always @(posedge clk) begin
        result_r <= a2_result;
      end
      assign result = result_r;
    end else begin : gen_lat3
      reg [31:0] result_r1, result_r2;
      always @(posedge clk) begin
        result_r1 <= a2_result;
        result_r2 <= result_r1;
      end
      assign result = result_r2;
    end
  endgenerate

endmodule
`default_nettype wire
