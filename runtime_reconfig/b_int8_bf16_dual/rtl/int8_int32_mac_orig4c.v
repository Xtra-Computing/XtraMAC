`timescale 1ns/1ps
`default_nettype none

// =============================================================
// int8_int32_mac_orig4c
//   Two-lane INT8×INT8 products accumulated into INT32 addends
//   Pipeline: S1 mapper -> S2 postproc -> S3 int8_add_orig4c -> S4 out reg
// =============================================================
module int8_int32_mac_orig4c (
    input  wire        clk,
    input  wire [31:0] a32,   // packed INT8 lanes: HI in [31:24], LO in [15:8]
    input  wire [15:0] b16,   // shared INT8 multiplicand (use [15:8])
    input  wire [63:0] c64,   // INT32 addends: {c_hi32, c_lo32}
    output reg  [63:0] result // {hi32, lo32}
);
  // --------------------------
  // S1: INT8 mapper
  // --------------------------
  wire [26:0] dsp_a_s1;
  wire [17:0] dsp_b_s1;
  wire        sign_hi_s1, sign_lo_s1;
  wire [31:0] c_hi_s1, c_lo_s1;

  mac_mapper_int8_orig4c u_map_int8 (
      .clk       (clk),
      .a32       (a32),
      .b16       (b16),
      .c64       (c64),
      .dsp_a_s1  (dsp_a_s1),
      .dsp_b_s1  (dsp_b_s1),
      .sign_hi_int8_s1 (sign_hi_s1),
      .sign_lo_int8_s1 (sign_lo_s1),
      .c_hi_s1   (c_hi_s1),
      .c_lo_s1   (c_lo_s1)
  );

  // --------------------------
  // Shared DSP (still 27×18)
  // --------------------------
  wire [44:0] product45;
  dsp_usage_orig4c u_dsp (
      .clk     (clk),
      .a       (dsp_a_s1),
      .b       (dsp_b_s1),
      .product (product45)
  );

  // --------------------------
  // S2: Post-processing (split DSP lanes, pass metadata)
  // --------------------------
  wire        sign_hi_s2, sign_lo_s2;
  wire [31:0] c_hi_s2, c_lo_s2;
  wire [15:0] prod_hi_mag_s2, prod_lo_mag_s2;

  mac_postproc_int8_orig4c u_post_int8 (
      .clk                 (clk),
      .sign_hi_int8_s1     (sign_hi_s1),
      .sign_lo_int8_s1     (sign_lo_s1),
      .c_hi_int8_s1        (c_hi_s1),
      .c_lo_int8_s1        (c_lo_s1),
      .product45           (product45),
      .sign_hi_int8_s2     (sign_hi_s2),
      .sign_lo_int8_s2     (sign_lo_s2),
      .c_hi_int8_s2        (c_hi_s2),
      .c_lo_int8_s2        (c_lo_s2),
      .prod_hi16_int8_mag  (prod_hi_mag_s2),
      .prod_lo16_int8_mag  (prod_lo_mag_s2)
  );

  // --------------------------
  // S3: Saturating INT32 adders (registers inside)
  // --------------------------
  wire [31:0] sum_hi_s4, sum_lo_s4;

  int8_add_orig4c u_int8_add_hi (
      .clk           (clk),
      .prod_mag16_s2 (prod_hi_mag_s2),
      .prod_sign_s2  (sign_hi_s2),
      .c32_s2        (c_hi_s2),
      .sum32_out     (sum_hi_s4)
  );

  int8_add_orig4c u_int8_add_lo (
      .clk           (clk),
      .prod_mag16_s2 (prod_lo_mag_s2),
      .prod_sign_s2  (sign_lo_s2),
      .c32_s2        (c_lo_s2),
      .sum32_out     (sum_lo_s4)
  );

  // --------------------------
  // S4: Output register
  // --------------------------
  always @(posedge clk) begin
    result <= {sum_hi_s4, sum_lo_s4};
  end
endmodule

`default_nettype wire
