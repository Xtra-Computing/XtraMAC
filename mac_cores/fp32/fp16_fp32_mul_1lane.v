`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp16_fp32_mul_1lane : 1-lane FP16 x FP16 -> FP32 multiplier
//   - 11b x 11b mantissa multiplication (uses DSP or fabric)
//   - Handles NaN/Inf/Zero precedence; FTZ/DAZ on inputs
//   - Latency: MUL_LAT cycles (1 or 2)
//   - II = 1
// =============================================================
module fp16_fp32_mul_1lane #(
    parameter MUL_LAT = 2  // 1 or 2
)(
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    output wire [31:0] prod32
);
  localparam [31:0] QNAN32 = 32'h7FC0_0000;

  // ----------------------------------------------------------------
  // Classify operands
  // ----------------------------------------------------------------
  wire sa, sb;
  wire [4:0] ea, eb;
  wire [9:0] fa, fb;
  wire a_nan, a_inf, a_zero, b_nan, b_inf, b_zero;

  fp16_class ca(.x(a16), .s(sa), .e(ea), .f(fa), .is_nan(a_nan), .is_inf(a_inf), .is_zero(a_zero));
  fp16_class cb(.x(b16), .s(sb), .e(eb), .f(fb), .is_nan(b_nan), .is_inf(b_inf), .is_zero(b_zero));

  // ----------------------------------------------------------------
  // S1 registers
  // ----------------------------------------------------------------
  reg        s1_sign;
  reg [5:0]  s1_ea_eff, s1_eb_eff;
  reg [10:0] s1_ma_eff, s1_mb_eff;
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
    s1_inf_and_zero <= (a_inf | b_inf) & (a_zero | b_zero);
  end

  // ----------------------------------------------------------------
  // Multiply and compose FP32
  // ----------------------------------------------------------------
  wire [21:0] mul22 = s1_ma_eff * s1_mb_eff;

  // Exponent: subtract both FP16 biases (15 each)
  wire signed [9:0] e_sum_16 = $signed({1'b0, s1_ea_eff}) + $signed({1'b0, s1_eb_eff}) - 10'sd30;

  // Normalize to [1,2)
  wire        leading2 = mul22[21];
  wire [21:0] norm_sig = leading2 ? (mul22 >> 1) : mul22;
  wire signed [9:0] e_norm_16 = leading2 ? (e_sum_16 + 10'sd1) : e_sum_16;

  // Map to FP32 biased
  wire signed [10:0] e32_unclamped = e_norm_16 + 10'sd127;

  // Exact map to 1+23 bits; FP16 product has 20 frac bits -> append 3 zeros
  wire [23:0] sig24 = {norm_sig[19:0], 3'b000, 1'b0};
  // Actually: norm_sig is 22 bits with hidden-1 at [20], frac at [19:0]
  // We need {1, frac[19:0], 3'b000} = 24 bits
  wire [23:0] sig24_correct = {1'b1, norm_sig[19:0], 3'b000};

  // RN-even (guard/sticky are zero for exact BF16 product)
  wire        guard   = 1'b0;
  wire        sticky  = 1'b0;
  wire        lsb     = sig24_correct[0];
  wire        round_inc = guard & (sticky | lsb);
  wire [24:0] sig_rw  = {1'b0, sig24_correct} + {24'd0, round_inc};
  wire        sig_ovf = sig_rw[24];
  wire [23:0] sig_rounded = sig_ovf ? 24'h800000 : sig_rw[23:0];
  wire signed [10:0] e32_rounded = sig_ovf ? (e32_unclamped + 11'sd1) : e32_unclamped;

  wire overflow   = (e32_rounded >= 11'sd255);
  wire underflow0 = (e32_rounded <= 11'sd0);

  wire is_nan_w  = s1_has_nan | s1_inf_and_zero;
  wire is_inf_w  = ~is_nan_w & s1_has_inf & ~s1_has_zero;
  wire is_zero_w = ~is_nan_w & ~is_inf_w & (s1_has_zero | underflow0);

  wire [31:0] finite_out = {s1_sign, e32_rounded[7:0], sig_rounded[22:0]};

  wire [31:0] result_comb = is_nan_w          ? QNAN32 :
                             (is_inf_w|overflow) ? {s1_sign, 8'hFF, 23'd0} :
                             is_zero_w          ? {s1_sign, 31'd0} :
                                                  finite_out;

  // ----------------------------------------------------------------
  // Output staging
  // ----------------------------------------------------------------
  generate
    if (MUL_LAT == 1) begin : gen_lat1
      // Total = 1 cycle (S1 regs only, comb mul)
      // Output is combinational from S1
      assign prod32 = result_comb;
    end else begin : gen_lat2
      // Total = 2 cycles (S1 regs + output reg)
      reg [31:0] prod32_r;
      always @(posedge clk) begin
        prod32_r <= result_comb;
      end
      assign prod32 = prod32_r;
    end
  endgenerate

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

`default_nettype wire
