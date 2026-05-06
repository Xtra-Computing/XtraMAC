`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// fp4e2m1_fp8e5m2_mac -- FP4(E2M1) x FP8(E5M2) + FP8 -> FP8, 4-lane
//   Converts two FP4(E2M1) lanes to FP8(E5M2), then feeds the MAC core.
//
//   FP4(E2M1): sign[3], exp[2:1] (2-bit, bias=1), frac[0] (1-bit).
//     exp=3,frac=0 => Inf;  exp=3,frac=1 => NaN.
//     exp=0,frac=0 => zero; exp=0,frac=1 => subnormal (0.1 * 2^0 = 2^-1
//       => FP8 exp = 15 + (-1) = 14, frac=00).
//     Normal: FP8 exp = 15 + (fp4_exp - 1) = 14 + fp4_exp.
//
//   Parameters:
//     MUL_LAT    -- multiplier latency (default 2)
//     MID_STAGES -- extra pipeline between mul and add (default 0)
//     ADD_LAT    -- adder latency (default 1)
// ======================================================================
module fp4e2m1_fp8e5m2_mac #(
    parameter integer MUL_LAT    = 2,
    parameter integer MID_STAGES = 0,
    parameter integer ADD_LAT    = 1
) (
    input  wire        clk,
    input  wire [7:0]  a_fp4,    // {a2[7:4], a1[3:0]} two FP4(E2M1) lanes
    input  wire [15:0] b_fp8,    // {b2[15:8], b1[7:0]} FP8(E5M2)
    input  wire [31:0] c_fp8,    // {c22,c21,c12,c11}  FP8(E5M2)
    output wire [31:0] result    // {y22,y21,y12,y11}
);

  `include "fp4_fp8_mac_common.vh"

  localparam [7:0] QNAN8 = 8'h7D;

  // ---- FP4(E2M1) -> FP8(E5M2) conversion ----
  function [7:0] fp4_to_fp8_e5m2;
    input [3:0] lane;
    reg        sign;
    reg [1:0]  exp2;
    reg        frac1;
    reg [4:0]  exp_final;
    begin
      sign  = lane[3];
      exp2  = lane[2:1];
      frac1 = lane[0];
      if (exp2 == 2'b11)
        fp4_to_fp8_e5m2 = (frac1 == 1'b0) ? {sign, 5'h1F, 2'b00} : QNAN8;
      else if (exp2 == 2'b00)
        fp4_to_fp8_e5m2 = (frac1 == 1'b0) ? {sign, 5'd0, 2'b00}       // zero
                                           : {sign, 5'd14, 2'b00};     // subnormal
      else begin
        exp_final = 5'd15 + {3'b000, exp2} - 5'd1; // 14 + exp2
        fp4_to_fp8_e5m2 = {sign, exp_final[4:0], {frac1, 1'b0}};
      end
    end
  endfunction

  wire [7:0] a1_fp8 = fp4_to_fp8_e5m2(a_fp4[3:0]);
  wire [7:0] a2_fp8 = fp4_to_fp8_e5m2(a_fp4[7:4]);

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
