`timescale 1ns/1ps
`default_nettype none

module fp4e3m0_fp8e5m2_mac (
    input  wire        clk,
    input  wire [7:0]  a_fp4,
    input  wire [15:0] b_fp8,
    input  wire [31:0] c_fp8,
    output wire [31:0] result
);
  `include "fp4_fp8_mac_common.vh"

  fp4_fp8e5m2_mac_core #(
      .FP4_MODE(`FP4_MODE_E3M0)
  ) u_core (
      .clk   (clk),
      .a_fp4 (a_fp4),
      .b_fp8 (b_fp8),
      .c_fp8 (c_fp8),
      .result(result)
  );

endmodule

`default_nettype wire
