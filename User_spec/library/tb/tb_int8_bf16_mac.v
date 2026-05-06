`timescale 1ns/1ps
`default_nettype none

// Uncomment (or compile with -DINT8_MAC_TB_USE_SIMPLE_DSP) if DSP48 is unavailable.
//`define INT8_MAC_TB_USE_SIMPLE_DSP

`ifdef INT8_MAC_TB_USE_SIMPLE_DSP
module dsp_usage (
  input  wire        clk,
  input  wire [26:0] a,
  input  wire [17:0] b,
  output wire [44:0] product
);
  assign product = a * b;
endmodule
`endif

module tb_int8_bf16_mac;
  reg         clk;
  reg  [15:0] a16;
  reg  [15:0] b16;
  reg  [31:0] c32;
  wire [31:0] result;

  wire [15:0] result_hi = result[31:16];
  wire [15:0] result_lo = result[15:0];

  int8_bf16_mac dut (
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

  integer N;
  integer k;
  reg [15:0] A_vec      [0:31];
  reg [15:0] B_vec      [0:31];
  reg [31:0] C_vec      [0:31];
  reg [15:0] EXP_HI_vec [0:31];
  reg [15:0] EXP_LO_vec [0:31];

  initial begin
    N = 0;

    // 0) Mixed signs, multiplier = +1.0
    A_vec[N]      = 16'h0AFB; // hi=+10, lo=-5
    B_vec[N]      = 16'h3F80; // +1.0
    C_vec[N]      = {16'h3F80, 16'h0000};
    EXP_HI_vec[N] = 16'h4130; // 10*1 + 1 = 11
    EXP_LO_vec[N] = 16'hC0A0; // -5*1 + 0 = -5
    N = N + 1;

    // 1) Negative multiplier
    A_vec[N]      = 16'hF807; // hi=-8, lo=+7
    B_vec[N]      = 16'hBF00; // -0.5
    C_vec[N]      = {16'hBF80, 16'h3F00};
    EXP_HI_vec[N] = 16'h4040;
    EXP_LO_vec[N] = 16'hC040;
    N = N + 1;

    // 2) Zeros
    A_vec[N]      = 16'h0000;
    B_vec[N]      = 16'h4000; // +2.0
    C_vec[N]      = 32'h00000000;
    EXP_HI_vec[N] = 16'h0000;
    EXP_LO_vec[N] = 16'h0000;
    N = N + 1;

    // 3) Large magnitude operands
    A_vec[N]      = 16'h7F80; // hi=+127, lo=-128
    B_vec[N]      = 16'h3FC0; // +1.5
    C_vec[N]      = {16'h4120, 16'hC120};
    EXP_HI_vec[N] = 16'h4348;
    EXP_LO_vec[N] = 16'hC34A;
    N = N + 1;

    // 4) Positive/negative mix with -1 multiplier
    A_vec[N]      = 16'h4020; // hi=+64, lo=+32
    B_vec[N]      = 16'hBF80; // -1.0
    C_vec[N]      = {16'hC0A0, 16'h40A0};
    EXP_HI_vec[N] = 16'hC28A;
    EXP_LO_vec[N] = 16'hC1D8;
    N = N + 1;

    // 5) Small values, fractional multiplier
    A_vec[N]      = 16'hFF01; // hi=-1, lo=+1
    B_vec[N]      = 16'h3E80; // +0.25
    C_vec[N]      = {16'h3E00, 16'hBE00};
    EXP_HI_vec[N] = 16'hBE00;
    EXP_LO_vec[N] = 16'h3E00;
    N = N + 1;

    // 6) Positive and negative lanes, multiplier 4.0
    A_vec[N]      = 16'h03FD; // hi=+3, lo=-3
    B_vec[N]      = 16'h4080; // +4.0
    C_vec[N]      = {16'h40C0, 16'h40C0};
    EXP_HI_vec[N] = 16'h4190;
    EXP_LO_vec[N] = 16'hC0C0;
    N = N + 1;

    // 7) Large negative multiplier
    A_vec[N]      = 16'hF614; // hi=-10, lo=+20
    B_vec[N]      = 16'hC000; // -2.0
    C_vec[N]      = {16'h4000, 16'hC000};
    EXP_HI_vec[N] = 16'h41B0;
    EXP_LO_vec[N] = 16'hC228;
    N = N + 1;

    // 8) Fractional multiplier 0.75
    A_vec[N]      = 16'h32C4; // hi=+50, lo=-60
    B_vec[N]      = 16'h3F40; // +0.75
    C_vec[N]      = {16'hBFC0, 16'h3FC0};
    EXP_HI_vec[N] = 16'h4210;
    EXP_LO_vec[N] = 16'hC22E;
    N = N + 1;

    // 9) Zero multiplier
    A_vec[N]      = 16'h01FF; // hi=+1, lo=-1
    B_vec[N]      = 16'h0000; // 0.0
    C_vec[N]      = {16'h3F80, 16'hBF80};
    EXP_HI_vec[N] = 16'h3F80;
    EXP_LO_vec[N] = 16'hBF80;
    N = N + 1;

    // 10) Both lanes positive, multiplier 0.5
    A_vec[N]      = 16'h0F0F;
    B_vec[N]      = 16'h3F00; // +0.5
    C_vec[N]      = 32'h0000_0000;
    EXP_HI_vec[N] = 16'h40F0;
    EXP_LO_vec[N] = 16'h40F0;
    N = N + 1;

    // 11) Mixed signs with 3.0 multiplier
    A_vec[N]      = 16'hE00A; // hi=-32, lo=+10
    B_vec[N]      = 16'h4040; // +3.0
    C_vec[N]      = {16'hC100, 16'h4080};
    EXP_HI_vec[N] = 16'hC2D0;
    EXP_LO_vec[N] = 16'h4208;
    N = N + 1;

    // Zero-fill remainder
    for (k = N; k < 32; k = k + 1) begin
      A_vec[k]      = 16'h0000;
      B_vec[k]      = 16'h0000;
      C_vec[k]      = 32'h00000000;
      EXP_HI_vec[k] = 16'h0000;
      EXP_LO_vec[k] = 16'h0000;
    end
  end

  integer idx_in, idx_out;
  integer pass_cnt, fail_cnt;
  reg [15:0] exp_hi_now, exp_lo_now;

  initial begin
    idx_in   = 0;
    idx_out  = -4; // bf16_mac latency
    pass_cnt = 0;
    fail_cnt = 0;

    a16 = 16'h0000;
    b16 = 16'h0000;
    c32 = 32'h00000000;

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
        c32 <= 32'h00000000;
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
