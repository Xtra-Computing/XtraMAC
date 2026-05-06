`timescale 1ns/1ps
`default_nettype none
module tb_mac;
  localparam N      = 256;
  localparam WARMUP = 16;
  localparam MAXLAT = 16;

  reg clk = 0;
  always #5 clk = ~clk;

  reg        mode_int8;
  reg [31:0] a32;
  reg [15:0] b16;
  reg [63:0] c64;
  wire [63:0] y4, y5, y6;

  int8_bf16_mac_4c u4 (.clk(clk), .mode_int8(mode_int8), .a32(a32), .b16(b16), .c64(c64), .result(y4));
  int8_bf16_mac_5c u5 (.clk(clk), .mode_int8(mode_int8), .a32(a32), .b16(b16), .c64(c64), .result(y5));
  int8_bf16_mac_6c u6 (.clk(clk), .mode_int8(mode_int8), .a32(a32), .b16(b16), .c64(c64), .result(y6));

  reg [63:0] y4_dly [0:MAXLAT-1];
  integer dki;
  always @(posedge clk) begin
    y4_dly[0] <= y4;
    for (dki = 1; dki < MAXLAT; dki = dki + 1) y4_dly[dki] <= y4_dly[dki-1];
  end
  wire [63:0] y4_for_5 = y4_dly[0];
  wire [63:0] y4_for_6 = y4_dly[1];

  integer i, errors_5 = 0, errors_6 = 0, compared = 0;
  reg [31:0] r0, r1, r2, r3;
  initial begin
    mode_int8 = 0; a32 = 0; b16 = 0; c64 = 0;
    @(negedge clk);
    for (i = 0; i < N; i = i + 1) begin
      r0 = $random; r1 = $random; r2 = $random; r3 = $random;
      mode_int8 = r0[0];
      a32       = r0;
      b16       = r1[15:0];
      c64       = {r2, r3};
      @(posedge clk);
      #1;
      if (i >= WARMUP) begin
        if (y5 !== y4_for_5) errors_5 = errors_5 + 1;
        if (y6 !== y4_for_6) errors_6 = errors_6 + 1;
        compared = compared + 1;
      end
    end
    $display("CONFIG=int8_bf16_dual CMP=%0d ERR5=%0d ERR6=%0d", compared, errors_5, errors_6);
    if (errors_5 == 0 && errors_6 == 0) $display("RESULT=int8_bf16_dual PASS");
    else                                $display("RESULT=int8_bf16_dual FAIL");
    $finish;
  end
  initial begin #500000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
