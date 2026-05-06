`timescale 1ns/1ps
`default_nettype none

`include "fp4_fp8_mac_common.vh"

module tb_fp4e2m1_fp8e5m2_16_mac;
  tb_fp4_fp8e5m2_16_mac_base #(.FP4_MODE(`FP4_MODE_E2M1)) tb();
endmodule

`default_nettype wire
