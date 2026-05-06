`timescale 1ns/1ps
`default_nettype none

`ifndef FP4_FP8_MAC_COMMON_VH
`define FP4_FP8_MAC_COMMON_VH

`define FP4_MODE_E3M0 2'd0
`define FP4_MODE_E2M1 2'd1
`define FP4_MODE_E1M2 2'd2

`endif // FP4_FP8_MAC_COMMON_VH

module fp4e1m2_fp8e5m2_16_mac (
    input  wire        clk,
    input  wire [7:0]  a_fp4,
    input  wire [15:0] b_fp8,
    input  wire [63:0] c64,
    output wire [63:0] result
);

  fp4_fp8e5m2_16_core #(
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
