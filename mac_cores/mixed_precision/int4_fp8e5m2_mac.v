`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// int4_fp8e5m2_mac -- INT4 x FP8(E5M2) + FP8 -> FP8, 4-lane
//   Two signed INT4 lanes (two's complement) x two FP8(E5M2) lanes.
//   INT4 is decoded via int4_fp8_common.vh into sign + unbiased exponent +
//   3-bit mantissa, then biased to E5M2 (bias=15).  A-side mantissas are
//   packed into the DSP alongside FP8 B-lanes.
//
//   Parameters:
//     MUL_LAT    -- multiplier latency (default 2)
//     MID_STAGES -- extra pipeline registers between mul and add (default 0)
//     ADD_LAT    -- adder latency (default 1)
// ======================================================================
module int4_fp8e5m2_mac #(
    parameter integer MUL_LAT    = 2,
    parameter integer MID_STAGES = 0,
    parameter integer ADD_LAT    = 1
) (
    input  wire        clk,
    input  wire [7:0]  a_int4,   // {a2[7:4], a1[3:0]} signed INT4 lanes
    input  wire [15:0] b_fp8,    // {b2[15:8], b1[7:0]} FP8(E5M2)
    input  wire [31:0] c_fp8,    // {c22,c21,c12,c11}  FP8(E5M2)
    output wire [31:0] result    // {y22,y21,y12,y11}
);

  `include "int4_fp8_common.vh"
  `DECL_INT4_DECODE_FP8_FIELDS

  // ---- FP8 E5M2 constants ----
  localparam integer EWIDTH = 5;
  localparam integer FWIDTH = 2;
  localparam integer MBITS  = 1 + FWIDTH; // 3
  localparam integer BIAS   = 15;

  // ---- INT4 decode ----
  wire [8:0] a1_core = int4_decode_fp8_fields(a_int4[3:0]);
  wire [8:0] a2_core = int4_decode_fp8_fields(a_int4[7:4]);

  wire a1_zero = a1_core[8];
  wire a2_zero = a2_core[8];
  wire sa1     = a1_core[7];
  wire sa2     = a2_core[7];
  wire [3:0] ea1_unb = a1_core[6:3];
  wire [3:0] ea2_unb = a2_core[6:3];
  wire [2:0] fa1_core = a1_core[2:0];
  wire [2:0] fa2_core = a2_core[2:0];

  // Bias to E5M2 (bias=15); INT4 unbiased exponent is 0..3
  wire [5:0] ea1_bias = {2'b00, ea1_unb} + 6'd15;
  wire [5:0] ea2_bias = {2'b00, ea2_unb} + 6'd15;
  wire [EWIDTH-1:0] ea1 = a1_zero ? 5'd0 : ea1_bias[4:0];
  wire [EWIDTH-1:0] ea2 = a2_zero ? 5'd0 : ea2_bias[4:0];

  // INT4 mantissa is 3-bit (1.xx) -- take top 2 frac bits for E5M2 frac
  wire [FWIDTH-1:0] fa1 = fa1_core[2:1];
  wire [FWIDTH-1:0] fa2 = fa2_core[2:1];

  // Pack as FP8 E5M2 for the MAC core
  wire [7:0] a1_fp8 = a1_zero ? 8'd0 : {sa1, ea1, fa1};
  wire [7:0] a2_fp8 = a2_zero ? 8'd0 : {sa2, ea2, fa2};

  // ---- MAC core ----
  fp8e5m2_mac_4lane #(
      .MUL_LAT    (MUL_LAT),
      .MID_STAGES (MID_STAGES),
      .ADD_LAT    (ADD_LAT)
  ) u_mac (
      .clk    (clk),
      .a16    ({a2_fp8, a1_fp8}),
      .b16    (b_fp8),
      .c32    (c_fp8),
      .result (result)
  );

endmodule

`default_nettype wire
