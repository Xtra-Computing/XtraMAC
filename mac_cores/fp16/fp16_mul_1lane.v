`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp16_mul_1lane : Parameterized 1-lane FP16 x FP16 multiplier
//   LATENCY=1 : 1-stage (logic multiply, single output register)
//   LATENCY=2 : 2-stage (DSP-packed mantissa multiply, narrowed product)
//   FTZ/DAZ, NaN/Inf rules, RN-even preserved
// =============================================================
module fp16_mul_1lane #(
    parameter integer LATENCY = 2   // 1 or 2
) (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    output reg  [15:0] prod16_w
);
  function is_nan;
    input [15:0] x;
    begin is_nan = (x[14:10]==5'h1F) && (x[9:0]!=10'd0); end
  endfunction

  function is_inf;
    input [15:0] x;
    begin is_inf = (x[14:10]==5'h1F) && (x[9:0]==10'd0); end
  endfunction

  function is_zero;
    input [15:0] x;
    begin is_zero = (x[14:10]==5'd0); end
  endfunction

  localparam [15:0] QNAN16 = 16'h7E00;

  // =====================================================================
  generate
  if (LATENCY == 1) begin : gen_1c
    // =========================================================
    // LATENCY = 1 : Single-cycle multiply (logic, no DSP)
    // =========================================================
    wire a_is_nan  = is_nan(a16);
    wire a_is_inf  = is_inf(a16);
    wire a_is_zero = is_zero(a16);

    wire b_is_nan  = is_nan(b16);
    wire b_is_inf  = is_inf(b16);
    wire b_is_zero = is_zero(b16);

    wire prod_has_nan  = a_is_nan | b_is_nan;
    wire prod_inf_and0 = (a_is_inf | b_is_inf) & (a_is_zero | b_is_zero);
    wire prod_is_nan   = prod_has_nan | prod_inf_and0;
    wire prod_is_inf   = ~prod_is_nan & (a_is_inf | b_is_inf);
    wire prod_is_zero  = ~prod_is_nan & ~prod_is_inf & (a_is_zero | b_is_zero);

    wire prod_sign = a16[15] ^ b16[15];

    wire signed [8:0] exp_sum_raw = $signed({1'b0, a16[14:10]}) + $signed({1'b0, b16[14:10]}) - 9'sd15;
    wire signed [8:0] exp_sum     = prod_is_zero ? 9'sd0 : exp_sum_raw;
    wire overflow_mul = exp_sum[8] | (exp_sum > 9'sd30);

    wire [10:0] man_a = a_is_zero ? 11'd0 : {1'b1, a16[9:0]};
    wire [10:0] man_b = b_is_zero ? 11'd0 : {1'b1, b16[9:0]};
    wire [21:0] product22 = man_a * man_b;

    wire prod_hi_bit = product22[21];
    wire [9:0] hi10  = product22[20:11];
    wire [9:0] lo10  = product22[19:10];

    wire [15:0] prod_fin_w =
        prod_hi_bit ? {prod_sign, (exp_sum[4:0] + 5'd1), hi10} :
                      {prod_sign,  exp_sum[4:0],         lo10};

    always @(posedge clk) begin
      prod16_w <=
        prod_is_nan                  ? QNAN16 :
        (prod_is_inf | overflow_mul) ? {prod_sign, 5'h1F, 10'd0} :
        prod_is_zero                 ? {prod_sign, 15'h0000} :
                                       prod_fin_w;
    end

  end else begin : gen_2c
    // =========================================================
    // LATENCY = 2 : Two-stage DSP-packed multiply
    // =========================================================
    reg  [24:0] man_a_packed;
    reg  [11:0] man_b_packed;
    wire [44:0] product45;

    reg  [11:0] dsp_lo_s2;

    reg  signed [8:0] exp_lo_s1, exp_lo_s2;
    reg               zero_lo_s1, zero_lo_s2;
    reg               sign_lo_s1, sign_lo_s2;

    reg a_is_nan_s1, a_is_inf_s1, a_is_zero_s1;
    reg b_is_nan_s1, b_is_inf_s1, b_is_zero_s1;
    reg a_is_nan_s2, a_is_inf_s2, a_is_zero_s2;
    reg b_is_nan_s2, b_is_inf_s2, b_is_zero_s2;

    initial begin
      man_a_packed = 25'd0;   man_b_packed = 12'd0;   dsp_lo_s2 = 12'd0;
      exp_lo_s1    = 9'sd0;   exp_lo_s2    = 9'sd0;
      zero_lo_s1   = 1'b0;    zero_lo_s2   = 1'b0;
      sign_lo_s1   = 1'b0;    sign_lo_s2   = 1'b0;
      a_is_nan_s1  = 1'b0; a_is_inf_s1=1'b0; a_is_zero_s1=1'b0;
      b_is_nan_s1  = 1'b0; b_is_inf_s1=1'b0; b_is_zero_s1=1'b0;
      a_is_nan_s2  = 1'b0; a_is_inf_s2=1'b0; a_is_zero_s2=1'b0;
      b_is_nan_s2  = 1'b0; b_is_inf_s2=1'b0; b_is_zero_s2=1'b0;
    end

    // ---- Stage M1 ----
    always @(posedge clk) begin
      a_is_nan_s1  <= is_nan(a16);
      a_is_inf_s1  <= is_inf(a16);
      a_is_zero_s1 <= is_zero(a16);

      b_is_nan_s1  <= is_nan(b16);
      b_is_inf_s1  <= is_inf(b16);
      b_is_zero_s1 <= is_zero(b16);

      sign_lo_s1   <= a16[15] ^ b16[15];
      exp_lo_s1    <= a16[14:10] + b16[14:10] - 5'd15;

      zero_lo_s1   <= (is_zero(a16) | is_zero(b16));

      man_a_packed <= {14'd0, 1'b1, a16[9:0]};
      man_b_packed <= {1'b0,  1'b1, b16[9:0]};
    end

    // External DSP multiply
    dsp_usage u_dsp (
      .clk(clk),
      .a({2'b0, man_a_packed}),
      .b({6'b0, man_b_packed}),
      .product(product45)
    );

    // ---- Stage M2 ----
    always @(posedge clk) begin
      dsp_lo_s2  <= product45[21:10];
      exp_lo_s2  <= zero_lo_s1 ? 9'd0 : exp_lo_s1;
      zero_lo_s2 <= zero_lo_s1;
      sign_lo_s2 <= sign_lo_s1;

      a_is_nan_s2 <= a_is_nan_s1;  a_is_inf_s2 <= a_is_inf_s1;  a_is_zero_s2 <= a_is_zero_s1;
      b_is_nan_s2 <= b_is_nan_s1;  b_is_inf_s2 <= b_is_inf_s1;  b_is_zero_s2 <= b_is_zero_s1;
    end

    // ---- Product compose (combinational) ----
    wire prod_has_nan   = (a_is_nan_s2 | b_is_nan_s2);
    wire prod_inf_and0  = (a_is_inf_s2 | b_is_inf_s2) & (a_is_zero_s2 | b_is_zero_s2);
    wire prod_is_nan    = prod_has_nan | prod_inf_and0;
    wire prod_is_inf    = ~prod_is_nan & (a_is_inf_s2 | b_is_inf_s2);
    wire prod_is_zero   = ~prod_is_nan & ~prod_is_inf & zero_lo_s2;

    wire        prod_sign = sign_lo_s2;
    wire        overflow_mul  = exp_lo_s2[8] | (exp_lo_s2 > 9'd30);

    wire        prod_hi_bit = dsp_lo_s2[11];
    wire [9:0]  hi10        = dsp_lo_s2[10:1];
    wire [9:0]  lo10        = dsp_lo_s2[9:0];

    wire [15:0] prod_fin_w =
        (prod_hi_bit) ? {prod_sign, (exp_lo_s2[4:0] + 5'd1), hi10} :
                        {prod_sign,  exp_lo_s2[4:0],          lo10};

    always @* begin
      prod16_w =
        prod_is_nan                      ? QNAN16 :
        (prod_is_inf | overflow_mul)     ? {prod_sign, 5'h1F, 10'd0} :
        prod_is_zero                     ? {prod_sign, 15'h0000} :
                                           prod_fin_w;
    end
  end
  endgenerate

endmodule

`default_nettype wire
