`timescale 1ns/1ps
`default_nettype none

// =============================================================
// int8_bf16_mac
//   mode_int8 = 1'b1 : INT8xINT8 -> INT16 magnitudes, sat-add with 32-bit C lanes
//   mode_int8 = 1'b0 : BF16xBF16 -> BF16 (two lanes), add with BF16 C
//   I/O packing: A={HI[31:24],...,LO[15:8]} for INT8; BF16 lanes packed in A
//                B: single INT8 (for INT8) or BF16 (for BF16)
//                C (INT mode) = {c_hi32, c_lo32}; BF16 uses lower 32 bits {hi16, lo16}
//   Output: INT mode => {hi32, lo32}; BF16 mode occupies lower 32 bits
//   Pipeline: S1 (mapper) -> S2 (postproc) -> S3 (adder regs) -> S4 (out reg)
// =============================================================
module int8_bf16_mac (
    input  wire        clk,
    input  wire        mode_int8,   // 1 -> INT8 path, 0 -> BF16 path
    input  wire [31:0] a32,         // packed lanes (INT8 or BF16)
    input  wire [15:0] b16,         // shared (INT8 or BF16)
    input  wire [63:0] c64,         // INT mode: {c_hi32, c_lo32}; BF16 mode uses lower 32 bits {hi16, lo16}
    output reg  [63:0] result       // INT mode: {hi32, lo32}; BF16 mode occupies lower 32 bits
);

  // ----------------------------
  // Mode pipeline (S1..S4)
  // ----------------------------
  reg mode_s1, mode_s2, mode_s3;
  always @(posedge clk) begin
    mode_s1 <= mode_int8;
    mode_s2 <= mode_s1;
    mode_s3 <= mode_s2;
  end

  // ===========================================================
  // S1: Mappers (compute DSP operands + meta)
  // ===========================================================
  // INT8 mapper
  wire [26:0] dsp_a_s1_int8;
  wire [17:0] dsp_b_s1_int8;
  wire        sign_hi_int8_s1, sign_lo_int8_s1;
  wire [31:0] c_hi_int8_s1, c_lo_int8_s1;

  mac_mapper_int8 u_map_int8 (
    .clk             (clk),
    .a32             (a32),
    .b16             (b16),
    .c64             (c64),
    .dsp_a_s1        (dsp_a_s1_int8),
    .dsp_b_s1        (dsp_b_s1_int8),
    .sign_hi_int8_s1 (sign_hi_int8_s1),
    .sign_lo_int8_s1 (sign_lo_int8_s1),
    .c_hi_s1         (c_hi_int8_s1),
    .c_lo_s1         (c_lo_int8_s1)
  );

  // BF16 mapper
  wire [26:0] dsp_a_s1_bf16;
  wire [17:0] dsp_b_s1_bf16;
  wire signed [8:0] exp_hi_bf16_s1, exp_lo_bf16_s1;
  wire        sign_hi_bf16_s1, sign_lo_bf16_s1;
  wire        a_hi_nan_s1, a_lo_nan_s1, b_nan_s1;
  wire        a_hi_inf_s1, a_lo_inf_s1, b_inf_s1;
  wire        a_hi_zero_s1, a_lo_zero_s1, b_zero_s1;
  wire [15:0] c_hi_bf16_s1, c_lo_bf16_s1;

  wire [15:0] c_lo_bf16_in = c64[15:0];
  wire [15:0] c_hi_bf16_in = c64[31:16];

  mac_mapper_bf16 u_map_bf16 (
    .clk               (clk),
    .a32               (a32),
    .b16               (b16),
    .c32               ({c_hi_bf16_in, c_lo_bf16_in}),
    .dsp_a_s1          (dsp_a_s1_bf16),
    .dsp_b_s1          (dsp_b_s1_bf16),
    .exp_hi_bf16_s1    (exp_hi_bf16_s1),
    .exp_lo_bf16_s1    (exp_lo_bf16_s1),
    .sign_hi_bf16_s1   (sign_hi_bf16_s1),
    .sign_lo_bf16_s1   (sign_lo_bf16_s1),
    .a_hi_nan_s1       (a_hi_nan_s1),
    .a_lo_nan_s1       (a_lo_nan_s1),
    .b_nan_s1          (b_nan_s1),
    .a_hi_inf_s1       (a_hi_inf_s1),
    .a_lo_inf_s1       (a_lo_inf_s1),
    .b_inf_s1          (b_inf_s1),
    .a_hi_zero_s1      (a_hi_zero_s1),
    .a_lo_zero_s1      (a_lo_zero_s1),
    .b_zero_s1         (b_zero_s1),
    .c_lo_s1           (c_lo_bf16_s1),
    .c_hi_s1           (c_hi_bf16_s1)
  );

  // ===========================================================
  // Mux DSP operands for single shared DSP block (S1 data)
  // ===========================================================
  wire [26:0] dsp_a_s1 = mode_s1 ? dsp_a_s1_int8 : dsp_a_s1_bf16;
  wire [17:0] dsp_b_s1 = mode_s1 ? dsp_b_s1_int8 : dsp_b_s1_bf16;

  wire [44:0] product45;
  dsp_usage u_dsp (
    .clk     (clk),
    .a       (dsp_a_s1),
    .b       (dsp_b_s1),
    .product (product45)
  );

  // ===========================================================
  // S2: Post-processing (lane split, specials, normalization)
  // ===========================================================
  // INT8 postproc
  wire        sign_hi_int8_s2, sign_lo_int8_s2;
  wire [31:0] c_hi_int8_s2,   c_lo_int8_s2;
  wire [15:0] prod_hi16_int8_mag, prod_lo16_int8_mag;

  mac_postproc_int8 u_pp_int8 (
    .clk                 (clk),
    .sign_hi_int8_s1     (sign_hi_int8_s1),
    .sign_lo_int8_s1     (sign_lo_int8_s1),
    .c_hi_int8_s1        (c_hi_int8_s1),
    .c_lo_int8_s1        (c_lo_int8_s1),
    .product45           (product45),
    .sign_hi_int8_s2     (sign_hi_int8_s2),
    .sign_lo_int8_s2     (sign_lo_int8_s2),
    .c_hi_int8_s2        (c_hi_int8_s2),
    .c_lo_int8_s2        (c_lo_int8_s2),
    .prod_hi16_int8_mag  (prod_hi16_int8_mag),
    .prod_lo16_int8_mag  (prod_lo16_int8_mag)
  );

  // BF16 postproc
  wire [15:0] prod_lo16_bf16, prod_hi16_bf16;
  wire [15:0] c_lo_bf16_s2,   c_hi_bf16_s2;

  mac_postproc_bf16 u_pp_bf16 (
    .clk               (clk),
    .exp_hi_bf16_s1    (exp_hi_bf16_s1),
    .exp_lo_bf16_s1    (exp_lo_bf16_s1),
    .sign_hi_bf16_s1   (sign_hi_bf16_s1),
    .sign_lo_bf16_s1   (sign_lo_bf16_s1),
    .a_hi_nan_s1       (a_hi_nan_s1),
    .a_lo_nan_s1       (a_lo_nan_s1),
    .b_nan_s1          (b_nan_s1),
    .a_hi_inf_s1       (a_hi_inf_s1),
    .a_lo_inf_s1       (a_lo_inf_s1),
    .b_inf_s1          (b_inf_s1),
    .a_hi_zero_s1      (a_hi_zero_s1),
    .a_lo_zero_s1      (a_lo_zero_s1),
    .b_zero_s1         (b_zero_s1),
    .c_lo_bf16_s1      (c_lo_bf16_s1),
    .c_hi_bf16_s1      (c_hi_bf16_s1),
    .product45         (product45),
    .prod_lo16_bf16    (prod_lo16_bf16),
    .prod_hi16_bf16    (prod_hi16_bf16),
    .c_lo_bf16_s2      (c_lo_bf16_s2),
    .c_hi_bf16_s2      (c_hi_bf16_s2)
  );

  // ===========================================================
  // S3: Adders (registered internally in adders)
  //   - INT8: saturating INT16 add (two lanes)
  //   - BF16: BF16 add (two lanes)
  //   NOTE: both adders include an S3 register stage and drive
  //         combinational outputs; we capture them at S4 below.
  // ===========================================================
  wire [31:0] int8_hi_sum_s4, int8_lo_sum_s4;
  int8_add u_int8_add_hi (
    .clk           (clk),
    .prod_mag16_s2 (prod_hi16_int8_mag),
    .prod_sign_s2  (sign_hi_int8_s2),
    .c32_s2        (c_hi_int8_s2),
    .sum32_out     (int8_hi_sum_s4)
  );
  int8_add u_int8_add_lo (
    .clk           (clk),
    .prod_mag16_s2 (prod_lo16_int8_mag),
    .prod_sign_s2  (sign_lo_int8_s2),
    .c32_s2        (c_lo_int8_s2),
    .sum32_out     (int8_lo_sum_s4)
  );

  wire [15:0] bf16_hi_sum_s4, bf16_lo_sum_s4;
  bf16_add u_bf16_add_hi (
    .clk (clk),
    .a16 (prod_hi16_bf16),
    .b16 (c_hi_bf16_s2),
    .c16 (bf16_hi_sum_s4)
  );
  bf16_add u_bf16_add_lo (
    .clk (clk),
    .a16 (prod_lo16_bf16),
    .b16 (c_lo_bf16_s2),
    .c16 (bf16_lo_sum_s4)
  );

  // ===========================================================
  // S4: Output register (aligns total latency to 4 cycles)
  // ===========================================================
  always @(posedge clk) begin
    if (mode_s3) begin
      result <= {int8_hi_sum_s4, int8_lo_sum_s4};
    end else begin
      result <= {32'd0, bf16_hi_sum_s4, bf16_lo_sum_s4};
    end
  end

endmodule

`default_nettype wire
