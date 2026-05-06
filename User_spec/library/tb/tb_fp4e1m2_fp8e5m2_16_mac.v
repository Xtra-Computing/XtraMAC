`timescale 1ns/1ps
`default_nettype none

`ifndef FP4_FP8_MAC_COMMON_VH
`define FP4_FP8_MAC_COMMON_VH

`define FP4_MODE_E3M0 2'd0
`define FP4_MODE_E2M1 2'd1
`define FP4_MODE_E1M2 2'd2

`endif // FP4_FP8_MAC_COMMON_VH

module tb_fp4e1m2_fp8e5m2_16_mac;
  tb_fp4_fp8e5m2_16_base #(.FP4_MODE(`FP4_MODE_E1M2)) tb();
endmodule

`default_nettype wire
