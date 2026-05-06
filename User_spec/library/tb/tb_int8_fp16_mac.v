`timescale 1ns/1ps
`default_nettype none

module tb_int8_fp16_mac;
  localparam integer VEC_COUNT = 16;
  localparam integer LATENCY   = 4;

  reg         clk;
  reg  [15:0] a16;
  reg  [15:0] b16;
  reg  [31:0] c32;
  wire [31:0] result;

  wire [15:0] res_hi = result[31:16];
  wire [15:0] res_lo = result[15:0];

  int8_fp16_mac dut (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

  // Golden references
  wire [15:0] a_lo_fp16 = int8_to_fp16(a16[7:0]);
  wire [15:0] a_hi_fp16 = int8_to_fp16(a16[15:8]);

  wire [15:0] gold_lo16;
  wire [15:0] gold_hi16;

  fp16_mac gold_lo (
    .clk (clk),
    .a16 (a_lo_fp16),
    .b16 (b16),
    .c16 (c32[15:0]),
    .result(gold_lo16)
  );

  fp16_mac gold_hi (
    .clk (clk),
    .a16 (a_hi_fp16),
    .b16 (b16),
    .c16 (c32[31:16]),
    .result(gold_hi16)
  );

  wire [15:0] gold_hi_pipe = gold_hi16;
  wire [15:0] gold_lo_pipe = gold_lo16;

  // Clock
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Test vectors
  reg [15:0] A_vec [0:VEC_COUNT-1];
  reg [15:0] B_vec [0:VEC_COUNT-1];
  reg [31:0] C_vec [0:VEC_COUNT-1];

  initial begin
    A_vec[0]  = pack_int8(127, 1);
    B_vec[0]  = 16'h3C00;  // +1.0
    C_vec[0]  = {16'h3C00, 16'h0000};

    A_vec[1]  = pack_int8(64, -32);
    B_vec[1]  = 16'h4000;  // +2.0
    C_vec[1]  = {16'h3C00, 16'hBC00};

    A_vec[2]  = pack_int8(-77, 23);
    B_vec[2]  = 16'hB800;  // -0.5
    C_vec[2]  = {16'h4000, 16'h4000};

    A_vec[3]  = pack_int8(0, 0);
    B_vec[3]  = 16'h3C00;
    C_vec[3]  = {16'h0000, 16'h0000};

    A_vec[4]  = pack_int8(-1, -1);
    B_vec[4]  = 16'h3C00;
    C_vec[4]  = {16'hBC00, 16'hBC00};

    A_vec[5]  = pack_int8(-128, 127);
    B_vec[5]  = 16'h3F00;  // 0.5
    C_vec[5]  = {16'h0080, 16'h8080};

    A_vec[6]  = pack_int8(7, -7);
    B_vec[6]  = 16'h4200;  // +48.0
    C_vec[6]  = {16'hFC00, 16'h0400};

    A_vec[7]  = pack_int8(15, 15);
    B_vec[7]  = 16'hC400;  // -48.0
    C_vec[7]  = {16'h3C00, 16'h3C00};

    A_vec[8]  = pack_int8(2, 4);
    B_vec[8]  = 16'h0000;  // zero multiplicand
    C_vec[8]  = {16'h3C00, 16'hBC00};

    A_vec[9]  = pack_int8(12, -9);
    B_vec[9]  = 16'h4C00;  // 4096
    C_vec[9]  = {16'h0000, 16'h8000};

    A_vec[10] = pack_int8(-3, 3);
    B_vec[10] = 16'h7C00;  // +Inf
    C_vec[10] = {16'h7C00, 16'hFC00};

    A_vec[11] = pack_int8(20, -20);
    B_vec[11] = 16'h7E00;  // NaN
    C_vec[11] = {16'h4000, 16'hC000};

    A_vec[12] = pack_int8(5, 6);
    B_vec[12] = 16'h3800;  // 0.5
    C_vec[12] = {16'h3C00, 16'hBC00};

    A_vec[13] = pack_int8(-5, -6);
    B_vec[13] = 16'hB800;  // -0.5
    C_vec[13] = {16'h3C00, 16'hBC00};

    A_vec[14] = pack_int8(25, -40);
    B_vec[14] = 16'h3E00;  // 0.75
    C_vec[14] = {16'h3F80, 16'hBF80};

    A_vec[15] = pack_int8(-1, 1);
    B_vec[15] = 16'h0001;  // smallest subnormal -> FTZ
    C_vec[15] = {16'h3C00, 16'hBC00};
  end

  integer idx_in;
  integer cycle;
  integer pass_cnt, fail_cnt;
  reg [15:0] next_a;
  reg [15:0] next_b;
  reg [31:0] next_c;

  initial begin
    idx_in   = 0;
    cycle    = 0;
    pass_cnt = 0;
    fail_cnt = 0;

    a16 = 16'h0000;
    b16 = 16'h0000;
    c32 = 32'h0000_0000;

    repeat (VEC_COUNT + LATENCY + 2) begin
      if (idx_in < VEC_COUNT) begin
        next_a = A_vec[idx_in];
        next_b = B_vec[idx_in];
        next_c = C_vec[idx_in];
      end else begin
        next_a = 16'h0000;
        next_b = 16'h0000;
        next_c = 32'h0000_0000;
      end

      @(posedge clk);
      a16 <= next_a;
      b16 <= next_b;
      c32 <= next_c;

      if (idx_in < VEC_COUNT)
        idx_in = idx_in + 1;

      if ((cycle >= LATENCY) && ((cycle - LATENCY) < VEC_COUNT)) begin
        if ((res_hi === gold_hi_pipe) && (res_lo === gold_lo_pipe)) begin
          pass_cnt = pass_cnt + 1;
        end else begin
          fail_cnt = fail_cnt + 1;
          $display("[%0t] FAIL vec%0d: res_hi=0x%04h res_lo=0x%04h exp_hi=0x%04h exp_lo=0x%04h",
                   $time, cycle-LATENCY, res_hi, res_lo, gold_hi_pipe, gold_lo_pipe);
        end
      end

      cycle = cycle + 1;
    end

    $display("---------------------------------------------------");
    $display("SUMMARY: PASS=%0d FAIL=%0d TOTAL=%0d", pass_cnt, fail_cnt, VEC_COUNT);
    if (fail_cnt == 0) $display("ALL TESTS PASSED ✔");
    else               $display("SOME TESTS FAILED ✘");
    $finish;
  end

  // Helper: signed INT8 -> FP16 (matches DUT conversion)
  function automatic [15:0] pack_int8;
    input integer hi;
    input integer lo;
    reg   signed [7:0] hi_s;
    reg   signed [7:0] lo_s;
    begin
      hi_s = hi;
      lo_s = lo;
      pack_int8 = {hi_s, lo_s};
    end
  endfunction

  function automatic [15:0] int8_to_fp16;
    input [7:0] x;
    reg        sign;
    reg [7:0]  mag;
    reg [4:0]  exp_fp16;
    reg [9:0]  frac_fp16;
    reg [17:0] mant_shift;
    reg [17:0] mant_norm;
    integer    k;
    begin
      sign = x[7];
      mag  = sign ? (~x + 8'd1) : x;
      if (mag == 8'd0) begin
        int8_to_fp16 = {sign, 15'd0};
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
        exp_fp16   = k + 5'd15;
        mant_shift = mag << (10 - k);
        mant_norm  = mant_shift - 18'd1024;
        frac_fp16  = mant_norm[9:0];
        int8_to_fp16 = {sign, exp_fp16, frac_fp16};
      end
    end
  endfunction
endmodule

`default_nettype wire
