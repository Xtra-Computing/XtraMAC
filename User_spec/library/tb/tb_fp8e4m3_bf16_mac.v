`timescale 1ns/1ps
`default_nettype none

// Uncomment the define below (or pass -DFP8_MAC_TB_USE_SIMPLE_DSP)
// when simulating with tools that do not provide the Xilinx DSP48 primitive.
//`define FP8_MAC_TB_USE_SIMPLE_DSP

`ifdef FP8_MAC_TB_USE_SIMPLE_DSP
module dsp_usage (
  input  wire        clk,
  input  wire [26:0] a,
  input  wire [17:0] b,
  output wire [44:0] product
);
  assign product = a * b;
endmodule
`endif

module tb_fp8e4m3_bf16_mac;
  // DUT I/O
  reg         clk;
  reg  [15:0] a16;
  reg  [15:0] b16;
  reg  [31:0] c32;
  wire [31:0] result;

  wire [15:0] result_hi = result[31:16];
  wire [15:0] result_lo = result[15:0];

  // Device under test
  fp8e4m3_bf16_mac dut (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

  // Clock generation (100 MHz)
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Vector memory
  integer N;
  integer k;
  reg [15:0] A_vec      [0:31];
  reg [15:0] B_vec      [0:31];
  reg [31:0] C_vec      [0:31];
  reg [15:0] EXP_HI_vec [0:31];
  reg [15:0] EXP_LO_vec [0:31];

  // Populate vectors
  initial begin
    N = 0;

    // 1) (hi=1.0, lo=0.5) * 1.0 + {1.0, 0.0} -> {2.0, 0.5}
    A_vec[N]      = 16'h3830;  // hi=0x38, lo=0x30
    B_vec[N]      = 16'h3F80;  // +1.0 (BF16)
    C_vec[N]      = {16'h3F80, 16'h0000};
    EXP_HI_vec[N] = 16'h4000;  // +2.0
    EXP_LO_vec[N] = 16'h3F00;  // +0.5
    N = N + 1;

    // 2) (hi=2.0, lo=1.0) * (-1.0) + {0.0, -1.5} -> {-2.0, -2.5}
    A_vec[N]      = 16'h4038;
    B_vec[N]      = 16'hBF80;  // -1.0
    C_vec[N]      = {16'h0000, 16'hBFC0}; // 0.0, -1.5
    EXP_HI_vec[N] = 16'hC000;  // -2.0
    EXP_LO_vec[N] = 16'hC020;  // -2.5
    N = N + 1;

    // 3) (hi=1.0, lo=-0.0) * 2.0 + {0.5, 0.5} -> {2.5, 0.5}
    A_vec[N]      = 16'h3880;
    B_vec[N]      = 16'h4000;  // +2.0
    C_vec[N]      = {16'h3F00, 16'h3F00};
    EXP_HI_vec[N] = 16'h4020;  // +2.5
    EXP_LO_vec[N] = 16'h3F00;  // +0.5
    N = N + 1;

    // 4) (hi=NaN, lo=1.0) * 1.0 + {-1.0, +1.0} -> {qNaN, 2.0}
    A_vec[N]      = 16'hFF38;  // hi=0xFF (NaN), lo=0x38
    B_vec[N]      = 16'h3F80;  // +1.0
    C_vec[N]      = {16'hBF80, 16'h3F80}; // -1.0, +1.0
    EXP_HI_vec[N] = 16'h7FC0;  // qNaN
    EXP_LO_vec[N] = 16'h4000;  // +2.0
    N = N + 1;

    // 5) Subnormal inputs -> flush to zero
    A_vec[N]      = 16'h0101;
    B_vec[N]      = 16'h3F80;  // +1.0
    C_vec[N]      = 32'h00000000;
    EXP_HI_vec[N] = 16'h0000;
    EXP_LO_vec[N] = 16'h0000;
    N = N + 1;

    // 6) Large magnitudes with fractional multiplier
    A_vec[N]      = 16'h4848;  // ~3.0 lanes
    B_vec[N]      = 16'h3FC0;  // +1.5
    C_vec[N]      = {16'h3E80, 16'hBE80}; // +0.25, -0.25
    EXP_HI_vec[N] = 16'h40C8;  // +6.25
    EXP_LO_vec[N] = 16'h40B8;  // +5.75
    N = N + 1;

    // 7) Near-maximum finite FP8 values (overflow to qNaN)
    A_vec[N]      = 16'h7878;
    B_vec[N]      = 16'h3F80;  // +1.0
    C_vec[N]      = 32'h00000000;
    EXP_HI_vec[N] = 16'h7FC0;
    EXP_LO_vec[N] = 16'h7FC0;
    N = N + 1;

    // 8) Positive zero and negative zero inputs
    A_vec[N]      = 16'h0080;
    B_vec[N]      = 16'hC000;  // -2.0
    C_vec[N]      = {16'h3F80, 16'hBF80}; // +1.0, -1.0
    EXP_HI_vec[N] = 16'h3F80;
    EXP_LO_vec[N] = 16'hBF80;
    N = N + 1;

    // 9) Mixed signs with small magnitudes
    A_vec[N]      = 16'h3C82;
    B_vec[N]      = 16'h3F00;  // +0.5
    C_vec[N]      = {16'h3F40, 16'hBF00}; // +0.75, -0.5
    EXP_HI_vec[N] = 16'h3FC0;
    EXP_LO_vec[N] = 16'hBF00;
    N = N + 1;

    // 10) Both lanes NaN; ensure NaN propagation
    A_vec[N]      = 16'hFFFF;
    B_vec[N]      = 16'hBF80;  // -1.0
    C_vec[N]      = 32'h00000000;
    EXP_HI_vec[N] = 16'h7FC0;
    EXP_LO_vec[N] = 16'h7FC0;
    N = N + 1;

    // 11) Fractional inputs with offsetting C
    A_vec[N]      = 16'h3F3F;
    B_vec[N]      = 16'h3F80;  // +1.0
    C_vec[N]      = {16'h3F00, 16'hBF00};
    EXP_HI_vec[N] = 16'h4018;
    EXP_LO_vec[N] = 16'h3FB0;
    N = N + 1;

    // 12) Small positive lanes with negative multiplier
    A_vec[N]      = 16'h3131;
    B_vec[N]      = 16'hBF40;  // -0.75
    C_vec[N]      = {16'h3F80, 16'h3F80};
    EXP_HI_vec[N] = 16'h3F14;
    EXP_LO_vec[N] = 16'h3F14;
    N = N + 1;

    // 13) Minimal normal exponent (exp=1)
    A_vec[N]      = 16'h0808;
    B_vec[N]      = 16'h3F80;  // +1.0
    C_vec[N]      = 32'h00000000;
    EXP_HI_vec[N] = 16'h3C80;
    EXP_LO_vec[N] = 16'h3C80;
    N = N + 1;

    // 14) Large & small mix with non-trivial C
    A_vec[N]      = 16'h7008;
    B_vec[N]      = 16'h4000;  // +2.0
    C_vec[N]      = {16'hC000, 16'h4000}; // -2.0, +2.0
    EXP_HI_vec[N] = 16'h437E;
    EXP_LO_vec[N] = 16'h4002;
    N = N + 1;

    // Zero-fill remaining entries
    for (k = N; k < 32; k = k + 1) begin
      A_vec[k]      = 16'h0000;
      B_vec[k]      = 16'h0000;
      C_vec[k]      = 32'h00000000;
      EXP_HI_vec[k] = 16'h0000;
      EXP_LO_vec[k] = 16'h0000;
    end
  end

  // Drive & check
  integer idx_in, idx_out;
  integer pass_cnt, fail_cnt;
  reg [15:0] exp_hi_now, exp_lo_now;

  initial begin
    idx_in   = 0;
    idx_out  = -4; // pipeline latency
    pass_cnt = 0;
    fail_cnt = 0;

    a16 = 16'h0000;
    b16 = 16'h0000;
    c32 = 32'h00000000;

    @(negedge clk);
    repeat (N + 6) begin
      // Apply inputs
      if (idx_in < N) begin
        a16 <= A_vec[idx_in];
        b16 <= B_vec[idx_in];
        c32 <= C_vec[idx_in];
        idx_in = idx_in + 1;
      end else begin
        a16 <= 16'h0000;
        b16 <= 16'h0000;
        c32 <= 32'h00000000;
      end

      // Check outputs after latency
      if (idx_out >= 0 && idx_out < N) begin
        exp_hi_now = EXP_HI_vec[idx_out];
        exp_lo_now = EXP_LO_vec[idx_out];
        if ((result_hi === exp_hi_now) && (result_lo === exp_lo_now)) begin
          pass_cnt = pass_cnt + 1;
          $display("[%0t] PASS vec%0d: a=0x%04h b=0x%04h c_hi=0x%04h c_lo=0x%04h -> res_hi=0x%04h res_lo=0x%04h",
                   $time, idx_out, A_vec[idx_out], B_vec[idx_out],
                   C_vec[idx_out][31:16], C_vec[idx_out][15:0],
                   result_hi, result_lo);
        end else begin
          fail_cnt = fail_cnt + 1;
          $display("[%0t] FAIL vec%0d: a=0x%04h b=0x%04h c_hi=0x%04h c_lo=0x%04h -> res_hi=0x%04h res_lo=0x%04h (exp_hi=0x%04h exp_lo=0x%04h)",
                   $time, idx_out, A_vec[idx_out], B_vec[idx_out],
                   C_vec[idx_out][31:16], C_vec[idx_out][15:0],
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
