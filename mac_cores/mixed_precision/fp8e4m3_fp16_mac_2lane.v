`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp8e4m3_fp16_mac_2lane : 2-lane FP8(E4M3) x FP16 + FP16 -> FP16
//   DSP packing: A={8'b0, a_hi_mant4, 11'b0, a_lo_mant4}, B={7'b0, man_b_eff}
//   MUL_LAT=1: pack+DSP in S1, compose same cycle
//   MUL_LAT=2: pack S1 | DSP+capture S2, compose from S2
//   MID_STAGES, ADD_LAT parameterized
// =============================================================
module fp8e4m3_fp16_mac_2lane #(
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

  // ---- FP16 B classification ----
  wire        b_sign    = b16[15];
  wire [4:0]  b_exp     = b16[14:10];
  wire [9:0]  b_frac    = b16[9:0];
  wire        b_is_nan  = (b_exp == 5'h1F) && (b_frac != 10'd0);
  wire        b_is_inf  = (b_exp == 5'h1F) && (b_frac == 10'd0);
  wire        b_is_zero = (b_exp == 5'd0);
  wire [10:0] man_b_eff = b_is_zero ? 11'd0 : {1'b1, b_frac};
  wire signed [11:0] b_unbias = $signed({1'b0, b_exp}) - 12'sd15;

  // ---- Shared lane compose function ----
  function automatic [15:0] lane_fp16_mul_result;
    input      [21:0] mul22;
    input signed [11:0] exp_unbiased_in;
    input               sign;
    input               a_is_zero;
    input               b_is_zero;
    input               any_is_nan;
    input               any_is_inf;
    reg         leading2;
    reg signed [12:0] exp_norm, exp_biased;
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
    reg        sign_lo_s1, sign_hi_s1;
    reg        a_lo_zero_s1, a_hi_zero_s1;
    reg        a_lo_nan_s1,  a_hi_nan_s1;
    reg        b_zero_s1, b_nan_s1, b_inf_s1;
    reg [15:0] c_lo_s1, c_hi_s1;

    always @(posedge clk) begin
      man_a_packed_s1 <= {8'd0, a_hi_mant, 11'd0, a_lo_mant};
      man_b_packed_s1 <= {7'd0, man_b_eff};

      exp_lo_s1 <= (a_lo_zero || a_lo_nan || b_is_zero || b_is_nan)
                   ? 12'sd0 : (a_lo_exp_unbias + b_unbias);
      exp_hi_s1 <= (a_hi_zero || a_hi_nan || b_is_zero || b_is_nan)
                   ? 12'sd0 : (a_hi_exp_unbias + b_unbias);

      sign_lo_s1 <= a_lo_sign ^ b_sign;
      sign_hi_s1 <= a_hi_sign ^ b_sign;

      a_lo_zero_s1 <= a_lo_zero;  a_hi_zero_s1 <= a_hi_zero;
      a_lo_nan_s1  <= a_lo_nan;   a_hi_nan_s1  <= a_hi_nan;
      b_zero_s1 <= b_is_zero;  b_nan_s1 <= b_is_nan;  b_inf_s1 <= b_is_inf;

      c_lo_s1 <= c32[15:0];  c_hi_s1 <= c32[31:16];
    end

    wire [44:0] product45;
    dsp_usage u_dsp (
      .clk(clk), .a(man_a_packed_s1), .b(man_b_packed_s1), .product(product45)
    );

    wire [14:0] man_lo_raw = product45[14:0];
    wire [14:0] man_hi_raw = product45[29:15];
    wire [21:0] man_lo_mul = {man_lo_raw, 7'd0};
    wire [21:0] man_hi_mul = {man_hi_raw, 7'd0};

    wire [15:0] prod_lo16_raw = lane_fp16_mul_result(
        man_lo_mul, exp_lo_s1, sign_lo_s1, a_lo_zero_s1, b_zero_s1,
        b_nan_s1 | a_lo_nan_s1, b_inf_s1);
    wire [15:0] prod_hi16_raw = lane_fp16_mul_result(
        man_hi_mul, exp_hi_s1, sign_hi_s1, a_hi_zero_s1, b_zero_s1,
        b_nan_s1 | a_hi_nan_s1, b_inf_s1);

    // Mid pipeline
    reg [15:0] plo [0:MID_STAGES]; reg [15:0] phi [0:MID_STAGES];
    reg [15:0] clo [0:MID_STAGES]; reg [15:0] chi [0:MID_STAGES];
    always @(*) begin plo[0]=prod_lo16_raw; phi[0]=prod_hi16_raw; clo[0]=c_lo_s1; chi[0]=c_hi_s1; end
    genvar gm;
    for (gm=1; gm<=MID_STAGES; gm=gm+1) begin : gen_mid
      always @(posedge clk) begin plo[gm]<=plo[gm-1]; phi[gm]<=phi[gm-1]; clo[gm]<=clo[gm-1]; chi[gm]<=chi[gm-1]; end
    end

    wire [15:0] sum_lo16, sum_hi16;
    fp16_add #(.LATENCY(ADD_LAT)) u_add_lo (.clk(clk),.x16(plo[MID_STAGES]),.y16(clo[MID_STAGES]),.result(sum_lo16));
    fp16_add #(.LATENCY(ADD_LAT)) u_add_hi (.clk(clk),.x16(phi[MID_STAGES]),.y16(chi[MID_STAGES]),.result(sum_hi16));
    assign result = {sum_hi16, sum_lo16};

  end else begin : gen_mul2
    reg [26:0] man_a_packed_s1;
    reg [17:0] man_b_packed_s1;
    reg signed [11:0] exp_lo_s1, exp_hi_s1;
    reg        sign_lo_s1, sign_hi_s1;
    reg        a_lo_zero_s1, a_hi_zero_s1;
    reg        a_lo_nan_s1,  a_hi_nan_s1;
    reg        b_zero_s1, b_nan_s1, b_inf_s1;
    reg [15:0] c_lo_s1, c_hi_s1;

    always @(posedge clk) begin
      man_a_packed_s1 <= {8'd0, a_hi_mant, 11'd0, a_lo_mant};
      man_b_packed_s1 <= {7'd0, man_b_eff};
      exp_lo_s1 <= (a_lo_zero||a_lo_nan||b_is_zero||b_is_nan) ? 12'sd0 : (a_lo_exp_unbias+b_unbias);
      exp_hi_s1 <= (a_hi_zero||a_hi_nan||b_is_zero||b_is_nan) ? 12'sd0 : (a_hi_exp_unbias+b_unbias);
      sign_lo_s1<=a_lo_sign^b_sign; sign_hi_s1<=a_hi_sign^b_sign;
      a_lo_zero_s1<=a_lo_zero; a_hi_zero_s1<=a_hi_zero;
      a_lo_nan_s1<=a_lo_nan;   a_hi_nan_s1<=a_hi_nan;
      b_zero_s1<=b_is_zero; b_nan_s1<=b_is_nan; b_inf_s1<=b_is_inf;
      c_lo_s1<=c32[15:0]; c_hi_s1<=c32[31:16];
    end

    wire [44:0] product45;
    dsp_usage u_dsp (.clk(clk),.a(man_a_packed_s1),.b(man_b_packed_s1),.product(product45));

    reg signed [11:0] exp_lo_s2, exp_hi_s2;
    reg        sign_lo_s2, sign_hi_s2;
    reg        a_lo_zero_s2, a_hi_zero_s2;
    reg        a_lo_nan_s2,  a_hi_nan_s2;
    reg        b_zero_s2, b_nan_s2, b_inf_s2;
    reg [15:0] c_lo_s2, c_hi_s2;
    reg [21:0] man_lo_mul_s2, man_hi_mul_s2;

    always @(posedge clk) begin
      exp_lo_s2<=exp_lo_s1; exp_hi_s2<=exp_hi_s1;
      sign_lo_s2<=sign_lo_s1; sign_hi_s2<=sign_hi_s1;
      a_lo_zero_s2<=a_lo_zero_s1; a_hi_zero_s2<=a_hi_zero_s1;
      a_lo_nan_s2<=a_lo_nan_s1;   a_hi_nan_s2<=a_hi_nan_s1;
      b_zero_s2<=b_zero_s1; b_nan_s2<=b_nan_s1; b_inf_s2<=b_inf_s1;
      c_lo_s2<=c_lo_s1; c_hi_s2<=c_hi_s1;
      man_lo_mul_s2 <= {product45[14:0], 7'd0};
      man_hi_mul_s2 <= {product45[29:15], 7'd0};
    end

    wire [15:0] prod_lo16_raw = lane_fp16_mul_result(
        man_lo_mul_s2, exp_lo_s2, sign_lo_s2, a_lo_zero_s2, b_zero_s2,
        b_nan_s2|a_lo_nan_s2, b_inf_s2);
    wire [15:0] prod_hi16_raw = lane_fp16_mul_result(
        man_hi_mul_s2, exp_hi_s2, sign_hi_s2, a_hi_zero_s2, b_zero_s2,
        b_nan_s2|a_hi_nan_s2, b_inf_s2);

    reg [15:0] plo [0:MID_STAGES]; reg [15:0] phi [0:MID_STAGES];
    reg [15:0] clo [0:MID_STAGES]; reg [15:0] chi [0:MID_STAGES];
    always @(*) begin plo[0]=prod_lo16_raw; phi[0]=prod_hi16_raw; clo[0]=c_lo_s2; chi[0]=c_hi_s2; end
    genvar gm;
    for (gm=1; gm<=MID_STAGES; gm=gm+1) begin : gen_mid
      always @(posedge clk) begin plo[gm]<=plo[gm-1]; phi[gm]<=phi[gm-1]; clo[gm]<=clo[gm-1]; chi[gm]<=chi[gm-1]; end
    end

    wire [15:0] sum_lo16, sum_hi16;
    fp16_add #(.LATENCY(ADD_LAT)) u_add_lo (.clk(clk),.x16(plo[MID_STAGES]),.y16(clo[MID_STAGES]),.result(sum_lo16));
    fp16_add #(.LATENCY(ADD_LAT)) u_add_hi (.clk(clk),.x16(phi[MID_STAGES]),.y16(chi[MID_STAGES]),.result(sum_hi16));
    assign result = {sum_hi16, sum_lo16};
  end
  endgenerate

endmodule

`default_nettype wire
