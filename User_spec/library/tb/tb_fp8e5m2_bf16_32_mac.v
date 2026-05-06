`timescale 1ns/1ps
`default_nettype none

//`define FP8E5_MAC32_TB_USE_SIMPLE_DSP

`ifdef FP8E5_MAC32_TB_USE_SIMPLE_DSP
module dsp_usage (
  input  wire        clk,
  input  wire [26:0] a,
  input  wire [17:0] b,
  output wire [44:0] product
);
  assign product = a * b;
endmodule
`endif

module tb_fp8e5m2_bf16_32_mac;
  reg         clk;
  reg  [15:0] a16;
  reg  [15:0] b16;
  reg  [63:0] c64;
  wire [63:0] result;

  wire [31:0] result_hi = result[63:32];
  wire [31:0] result_lo = result[31:0];

  fp8e5m2_bf16_32_mac dut (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .c64   (c64),
    .result(result)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  integer N;
  integer k;
  reg [15:0] A_vec      [0:31];
  reg [15:0] B_vec      [0:31];
  reg [63:0] C_vec      [0:31];
  reg [31:0] EXP_HI_vec [0:31];
  reg [31:0] EXP_LO_vec [0:31];

  initial begin
    N = 0;

    A_vec[N]      = 16'h3C34;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = {32'h3F800000, 32'h00000000};
    EXP_HI_vec[N] = 32'h40000000;
    EXP_LO_vec[N] = 32'h3E800000;
    N = N + 1;

    A_vec[N]      = 16'h443C;
    B_vec[N]      = 16'hBF00;
    C_vec[N]      = {32'hBF800000, 32'h3F000000};
    EXP_HI_vec[N] = 32'hC0400000;
    EXP_LO_vec[N] = 32'h00000000;
    N = N + 1;

    A_vec[N]      = 16'h3C80;
    B_vec[N]      = 16'h4000;
    C_vec[N]      = {32'h3F000000, 32'h3F000000};
    EXP_HI_vec[N] = 32'h40200000;
    EXP_LO_vec[N] = 32'h3F000000;
    N = N + 1;

    A_vec[N]      = 16'hFC3C;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = {32'hBF800000, 32'h3F800000};
    EXP_HI_vec[N] = 32'hFF800000;
    EXP_LO_vec[N] = 32'h40000000;
    N = N + 1;

    A_vec[N]      = 16'h7CB8;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = 64'h0000_0000_0000_0000;
    EXP_HI_vec[N] = 32'h7F800000;
    EXP_LO_vec[N] = 32'hBF000000;
    N = N + 1;

    A_vec[N]      = 16'h7DB8;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = {32'h3F800000, 32'h3F800000};
    EXP_HI_vec[N] = 32'h7FC00000;
    EXP_LO_vec[N] = 32'h3F000000;
    N = N + 1;

    A_vec[N]      = 16'h0101;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = 64'h0000_0000_0000_0000;
    EXP_HI_vec[N] = 32'h00000000;
    EXP_LO_vec[N] = 32'h00000000;
    N = N + 1;

    A_vec[N]      = 16'h4848;
    B_vec[N]      = 16'h3FC0;
    C_vec[N]      = {32'h3E800000, 32'hBE800000};
    EXP_HI_vec[N] = 32'h41440000;
    EXP_LO_vec[N] = 32'h413C0000;
    N = N + 1;

    A_vec[N]      = 16'h7878;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = 64'h0000_0000_0000_0000;
    EXP_HI_vec[N] = 32'h47000000;
    EXP_LO_vec[N] = 32'h47000000;
    N = N + 1;

    A_vec[N]      = 16'h0080;
    B_vec[N]      = 16'hC000;
    C_vec[N]      = {32'h3F800000, 32'hBF800000};
    EXP_HI_vec[N] = 32'h3F800000;
    EXP_LO_vec[N] = 32'hBF800000;
    N = N + 1;

    for (k = N; k < 32; k = k + 1) begin
      A_vec[k]      = 16'h0000;
      B_vec[k]      = 16'h0000;
      C_vec[k]      = 64'h0;
      EXP_HI_vec[k] = 32'h00000000;
      EXP_LO_vec[k] = 32'h00000000;
    end
  end

  integer idx_in, idx_out;
  integer pass_cnt, fail_cnt;
  reg [31:0] exp_hi_now, exp_lo_now;

  initial begin
    idx_in   = 0;
    idx_out  = -5;
    pass_cnt = 0;
    fail_cnt = 0;

    a16 = 16'h0000;
    b16 = 16'h0000;
    c64 = 64'h0;

    @(negedge clk);
    repeat (N + 6) begin
      if (idx_in < N) begin
        a16 <= A_vec[idx_in];
        b16 <= B_vec[idx_in];
        c64 <= C_vec[idx_in];
        idx_in = idx_in + 1;
      end else begin
        a16 <= 16'h0000;
        b16 <= 16'h0000;
        c64 <= 64'h0;
      end

      if (idx_out >= 0 && idx_out < N) begin
        exp_hi_now = EXP_HI_vec[idx_out];
        exp_lo_now = EXP_LO_vec[idx_out];
        if ((result_hi === exp_hi_now) && (result_lo === exp_lo_now)) begin
          pass_cnt = pass_cnt + 1;
        end else begin
          fail_cnt = fail_cnt + 1;
          $display("FAIL vec%0d: res_hi=0x%08h res_lo=0x%08h exp_hi=0x%08h exp_lo=0x%08h",
                   idx_out, result_hi, result_lo, exp_hi_now, exp_lo_now);
        end
      end

      idx_out = idx_out + 1;
      @(negedge clk);
    end

    $display("SUMMARY: PASS=%0d FAIL=%0d TOTAL=%0d", pass_cnt, fail_cnt, N);
    if (fail_cnt == 0) $display("ALL TESTS PASSED ✔");
    else               $display("SOME TESTS FAILED ✘");
    $finish;
  end
endmodule

`default_nettype wire
