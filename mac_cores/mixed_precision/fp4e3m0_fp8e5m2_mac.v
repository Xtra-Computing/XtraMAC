`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// fp4e3m0_fp8e5m2_mac -- FP4(E3M0) x FP8(E5M2) + FP8 -> FP8, 4-lane
//   Converts two FP4(E3M0) lanes to FP8(E5M2), then feeds the MAC core.
//
//   FP4(E3M0): sign[3], exp[2:0] (3-bit, bias=3), no fraction bits.
//     exp=7 => Inf (mapped to FP8 Inf), exp=0 => zero, else bias-shift.
//     FP8 exp = fp4_exp + 12 (i.e. fp4_exp - 3 + 15)
//
//   Parameters:
//     MUL_LAT    -- multiplier latency (default 2)
//     MID_STAGES -- extra pipeline between mul and add (default 0)
//     ADD_LAT    -- adder latency (default 1)
// ======================================================================
module fp4e3m0_fp8e5m2_mac #(
    parameter integer MUL_LAT    = 2,
    parameter integer MID_STAGES = 0,
    parameter integer ADD_LAT    = 1
) (
    input  wire        clk,
    input  wire [7:0]  a_fp4,    // {a2[7:4], a1[3:0]} two FP4(E3M0) lanes
    input  wire [15:0] b_fp8,    // {b2[15:8], b1[7:0]} FP8(E5M2)
    input  wire [31:0] c_fp8,    // {c22,c21,c12,c11}  FP8(E5M2)
    output wire [31:0] result    // {y22,y21,y12,y11}
);

  `include "fp4_fp8_mac_common.vh"

  localparam [7:0] QNAN8 = 8'h7D;

  // ---- FP4(E3M0) -> FP8(E5M2) conversion ----
  function [7:0] fp4_to_fp8_e5m2;
    input [3:0] lane;
    reg        sign;
    reg [2:0]  exp3;
    reg [4:0]  exp_final;
    begin
      sign = lane[3];
      exp3 = lane[2:0];
      if (exp3 == 3'd7)
        fp4_to_fp8_e5m2 = {sign, 5'h1F, 2'b00};  // Inf
      else if (exp3 == 3'd0)
        fp4_to_fp8_e5m2 = {sign, 5'd0, 2'b00};   // zero
      else begin
        exp_final = {2'b00, exp3} + 5'd12;         // (exp - 3) + 15
        fp4_to_fp8_e5m2 = {sign, exp_final[4:0], 2'b00};
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
