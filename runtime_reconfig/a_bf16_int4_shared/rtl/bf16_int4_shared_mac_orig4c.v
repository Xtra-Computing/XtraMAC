`timescale 1ns/1ps
`default_nettype none

// =============================================================
// bf16_int4_shared_mac_orig4c
//   - Combined INT4×BF16+BF16 and BF16×BF16+BF16 MAC
//   - Shared DSP48 pipeline
//   - Pipeline: S1 mapper (bf16/int4) -> S2 postproc -> S3 bf16_add_orig4c -> S4 out reg
//   - II = 1, latency = 4 cycles
//   - INT4 mapping: a_bf16_int4[3:0] = lane0, [7:4] = lane1 (two's complement)
// =============================================================
module bf16_int4_shared_mac_orig4c (
    input  wire        clk,
    input  wire        mode_int4,      // 1 => use INT4 mapper, 0 => BF16 mapper
    input  wire [31:0] a_bf16_int4,    // BF16 lanes {hi, lo} or packed INT4 lanes (lo nibble first)
    input  wire [15:0] b16,
    input  wire [31:0] c32,
    output reg  [31:0] result
);
  localparam [15:0] QNAN16 = 16'h7FC0;

  // ---- S1 mapper outputs (BF16 path) ----
  wire [26:0] man_a_bf16_s1;
  wire [17:0] man_b_bf16_s1;
  wire signed [8:0] exp_hi_bf16_s1, exp_lo_bf16_s1;
  wire sign_hi_bf16_s1, sign_lo_bf16_s1;
  wire a_hi_nan_bf16_s1, a_lo_nan_bf16_s1, b_nan_bf16_s1;
  wire a_hi_inf_bf16_s1, a_lo_inf_bf16_s1, b_inf_bf16_s1;
  wire a_hi_zero_bf16_s1, a_lo_zero_bf16_s1, b_zero_bf16_s1;
  wire [15:0] c_lo_bf16_s1, c_hi_bf16_s1;

  bf16_mac_s1_prep_orig4c u_s1_bf16 (
      .clk(clk),
      .a32(a_bf16_int4),
      .b16(b16),
      .c32(c32),
      .man_a_packed(man_a_bf16_s1),
      .man_b_packed(man_b_bf16_s1),
      .exp_hi_s1(exp_hi_bf16_s1),
      .exp_lo_s1(exp_lo_bf16_s1),
      .sign_hi_s1(sign_hi_bf16_s1),
      .sign_lo_s1(sign_lo_bf16_s1),
      .a_hi_nan_s1(a_hi_nan_bf16_s1),
      .a_lo_nan_s1(a_lo_nan_bf16_s1),
      .b_nan_s1(b_nan_bf16_s1),
      .a_hi_inf_s1(a_hi_inf_bf16_s1),
      .a_lo_inf_s1(a_lo_inf_bf16_s1),
      .b_inf_s1(b_inf_bf16_s1),
      .a_hi_zero_s1(a_hi_zero_bf16_s1),
      .a_lo_zero_s1(a_lo_zero_bf16_s1),
      .b_zero_s1(b_zero_bf16_s1),
      .c_lo_s1(c_lo_bf16_s1),
      .c_hi_s1(c_hi_bf16_s1)
  );

  // ---- S1 mapper outputs (INT4 path) ----
  wire [26:0] man_a_i4_s1;
  wire [17:0] man_b_i4_s1;
  wire signed [8:0] exp_hi_i4_s1, exp_lo_i4_s1;
  wire sign_hi_i4_s1, sign_lo_i4_s1;
  wire a_hi_nan_i4_s1, a_lo_nan_i4_s1, b_nan_i4_s1;
  wire a_hi_inf_i4_s1, a_lo_inf_i4_s1, b_inf_i4_s1;
  wire a_hi_zero_i4_s1, a_lo_zero_i4_s1, b_zero_i4_s1;
  wire [15:0] c_lo_i4_s1, c_hi_i4_s1;

  int4_bf16_mac_s1_mapper_orig4c u_s1_int4 (
      .clk(clk),
      .a_int4_bus(a_bf16_int4),
      .b16(b16),
      .c32(c32),
      .man_a_packed(man_a_i4_s1),
      .man_b_packed(man_b_i4_s1),
      .exp_hi_s1(exp_hi_i4_s1),
      .exp_lo_s1(exp_lo_i4_s1),
      .sign_hi_s1(sign_hi_i4_s1),
      .sign_lo_s1(sign_lo_i4_s1),
      .a_hi_nan_s1(a_hi_nan_i4_s1),
      .a_lo_nan_s1(a_lo_nan_i4_s1),
      .b_nan_s1(b_nan_i4_s1),
      .a_hi_inf_s1(a_hi_inf_i4_s1),
      .a_lo_inf_s1(a_lo_inf_i4_s1),
      .b_inf_s1(b_inf_i4_s1),
      .a_hi_zero_s1(a_hi_zero_i4_s1),
      .a_lo_zero_s1(a_lo_zero_i4_s1),
      .b_zero_s1(b_zero_i4_s1),
      .c_lo_s1(c_lo_i4_s1),
      .c_hi_s1(c_hi_i4_s1)
  );

  // ---- Mode pipeline register to align with registered mapper outputs ----
  reg mode_s1;
  always @(posedge clk) begin
    mode_s1 <= mode_int4;
  end

  // ---- Mux S1 outputs based on registered mode ----
  wire [26:0] man_a_packed_s1 = mode_s1 ? man_a_i4_s1       : man_a_bf16_s1;
  wire [17:0] man_b_packed_s1 = mode_s1 ? man_b_i4_s1       : man_b_bf16_s1;
  wire signed [8:0] exp_hi_s1 = mode_s1 ? exp_hi_i4_s1      : exp_hi_bf16_s1;
  wire signed [8:0] exp_lo_s1 = mode_s1 ? exp_lo_i4_s1      : exp_lo_bf16_s1;
  wire sign_hi_s1             = mode_s1 ? sign_hi_i4_s1     : sign_hi_bf16_s1;
  wire sign_lo_s1             = mode_s1 ? sign_lo_i4_s1     : sign_lo_bf16_s1;
  wire a_hi_nan_s1            = mode_s1 ? a_hi_nan_i4_s1    : a_hi_nan_bf16_s1;
  wire a_lo_nan_s1            = mode_s1 ? a_lo_nan_i4_s1    : a_lo_nan_bf16_s1;
  wire b_nan_s1               = mode_s1 ? b_nan_i4_s1       : b_nan_bf16_s1;
  wire a_hi_inf_s1            = mode_s1 ? a_hi_inf_i4_s1    : a_hi_inf_bf16_s1;
  wire a_lo_inf_s1            = mode_s1 ? a_lo_inf_i4_s1    : a_lo_inf_bf16_s1;
  wire b_inf_s1               = mode_s1 ? b_inf_i4_s1       : b_inf_bf16_s1;
  wire a_hi_zero_s1           = mode_s1 ? a_hi_zero_i4_s1   : a_hi_zero_bf16_s1;
  wire a_lo_zero_s1           = mode_s1 ? a_lo_zero_i4_s1   : a_lo_zero_bf16_s1;
  wire b_zero_s1              = mode_s1 ? b_zero_i4_s1      : b_zero_bf16_s1;
  wire [15:0] c_lo_s1         = mode_s1 ? c_lo_i4_s1        : c_lo_bf16_s1;
  wire [15:0] c_hi_s1         = mode_s1 ? c_hi_i4_s1        : c_hi_bf16_s1;

  // ---- DSP stage (shared) ----
  wire [44:0] product45;
  reg  [35:0] dsp_p;

  (* use_dsp = "yes" *)
  dsp_usage_orig4c u_dsp (
      .clk    (clk),
      .a      ({2'b0, man_a_packed_s1}),
      .b      ({6'b0, man_b_packed_s1}),
      .product(product45)
  );

  // ---- S2 registers (post-processing inputs) ----
  reg signed [8:0] exp_hi_s2, exp_lo_s2;
  reg        sign_hi_s2, sign_lo_s2;
  reg a_hi_nan_s2, a_lo_nan_s2, b_nan_s2;
  reg a_hi_inf_s2, a_lo_inf_s2, b_inf_s2;
  reg a_hi_zero_s2, a_lo_zero_s2, b_zero_s2;
  reg [15:0] c_lo_s2, c_hi_s2;

  always @(posedge clk) begin
    dsp_p <= product45[35:0];

    exp_hi_s2  <= exp_hi_s1;    exp_lo_s2  <= exp_lo_s1;
    sign_hi_s2 <= sign_hi_s1;   sign_lo_s2 <= sign_lo_s1;

    a_hi_nan_s2  <= a_hi_nan_s1;  a_lo_nan_s2  <= a_lo_nan_s1;  b_nan_s2  <= b_nan_s1;
    a_hi_inf_s2  <= a_hi_inf_s1;  a_lo_inf_s2  <= a_lo_inf_s1;  b_inf_s2  <= b_inf_s1;
    a_hi_zero_s2 <= a_hi_zero_s1; a_lo_zero_s2 <= a_lo_zero_s1; b_zero_s2 <= b_zero_s1;

    c_lo_s2 <= c_lo_s1;
    c_hi_s2 <= c_hi_s1;
  end

  // ---- S3 lane packing + specials (reused from bf16_mac_orig4c) ----
  wire [17:0] P_lo = dsp_p[17:0];
  wire [17:0] P_hi = dsp_p[35:18];

  wire nan_hi   = a_hi_nan_s2 | b_nan_s2 | ((a_hi_inf_s2 & b_zero_s2) | (a_hi_zero_s2 & b_inf_s2));
  wire inf_hi   = ~nan_hi  & (a_hi_inf_s2 | b_inf_s2);
  wire zero_hi  = ~nan_hi  & ~inf_hi & (a_hi_zero_s2 | b_zero_s2);
  wire zsign_hi = sign_hi_s2;
  wire [7:0] ehi = exp_hi_s2[7:0];

  wire nan_lo   = a_lo_nan_s2 | b_nan_s2 | ((a_lo_inf_s2 & b_zero_s2) | (a_lo_zero_s2 & b_inf_s2));
  wire inf_lo   = ~nan_lo  & (a_lo_inf_s2 | b_inf_s2);
  wire zero_lo  = ~nan_lo  & ~inf_lo & (a_lo_zero_s2 | b_zero_s2);
  wire zsign_lo = sign_lo_s2;
  wire [7:0] elo = exp_lo_s2[7:0];

  wire [15:0] prod_hi16_finite =
      (exp_hi_s2[8] | (exp_hi_s2 > 9'd254)) ? {sign_hi_s2, 8'hFF, 7'b0} :
      (P_hi[13])                            ? {sign_hi_s2, ehi + 8'd1, P_hi[12:6]} :
                                              {sign_hi_s2, ehi,        P_hi[11:5]};

  wire [15:0] prod_lo16_finite =
      (exp_lo_s2[8] | (exp_lo_s2 > 9'd254)) ? {sign_lo_s2, 8'hFF, 7'b0} :
      (P_lo[15])                            ? {sign_lo_s2, elo + 8'd1, P_lo[14:8]} :
                                              {sign_lo_s2, elo,        P_lo[13:7]};

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

  wire [15:0] sum_lo16, sum_hi16;

  bf16_add_orig4c u_add_lo (
      .clk (clk),
      .a16 (prod_lo16_w),
      .b16 (c_lo_s2),
      .c16 (sum_lo16)
  );

  bf16_add_orig4c u_add_hi (
      .clk (clk),
      .a16 (prod_hi16_w),
      .b16 (c_hi_s2),
      .c16 (sum_hi16)
  );

  // ---- S4 output register ----
  always @(posedge clk) begin
    result <= {sum_hi16, sum_lo16};
  end
endmodule

// =============================================================
// INT4 mapper: converts two INT4 lanes to BF16 and reuses BF16 prenorm flow
// =============================================================
module int4_bf16_mac_s1_mapper_orig4c (
    input  wire        clk,
    input  wire [31:0] a_int4_bus, // uses [3:0]=lo lane, [7:4]=hi lane
    input  wire [15:0] b16,
    input  wire [31:0] c32,

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
  localparam [7:0] BF16_BIAS = 8'd127;

  wire [15:0] a_lo_bf16 = int4_to_bf16(a_int4_bus[3:0]);
  wire [15:0] a_hi_bf16 = int4_to_bf16(a_int4_bus[7:4]);
  wire [31:0] a32_mux   = {a_hi_bf16, a_lo_bf16};

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

  always @(posedge clk) begin
    sign_hi_s1 <= a32_mux[31] ^ b16[15];
    sign_lo_s1 <= a32_mux[15] ^ b16[15];

    exp_hi_s1 <= {1'b0, a32_mux[30:23]} + {1'b0, b16[14:7]} - {1'b0, BF16_BIAS};
    exp_lo_s1 <= {1'b0, a32_mux[14:7]}  + {1'b0, b16[14:7]} - {1'b0, BF16_BIAS};

    a_hi_nan_s1  <= (a32_mux[30:23]==8'hFF) && (a32_mux[22:16]!=7'd0);
    a_hi_inf_s1  <= (a32_mux[30:23]==8'hFF) && (a32_mux[22:16]==7'd0);
    a_hi_zero_s1 <= (a32_mux[30:23]==8'd0);

    a_lo_nan_s1  <= (a32_mux[14:7]==8'hFF) && (a32_mux[6:0]!=7'd0);
    a_lo_inf_s1  <= (a32_mux[14:7]==8'hFF) && (a32_mux[6:0]==7'd0);
    a_lo_zero_s1 <= (a32_mux[14:7]==8'd0);

    b_nan_s1  <= (b16[14:7]==8'hFF) && (b16[6:0]!=7'd0);
    b_inf_s1  <= (b16[14:7]==8'hFF) && (b16[6:0]==7'd0);
    b_zero_s1 <= (b16[14:7]==8'd0);

    man_a_packed <= {3'b0, 1'b1, a32_mux[22:16], 8'd0, 1'b1, a32_mux[6:0]};
    man_b_packed <= {10'b0, 1'b1, b16[6:0]};

    c_lo_s1 <= c32[15:0];
    c_hi_s1 <= c32[31:16];
  end

  // INT4 -> BF16 conversion via sign-extension to 8-bit magnitude
  function automatic [15:0] int4_to_bf16;
    input [3:0] x;
    reg [7:0] val8;
    reg        sign;
    reg [7:0]  mag;
    reg [7:0]  exp_bf16;
    reg [6:0]  frac_bf16;
    reg [7:0]  shift_tmp;
    integer    k;
    begin
      val8 = {{4{x[3]}}, x}; // sign-extend to 8 bits
      sign = val8[7];
      mag  = sign ? (~val8 + 8'd1) : val8;

      if (mag == 8'd0) begin
        int4_to_bf16 = {sign, 15'd0};
      end else begin
        casex (mag)
          8'b1xxxxxxx: k = 7;
          8'b01xxxxxx: k = 6;
          8'b001xxxxx: k = 5;
          8'b0001xxxx: k = 4;
          8'b00001xxx: k = 3;
          8'b000001xx: k = 2;
          8'b0000001x: k = 1;
          default:      k = 0;
        endcase

        exp_bf16  = k + 8'd127;
        shift_tmp = mag << (7 - k);
        frac_bf16 = shift_tmp[6:0];

        int4_to_bf16 = {sign, exp_bf16, frac_bf16};
      end
    end
  endfunction
endmodule

`default_nettype wire
