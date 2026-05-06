`timescale 1ns/1ps
`default_nettype none

module fp4e1m2_fp8e4m3_16_mac (
    input  wire        clk,
    input  wire [7:0]  a_fp4,
    input  wire [15:0] b_fp8,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  `include "fp4_fp8_mac_common.vh"

  fp4_fp8e4m3_16_core #(
      .FP4_MODE(`FP4_MODE_E1M2)
  ) u_core (
      .clk   (clk),
      .a_fp4 (a_fp4),
      .b_fp8 (b_fp8),
      .c64   (c64),
      .result(result)
  );

endmodule

`default_nettype wire
