`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// fp4e1m2_fp8e5m2_mac -- FP4(E1M2) x FP8(E5M2) + FP8 -> FP8, 4-lane
//   Converts two FP4(E1M2) lanes to FP8(E5M2), then feeds the MAC core.
//
//   FP4(E1M2): sign[3], exp[2] (1-bit), frac[1:0] (2-bit).
//     exp=0,frac=00 => zero
//     exp=0,frac!=0 => subnormal (value = 0.frac * 2^0, mapped to FP8 exp=15)
//     exp=1         => normal    (value = 1.frac * 2^0, mapped to FP8 exp=15)
//     Note: E1M2 has no NaN/Inf encoding (single exp bit, no all-ones special).
//
//   Parameters:
//     MUL_LAT    -- multiplier latency (default 2)
//     MID_STAGES -- extra pipeline between mul and add (default 0)
//     ADD_LAT    -- adder latency (default 1)
// ======================================================================
module fp4e1m2_fp8e5m2_mac #(
    parameter integer MUL_LAT    = 2,
    parameter integer MID_STAGES = 0,
    parameter integer ADD_LAT    = 1
) (
    input  wire        clk,
    input  wire [7:0]  a_fp4,    // {a2[7:4], a1[3:0]} two FP4(E1M2) lanes
    input  wire [15:0] b_fp8,    // {b2[15:8], b1[7:0]} FP8(E5M2)
    input  wire [31:0] c_fp8,    // {c22,c21,c12,c11}  FP8(E5M2)
    output wire [31:0] result    // {y22,y21,y12,y11}
);

  `include "fp4_fp8_mac_common.vh"

  // ---- FP4(E1M2) -> FP8(E5M2) conversion ----
  function [7:0] fp4_to_fp8_e5m2;
    input [3:0] lane;
    reg        sign;
    reg [1:0]  frac2;
    begin
      sign  = lane[3];
      frac2 = lane[1:0];
      if ((lane[2] == 1'b0) && (frac2 == 2'b00))
        fp4_to_fp8_e5m2 = {sign, 5'd0, 2'b00};  // zero
      else
        fp4_to_fp8_e5m2 = {sign, 5'd15, frac2};  // exp=15 (value around 1.xx)
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
