`timescale 1ns/1ps
`default_nettype none
// =============================================================
// bf16_mul_2lane : 2-lane BF16 x BF16 multiplier
//   LATENCY = 1 : LUT-based multiply (no DSP), 1-cycle registered output.
//   LATENCY = 2 : DSP-based (DSP48E2 27x18), S1 pack + S2 capture.
//
//   Inputs:
//     a32[31:0] = {a_hi[31:16], a_lo[15:0]}  two BF16 lanes
//     b16[15:0] = shared BF16 multiplicand
//   Outputs:
//     p32[31:0] = {prod_hi[31:16], prod_lo[15:0]} two BF16 products
//
//   DSP packing (LATENCY=2):
//     A[26:0] = {3'b0, 1'b1, a_hi[22:16], 8'b0, 1'b1, a_lo[6:0]}
//     B[17:0] = {10'b0, 1'b1, b[6:0]}
//     product45 = A * B via dsp_usage, capture product45[35:0]
//
//   Special handling per lane (NaN/Inf/Zero, FTZ):
//     - NaN  if (a is NaN) or (b is NaN) or (Inf * 0)
//     - Inf  if (a is Inf) or (b is Inf) [and not Inf*0]
//     - Zero if (a is 0) or (b is 0)     [and not Inf*0]
//   FTZ: exp==0 treated as zero.
// =============================================================
module bf16_mul_2lane #(
    parameter LATENCY = 2  // 1 or 2
)(
    input  wire        clk,
    input  wire [31:0] a32,   // {hi[31:16], lo[15:0]}
    input  wire [15:0] b16,   // shared BF16
    output wire [31:0] p32    // {hi, lo} BF16 products
);

  localparam [7:0]  BF16_BIAS = 8'd127;
  localparam [15:0] QNAN16    = 16'h7FC0;

  generate
  // =========================================================================
  // LATENCY = 2 : DSP-based 2-lane multiply (S1 prep + S2 capture)
  // =========================================================================
  if (LATENCY == 2) begin : gen_dsp

    // ---- S1 registered prep (same as bf16_mac_s1_prep) ----
    reg [26:0] man_a_packed;
    reg [17:0] man_b_packed;
    reg signed [8:0] exp_hi_s1, exp_lo_s1;
    reg              sign_hi_s1, sign_lo_s1;
    reg a_hi_nan_s1, a_lo_nan_s1, b_nan_s1;
    reg a_hi_inf_s1, a_lo_inf_s1, b_inf_s1;
    reg a_hi_zero_s1, a_lo_zero_s1, b_zero_s1;

    initial begin
      man_a_packed = 27'd0; man_b_packed = 18'd0;
      exp_hi_s1 = 9'sd0; exp_lo_s1 = 9'sd0;
      sign_hi_s1 = 1'b0; sign_lo_s1 = 1'b0;
      a_hi_nan_s1 = 1'b0; a_lo_nan_s1 = 1'b0; b_nan_s1 = 1'b0;
      a_hi_inf_s1 = 1'b0; a_lo_inf_s1 = 1'b0; b_inf_s1 = 1'b0;
      a_hi_zero_s1 = 1'b0; a_lo_zero_s1 = 1'b0; b_zero_s1 = 1'b0;
    end

    always @(posedge clk) begin
      sign_hi_s1 <= a32[31] ^ b16[15];
      sign_lo_s1 <= a32[15] ^ b16[15];

      exp_hi_s1 <= {1'b0, a32[30:23]} + {1'b0, b16[14:7]} - {1'b0, BF16_BIAS};
      exp_lo_s1 <= {1'b0, a32[14:7]}  + {1'b0, b16[14:7]} - {1'b0, BF16_BIAS};

      a_hi_nan_s1  <= (a32[30:23]==8'hFF) && (a32[22:16]!=7'd0);
      a_hi_inf_s1  <= (a32[30:23]==8'hFF) && (a32[22:16]==7'd0);
      a_hi_zero_s1 <= (a32[30:23]==8'd0);

      a_lo_nan_s1  <= (a32[14:7]==8'hFF) && (a32[6:0]!=7'd0);
      a_lo_inf_s1  <= (a32[14:7]==8'hFF) && (a32[6:0]==7'd0);
      a_lo_zero_s1 <= (a32[14:7]==8'd0);

      b_nan_s1  <= (b16[14:7]==8'hFF) && (b16[6:0]!=7'd0);
      b_inf_s1  <= (b16[14:7]==8'hFF) && (b16[6:0]==7'd0);
      b_zero_s1 <= (b16[14:7]==8'd0);

      man_a_packed <= {3'b0, 1'b1, a32[22:16], 8'd0, 1'b1, a32[6:0]};
      man_b_packed <= {10'b0, 1'b1, b16[6:0]};
    end

    // ---- DSP (combinational product) ----
    wire [44:0] product45;
    (* use_dsp = "yes" *)
    dsp_usage u_dsp (
      .clk    (clk),
      .a      ({2'b0, man_a_packed}),
      .b      ({6'b0, man_b_packed}),
      .product(product45)
    );

    // ---- S2: capture product + meta ----
    reg [35:0] dsp_p;
    reg signed [8:0] exp_hi_s2, exp_lo_s2;
    reg              sign_hi_s2, sign_lo_s2;
    reg a_hi_nan_s2, a_lo_nan_s2, b_nan_s2;
    reg a_hi_inf_s2, a_lo_inf_s2, b_inf_s2;
    reg a_hi_zero_s2, a_lo_zero_s2, b_zero_s2;

    always @(posedge clk) begin
      dsp_p <= product45[35:0];

      exp_hi_s2  <= exp_hi_s1;  exp_lo_s2  <= exp_lo_s1;
      sign_hi_s2 <= sign_hi_s1; sign_lo_s2 <= sign_lo_s1;

      a_hi_nan_s2  <= a_hi_nan_s1;  a_lo_nan_s2  <= a_lo_nan_s1;  b_nan_s2  <= b_nan_s1;
      a_hi_inf_s2  <= a_hi_inf_s1;  a_lo_inf_s2  <= a_lo_inf_s1;  b_inf_s2  <= b_inf_s1;
      a_hi_zero_s2 <= a_hi_zero_s1; a_lo_zero_s2 <= a_lo_zero_s1; b_zero_s2 <= b_zero_s1;
    end

    // ---- Lane unpack & compose BF16 products (combinational from S2 regs) ----
    wire [17:0] P_lo = dsp_p[17:0];
    wire [17:0] P_hi = dsp_p[35:18];

    // HI lane specials
    wire nan_hi  = a_hi_nan_s2 | b_nan_s2 |
                   ((a_hi_inf_s2 & b_zero_s2) | (a_hi_zero_s2 & b_inf_s2));
    wire inf_hi  = ~nan_hi & (a_hi_inf_s2 | b_inf_s2);
    wire zero_hi = ~nan_hi & ~inf_hi & (a_hi_zero_s2 | b_zero_s2);
    wire [7:0] ehi = exp_hi_s2[7:0];

    wire [15:0] prod_hi16_finite =
        (exp_hi_s2[8] | (exp_hi_s2 > 9'd254)) ? {sign_hi_s2, 8'hFF, 7'b0} :
        (P_hi[13])                             ? {sign_hi_s2, ehi + 8'd1, P_hi[12:6]} :
                                                  {sign_hi_s2, ehi,        P_hi[11:5]};

    wire [15:0] prod_hi16 =
        nan_hi  ? QNAN16 :
        inf_hi  ? {sign_hi_s2, 8'hFF, 7'd0} :
        zero_hi ? {sign_hi_s2, 15'h0000} :
                  prod_hi16_finite;

    // LO lane specials
    wire nan_lo  = a_lo_nan_s2 | b_nan_s2 |
                   ((a_lo_inf_s2 & b_zero_s2) | (a_lo_zero_s2 & b_inf_s2));
    wire inf_lo  = ~nan_lo & (a_lo_inf_s2 | b_inf_s2);
    wire zero_lo = ~nan_lo & ~inf_lo & (a_lo_zero_s2 | b_zero_s2);
    wire [7:0] elo = exp_lo_s2[7:0];

    wire [15:0] prod_lo16_finite =
        (exp_lo_s2[8] | (exp_lo_s2 > 9'd254)) ? {sign_lo_s2, 8'hFF, 7'b0} :
        (P_lo[15])                             ? {sign_lo_s2, elo + 8'd1, P_lo[14:8]} :
                                                  {sign_lo_s2, elo,        P_lo[13:7]};

    wire [15:0] prod_lo16 =
        nan_lo  ? QNAN16 :
        inf_lo  ? {sign_lo_s2, 8'hFF, 7'd0} :
        zero_lo ? {sign_lo_s2, 15'h0000} :
                  prod_lo16_finite;

    assign p32 = {prod_hi16, prod_lo16};

  end // gen_dsp

  // =========================================================================
  // LATENCY = 1 : LUT-based multiply (no DSP), single-cycle registered out
  // =========================================================================
  else begin : gen_lut

    // Unpack BF16 fields
    wire        s_hi = a32[31];
    wire [7:0]  e_hi = a32[30:23];
    wire [6:0]  f_hi = a32[22:16];
    wire        s_lo = a32[15];
    wire [7:0]  e_lo = a32[14:7];
    wire [6:0]  f_lo = a32[6:0];
    wire        s_b  = b16[15];
    wire [7:0]  e_b  = b16[14:7];
    wire [6:0]  f_b  = b16[6:0];

    // Classify
    wire hi_nan  = (e_hi == 8'hFF) && (f_hi != 7'd0);
    wire hi_inf  = (e_hi == 8'hFF) && (f_hi == 7'd0);
    wire hi_zero = (e_hi == 8'd0);
    wire lo_nan  = (e_lo == 8'hFF) && (f_lo != 7'd0);
    wire lo_inf  = (e_lo == 8'hFF) && (f_lo == 7'd0);
    wire lo_zero = (e_lo == 8'd0);
    wire b_nan   = (e_b  == 8'hFF) && (f_b  != 7'd0);
    wire b_inf   = (e_b  == 8'hFF) && (f_b  == 7'd0);
    wire b_zero  = (e_b  == 8'd0);

    // Mantissa multiply (8x8 = 16 bits)
    wire [7:0] m_hi = {1'b1, f_hi};
    wire [7:0] m_lo = {1'b1, f_lo};
    wire [7:0] m_b  = {1'b1, f_b};
    wire [15:0] mul_hi = m_hi * m_b;
    wire [15:0] mul_lo = m_lo * m_b;

    // Exponent
    wire signed [8:0] exp_hi_raw = {1'b0, e_hi} + {1'b0, e_b} - {1'b0, BF16_BIAS};
    wire signed [8:0] exp_lo_raw = {1'b0, e_lo} + {1'b0, e_b} - {1'b0, BF16_BIAS};

    // Compose per lane
    wire sign_hi_w = s_hi ^ s_b;
    wire sign_lo_w = s_lo ^ s_b;

    // HI specials
    wire snan_hi = hi_nan | b_nan | ((hi_inf & b_zero) | (hi_zero & b_inf));
    wire sinf_hi = ~snan_hi & (hi_inf | b_inf);
    wire szro_hi = ~snan_hi & ~sinf_hi & (hi_zero | b_zero);

    wire [15:0] hi_finite =
        (exp_hi_raw[8] | (exp_hi_raw > 9'd254)) ? {sign_hi_w, 8'hFF, 7'd0} :
        mul_hi[15] ? {sign_hi_w, exp_hi_raw[7:0] + 8'd1, mul_hi[14:8]} :
                     {sign_hi_w, exp_hi_raw[7:0],         mul_hi[13:7]};

    wire [15:0] hi_out =
        snan_hi ? QNAN16 :
        sinf_hi ? {sign_hi_w, 8'hFF, 7'd0} :
        szro_hi ? {sign_hi_w, 15'd0} :
                  hi_finite;

    // LO specials
    wire snan_lo = lo_nan | b_nan | ((lo_inf & b_zero) | (lo_zero & b_inf));
    wire sinf_lo = ~snan_lo & (lo_inf | b_inf);
    wire szro_lo = ~snan_lo & ~sinf_lo & (lo_zero | b_zero);

    wire [15:0] lo_finite =
        (exp_lo_raw[8] | (exp_lo_raw > 9'd254)) ? {sign_lo_w, 8'hFF, 7'd0} :
        mul_lo[15] ? {sign_lo_w, exp_lo_raw[7:0] + 8'd1, mul_lo[14:8]} :
                     {sign_lo_w, exp_lo_raw[7:0],         mul_lo[13:7]};

    wire [15:0] lo_out =
        snan_lo ? QNAN16 :
        sinf_lo ? {sign_lo_w, 8'hFF, 7'd0} :
        szro_lo ? {sign_lo_w, 15'd0} :
                  lo_finite;

    reg [31:0] p32_r;
    always @(posedge clk) begin
      p32_r <= {hi_out, lo_out};
    end
    assign p32 = p32_r;

  end // gen_lut
  endgenerate

endmodule

`default_nettype wire
