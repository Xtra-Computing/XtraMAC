`timescale 1ns/1ps
`default_nettype none

// Uncomment (or pass -DFP8E5_MAC_TB_USE_SIMPLE_DSP) if your simulator
// does not provide the Xilinx DSP48 primitive.
//`define FP8E5_MAC_TB_USE_SIMPLE_DSP

`ifdef FP8E5_MAC_TB_USE_SIMPLE_DSP
module dsp_usage (
  input  wire        clk,
  input  wire [26:0] a,
  input  wire [17:0] b,
  output wire [44:0] product
);
  assign product = a * b;
endmodule
`endif

module tb_fp8e5m2_bf16_mac;

  reg         clk;
  reg  [15:0] a16;
  reg  [15:0] b16;
  reg  [31:0] c32;
  wire [31:0] result;

  wire [15:0] result_hi = result[31:16];
  wire [15:0] result_lo = result[15:0];

  fp8e5m2_bf16_mac dut (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

  // 100 MHz clock
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Vector storage (room for up to 32 cases)
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

    // 0) (hi=1.5, lo=1.25) * 1.0 + {1.0, 0.0} -> {2.5, 1.25}
    A_vec[N]      = 16'h3C34;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = {16'h3F80, 16'h0000};
    EXP_HI_vec[N] = 16'h4000;
    EXP_LO_vec[N] = 16'h3E80;
    N = N + 1;

    // 1) Mixed signs, negative multiplier
    A_vec[N]      = 16'h443C;
    B_vec[N]      = 16'hBF80;
    C_vec[N]      = {16'h0000, 16'hBFC0};
    EXP_HI_vec[N] = 16'hC080;
    EXP_LO_vec[N] = 16'hC020;
    N = N + 1;

    // 2) Negative zero on low lane
    A_vec[N]      = 16'h3C80;
    B_vec[N]      = 16'h4000;
    C_vec[N]      = {16'h3F00, 16'h3F00};
    EXP_HI_vec[N] = 16'h4020;
    EXP_LO_vec[N] = 16'h3F00;
    N = N + 1;

    // 3) Infinity propagation (hi=-Inf)
    A_vec[N]      = 16'hFC3C;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = {16'hBF80, 16'h3F80};
    EXP_HI_vec[N] = 16'hFF80; // -Inf
    EXP_LO_vec[N] = 16'h4000;
    N = N + 1;

    // 4) Infinity input in hi lane, finite lo lane
    A_vec[N]      = 16'h7CB8;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = 32'h0000_0000;
    EXP_HI_vec[N] = 16'h7F80; // +Inf
    EXP_LO_vec[N] = 16'hBF00; // -0.5
    N = N + 1;

    // 5) NaN input (hi lane)
    A_vec[N]      = 16'h7DB8;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = {16'h3F80, 16'h3F80};
    EXP_HI_vec[N] = 16'h7FC0; // qNaN
    EXP_LO_vec[N] = 16'h3F00;
    N = N + 1;

    // 6) Subnormals -> zero
    A_vec[N]      = 16'h0101;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = 32'h0000_0000;
    EXP_HI_vec[N] = 16'h0000;
    EXP_LO_vec[N] = 16'h0000;
    N = N + 1;

    // 7) Larger magnitudes with fractional multiplier
    A_vec[N]      = 16'h4848;
    B_vec[N]      = 16'h3FC0; // +1.5
    C_vec[N]      = {16'h3E80, 16'hBE80};
    EXP_HI_vec[N] = 16'h4144;
    EXP_LO_vec[N] = 16'h413C;
    N = N + 1;

    // 8) Near-maximum finite values -> overflow to large BF16
    A_vec[N]      = 16'h7878;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = 32'h0000_0000;
    EXP_HI_vec[N] = 16'h4700;
    EXP_LO_vec[N] = 16'h4700;
    N = N + 1;

    // 9) Zero and negative zero lanes
    A_vec[N]      = 16'h0080;
    B_vec[N]      = 16'hC000; // -2.0
    C_vec[N]      = {16'h3F80, 16'hBF80};
    EXP_HI_vec[N] = 16'h3F80;
    EXP_LO_vec[N] = 16'hBF80;
    N = N + 1;

    // 10) Opposite infinities
    A_vec[N]      = 16'h7CFC;
    B_vec[N]      = 16'hBF80;
    C_vec[N]      = 32'h0000_0000;
    EXP_HI_vec[N] = 16'hFF80; // -Inf
    EXP_LO_vec[N] = 16'h7F80; // +Inf
    N = N + 1;

    // 11) Fractional mix
    A_vec[N]      = 16'h3EBE;
    B_vec[N]      = 16'h3F00; // +0.5
    C_vec[N]      = {16'h3F40, 16'hBF00};
    EXP_HI_vec[N] = 16'h3FC0;
    EXP_LO_vec[N] = 16'hBFA0;
    N = N + 1;

    // 12) 1.875 lanes with offsets
    A_vec[N]      = 16'h3F3F;
    B_vec[N]      = 16'h3F80;
    C_vec[N]      = {16'h3F00, 16'hBF00};
    EXP_HI_vec[N] = 16'h4010;
    EXP_LO_vec[N] = 16'h3FA0;
    N = N + 1;

    // 13) Small normals and negative multiplier
    A_vec[N]      = 16'h2121;
    B_vec[N]      = 16'hBF40; // -0.75
    C_vec[N]      = {16'h3F80, 16'h3F80};
    EXP_HI_vec[N] = 16'h3F7F;
    EXP_LO_vec[N] = 16'h3F7F;
    N = N + 1;

    // Zero-fill remainder
    for (k = N; k < 32; k = k + 1) begin
      A_vec[k]      = 16'h0000;
      B_vec[k]      = 16'h0000;
      C_vec[k]      = 32'h0000_0000;
      EXP_HI_vec[k] = 16'h0000;
      EXP_LO_vec[k] = 16'h0000;
    end
  end

  // Drive/check
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
    c32 = 32'h0000_0000;

    @(negedge clk);
    repeat (N + 6) begin
      if (idx_in < N) begin
        a16 <= A_vec[idx_in];
        b16 <= B_vec[idx_in];
        c32 <= C_vec[idx_in];
        idx_in = idx_in + 1;
      end else begin
        a16 <= 16'h0000;
        b16 <= 16'h0000;
        c32 <= 32'h0000_0000;
      end

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
