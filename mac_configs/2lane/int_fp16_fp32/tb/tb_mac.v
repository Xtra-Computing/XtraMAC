`timescale 1ns/1ps
`default_nettype none
// =============================================================
// Auto-generated TB for int_fp16_fp32 (lane=2lane)
// Expected latencies: 4c=4, 5c=5, 6c=6
// =============================================================
module tb_mac;
  localparam integer N        = 512;
  localparam integer WARMUP   = 16;
  localparam integer EXP4 = 4;
  localparam integer EXP5 = 5;
  localparam integer EXP6 = 6;
  localparam integer MAXLAT   = 16;

  reg clk;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  reg  [15:0] a_int;
  reg  [15:0] b16;
  reg  [63:0] c64;
  wire [63:0] y4, y5, y6;

  int_fp16_fp32_mac_4c u4 (.clk(clk), .a_int(a_int), .b16(b16), .c64(c64), .result(y4));
  int_fp16_fp32_mac_5c u5 (.clk(clk), .a_int(a_int), .b16(b16), .c64(c64), .result(y5));
  int_fp16_fp32_mac_6c u6 (.clk(clk), .a_int(a_int), .b16(b16), .c64(c64), .result(y6));

  reg  [63:0] y4_dly [0:MAXLAT-1];
  integer dki;
  always @(posedge clk) begin
    y4_dly[0] <= y4;
    for (dki = 1; dki < MAXLAT; dki = dki + 1) y4_dly[dki] <= y4_dly[dki-1];
  end

  wire [63:0] y4_for_5 = y4_dly[0];
  wire [63:0] y4_for_6 = y4_dly[1];

  integer i;
  integer errors_5 = 0;
  integer errors_6 = 0;
  integer compared = 0;
  integer pc = 0;
  always @(posedge clk) pc <= pc + 1;

  integer drain_start_pc = -1;
  integer y4_zero_pc = -1;
  integer y5_zero_pc = -1;
  integer y6_zero_pc = -1;
  integer lat4_m = -1, lat5_m = -1, lat6_m = -1;
  wire [63:0] ZERO = 64'd0;

  reg [31:0] r0, r1, r2, r3;
  initial begin
    a_int = 0;
    b16 = 0;
    c64 = 0;
    @(negedge clk);

    for (i = 0; i < N; i = i + 1) begin
      r0 = $random; r1 = $random; r2 = $random; r3 = $random;
      a_int = r0[15:0];
      b16 = r1[15:0];
      c64 = {r0, r1, r2, r3};
      @(posedge clk);
      #1;
      if (i >= WARMUP) begin
        if (y5 !== y4_for_5) errors_5 = errors_5 + 1;
        if (y6 !== y4_for_6) errors_6 = errors_6 + 1;
        compared = compared + 1;
      end
    end

    a_int = 0;
    b16 = 0;
    c64 = 0;
    drain_start_pc = pc;
    @(posedge clk);
    for (i = 0; i < 4*MAXLAT; i = i + 1) begin
      #1;
      if (y4_zero_pc < 0 && y4 === ZERO) y4_zero_pc = pc;
      if (y5_zero_pc < 0 && y5 === ZERO) y5_zero_pc = pc;
      if (y6_zero_pc < 0 && y6 === ZERO) y6_zero_pc = pc;
      @(posedge clk);
    end

    if (y4_zero_pc >= 0) lat4_m = y4_zero_pc - drain_start_pc;
    if (y5_zero_pc >= 0) lat5_m = y5_zero_pc - drain_start_pc;
    if (y6_zero_pc >= 0) lat6_m = y6_zero_pc - drain_start_pc;

    $display("CONFIG=int_fp16_fp32 LANE=2lane EXP=%0d,%0d,%0d MEAS=%0d,%0d,%0d CMP=%0d ERR5=%0d ERR6=%0d",
             EXP4, EXP5, EXP6, lat4_m, lat5_m, lat6_m,
             compared, errors_5, errors_6);

    if (lat4_m == EXP4 && lat5_m == EXP5 && lat6_m == EXP6 &&
        errors_5 == 0 && errors_6 == 0)
      $display("RESULT=int_fp16_fp32 PASS");
    else
      $display("RESULT=int_fp16_fp32 FAIL");
    $finish;
  end

  initial begin
    #2000000;
    $display("RESULT=int_fp16_fp32 FAIL (timeout)");
    $finish;
  end

endmodule
`default_nettype wire
