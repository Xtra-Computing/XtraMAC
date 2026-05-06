// =============================================================
// fp16_mul : 2-stage FP16 multiply (+classify/pack)
//   - Implements FTZ/DAZ for inputs
//   - Handles NaN/Inf/Zero precedence and overflow to Inf
//   - Outputs a fully packed FP16 product (or special)
//   - [OPT] narrows product pipeline to bits actually used
// =============================================================
module fp16_mul (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    output reg  [15:0] prod16_w
);
  // -------- Small helpers (FTZ: subnormals count as zero) --------
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

  // =========================================================
  //                Multiplier (2 stages)
  // =========================================================
  reg  [24:0] man_a_packed;
  reg  [11:0] man_b_packed;
  wire [44:0] product45;

  // [OPT] narrow product pipeline reg: only keep bits [21:10]
  reg  [11:0] dsp_lo_s2; // product45[21:10]

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
    a_is_zero_s1 <= is_zero(a16);      // FTZ

    b_is_nan_s1  <= is_nan(b16);
    b_is_inf_s1  <= is_inf(b16);
    b_is_zero_s1 <= is_zero(b16);      // FTZ

    sign_lo_s1   <= a16[15] ^ b16[15];
    exp_lo_s1    <= a16[14:10] + b16[14:10] - 5'd15;

    zero_lo_s1   <= (is_zero(a16) | is_zero(b16)); // zero×anything -> zero (unless Inf/NaN)

    man_a_packed <= {14'd0, 1'b1, a16[9:0]};
    man_b_packed <= {1'b0,  1'b1, b16[9:0]};
  end

  // external DSP mul (device-specific implementation provided elsewhere)
  dsp_usage u_dsp (
    .clk(clk),
    .a({2'b0, man_a_packed}),
    .b({6'b0, man_b_packed}),
    .product(product45)
  );

  // ---- Stage M2 ----
  always @(posedge clk) begin
    dsp_lo_s2  <= product45[21:10]; // keep only 12 bits actually used
    exp_lo_s2  <= zero_lo_s1 ? 9'd0 : exp_lo_s1; // exp value not used on zero path
    zero_lo_s2 <= zero_lo_s1;
    sign_lo_s2 <= sign_lo_s1;

    a_is_nan_s2 <= a_is_nan_s1;  a_is_inf_s2 <= a_is_inf_s1;  a_is_zero_s2 <= a_is_zero_s1;
    b_is_nan_s2 <= b_is_nan_s1;  b_is_inf_s2 <= b_is_inf_s1;  b_is_zero_s2 <= b_is_zero_s1;
  end

  // ---- Product compose (combinational) ----
  // Priority: NaN > Inf*0 → NaN > Inf > Zero > Finite
  wire prod_has_nan   = (a_is_nan_s2 | b_is_nan_s2);
  wire prod_inf_and0  = (a_is_inf_s2 | b_is_inf_s2) & (a_is_zero_s2 | b_is_zero_s2);
  wire prod_is_nan    = prod_has_nan | prod_inf_and0;                 // NaN anywhere, or Inf*0
  wire prod_is_inf    = ~prod_is_nan & (a_is_inf_s2 | b_is_inf_s2);   // any Inf and not NaN
  wire prod_is_zero   = ~prod_is_nan & ~prod_is_inf & zero_lo_s2;     // zero×finite => zero

  wire        prod_sign = sign_lo_s2;
  wire        overflow_mul  = exp_lo_s2[8] | (exp_lo_s2 > 9'd30);

  // Use narrowed product bits
  wire        prod_hi_bit = dsp_lo_s2[11];    // product45[21]
  wire [9:0]  hi10        = dsp_lo_s2[10:1];  // product45[20:11]
  wire [9:0]  lo10        = dsp_lo_s2[9:0];   // product45[19:10]

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
endmodule