`timescale 1ns/1ps
`default_nettype none

module tb_int8_bf16_mac;
  parameter CLK_PERIOD  = 10;
  parameter NUM_VECTORS = 8;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg        mode_int8;
  reg [31:0] a32;
  reg [15:0] b16;
  reg [63:0] c64;
  wire [63:0] dut_result;

  reg        feed_valid;
  reg [3:0]  mode_pipe;
  reg [3:0]  valid_pipe;

  integer checks;
  integer errors;
  integer i;

  int8_bf16_mac dut (
      .clk     (clk),
      .mode_int8(mode_int8),
      .a32     (a32),
      .b16     (b16),
      .c64     (c64),
      .result  (dut_result)
  );

  // ---- Reference paths ----
  wire [15:0] c_lo_bf16 = c64[15:0];
  wire [15:0] c_hi_bf16 = c64[31:16];
  wire [31:0] ref_c32   = {c_hi_bf16, c_lo_bf16};

  wire [31:0] bf16_ref_result;
  bf16_mac u_ref_bf16 (
      .clk   (clk),
      .a32   (a32),
      .b16   (b16),
      .c32   (ref_c32),
      .result(bf16_ref_result)
  );

  reg [63:0] int_exp_pipe0, int_exp_pipe1, int_exp_pipe2, int_exp_pipe3;
  reg [3:0]  int_valid_pipe;

  // Stimulus vectors
  reg        vec_mode   [0:NUM_VECTORS-1];
  reg [31:0] vec_a      [0:NUM_VECTORS-1];
  reg [15:0] vec_b      [0:NUM_VECTORS-1];
  reg [63:0] vec_c      [0:NUM_VECTORS-1];

  localparam [15:0] BF16_POS_ONE   = 16'h3F80;
  localparam [15:0] BF16_NEG_ONE   = 16'hBF80;
  localparam [15:0] BF16_POS_HALF  = 16'h3F00;
  localparam [15:0] BF16_NEG_HALF  = 16'hBF00;
  localparam [15:0] BF16_POS_TWO   = 16'h4000;
  localparam [15:0] BF16_POS_THREE = 16'h4040;
  localparam [15:0] BF16_POS_ONEP5 = 16'h3FC0;
  localparam [15:0] BF16_NEG_TWO   = 16'hC000;

  function [31:0] pack_bf16_pair;
    input [15:0] hi;
    input [15:0] lo;
    begin
      pack_bf16_pair = {hi, lo};
    end
  endfunction

  function [31:0] pack_int8_pair;
    input [7:0] hi;
    input [7:0] lo;
    reg [31:0] tmp;
    begin
      tmp = 32'd0;
      tmp[31:24] = hi;
      tmp[15:8]  = lo;
      pack_int8_pair = tmp;
    end
  endfunction

  function [31:0] sat_add32;
    input [31:0] base;
    input [31:0] addend;
    reg [31:0] sum;
    begin
      sum = base + addend;
      if ((base[31] == addend[31]) && (sum[31] != base[31]))
        sat_add32 = base[31] ? 32'h8000_0000 : 32'h7FFF_FFFF;
      else
        sat_add32 = sum;
    end
  endfunction

  function [63:0] calc_int_result;
    input [31:0] a_vec;
    input [15:0] b_vec;
    input [63:0] c_vec;
    reg signed [7:0] a_hi, a_lo, b_shared;
    reg signed [15:0] prod_hi16, prod_lo16;
    reg [31:0] prod_hi32, prod_lo32;
    reg [31:0] sat_hi, sat_lo;
    begin
      a_hi = a_vec[31:24];
      a_lo = a_vec[15:8];
      b_shared = b_vec[15:8];
      prod_hi16 = a_hi * b_shared;
      prod_lo16 = a_lo * b_shared;
      prod_hi32 = {{16{prod_hi16[15]}}, prod_hi16};
      prod_lo32 = {{16{prod_lo16[15]}}, prod_lo16};
      sat_hi = sat_add32(c_vec[63:32], prod_hi32);
      sat_lo = sat_add32(c_vec[31:0],  prod_lo32);
      calc_int_result = {sat_hi, sat_lo};
    end
  endfunction

  initial begin
    vec_mode[0] = 1'b0;
    vec_a[0]    = pack_bf16_pair(BF16_POS_ONEP5, BF16_NEG_TWO);
    vec_b[0]    = BF16_POS_ONE;
    vec_c[0]    = {32'd0, pack_bf16_pair(BF16_POS_HALF, BF16_NEG_HALF)};

    vec_mode[1] = 1'b0;
    vec_a[1]    = pack_bf16_pair(BF16_POS_THREE, BF16_POS_TWO);
    vec_b[1]    = BF16_POS_HALF;
    vec_c[1]    = {32'd0, pack_bf16_pair(BF16_POS_ONE, BF16_POS_ONE)};

    vec_mode[2] = 1'b1;
    vec_a[2]    = pack_int8_pair(8'sd100, -8'sd40);
    vec_b[2]    = {8'sd12, 8'd0};
    vec_c[2]    = {32'h7FFF_FF00, 32'h0000_0100};

    vec_mode[3] = 1'b1;
    vec_a[3]    = pack_int8_pair(-8'sd120, 8'sd80);
    vec_b[3]    = {8'sd3, 8'd0};
    vec_c[3]    = {32'h8000_0000, 32'h7FFF_FFFF};

    vec_mode[4] = 1'b0;
    vec_a[4]    = pack_bf16_pair(BF16_NEG_HALF, BF16_POS_ONE);
    vec_b[4]    = BF16_POS_ONEP5;
    vec_c[4]    = {32'd0, pack_bf16_pair(16'h0000, BF16_POS_TWO)};

    vec_mode[5] = 1'b1;
    vec_a[5]    = pack_int8_pair(8'sd10, 8'sd20);
    vec_b[5]    = {8'sd50, 8'd0};
    vec_c[5]    = {32'h0000_1000, 32'hFFFF_FF00};

    vec_mode[6] = 1'b0;
    vec_a[6]    = pack_bf16_pair(BF16_POS_ONE, BF16_POS_ONEP5);
    vec_b[6]    = BF16_NEG_ONE;
    vec_c[6]    = {32'd0, pack_bf16_pair(BF16_NEG_HALF, 16'h0000)};

    vec_mode[7] = 1'b1;
    vec_a[7]    = pack_int8_pair(-8'sd5, -8'sd6);
    vec_b[7]    = {8'sd100, 8'd0};
    vec_c[7]    = {32'h0000_0001, 32'hFFFF_FFFE};
  end

  // Tracking pipelines
  always @(posedge clk) begin
    mode_pipe  <= {mode_pipe[2:0], mode_int8};
    valid_pipe <= {valid_pipe[2:0], feed_valid};

    int_exp_pipe3 <= int_exp_pipe2;
    int_exp_pipe2 <= int_exp_pipe1;
    int_exp_pipe1 <= int_exp_pipe0;
    if (feed_valid && mode_int8) begin
      int_exp_pipe0 <= calc_int_result(a32, b16, c64);
    end else begin
      int_exp_pipe0 <= 64'd0;
    end
    int_valid_pipe <= {int_valid_pipe[2:0], (feed_valid & mode_int8)};
  end

  reg [63:0] expected;
  always @(posedge clk) begin
    if (valid_pipe[3]) begin
      if (mode_pipe[3]) begin
        expected = int_exp_pipe3;
      end else begin
        expected = {32'd0, bf16_ref_result};
      end
      checks <= checks + 1;
      if (mode_pipe[3] && ~int_valid_pipe[3]) begin
        errors <= errors + 1;
        $display("[%0t] ERROR missing INT exp data", $time);
      end else if (dut_result !== expected) begin
        errors <= errors + 1;
        $display("[%0t] ERROR mode=%0d exp=%h got=%h",
                 $time, mode_pipe[3], expected, dut_result);
      end else begin
        $display("[%0t] PASS  mode=%0d result=%h",
                 $time, mode_pipe[3], dut_result);
      end
    end
  end

  // Main sequence
  initial begin
    mode_int8   = 1'b0;
    a32         = 32'd0;
    b16         = 16'd0;
    c64         = 64'd0;
    feed_valid  = 1'b0;
    mode_pipe   = 4'd0;
    valid_pipe  = 4'd0;
    int_valid_pipe = 4'd0;
    int_exp_pipe0 = 64'd0;
    int_exp_pipe1 = 64'd0;
    int_exp_pipe2 = 64'd0;
    int_exp_pipe3 = 64'd0;
    checks      = 0;
    errors      = 0;

    repeat (4) @(posedge clk);

    for (i = 0; i < NUM_VECTORS; i = i + 1) begin
      apply_vector(vec_mode[i], vec_a[i], vec_b[i], vec_c[i]);
    end

    feed_valid <= 1'b0;
    mode_int8  <= 1'b0;
    a32        <= 32'd0;
    b16        <= 16'd0;
    c64        <= 64'd0;

    repeat (8) @(posedge clk);

    $display("====================================================");
    $display("Testbench completed: %0d checks, %0d errors", checks, errors);
    if (errors == 0) begin
      $display("All tests PASSED");
    end else begin
      $display("TEST FAILED");
    end
    $display("====================================================");
    $finish;
  end

  task apply_vector;
    input mode_v;
    input [31:0] a_v;
    input [15:0] b_v;
    input [63:0] c_v;
    begin
      mode_int8  <= mode_v;
      a32        <= a_v;
      b16        <= b_v;
      c64        <= c_v;
      feed_valid <= 1'b1;
      @(posedge clk);
    end
  endtask

endmodule

`default_nettype wire
