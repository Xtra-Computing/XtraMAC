`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp8e5m2_fp16_mac_2lane : 2-lane FP8(E5M2) x FP16 + FP16 -> FP16
//   DSP packing: A={9'b0, a_hi_mant3, 12'b0, a_lo_mant3}, B={7'b0, man_b_eff}
//   Product windows: lo=[13:0], hi=[28:15]  (14-bit each)
//   Promoted to Q2.20 by appending 8 fractional zeros
// =============================================================
module fp8e5m2_fp16_mac_2lane #(
    parameter integer MUL_LAT    = 1,
    parameter integer MID_STAGES = 0,
    parameter integer ADD_LAT    = 3
) (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [31:0] c32,
    output wire [31:0] result
);
  localparam [15:0] QNAN16 = 16'h7E00;

  // ---- FP8 E5M2 decode ----
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

  // ---- FP16 B ----
  wire        b_sign    = b16[15];
  wire [4:0]  b_exp     = b16[14:10];
  wire [9:0]  b_frac    = b16[9:0];
  wire        b_is_nan  = (b_exp == 5'h1F) && (b_frac != 10'd0);
  wire        b_is_inf  = (b_exp == 5'h1F) && (b_frac == 10'd0);
  wire        b_is_zero = (b_exp == 5'd0);
  wire [10:0] man_b_eff = b_is_zero ? 11'd0 : {1'b1, b_frac};
  wire signed [11:0] b_unbias = $signed({1'b0, b_exp}) - 12'sd15;

  // ---- Shared compose function ----
  function automatic [15:0] lane_fp16_mul_result;
    input [21:0] mul22;
    input signed [11:0] exp_unbiased_in;
    input sign, a_is_zero, b_is_zero, any_is_nan, any_is_inf;
    reg leading2;
    reg signed [12:0] exp_norm, exp_biased, exp_final;
    reg [21:0] norm22;
    reg [10:0] mant_pre, mant_final;
    reg guard, round_bit, sticky, lsb, mant_carry;
    reg [11:0] mant_round;
    begin
      if (any_is_nan || (any_is_inf && (a_is_zero || b_is_zero)))
        lane_fp16_mul_result = QNAN16;
      else if (any_is_inf)
        lane_fp16_mul_result = {sign, 5'h1F, 10'd0};
      else if (a_is_zero || b_is_zero)
        lane_fp16_mul_result = {sign, 15'd0};
      else begin
        leading2   = mul22[21];
        norm22     = leading2 ? (mul22 >> 1) : mul22;
        exp_norm   = exp_unbiased_in + (leading2 ? 13'sd1 : 13'sd0);
        exp_biased = exp_norm + 13'sd15;
        if (exp_biased >= 13'sd31)
          lane_fp16_mul_result = {sign, 5'h1F, 10'd0};
        else if (exp_biased <= 13'sd0)
          lane_fp16_mul_result = {sign, 15'd0};
        else begin
          mant_pre   = norm22[20:10];
          guard      = norm22[9];
          round_bit  = norm22[8];
          sticky     = |norm22[7:0];
          lsb        = mant_pre[0];
          mant_round = {1'b0, mant_pre} + {11'd0, (guard & (round_bit | sticky | lsb))};
          mant_carry = mant_round[11];
          mant_final = mant_carry ? 11'b10000000000 : mant_round[10:0];
          exp_final  = exp_biased + (mant_carry ? 13'sd1 : 13'sd0);
          if (exp_final >= 13'sd31)
            lane_fp16_mul_result = {sign, 5'h1F, 10'd0};
          else
            lane_fp16_mul_result = {sign, exp_final[4:0], mant_final[9:0]};
        end
      end
    end
  endfunction

  // --------------------------------------------------------------------------
  generate
  if (MUL_LAT == 1) begin : gen_mul1
    reg [26:0] man_a_packed_s1;
    reg [17:0] man_b_packed_s1;
    reg signed [11:0] exp_lo_s1, exp_hi_s1;
    reg sign_lo_s1, sign_hi_s1;
    reg a_lo_zero_s1, a_hi_zero_s1, a_lo_nan_s1, a_hi_nan_s1, a_lo_inf_s1, a_hi_inf_s1;
    reg b_zero_s1, b_nan_s1, b_inf_s1;
    reg [15:0] c_lo_s1, c_hi_s1;

    always @(posedge clk) begin
      man_a_packed_s1 <= {9'd0, a_hi_mant, 12'd0, a_lo_mant};
      man_b_packed_s1 <= {7'd0, man_b_eff};
      exp_lo_s1 <= (a_lo_zero||a_lo_nan||a_lo_inf||b_is_zero||b_is_nan) ? 12'sd0 : (a_lo_exp_unbias+b_unbias);
      exp_hi_s1 <= (a_hi_zero||a_hi_nan||a_hi_inf||b_is_zero||b_is_nan) ? 12'sd0 : (a_hi_exp_unbias+b_unbias);
      sign_lo_s1<=a_lo_sign^b_sign; sign_hi_s1<=a_hi_sign^b_sign;
      a_lo_zero_s1<=a_lo_zero; a_hi_zero_s1<=a_hi_zero;
      a_lo_nan_s1<=a_lo_nan;   a_hi_nan_s1<=a_hi_nan;
      a_lo_inf_s1<=a_lo_inf;   a_hi_inf_s1<=a_hi_inf;
      b_zero_s1<=b_is_zero; b_nan_s1<=b_is_nan; b_inf_s1<=b_is_inf;
      c_lo_s1<=c32[15:0]; c_hi_s1<=c32[31:16];
    end

    wire [44:0] product45;
    dsp_usage u_dsp (.clk(clk),.a(man_a_packed_s1),.b(man_b_packed_s1),.product(product45));

    wire [21:0] man_lo_mul = {product45[13:0], 8'd0};
    wire [21:0] man_hi_mul = {product45[28:15], 8'd0};

    wire [15:0] plo_raw = lane_fp16_mul_result(man_lo_mul, exp_lo_s1, sign_lo_s1,
        a_lo_zero_s1, b_zero_s1, b_nan_s1|a_lo_nan_s1, b_inf_s1|a_lo_inf_s1);
    wire [15:0] phi_raw = lane_fp16_mul_result(man_hi_mul, exp_hi_s1, sign_hi_s1,
        a_hi_zero_s1, b_zero_s1, b_nan_s1|a_hi_nan_s1, b_inf_s1|a_hi_inf_s1);

    reg [15:0] plo_m[0:MID_STAGES], phi_m[0:MID_STAGES], clo_m[0:MID_STAGES], chi_m[0:MID_STAGES];
    always @(*) begin plo_m[0]=plo_raw; phi_m[0]=phi_raw; clo_m[0]=c_lo_s1; chi_m[0]=c_hi_s1; end
    genvar gm;
    for (gm=1;gm<=MID_STAGES;gm=gm+1) begin:gen_mid
      always @(posedge clk) begin plo_m[gm]<=plo_m[gm-1]; phi_m[gm]<=phi_m[gm-1]; clo_m[gm]<=clo_m[gm-1]; chi_m[gm]<=chi_m[gm-1]; end
    end

    wire [15:0] slo, shi;
    fp16_add #(.LATENCY(ADD_LAT)) u_add_lo (.clk(clk),.x16(plo_m[MID_STAGES]),.y16(clo_m[MID_STAGES]),.result(slo));
    fp16_add #(.LATENCY(ADD_LAT)) u_add_hi (.clk(clk),.x16(phi_m[MID_STAGES]),.y16(chi_m[MID_STAGES]),.result(shi));
    assign result = {shi, slo};

  end else begin : gen_mul2
    reg [26:0] man_a_packed_s1; reg [17:0] man_b_packed_s1;
    reg signed [11:0] exp_lo_s1, exp_hi_s1;
    reg sign_lo_s1, sign_hi_s1;
    reg a_lo_zero_s1, a_hi_zero_s1, a_lo_nan_s1, a_hi_nan_s1, a_lo_inf_s1, a_hi_inf_s1;
    reg b_zero_s1, b_nan_s1, b_inf_s1;
    reg [15:0] c_lo_s1, c_hi_s1;

    always @(posedge clk) begin
      man_a_packed_s1<={9'd0,a_hi_mant,12'd0,a_lo_mant}; man_b_packed_s1<={7'd0,man_b_eff};
      exp_lo_s1<=(a_lo_zero||a_lo_nan||a_lo_inf||b_is_zero||b_is_nan)?12'sd0:(a_lo_exp_unbias+b_unbias);
      exp_hi_s1<=(a_hi_zero||a_hi_nan||a_hi_inf||b_is_zero||b_is_nan)?12'sd0:(a_hi_exp_unbias+b_unbias);
      sign_lo_s1<=a_lo_sign^b_sign; sign_hi_s1<=a_hi_sign^b_sign;
      a_lo_zero_s1<=a_lo_zero; a_hi_zero_s1<=a_hi_zero;
      a_lo_nan_s1<=a_lo_nan; a_hi_nan_s1<=a_hi_nan;
      a_lo_inf_s1<=a_lo_inf; a_hi_inf_s1<=a_hi_inf;
      b_zero_s1<=b_is_zero; b_nan_s1<=b_is_nan; b_inf_s1<=b_is_inf;
      c_lo_s1<=c32[15:0]; c_hi_s1<=c32[31:16];
    end

    wire [44:0] product45;
    dsp_usage u_dsp (.clk(clk),.a(man_a_packed_s1),.b(man_b_packed_s1),.product(product45));

    reg signed [11:0] exp_lo_s2, exp_hi_s2;
    reg sign_lo_s2, sign_hi_s2;
    reg a_lo_zero_s2, a_hi_zero_s2, a_lo_nan_s2, a_hi_nan_s2, a_lo_inf_s2, a_hi_inf_s2;
    reg b_zero_s2, b_nan_s2, b_inf_s2;
    reg [15:0] c_lo_s2, c_hi_s2;
    reg [21:0] man_lo_s2, man_hi_s2;

    always @(posedge clk) begin
      exp_lo_s2<=exp_lo_s1; exp_hi_s2<=exp_hi_s1;
      sign_lo_s2<=sign_lo_s1; sign_hi_s2<=sign_hi_s1;
      a_lo_zero_s2<=a_lo_zero_s1; a_hi_zero_s2<=a_hi_zero_s1;
      a_lo_nan_s2<=a_lo_nan_s1; a_hi_nan_s2<=a_hi_nan_s1;
      a_lo_inf_s2<=a_lo_inf_s1; a_hi_inf_s2<=a_hi_inf_s1;
      b_zero_s2<=b_zero_s1; b_nan_s2<=b_nan_s1; b_inf_s2<=b_inf_s1;
      c_lo_s2<=c_lo_s1; c_hi_s2<=c_hi_s1;
      man_lo_s2<={product45[13:0],8'd0}; man_hi_s2<={product45[28:15],8'd0};
    end

    wire [15:0] plo_raw = lane_fp16_mul_result(man_lo_s2, exp_lo_s2, sign_lo_s2,
        a_lo_zero_s2, b_zero_s2, b_nan_s2|a_lo_nan_s2, b_inf_s2|a_lo_inf_s2);
    wire [15:0] phi_raw = lane_fp16_mul_result(man_hi_s2, exp_hi_s2, sign_hi_s2,
        a_hi_zero_s2, b_zero_s2, b_nan_s2|a_hi_nan_s2, b_inf_s2|a_hi_inf_s2);

    reg [15:0] plo_m[0:MID_STAGES], phi_m[0:MID_STAGES], clo_m[0:MID_STAGES], chi_m[0:MID_STAGES];
    always @(*) begin plo_m[0]=plo_raw; phi_m[0]=phi_raw; clo_m[0]=c_lo_s2; chi_m[0]=c_hi_s2; end
    genvar gm;
    for (gm=1;gm<=MID_STAGES;gm=gm+1) begin:gen_mid
      always @(posedge clk) begin plo_m[gm]<=plo_m[gm-1]; phi_m[gm]<=phi_m[gm-1]; clo_m[gm]<=clo_m[gm-1]; chi_m[gm]<=chi_m[gm-1]; end
    end

    wire [15:0] slo, shi;
    fp16_add #(.LATENCY(ADD_LAT)) u_add_lo (.clk(clk),.x16(plo_m[MID_STAGES]),.y16(clo_m[MID_STAGES]),.result(slo));
    fp16_add #(.LATENCY(ADD_LAT)) u_add_hi (.clk(clk),.x16(phi_m[MID_STAGES]),.y16(chi_m[MID_STAGES]),.result(shi));
    assign result = {shi, slo};
  end
  endgenerate

endmodule

`default_nettype wire
