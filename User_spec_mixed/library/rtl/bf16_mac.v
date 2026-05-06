`timescale 1ns/1ps
`default_nettype none
// =============================================================
// bf16_mac  (Two-lane BF16*BF16 + BF16 add, 4-cycle total)
//   S1: extracted into bf16_mac_s1_prep (this file)
//   DSP: 1-cycle product (remains here)
//   S2: capture product + meta + aligned C
//   S3: lane unpack/order (reg)
//   S4: lane align+add+normalize (comb) -> top-level result reg
//   II = 1
//   Specials for multiply (per lane):
//     - NaN if (a is NaN) or (b is NaN) or (Inf * 0)
//     - Inf if (a is Inf) or (b is Inf)  [and not Inf*0 case]; sign = XOR
//     - Zero if (a is 0) or (b is 0)     [and not Inf*0 case]; sign = XOR
//   FTZ for inputs: exp==0 treated as zero
// =============================================================
module bf16_mac (
    input  wire        clk,
    input  wire [31:0] a32,     // BF16 lanes {hi[31:16], lo[15:0]}
    input  wire [15:0] b16,     // shared BF16
    input  wire [31:0] c32,     // BF16 addends {hi, lo}
    output reg  [31:0] result   // {hi, lo}, registered here (S4)
);
  localparam [7:0]  BF16_BIAS = 8'd127;
  localparam [15:0] QNAN16    = 16'h7FC0; // canonical BF16 qNaN

  // ---- S1 outputs (as wires from the submodule) ----
  wire signed [8:0] exp_hi_s1, exp_lo_s1;
  wire              sign_hi_s1, sign_lo_s1;

  wire a_hi_nan_s1, a_lo_nan_s1, b_nan_s1;
  wire a_hi_inf_s1, a_lo_inf_s1, b_inf_s1;
  wire a_hi_zero_s1, a_lo_zero_s1, b_zero_s1;

  wire [15:0] c_lo_s1, c_hi_s1;

  // ---- DSP packs (registered in S1 submodule; used here) ----
  wire [26:0] man_a_packed;
  wire [17:0] man_b_packed;

  // ---- mul meta S1->S2 ----
  reg  signed [8:0] exp_hi_s2, exp_lo_s2;
  reg               sign_hi_s2, sign_lo_s2;

  // Per-operand classification (S1->S2)
  reg a_hi_nan_s2, a_lo_nan_s2, b_nan_s2;
  reg a_hi_inf_s2, a_lo_inf_s2, b_inf_s2;
  reg a_hi_zero_s2, a_lo_zero_s2, b_zero_s2;

  // ---- align C to S2 ----
  reg [15:0] c_lo_s2, c_hi_s2;

  // ---- DSP signals ----
  wire [44:0] product45;
  reg  [35:0] dsp_p;

  // --------------------------
  // Instantiate S1 prenorm/alignment stage
  // --------------------------
  bf16_mac_s1_prep u_s1 (
    .clk(clk),
    .a32(a32),
    .b16(b16),
    .c32(c32),
    .man_a_packed(man_a_packed),
    .man_b_packed(man_b_packed),
    .exp_hi_s1(exp_hi_s1),
    .exp_lo_s1(exp_lo_s1),
    .sign_hi_s1(sign_hi_s1),
    .sign_lo_s1(sign_lo_s1),
    .a_hi_nan_s1(a_hi_nan_s1),
    .a_lo_nan_s1(a_lo_nan_s1),
    .b_nan_s1(b_nan_s1),
    .a_hi_inf_s1(a_hi_inf_s1),
    .a_lo_inf_s1(a_lo_inf_s1),
    .b_inf_s1(b_inf_s1),
    .a_hi_zero_s1(a_hi_zero_s1),
    .a_lo_zero_s1(a_lo_zero_s1),
    .b_zero_s1(b_zero_s1),
    .c_lo_s1(c_lo_s1),
    .c_hi_s1(c_hi_s1)
  );

  // --------------------------
  // DSP (1-cycle product) — remains in top
  // --------------------------
  (* use_dsp = "yes" *)
  dsp_usage u_dsp (
    .clk    (clk),
    .a      ({2'b0, man_a_packed}),
    .b      ({6'b0, man_b_packed}),
    .product(product45)
  );

  // --------------------------
  // S2: capture product + meta + C
  // --------------------------
  always @(posedge clk) begin
    dsp_p      <= product45[35:0];

    exp_hi_s2  <= exp_hi_s1;    exp_lo_s2  <= exp_lo_s1;
    sign_hi_s2 <= sign_hi_s1;   sign_lo_s2 <= sign_lo_s1;

    a_hi_nan_s2  <= a_hi_nan_s1;  a_lo_nan_s2  <= a_lo_nan_s1;  b_nan_s2  <= b_nan_s1;
    a_hi_inf_s2  <= a_hi_inf_s1;  a_lo_inf_s2  <= a_lo_inf_s1;  b_inf_s2  <= b_inf_s1;
    a_hi_zero_s2 <= a_hi_zero_s1; a_lo_zero_s2 <= a_lo_zero_s1; b_zero_s2 <= b_zero_s1;

    c_lo_s2    <= c_lo_s1;
    c_hi_s2    <= c_hi_s1;
  end

  // --------------------------
  // S3/S4 (per lane): pack product or specials, then add C via bf16_add_lane
  // --------------------------
  wire [17:0] P_lo = dsp_p[17:0];
  wire [17:0] P_hi = dsp_p[35:18];

  // Per-lane special controls
  wire nan_hi   = a_hi_nan_s2 | b_nan_s2 | ((a_hi_inf_s2 & b_zero_s2) | (a_hi_zero_s2 & b_inf_s2));
  wire inf_hi   = ~nan_hi  & (a_hi_inf_s2 | b_inf_s2);
  wire zero_hi  = ~nan_hi  & ~inf_hi & (a_hi_zero_s2 | b_zero_s2);
  wire zsign_hi = sign_hi_s2;             // choose XOR sign for zero; change to 1'b0 if you prefer +0
  wire [7:0] ehi = exp_hi_s2[7:0];

  wire nan_lo   = a_lo_nan_s2 | b_nan_s2 | ((a_lo_inf_s2 & b_zero_s2) | (a_lo_zero_s2 & b_inf_s2));
  wire inf_lo   = ~nan_lo  & (a_lo_inf_s2 | b_inf_s2);
  wire zero_lo  = ~nan_lo  & ~inf_lo & (a_lo_zero_s2 | b_zero_s2);
  wire zsign_lo = sign_lo_s2;
  wire [7:0] elo = exp_lo_s2[7:0];

  // BF16 product words (finite path uses existing mapping; overflow check kept)
  // HI lane mapping (matches original comment): carry=dsp_p[31] => P_hi[13]
  wire [15:0] prod_hi16_finite =
      (exp_hi_s2[8] | (exp_hi_s2 > 9'd254)) ? {sign_hi_s2, 8'hFF, 7'b0} :
      (P_hi[13])                            ? {sign_hi_s2, ehi + 8'd1, P_hi[12:6]} :
                                              {sign_hi_s2, ehi,        P_hi[11:5]};

  // LO lane mapping: carry=dsp_p[15] => P_lo[15]
  wire [15:0] prod_lo16_finite =
      (exp_lo_s2[8] | (exp_lo_s2 > 9'd254)) ? {sign_lo_s2, 8'hFF, 7'b0} :
      (P_lo[15])                            ? {sign_lo_s2, elo + 8'd1, P_lo[14:8]} :
                                              {sign_lo_s2, elo,        P_lo[13:7]};

  // Final per-lane product with specials
  wire [15:0] prod_hi16_w =
      nan_hi  ? QNAN16 :
      inf_hi  ? {sign_hi_s2, 8'hFF, 7'd0} :
      zero_hi ? {zsign_hi,    15'h0000}   :
                prod_hi16_finite;

  wire [15:0] prod_lo16_w =
      nan_lo  ? QNAN16 :
      inf_lo  ? {sign_lo_s2, 8'hFF, 7'd0} :
      zero_lo ? {zsign_lo,    15'h0000}   :
                prod_lo16_finite;

  // Lane adders: S3 latch inside; S4 combinational output wires
  wire [15:0] sum_lo16, sum_hi16;

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

  // --------------------------
  // S4 register: final output
  // --------------------------
  always @(posedge clk) begin
    result <= {sum_hi16, sum_lo16};
  end
endmodule


// =============================================================
// S1 module: BF16×BF16 prenorm + align C
// - Extracted from bf16_mac top
// - Registers on posedge clk, II=1
// - Keeps FTZ classification and mantissa packing
// =============================================================
module bf16_mac_s1_prep (
    input  wire        clk,
    input  wire [31:0] a32,     // BF16 lanes {hi[31:16], lo[15:0]}
    input  wire [15:0] b16,     // shared BF16
    input  wire [31:0] c32,     // BF16 addends {hi, lo}

    // outputs consumed by S2 in top
    output reg  [26:0] man_a_packed,
    output reg  [17:0] man_b_packed,

    output reg  signed [8:0] exp_hi_s1,
    output reg  signed [8:0] exp_lo_s1,
    output reg               sign_hi_s1,
    output reg               sign_lo_s1,

    output reg a_hi_nan_s1,
    output reg a_lo_nan_s1,
    output reg b_nan_s1,
    output reg a_hi_inf_s1,
    output reg a_lo_inf_s1,
    output reg b_inf_s1,
    output reg a_hi_zero_s1,
    output reg a_lo_zero_s1,
    output reg b_zero_s1,

    output reg [15:0] c_lo_s1,
    output reg [15:0] c_hi_s1
);
  localparam [7:0]  BF16_BIAS = 8'd127;

  // Power-up clean (optional, FPGA-friendly)
  initial begin
    man_a_packed = 27'd0;
    man_b_packed = 18'd0;

    exp_hi_s1=9'sd0; exp_lo_s1=9'sd0;
    sign_hi_s1=1'b0; sign_lo_s1=1'b0;

    a_hi_nan_s1=1'b0; a_lo_nan_s1=1'b0; b_nan_s1=1'b0;
    a_hi_inf_s1=1'b0; a_lo_inf_s1=1'b0; b_inf_s1=1'b0;
    a_hi_zero_s1=1'b0; a_lo_zero_s1=1'b0; b_zero_s1=1'b0;

    c_lo_s1=16'h0000; c_hi_s1=16'h0000;
  end

  // --------------------------
  // S1: BF16×BF16 prenorm + align C
  // --------------------------
  always @(posedge clk) begin
    // signs (per lane) = XOR
    sign_hi_s1 <= a32[31] ^ b16[15];
    sign_lo_s1 <= a32[15] ^ b16[15];

    // exponents (finite path); signed to catch negatives (underflow) & big positives
    exp_hi_s1 <= {1'b0, a32[30:23]} + {1'b0, b16[14:7]} - {1'b0, BF16_BIAS};
    exp_lo_s1 <= {1'b0, a32[14:7]}  + {1'b0, b16[14:7]} - {1'b0, BF16_BIAS};

    // classify A(hi/lo)
    a_hi_nan_s1  <= (a32[30:23]==8'hFF) && (a32[22:16]!=7'd0);
    a_hi_inf_s1  <= (a32[30:23]==8'hFF) && (a32[22:16]==7'd0);
    a_hi_zero_s1 <= (a32[30:23]==8'd0); // FTZ

    a_lo_nan_s1  <= (a32[14:7]==8'hFF) && (a32[6:0]!=7'd0);
    a_lo_inf_s1  <= (a32[14:7]==8'hFF) && (a32[6:0]==7'd0);
    a_lo_zero_s1 <= (a32[14:7]==8'd0); // FTZ

    // classify shared B
    b_nan_s1     <= (b16[14:7]==8'hFF) && (b16[6:0]!=7'd0);
    b_inf_s1     <= (b16[14:7]==8'hFF) && (b16[6:0]==7'd0);
    b_zero_s1    <= (b16[14:7]==8'd0); // FTZ

    // pack mantissas with hidden-1 (finite path only; specials will bypass)
    man_a_packed <= {3'b0, 1'b1, a32[22:16], 8'd0, 1'b1, a32[6:0]};
    man_b_packed <= {10'b0, 1'b1, b16[6:0]};

    // align C to S2 pipeline boundary (carried to top S2 regs)
    c_lo_s1 <= c32[15:0];
    c_hi_s1 <= c32[31:16];
  end
endmodule

`default_nettype wire
