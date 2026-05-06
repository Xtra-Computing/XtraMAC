`timescale 1ns/1ps
`default_nettype none

module tb_fp8_bf16_dual_mac;
  localparam CLK_PERIOD  = 10;
  localparam NUM_VECTORS = 8;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg        mode_fp8;
  reg [31:0] a32;
  reg [15:0] b16;
  reg [63:0] c64;

  wire [63:0] result;

  fp8_bf16_dual_mac dut (
      .clk     (clk),
      .mode_fp8(mode_fp8),
      .a32     (a32),
      .b16     (b16),
      .c64     (c64),
      .result  (result)
  );

  // Reference implementations
  wire [31:0] ref_bf16_result;
  wire [63:0] ref_fp8_result;

  bf16_mac u_ref_bf16 (
      .clk   (clk),
      .a32   (a32),
      .b16   (b16),
      .c32   (c64[31:0]),
      .result(ref_bf16_result)
  );

  fp8e4m3_bf16_mac u_ref_fp8 (
      .clk   (clk),
      .a18   (a32),
      .b18   (b16),
      .c64   (c64),
      .result(ref_fp8_result)
  );

  // Stimulus storage
  reg        vec_mode [0:NUM_VECTORS-1];
  reg [31:0] vec_a    [0:NUM_VECTORS-1];
  reg [15:0] vec_b    [0:NUM_VECTORS-1];
  reg [63:0] vec_c    [0:NUM_VECTORS-1];

  function [31:0] pack_fp8_pair;
    input [7:0] hi;
    input [7:0] lo;
    begin
      pack_fp8_pair = {16'd0, hi, lo};
    end
  endfunction

  initial begin
    // BF16 mode vectors (mode_fp8=0)
    vec_mode[0] = 1'b0;
    vec_a[0]    = {16'h4000, 16'h3F80};
    vec_b[0]    = 16'h3F80;
    vec_c[0]    = {32'h0000_0000, 32'h3F80_BF80};

    vec_mode[1] = 1'b0;
    vec_a[1]    = {16'hBF80, 16'h3FC0};
    vec_b[1]    = 16'h4000;
    vec_c[1]    = {32'hFFFF_FFFF, 32'h0001_0002};

    vec_mode[2] = 1'b0;
    vec_a[2]    = {16'h0000, 16'hC000};
    vec_b[2]    = 16'h3F00;
    vec_c[2]    = {32'hDEAD_BEEF, 32'h3F80_3F00};

    vec_mode[3] = 1'b0;
    vec_a[3]    = {16'h7F80, 16'h3F00};
    vec_b[3]    = 16'h0000;
    vec_c[3]    = {32'h1234_5678, 32'h3F80_0000};

    // FP8 mode vectors (mode_fp8=1)
    vec_mode[4] = 1'b1;
    vec_a[4]    = pack_fp8_pair(8'h3A, 8'h32);
    vec_b[4]    = {8'h3C, 8'h30};
    vec_c[4]    = {16'h3F80,16'hBF80,16'h3F00,16'h4000};

    vec_mode[5] = 1'b1;
    vec_a[5]    = pack_fp8_pair(8'h2A, 8'h1A);
    vec_b[5]    = {8'h39, 8'h21};
    vec_c[5]    = {16'hBF80,16'h3FC0,16'h0000,16'hBF00};

    vec_mode[6] = 1'b1;
    vec_a[6]    = pack_fp8_pair(8'h40, 8'h20);
    vec_b[6]    = {8'h40, 8'h20};
    vec_c[6]    = {16'h3F80,16'h4000,16'hBF80,16'hBF80};

    vec_mode[7] = 1'b1;
    vec_a[7]    = pack_fp8_pair(8'h10, 8'h30);
    vec_b[7]    = {8'h28, 8'h18};
    vec_c[7]    = {16'h4040,16'h3F80,16'hBF00,16'hBF00};
  end

  // Pipeline tracking
  reg mode_s0, mode_s1, mode_s2, mode_s3;
  reg valid_s0, valid_s1, valid_s2, valid_s3;
  reg feed_valid;

  integer idx;
  integer errors;
  integer checks;

  wire [63:0] ref_bf16_expanded = {32'd0, ref_bf16_result};
  wire [63:0] expected_mux      = mode_s3 ? ref_fp8_result : ref_bf16_expanded;

  always @(posedge clk) begin
    mode_s0  <= mode_fp8;
    mode_s1  <= mode_s0;
    mode_s2  <= mode_s1;
    mode_s3  <= mode_s2;

    valid_s0 <= feed_valid;
    valid_s1 <= valid_s0;
    valid_s2 <= valid_s1;
    valid_s3 <= valid_s2;

    if (valid_s3) begin
      checks <= checks + 1;
      if (result !== expected_mux) begin
        errors <= errors + 1;
        $display("[%0t] ERROR mode=%0d exp=%h got=%h", $time, mode_s3, expected_mux, result);
      end else begin
        $display("[%0t] PASS  mode=%0d result=%h", $time, mode_s3, result);
      end
    end
  end

  initial begin
    mode_fp8   = 1'b0;
    a32        = 32'd0;
    b16        = 16'd0;
    c64        = 64'd0;
    feed_valid = 1'b0;
    mode_s0 = 0; mode_s1 = 0; mode_s2 = 0; mode_s3 = 0;
    valid_s0 = 0; valid_s1 = 0; valid_s2 = 0; valid_s3 = 0;
    errors = 0; checks = 0;

    repeat (5) @(posedge clk);

    for (idx = 0; idx < NUM_VECTORS; idx = idx + 1) begin
      mode_fp8   <= vec_mode[idx];
      a32        <= vec_a[idx];
      b16        <= vec_b[idx];
      c64        <= vec_c[idx];
      feed_valid <= 1'b1;
      @(posedge clk);
    end

    feed_valid <= 1'b0;
    mode_fp8   <= 1'b0;
    a32        <= 32'd0;
    b16        <= 16'd0;
    c64        <= 64'd0;

    while (checks < NUM_VECTORS) @(posedge clk);

    $display("====================================================");
    $display("fp8_bf16_dual_mac TB: %0d checks, %0d errors", checks, errors);
    if (errors == 0) $display("All tests PASSED");
    else             $display("TEST FAILED");
    $display("====================================================");
    $finish;
  end
endmodule

`default_nettype wire
