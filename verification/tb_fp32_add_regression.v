// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none

// Directed finite-normal RN-even regressions for both maintained FP32 adders.
// Run from the repository root:
// iverilog -g2012 -s tb_fp32_add_regression -o fp32_add_regression.vvp \
//   mac_cores/fp32/fp32_add.v verification/tb_fp32_add_regression.v
// vvp fp32_add_regression.vvp
// Test the bundle generator's fixed two-cycle copy separately:
// iverilog -g2012 -DBUNDLED_FP32_ADD -s tb_fp32_add_regression \
//   -o fp32_add_bundle_regression.vvp \
//   User_spec/library/rtl/fp16_32_mac.v verification/tb_fp32_add_regression.v
// vvp fp32_add_bundle_regression.vvp
module tb_fp32_add_regression;
  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg [31:0] x = 32'd0, y = 32'd0;
  wire [31:0] result2, default2;
  integer checked = 0, errors = 0;

`ifdef BUNDLED_FP32_ADD
  fp32_add #(.SATURATE_ON_MAX(0), .INF_CANCELLATION_TO_NAN(0))
    dut2 (.clk(clk), .x32(x), .y32(y), .result(result2));
  fp32_add defaults2 (.clk(clk), .x32(x), .y32(y), .result(default2));
`else
  wire [31:0] result3, default3;
  fp32_add #(.LATENCY(2), .SATURATE_ON_MAX(0), .INF_CANCELLATION_TO_NAN(0))
    dut2 (.clk(clk), .x32(x), .y32(y), .result(result2));
  fp32_add #(.LATENCY(3), .SATURATE_ON_MAX(0), .INF_CANCELLATION_TO_NAN(0))
    dut3 (.clk(clk), .x32(x), .y32(y), .result(result3));
  fp32_add #(.LATENCY(2)) defaults2 (.clk(clk), .x32(x), .y32(y), .result(default2));
  fp32_add #(.LATENCY(3)) defaults3 (.clk(clk), .x32(x), .y32(y), .result(default3));
`endif

  task check;
    input [31:0] a, b, expected;
    begin
      @(negedge clk); x = a; y = b;
      repeat (4) @(posedge clk);
      #1;
      checked = checked + 1;
      if (result2 !== expected || default2 !== expected
`ifndef BUNDLED_FP32_ADD
          || result3 !== expected || default3 !== expected
`endif
      ) begin
        errors = errors + 1;
        $display("FAIL x=%h y=%h expected=%h lat2=%h default2=%h",
                 a, b, expected, result2, default2);
`ifndef BUNDLED_FP32_ADD
        $display("  lat3=%h default3=%h", result3, default3);
`endif
      end
    end
  endtask

  initial begin
    // Keep the exponent difference intact before clamping the shift amount.
    check(32'h5f000000, 32'h3f800000, 32'h5f000000); // 2^63 + 1
    check(32'h5f800000, 32'h3f800000, 32'h5f800000); // 2^64 + 1
    check(32'h5f800000, 32'hbf800000, 32'h5f800000); // 2^64 - 1
    check(32'h3f800000, 32'h5f800000, 32'h5f800000); // swapped operands
    check(32'h60000000, 32'h3f800000, 32'h60000000); // 2^65 + 1
    check(32'hdf800000, 32'h3f800000, 32'hdf800000); // -2^64 + 1
    check(32'hdf800000, 32'hbf800000, 32'hdf800000); // -2^64 - 1
    check(32'h7f000000, 32'h1f000000, 32'h7f000000); // exponent difference 192
    // Preserve sticky information during same-sign carry normalization.
    check(32'h63d8c6c1, 32'h65737475, 32'h658746a7);
    check(32'h65737475, 32'h63d8c6c1, 32'h658746a7);
    check(32'he3d8c6c1, 32'he5737475, 32'he58746a7);
    // Ordinary exact addition and ties-to-even controls.
    check(32'h3f800000, 32'h3f800000, 32'h40000000); // 1 + 1
    check(32'h4b800000, 32'h3f800000, 32'h4b800000); // 2^24 + 1
    check(32'h4b800000, 32'h40400000, 32'h4b800002); // 2^24 + 3
    if (errors != 0) $fatal(1, "FP32_ADD_REGRESSION_FAIL checked=%0d errors=%0d", checked, errors);
    $display("FP32_ADD_REGRESSION_PASS checked=%0d", checked);
    $finish;
  end
endmodule
`default_nettype wire
