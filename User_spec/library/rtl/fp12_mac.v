`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp12_mac  (Two-lane FP12*FP12 + FP12 add, 4-cycle total)
//   FP12 per lane: [11]=sign, [10:5]=exp(6), [4:0]=frac(5), bias=31
//   S1: FP12×FP12 prenorm + align C (classify, exp sum, pack mantissas)
//   DSP: 1-cycle product (two lanes packed into A; shared B in B)
//   S2: capture product + meta + aligned C
//   S3: per-lane specials/finite pack
//   S4: per-lane add (internal 1-reg stage in fp12_add) -> top-level reg
//   II = 1
//   Multiply specials (per lane):
//     - NaN if (a is NaN) or (b is NaN) or (Inf * 0)
//     - Inf if (a is Inf) or (b is Inf) [and not Inf*0 case]; sign = XOR
//     - Zero if (a is 0) or (b is 0)     [and not Inf*0 case]; sign = XOR
//   FTZ for inputs: exp==0 treated as zero
// =============================================================
module fp12_mac (
    input  wire        clk,
    input  wire [23:0] a24,     // FP12 lanes {hi[23:12], lo[11:0]}
    input  wire [11:0] b12,     // shared FP12
    input  wire [23:0] c24,     // FP12 addends {hi, lo}
    output reg  [23:0] result   // {hi, lo}, registered here (S4)
);
  localparam [5:0] FP12_BIAS = 6'd31;
  localparam [11:0] QNAN12   = 12'h7F0; // canonical FP12 qNaN exemplar (exp=all1, frac MSB=1)

  // ---- DSP packs (A=27b, B=18b) ----
  // man_a_packed layout (LSB..MSB): [ lo(6) | Zsep(6) | hi(6) ] => 18b, then zero-extend to 27b
  // man_b_m6 layout:                 [           Mb(6)         ] => 6b, then zero-extend to 18b
  reg  [17:0] man_a_packed;  // 6+6+6 = 18
  reg  [5:0]  man_b_m6;      // 1+frac5
  wire [44:0] product45;
  reg  [35:0] dsp_p;         // lowest 36 bits are enough (two 12b lanes)

  // ---- mul meta S1->S2 ----
  reg  signed [7:0] exp_hi_s1, exp_lo_s1, exp_hi_s2, exp_lo_s2;
  reg               sign_hi_s1, sign_lo_s1, sign_hi_s2, sign_lo_s2;

  // per-operand classification (S1->S2)
  reg a_hi_nan_s1, a_lo_nan_s1, b_nan_s1;
  reg a_hi_inf_s1, a_lo_inf_s1, b_inf_s1;
  reg a_hi_zero_s1, a_lo_zero_s1, b_zero_s1;

  reg a_hi_nan_s2, a_lo_nan_s2, b_nan_s2;
  reg a_hi_inf_s2, a_lo_inf_s2, b_inf_s2;
  reg a_hi_zero_s2, a_lo_zero_s2, b_zero_s2;

  // align C to S2
  reg [11:0] c_lo_s1, c_lo_s2;
  reg [11:0] c_hi_s1, c_hi_s2;

  // Power-up clean
  initial begin
    man_a_packed = 18'd0;
    man_b_m6     = 6'd0;
    dsp_p        = 36'd0;

    exp_hi_s1=8'sd0; exp_lo_s1=8'sd0;
    exp_hi_s2=8'sd0; exp_lo_s2=8'sd0;

    sign_hi_s1=1'b0; sign_lo_s1=1'b0;
    sign_hi_s2=1'b0; sign_lo_s2=1'b0;

    a_hi_nan_s1=1'b0; a_lo_nan_s1=1'b0; b_nan_s1=1'b0;
    a_hi_inf_s1=1'b0; a_lo_inf_s1=1'b0; b_inf_s1=1'b0;
    a_hi_zero_s1=1'b0; a_lo_zero_s1=1'b0; b_zero_s1=1'b0;

    a_hi_nan_s2=1'b0; a_lo_nan_s2=1'b0; b_nan_s2=1'b0;
    a_hi_inf_s2=1'b0; a_lo_inf_s2=1'b0; b_inf_s2=1'b0;
    a_hi_zero_s2=1'b0; a_lo_zero_s2=1'b0; b_zero_s2=1'b0;

    c_lo_s1=12'h000; c_lo_s2=12'h000;
    c_hi_s1=12'h000; c_hi_s2=12'h000;

    result = 24'h000000;
  end

  // --------------------------
  // S1: FP12×FP12 prenorm + align C
  // --------------------------
  always @(posedge clk) begin
    // signs (per lane) = XOR
    sign_hi_s1 <= a24[23] ^ b12[11];
    sign_lo_s1 <= a24[11] ^ b12[11];

    // exponents (finite path)
    exp_hi_s1 <= {1'b0, a24[22:17]} + {1'b0, b12[10:5]} - {1'b0, FP12_BIAS};
    exp_lo_s1 <= {1'b0, a24[10:5]}  + {1'b0, b12[10:5]} - {1'b0, FP12_BIAS};

    // classify A(hi/lo)
    a_hi_nan_s1  <= (a24[22:17]==6'h3F) && (a24[16:12]!=5'd0);
    a_hi_inf_s1  <= (a24[22:17]==6'h3F) && (a24[16:12]==5'd0);
    a_hi_zero_s1 <= (a24[22:17]==6'd0); // FTZ

    a_lo_nan_s1  <= (a24[10:5]==6'h3F) && (a24[4:0]!=5'd0);
    a_lo_inf_s1  <= (a24[10:5]==6'h3F) && (a24[4:0]==5'd0);
    a_lo_zero_s1 <= (a24[10:5]==6'd0); // FTZ

    // classify shared B
    b_nan_s1     <= (b12[10:5]==6'h3F) && (b12[4:0]!=5'd0);
    b_inf_s1     <= (b12[10:5]==6'h3F) && (b12[4:0]==5'd0);
    b_zero_s1    <= (b12[10:5]==6'd0); // FTZ

    // pack mantissas with hidden-1 (finite path only; specials will bypass)
    // man_a_packed = {hi(6), 6'b0, lo(6)} with implicit 1s
    man_a_packed <= { (1'b1), a24[16:12], 6'b0, (1'b1), a24[4:0] };
    // B mantissa (LSB)
    man_b_m6     <= {1'b1, b12[4:0]};

    c_lo_s1 <= c24[11:0];
    c_hi_s1 <= c24[23:12];
  end

  // DSP (1-cycle product)
  (* use_dsp = "yes" *)
  dsp_usage u_dsp (
    .clk    (clk),
    .a      ({9'b0, man_a_packed}),      // 27b
    .b      ({12'b0, man_b_m6}),         // 18b (mantissa at LSBs)
    .product(product45)
  );

  // --------------------------
  // S2: capture product + meta + C
  // --------------------------
  always @(posedge clk) begin
    dsp_p      <= product45[35:0]; // two 12-bit lanes covered

    exp_hi_s2  <= exp_hi_s1;    exp_lo_s2  <= exp_lo_s1;
    sign_hi_s2 <= sign_hi_s1;   sign_lo_s2 <= sign_lo_s1;

    a_hi_nan_s2  <= a_hi_nan_s1;  a_lo_nan_s2  <= a_lo_nan_s1;  b_nan_s2  <= b_nan_s1;
    a_hi_inf_s2  <= a_hi_inf_s1;  a_lo_inf_s2  <= a_lo_inf_s1;  b_inf_s2  <= b_inf_s1;
    a_hi_zero_s2 <= a_hi_zero_s1; a_lo_zero_s2 <= a_lo_zero_s1; b_zero_s2 <= b_zero_s1;

    c_lo_s2    <= c_lo_s1;
    c_hi_s2    <= c_hi_s1;
  end

  // --------------------------
  // S3/S4 (per lane): pack product or specials, then add C via fp12_add
  // --------------------------
  // With the packing above, lane products occupy:
  //   LO: product bits [11:0],  HI: product bits [23:12]
  wire [11:0] P_lo = dsp_p[11:0];
  wire [11:0] P_hi = dsp_p[23:12];

  // Per-lane special controls
  wire nan_hi   = a_hi_nan_s2 | b_nan_s2 | ((a_hi_inf_s2 & b_zero_s2) | (a_hi_zero_s2 & b_inf_s2));
  wire inf_hi   = ~nan_hi  & (a_hi_inf_s2 | b_inf_s2);
  wire zero_hi  = ~nan_hi  & ~inf_hi & (a_hi_zero_s2 | b_zero_s2);
  wire zsign_hi = sign_hi_s2;               // XOR sign for zero (choose 1'b0 for +0 if desired)
  wire [5:0] ehi = exp_hi_s2[5:0];

  wire nan_lo   = a_lo_nan_s2 | b_nan_s2 | ((a_lo_inf_s2 & b_zero_s2) | (a_lo_zero_s2 & b_inf_s2));
  wire inf_lo   = ~nan_lo  & (a_lo_inf_s2 | b_inf_s2);
  wire zero_lo  = ~nan_lo  & ~inf_lo & (a_lo_zero_s2 | b_zero_s2);
  wire zsign_lo = sign_lo_s2;
  wire [5:0] elo = exp_lo_s2[5:0];

  // FP12 product words (finite path); per-lane carry is MSB of the 12-bit product
  // fraction (5b): if carry -> [10:6], else [9:5]
  // exponent bump on carry; overflow/underflow -> signed Inf
  wire [11:0] prod_hi12_finite =
      (exp_hi_s2[7] | (exp_hi_s2 > 8'd62)) ? {sign_hi_s2, 6'h3F, 5'b0} :
      (P_hi[11])                           ? {sign_hi_s2, ehi + 6'd1, P_hi[10:6]} :
                                             {sign_hi_s2, ehi,        P_hi[9:5]};

  wire [11:0] prod_lo12_finite =
      (exp_lo_s2[7] | (exp_lo_s2 > 8'd62)) ? {sign_lo_s2, 6'h3F, 5'b0} :
      (P_lo[11])                           ? {sign_lo_s2, elo + 6'd1, P_lo[10:6]} :
                                             {sign_lo_s2, elo,        P_lo[9:5]};

  // Final per-lane product with specials
  wire [11:0] prod_hi12_w =
      nan_hi  ? QNAN12 :
      inf_hi  ? {sign_hi_s2, 6'h3F, 5'd0} :
      zero_hi ? {zsign_hi,    11'h000}    :
                prod_hi12_finite;

  wire [11:0] prod_lo12_w =
      nan_lo  ? QNAN12 :
      inf_lo  ? {sign_lo_s2, 6'h3F, 5'd0} :
      zero_lo ? {zsign_lo,    11'h000}    :
                prod_lo12_finite;

  // Lane adders: internal 1-reg stage; outputs are combinational wires here
  wire [11:0] sum_lo12, sum_hi12;

  fp12_add u_add_lo (
    .clk (clk),
    .a12 (prod_lo12_w),
    .b12 (c_lo_s2),
    .c12 (sum_lo12)
  );

  fp12_add u_add_hi (
    .clk (clk),
    .a12 (prod_hi12_w),
    .b12 (c_hi_s2),
    .c12 (sum_hi12)
  );

  // --------------------------
  // S4 register: final output
  // --------------------------
  always @(posedge clk) begin
    result <= {sum_hi12, sum_lo12};
  end

endmodule