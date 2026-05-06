`timescale 1ns/1ps
`default_nettype none

// Uncomment the define below (or pass -DBF16_32_MAC_TB_USE_SIMPLE_DSP)
// when simulating with tools that do not provide the Xilinx DSP48 primitive.
//`define BF16_32_MAC_TB_USE_SIMPLE_DSP

`ifdef BF16_32_MAC_TB_USE_SIMPLE_DSP
module dsp_usage (
  input  wire        clk,
  input  wire [26:0] a,
  input  wire [17:0] b,
  output wire [44:0] product
);
  // Simple behavioral multiplier sufficient for testbench use.
  assign product = a * b;
endmodule
`endif

module tb_bf16_32_mac;

  // DUT I/O
  reg         clk;
  reg  [31:0] a32;
  reg  [15:0] b16;
  reg  [63:0] c64;
  wire [63:0] result;

  wire [31:0] result_hi = result[63:32];
  wire [31:0] result_lo = result[31:0];

  // Device under test
  bf16_32_mac dut (
    .clk   (clk),
    .a32   (a32),
    .b16   (b16),
    .c64   (c64),
    .result(result)
  );

  // Clock generation (100 MHz)
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // BF16 handy constants
  localparam [15:0] B_PZERO   = 16'h0000;
  localparam [15:0] B_NZERO   = 16'h8000;
  localparam [15:0] B_PONE    = 16'h3F80;
  localparam [15:0] B_P0_5    = 16'h3F00;
  localparam [15:0] B_P1_5    = 16'h3FC0;
  localparam [15:0] B_PTWO    = 16'h4000;
  localparam [15:0] B_PTHREE  = 16'h4040;
  localparam [15:0] B_PFOUR   = 16'h4080;
  localparam [15:0] B_MAXFIN  = 16'h7F7F;
  localparam [15:0] B_INF     = 16'h7F80;
  localparam [15:0] B_NINF    = 16'hFF80;
  localparam [15:0] B_QNAN    = 16'h7FC0;
  localparam [15:0] B_MIN_SUB = 16'h0001;
  localparam [15:0] B_NONE    = 16'hBF80;
  localparam [15:0] B_NTWO    = 16'hC000;

  // FP32 handy constants
  localparam [31:0] F_PZERO    = 32'h00000000;
  localparam [31:0] F_NZERO    = 32'h80000000;
  localparam [31:0] F_P0_25    = 32'h3E800000;
  localparam [31:0] F_P0_5     = 32'h3F000000;
  localparam [31:0] F_PONE     = 32'h3F800000;
  localparam [31:0] F_P1_5     = 32'h3FC00000;
  localparam [31:0] F_P1_25    = 32'h3FA00000;
  localparam [31:0] F_MIN_SUB1  = 32'h00000001;
  localparam [31:0] F_PTWO     = 32'h40000000;
  localparam [31:0] F_P2_25    = 32'h40100000;
  localparam [31:0] F_P2_75    = 32'h40300000;
  localparam [31:0] F_PTHREE   = 32'h40400000;
  localparam [31:0] F_PFOUR    = 32'h40800000;
  localparam [31:0] F_P4_5     = 32'h40900000;
  localparam [31:0] F_P5       = 32'h40A00000;
  localparam [31:0] F_P8       = 32'h41000000;
  localparam [31:0] F_PMFIN    = 32'h7F7FFFFF;
  localparam [31:0] F_PINF     = 32'h7F800000;
  localparam [31:0] F_NINF     = 32'hFF800000;
  localparam [31:0] F_NONE     = 32'hBF800000;
  localparam [31:0] F_NTWO     = 32'hC0000000;
  localparam [31:0] F_NTHREE   = 32'hC0400000;
  localparam [31:0] F_N4_5     = 32'hC0900000;
  localparam [31:0] F_QNAN     = 32'h7FC00000;

  // Vector memory
  integer N;
  integer k;
  reg [31:0] A_vec      [0:255];
  reg [15:0] B_vec      [0:255];
  reg [63:0] C_vec      [0:255];
  reg [31:0] EXP_HI_vec [0:255];
  reg [31:0] EXP_LO_vec [0:255];

  // Populate vectors
  initial begin
    N = 0;

    // vec0: dual positive lanes
    A_vec[N]      = {B_PONE,   B_P0_5};
    B_vec[N]      = B_PTWO;
    C_vec[N]      = {F_PONE,   F_P0_25};
    EXP_HI_vec[N] = F_PTHREE;   // +3.0
    EXP_LO_vec[N] = F_P1_25;    // +1.25
    N = N + 1;

    // vec1: mixed sign multiply/adds
    A_vec[N]      = {B_P1_5,   B_NONE};
    B_vec[N]      = B_P1_5;
    C_vec[N]      = {F_P0_5,   F_NTHREE};
    EXP_HI_vec[N] = F_P2_75;    // +2.75
    EXP_LO_vec[N] = F_N4_5;     // -4.5
    N = N + 1;

    // vec2: large finite numbers
    A_vec[N]      = {B_NTWO,   B_PTHREE};
    B_vec[N]      = B_PTHREE;
    C_vec[N]      = {F_PFOUR,  F_NONE};
    EXP_HI_vec[N] = F_NTWO;     // -2.0
    EXP_LO_vec[N] = F_P8;       // +8.0
    N = N + 1;

    // vec3: Inf * 0 -> NaN, other lane finite
    A_vec[N]      = {B_INF,    B_PONE};
    B_vec[N]      = B_PZERO;
    C_vec[N]      = {F_PONE,   F_PONE};
    EXP_HI_vec[N] = F_QNAN;     // qNaN
    EXP_LO_vec[N] = F_PONE;       // +1.0
    N = N + 1;

    // vec4: Inf product, -Inf + +Inf -> NaN in low lane
    A_vec[N]      = {B_INF,    B_NINF};
    B_vec[N]      = B_PTWO;
    C_vec[N]      = {F_P0_5,   F_PINF};
    EXP_HI_vec[N] = F_PINF;       // +Inf
    EXP_LO_vec[N] = F_QNAN;     // qNaN
    N = N + 1;

    // vec5: NaN propagation on low lane
    A_vec[N]      = {B_P0_5,   B_QNAN};
    B_vec[N]      = B_P1_5;
    C_vec[N]      = {F_P1_5,   F_PTHREE};
    EXP_HI_vec[N] = F_P2_25;    // +2.25
    EXP_LO_vec[N] = F_QNAN;     // qNaN
    N = N + 1;

    // vec6: Subnormal BF16 input flushed to zero
    A_vec[N]      = {B_MIN_SUB, B_PONE};
    B_vec[N]      = B_PONE;
    C_vec[N]      = {F_PTWO,    F_PTWO};
    EXP_HI_vec[N] = F_PTWO;     // unchanged (product treated as zero)
    EXP_LO_vec[N] = F_PTHREE;   // 1*1 + 2 = 3
    N = N + 1;

    // vec7: Subnormal FP32 addend (DAZ)
    A_vec[N]      = {B_PONE,   B_P0_5};
    B_vec[N]      = B_PONE;
    C_vec[N]      = {F_MIN_SUB1, F_MIN_SUB1};
    EXP_HI_vec[N] = F_PONE;     // +1.0
    EXP_LO_vec[N] = F_P0_5;     // +0.5
    N = N + 1;

    // vec8: large + finite (no overflow)
    A_vec[N]      = {B_PONE,   B_P0_5};
    B_vec[N]      = B_PONE;
    C_vec[N]      = {F_PMFIN,  F_PFOUR};
    EXP_HI_vec[N] = F_PMFIN;    // remains max finite
    EXP_LO_vec[N] = F_P4_5;     // +4.5
    N = N + 1;

    // vec9: -0 lanes
    A_vec[N]      = {B_NZERO,  B_NZERO};
    B_vec[N]      = B_PZERO;
    C_vec[N]      = {F_PZERO,  F_NZERO};
    EXP_HI_vec[N] = F_PZERO;    // +0
    EXP_LO_vec[N] = F_NZERO;    // -0
    N = N + 1;

    // vec10: cancellation to +0 and -Inf from adder
    A_vec[N]      = {B_PONE,   B_PONE};
    B_vec[N]      = B_PONE;
    C_vec[N]      = {F_NONE,   F_NINF};
    EXP_HI_vec[N] = F_PZERO;    // +0
    EXP_LO_vec[N] = F_NINF;     // -Inf
    N = N + 1;

    // vec11: product zero + +Inf -> +Inf hi, Inf - Inf -> NaN lo
    A_vec[N]      = {B_PONE,   B_INF};
    B_vec[N]      = B_PONE;
    C_vec[N]      = {F_PINF,   F_NINF};
    EXP_HI_vec[N] = F_PINF;
    EXP_LO_vec[N] = F_QNAN;
    N = N + 1;

    // vec12: addition overflow to +Inf
    A_vec[N]      = {B_MAXFIN, B_PONE};
    B_vec[N]      = B_PONE;
    C_vec[N]      = {F_PMFIN,  F_PFOUR};
    EXP_HI_vec[N] = F_PINF;
    EXP_LO_vec[N] = F_P5;       // +5.0
    N = N + 1;

    // Zero-fill remaining entries
    for (k = N; k < 256; k = k + 1) begin
      A_vec[k]      = 32'd0;
      B_vec[k]      = 16'd0;
      C_vec[k]      = 64'd0;
      EXP_HI_vec[k] = 32'd0;
      EXP_LO_vec[k] = 32'd0;
    end
  end

  // Drive & check
  integer idx_in, idx_out;
  integer pass_cnt, fail_cnt;
  reg [31:0] exp_hi_now, exp_lo_now;

  initial begin
    idx_in   = 0;
    idx_out  = -5; // pipeline latency
    pass_cnt = 0;
    fail_cnt = 0;

    a32 = 32'd0;
    b16 = 16'd0;
    c64 = 64'd0;

    @(negedge clk);
    repeat (N + 8) begin
      // Apply inputs
      if (idx_in < N) begin
        a32 <= A_vec[idx_in];
        b16 <= B_vec[idx_in];
        c64 <= C_vec[idx_in];
        idx_in = idx_in + 1;
      end else begin
        a32 <= 32'd0;
        b16 <= 16'd0;
        c64 <= 64'd0;
      end

      // Check outputs after latency
      if (idx_out >= 0 && idx_out < N) begin
        exp_hi_now = EXP_HI_vec[idx_out];
        exp_lo_now = EXP_LO_vec[idx_out];
        if ((result_hi === exp_hi_now) && (result_lo === exp_lo_now)) begin
          pass_cnt = pass_cnt + 1;
          $display("[%0t] PASS vec%0d: a=0x%08h b=0x%04h c_hi=0x%08h c_lo=0x%08h -> res_hi=0x%08h res_lo=0x%08h",
                   $time, idx_out, A_vec[idx_out], B_vec[idx_out],
                   C_vec[idx_out][63:32], C_vec[idx_out][31:0],
                   result_hi, result_lo);
        end else begin
          fail_cnt = fail_cnt + 1;
          $display("[%0t] FAIL vec%0d: a=0x%08h b=0x%04h c_hi=0x%08h c_lo=0x%08h -> res_hi=0x%08h res_lo=0x%08h (exp_hi=0x%08h exp_lo=0x%08h)",
                   $time, idx_out, A_vec[idx_out], B_vec[idx_out],
                   C_vec[idx_out][63:32], C_vec[idx_out][31:0],
                   result_hi, result_lo, exp_hi_now, exp_lo_now);
        end
      end

      idx_out = idx_out + 1;
      @(negedge clk);
    end

    $display("---------------------------------------------------");
    $display("SUMMARY: PASS=%0d  FAIL=%0d  (Total vectors=%0d)", pass_cnt, fail_cnt, N);
    if (fail_cnt == 0) $display("ALL TESTS PASSED ✔");
    else               $display("SOME TESTS FAILED ✘");
    $finish;
  end

endmodule

`default_nettype wire

