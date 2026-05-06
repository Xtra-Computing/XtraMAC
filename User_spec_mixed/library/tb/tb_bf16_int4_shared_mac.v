`timescale 1ns/1ps
`default_nettype none

module tb_bf16_int4_shared_mac;
  parameter CLK_PERIOD   = 10;
  parameter NUM_VECTORS  = 6;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg        mode_int4;
  reg [31:0] a_bf16_int4;
  reg [15:0] b16;
  reg [31:0] c32;
  wire [31:0] dut_result;

  reg        feed_valid;
  reg [3:0]  mode_pipe;
  reg [3:0]  valid_pipe;

  integer checks;
  integer errors;
  integer i;
  reg [31:0] expected;

  bf16_int4_shared_mac dut (
      .clk(clk),
      .mode_int4(mode_int4),
      .a_bf16_int4(a_bf16_int4),
      .b16(b16),
      .c32(c32),
      .result(dut_result)
  );

  // Reference implementations (bf16_mac reused)
  wire [15:0] int4_lo_bf16 = int4_to_bf16_tb(a_bf16_int4[3:0]);
  wire [15:0] int4_hi_bf16 = int4_to_bf16_tb(a_bf16_int4[7:4]);
  wire [31:0] ref_a32_int4 = {int4_hi_bf16, int4_lo_bf16};

  wire [31:0] ref_res_bf16;
  wire [31:0] ref_res_int4;

  bf16_mac u_ref_bf16 (
      .clk   (clk),
      .a32   (a_bf16_int4),
      .b16   (b16),
      .c32   (c32),
      .result(ref_res_bf16)
  );

  bf16_mac u_ref_int4 (
      .clk   (clk),
      .a32   (ref_a32_int4),
      .b16   (b16),
      .c32   (c32),
      .result(ref_res_int4)
  );

  // Pipeline tracking
  always @(posedge clk) begin
    mode_pipe  <= {mode_pipe[2:0], mode_int4};
    valid_pipe <= {valid_pipe[2:0], feed_valid};
  end

  always @(posedge clk) begin
    if (valid_pipe[3]) begin
      expected = mode_pipe[3] ? ref_res_int4 : ref_res_bf16;
      checks <= checks + 1;
      if (dut_result !== expected) begin
        errors <= errors + 1;
        $display("[%0t] ERROR  mode=%0d  expected=%h  got=%h",
                 $time, mode_pipe[3], expected, dut_result);
      end else begin
        $display("[%0t] PASS   mode=%0d  result=%h",
                 $time, mode_pipe[3], dut_result);
      end
    end
  end

  // Stimulus vectors (parallel arrays)
  reg        vec_mode   [0:NUM_VECTORS-1];
  reg [31:0] vec_a      [0:NUM_VECTORS-1];
  reg [15:0] vec_b      [0:NUM_VECTORS-1];
  reg [31:0] vec_c      [0:NUM_VECTORS-1];

  localparam [15:0] BF16_POS_ONE   = 16'h3F80;
  localparam [15:0] BF16_NEG_ONE   = 16'hBF80;
  localparam [15:0] BF16_POS_HALF  = 16'h3F00;
  localparam [15:0] BF16_NEG_HALF  = 16'hBF00;
  localparam [15:0] BF16_POS_TWO   = 16'h4000;
  localparam [15:0] BF16_POS_THREE = 16'h4040;
  localparam [15:0] BF16_POS_ONEP5 = 16'h3FC0;
  localparam [15:0] BF16_NEG_TWO   = 16'hC000;
  localparam [15:0] BF16_POS_TWOP5 = 16'h4020;
  localparam [15:0] BF16_NEG_ONEP5 = 16'hBFC0;

  function [31:0] pack_bf16_pair;
    input [15:0] hi;
    input [15:0] lo;
    begin
      pack_bf16_pair = {hi, lo};
    end
  endfunction

  function [31:0] pack_int4_pair;
    input signed [3:0] hi;
    input signed [3:0] lo;
    reg [31:0] tmp;
    begin
      tmp       = 32'd0;
      tmp[3:0]  = lo[3:0];
      tmp[7:4]  = hi[3:0];
      pack_int4_pair = tmp;
    end
  endfunction

  initial begin
    vec_mode[0] = 1'b0;
    vec_a[0]    = pack_bf16_pair(BF16_POS_ONEP5, BF16_NEG_TWO);
    vec_b[0]    = BF16_POS_ONE;
    vec_c[0]    = pack_bf16_pair(BF16_POS_HALF, BF16_NEG_HALF);

    vec_mode[1] = 1'b0;
    vec_a[1]    = pack_bf16_pair(BF16_POS_TWOP5, BF16_POS_THREE);
    vec_b[1]    = BF16_POS_HALF;
    vec_c[1]    = pack_bf16_pair(BF16_POS_ONE, BF16_POS_ONE);

    vec_mode[2] = 1'b1;
    vec_a[2]    = pack_int4_pair(-3, 5);
    vec_b[2]    = BF16_POS_ONE;
    vec_c[2]    = pack_bf16_pair(16'h0000, 16'h0000);

    vec_mode[3] = 1'b1;
    vec_a[3]    = pack_int4_pair(7, -8);
    vec_b[3]    = BF16_POS_TWO;
    vec_c[3]    = pack_bf16_pair(BF16_POS_ONE, BF16_NEG_ONE);

    vec_mode[4] = 1'b0;
    vec_a[4]    = pack_bf16_pair(BF16_NEG_HALF, BF16_POS_TWO);
    vec_b[4]    = BF16_NEG_ONEP5;
    vec_c[4]    = pack_bf16_pair(BF16_POS_ONE, 16'h0000);

    vec_mode[5] = 1'b1;
    vec_a[5]    = pack_int4_pair(2, -1);
    vec_b[5]    = BF16_POS_HALF;
    vec_c[5]    = pack_bf16_pair(BF16_POS_HALF, BF16_POS_HALF);
  end

  // Main sequence
  initial begin
    mode_int4     = 1'b0;
    a_bf16_int4   = 32'd0;
    b16           = 16'd0;
    c32           = 32'd0;
    feed_valid    = 1'b0;
    mode_pipe     = 4'd0;
    valid_pipe    = 4'd0;
    checks        = 0;
    errors        = 0;

    repeat (4) @(posedge clk);

    for (i = 0; i < NUM_VECTORS; i = i + 1) begin
      apply_vector(vec_mode[i], vec_a[i], vec_b[i], vec_c[i]);
    end

    feed_valid  <= 1'b0;
    mode_int4   <= 1'b0;
    a_bf16_int4 <= 32'd0;
    b16         <= 16'd0;
    c32         <= 32'd0;

    repeat (6) @(posedge clk);

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
    input [31:0] c_v;
    begin
      mode_int4     <= mode_v;
      a_bf16_int4   <= a_v;
      b16           <= b_v;
      c32           <= c_v;
      feed_valid    <= 1'b1;
      @(posedge clk);
    end
  endtask

  // Helper: INT4 -> BF16 conversion (same as DUT mapper)
  function [15:0] int4_to_bf16_tb;
    input [3:0] x;
    reg [7:0] val8;
    reg       sign;
    reg [7:0] mag;
    reg [7:0] exp_bf16;
    reg [6:0] frac_bf16;
    reg [7:0] shift_tmp;
    integer k;
    begin
      val8 = { {4{x[3]}}, x };
      sign = val8[7];
      mag  = sign ? (~val8 + 8'd1) : val8;

      if (mag == 8'd0) begin
        int4_to_bf16_tb = {sign, 15'd0};
      end else begin
        casex (mag)
          8'b1xxxxxxx: k = 7;
          8'b01xxxxxx: k = 6;
          8'b001xxxxx: k = 5;
          8'b0001xxxx: k = 4;
          8'b00001xxx: k = 3;
          8'b000001xx: k = 2;
          8'b0000001x: k = 1;
          default:      k = 0;
        endcase

        exp_bf16  = k + 8'd127;
        shift_tmp = mag << (7 - k);
        frac_bf16 = shift_tmp[6:0];

        int4_to_bf16_tb = {sign, exp_bf16, frac_bf16};
      end
    end
  endfunction

endmodule

`default_nettype wire
