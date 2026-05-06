`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp8e4m3_fp16_fp32_mac : FP8(E4M3) x FP16 + FP32 -> FP32 (2-lane)
//   - Decodes FP8 E4M3 each lane to 4-bit mantissa + 4-bit exponent
//   - DSP-packs two lanes into one 27x18 DSP:
//       A = {8'd0, a_hi_mant4, 11'd0, a_lo_mant4}
//       B = {7'd0, man_b_eff(11)}
//     Per-lane product occupies 15 bits.
//   - Each lane composes FP32 product, then fp32_add with c addend.
// =============================================================
module fp8e4m3_fp16_fp32_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 0,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire [15:0] a16,   // packed FP8E4M3 {hi[15:8], lo[7:0]}
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  localparam [31:0] QNAN32 = 32'h7FC0_0000;

  // ---- FP8 E4M3 decode ----
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

  // ---- FP16 B classify ----
  wire        b_sign   = b16[15];
  wire [4:0]  b_exp    = b16[14:10];
  wire [9:0]  b_frac   = b16[9:0];
  wire        b_is_nan = (b_exp == 5'h1F) && (b_frac != 10'd0);
  wire        b_is_inf = (b_exp == 5'h1F) && (b_frac == 10'd0);
  wire        b_is_zero= (b_exp == 5'd0);
  wire [10:0] man_b_eff = b_is_zero ? 11'd0 : {1'b1, b_frac};
  wire signed [11:0] b_unbias = $signed({1'b0, b_exp}) - 12'sd15;

  // ---- Per-lane compose: 22-bit mantissa product -> FP32 ----
  //   Input mul22 = {15-bit FP8 x FP16 product, 7'b0} (paper convention).
  //   Always in FP32 normal range, so no overflow/underflow check.
  function automatic [31:0] lane_fp32_mul_result;
    input [21:0]        mul22;
    input signed [11:0] exp_unbiased_in;
    input               sign;
    input               a_is_zero;
    input               b_is_zero_in;
    input               any_is_nan;
    input               any_is_inf;
    reg                 leading2;
    reg [21:0]          norm22;
    reg signed  [11:0]  exp_biased;
    begin
      if (any_is_nan || (any_is_inf && (a_is_zero || b_is_zero_in))) begin
        lane_fp32_mul_result = QNAN32;
      end else if (any_is_inf) begin
        lane_fp32_mul_result = {sign, 8'hFF, 23'd0};
      end else if (a_is_zero || b_is_zero_in) begin
        lane_fp32_mul_result = {sign, 31'd0};
      end else begin
        leading2   = mul22[21];
        norm22     = leading2 ? (mul22 >> 1) : mul22;
        exp_biased = exp_unbiased_in + (leading2 ? 12'sd128 : 12'sd127);
        lane_fp32_mul_result = {sign, exp_biased[7:0], norm22[19:0], 3'd0};
      end
    end
  endfunction

  generate
  if (MUL_LAT == 1) begin : gen_mul1
    reg [26:0] man_a_packed_s1;
    reg [17:0] man_b_packed_s1;
    reg signed [11:0] exp_lo_s1, exp_hi_s1;
    reg        sign_lo_s1, sign_hi_s1;
    reg        a_lo_zero_s1, a_hi_zero_s1, a_lo_nan_s1, a_hi_nan_s1;
    reg        b_zero_s1, b_nan_s1, b_inf_s1;
    reg [31:0] c_lo_s1, c_hi_s1;

    always @(posedge clk) begin
      man_a_packed_s1 <= {8'd0, a_hi_mant, 11'd0, a_lo_mant};
      man_b_packed_s1 <= {7'd0, man_b_eff};
      exp_lo_s1  <= (a_lo_zero || a_lo_nan || b_is_zero || b_is_nan) ? 12'sd0
                  : (a_lo_exp_unbias + b_unbias);
      exp_hi_s1  <= (a_hi_zero || a_hi_nan || b_is_zero || b_is_nan) ? 12'sd0
                  : (a_hi_exp_unbias + b_unbias);
      sign_lo_s1 <= a_lo_sign ^ b_sign;
      sign_hi_s1 <= a_hi_sign ^ b_sign;
      a_lo_zero_s1 <= a_lo_zero;  a_hi_zero_s1 <= a_hi_zero;
      a_lo_nan_s1  <= a_lo_nan;   a_hi_nan_s1  <= a_hi_nan;
      b_zero_s1 <= b_is_zero;  b_nan_s1 <= b_is_nan;  b_inf_s1 <= b_is_inf;
      c_lo_s1 <= c64[31:0];  c_hi_s1 <= c64[63:32];
    end

    wire [44:0] product45;
    dsp_usage u_dsp (.clk(clk), .a(man_a_packed_s1), .b(man_b_packed_s1), .product(product45));

    wire [21:0] prod_lo22 = {product45[14:0], 7'd0};
    wire [21:0] prod_hi22 = {product45[29:15], 7'd0};

    wire [31:0] prod_lo32 = lane_fp32_mul_result(
        prod_lo22, exp_lo_s1, sign_lo_s1, a_lo_zero_s1, b_zero_s1,
        a_lo_nan_s1 | b_nan_s1, b_inf_s1);
    wire [31:0] prod_hi32 = lane_fp32_mul_result(
        prod_hi22, exp_hi_s1, sign_hi_s1, a_hi_zero_s1, b_zero_s1,
        a_hi_nan_s1 | b_nan_s1, b_inf_s1);

    reg [31:0] plo_mid [0:MID_STAGES];
    reg [31:0] phi_mid [0:MID_STAGES];
    reg [31:0] clo_mid [0:MID_STAGES];
    reg [31:0] chi_mid [0:MID_STAGES];
    always @(*) begin
      plo_mid[0]=prod_lo32; phi_mid[0]=prod_hi32; clo_mid[0]=c_lo_s1; chi_mid[0]=c_hi_s1;
    end
    genvar gm;
    for (gm=1; gm<=MID_STAGES; gm=gm+1) begin : gen_mid
      always @(posedge clk) begin
        plo_mid[gm]<=plo_mid[gm-1]; phi_mid[gm]<=phi_mid[gm-1];
        clo_mid[gm]<=clo_mid[gm-1]; chi_mid[gm]<=chi_mid[gm-1];
      end
    end

    wire [31:0] sum_lo32, sum_hi32;
    fp32_add #(.LATENCY(ADD_LAT), .SATURATE_ON_MAX(1'b0), .INF_CANCELLATION_TO_NAN(1'b0))
      u_add_lo (.clk(clk), .x32(plo_mid[MID_STAGES]), .y32(clo_mid[MID_STAGES]), .result(sum_lo32));
    fp32_add #(.LATENCY(ADD_LAT), .SATURATE_ON_MAX(1'b0), .INF_CANCELLATION_TO_NAN(1'b0))
      u_add_hi (.clk(clk), .x32(phi_mid[MID_STAGES]), .y32(chi_mid[MID_STAGES]), .result(sum_hi32));
    assign result = {sum_hi32, sum_lo32};

  end else begin : gen_mul2
    reg [26:0] man_a_packed_s1;
    reg [17:0] man_b_packed_s1;
    reg signed [11:0] exp_lo_s1, exp_hi_s1;
    reg        sign_lo_s1, sign_hi_s1;
    reg        a_lo_zero_s1, a_hi_zero_s1, a_lo_nan_s1, a_hi_nan_s1;
    reg        b_zero_s1, b_nan_s1, b_inf_s1;
    reg [31:0] c_lo_s1, c_hi_s1;

    always @(posedge clk) begin
      man_a_packed_s1 <= {8'd0, a_hi_mant, 11'd0, a_lo_mant};
      man_b_packed_s1 <= {7'd0, man_b_eff};
      exp_lo_s1  <= (a_lo_zero||a_lo_nan||b_is_zero||b_is_nan) ? 12'sd0
                  : (a_lo_exp_unbias + b_unbias);
      exp_hi_s1  <= (a_hi_zero||a_hi_nan||b_is_zero||b_is_nan) ? 12'sd0
                  : (a_hi_exp_unbias + b_unbias);
      sign_lo_s1 <= a_lo_sign ^ b_sign;  sign_hi_s1 <= a_hi_sign ^ b_sign;
      a_lo_zero_s1 <= a_lo_zero;  a_hi_zero_s1 <= a_hi_zero;
      a_lo_nan_s1  <= a_lo_nan;   a_hi_nan_s1  <= a_hi_nan;
      b_zero_s1 <= b_is_zero;  b_nan_s1 <= b_is_nan;  b_inf_s1 <= b_is_inf;
      c_lo_s1 <= c64[31:0];  c_hi_s1 <= c64[63:32];
    end

    wire [44:0] product45;
    dsp_usage u_dsp (.clk(clk), .a(man_a_packed_s1), .b(man_b_packed_s1), .product(product45));

    reg [44:0] prod_s2;
    reg signed [11:0] exp_lo_s2, exp_hi_s2;
    reg        sign_lo_s2, sign_hi_s2;
    reg        a_lo_zero_s2, a_hi_zero_s2, a_lo_nan_s2, a_hi_nan_s2;
    reg        b_zero_s2, b_nan_s2, b_inf_s2;
    reg [31:0] c_lo_s2, c_hi_s2;

    always @(posedge clk) begin
      prod_s2 <= product45;
      exp_lo_s2 <= exp_lo_s1;  exp_hi_s2 <= exp_hi_s1;
      sign_lo_s2<= sign_lo_s1; sign_hi_s2<= sign_hi_s1;
      a_lo_zero_s2<=a_lo_zero_s1; a_hi_zero_s2<=a_hi_zero_s1;
      a_lo_nan_s2 <=a_lo_nan_s1;  a_hi_nan_s2 <=a_hi_nan_s1;
      b_zero_s2<=b_zero_s1; b_nan_s2<=b_nan_s1; b_inf_s2<=b_inf_s1;
      c_lo_s2<=c_lo_s1; c_hi_s2<=c_hi_s1;
    end

    wire [21:0] prod_lo22 = {prod_s2[14:0], 7'd0};
    wire [21:0] prod_hi22 = {prod_s2[29:15], 7'd0};

    wire [31:0] prod_lo32 = lane_fp32_mul_result(
        prod_lo22, exp_lo_s2, sign_lo_s2, a_lo_zero_s2, b_zero_s2,
        a_lo_nan_s2 | b_nan_s2, b_inf_s2);
    wire [31:0] prod_hi32 = lane_fp32_mul_result(
        prod_hi22, exp_hi_s2, sign_hi_s2, a_hi_zero_s2, b_zero_s2,
        a_hi_nan_s2 | b_nan_s2, b_inf_s2);

    reg [31:0] plo_mid [0:MID_STAGES];
    reg [31:0] phi_mid [0:MID_STAGES];
    reg [31:0] clo_mid [0:MID_STAGES];
    reg [31:0] chi_mid [0:MID_STAGES];
    always @(*) begin
      plo_mid[0]=prod_lo32; phi_mid[0]=prod_hi32; clo_mid[0]=c_lo_s2; chi_mid[0]=c_hi_s2;
    end
    genvar gm;
    for (gm=1; gm<=MID_STAGES; gm=gm+1) begin : gen_mid
      always @(posedge clk) begin
        plo_mid[gm]<=plo_mid[gm-1]; phi_mid[gm]<=phi_mid[gm-1];
        clo_mid[gm]<=clo_mid[gm-1]; chi_mid[gm]<=chi_mid[gm-1];
      end
    end

    wire [31:0] sum_lo32, sum_hi32;
    fp32_add #(.LATENCY(ADD_LAT), .SATURATE_ON_MAX(1'b0), .INF_CANCELLATION_TO_NAN(1'b0))
      u_add_lo (.clk(clk), .x32(plo_mid[MID_STAGES]), .y32(clo_mid[MID_STAGES]), .result(sum_lo32));
    fp32_add #(.LATENCY(ADD_LAT), .SATURATE_ON_MAX(1'b0), .INF_CANCELLATION_TO_NAN(1'b0))
      u_add_hi (.clk(clk), .x32(phi_mid[MID_STAGES]), .y32(chi_mid[MID_STAGES]), .result(sum_hi32));
    assign result = {sum_hi32, sum_lo32};
  end
  endgenerate

endmodule
`default_nettype wire
