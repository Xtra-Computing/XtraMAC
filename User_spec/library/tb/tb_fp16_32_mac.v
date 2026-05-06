`timescale 1ns/1ps
`default_nettype none

module tb_fp16_32_mac;

  reg         clk;
  reg  [15:0] a16;
  reg  [15:0] b16;
  reg  [31:0] c32;
  wire [31:0] result;

  // DUT
  fp16_32_mac dut (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

  // Clock
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk; // 100 MHz
  end

  // ----------------------------
  // Test vectors
  // ----------------------------
  // Handy FP16 constants
  localparam [15:0] H_PZERO   = 16'h0000;
  localparam [15:0] H_NZERO   = 16'h8000;
  localparam [15:0] H_PONE    = 16'h3C00; // +1.0
  localparam [15:0] H_P1_5    = 16'h3E00; // +1.5
  localparam [15:0] H_PTWO    = 16'h4000; // +2.0
  localparam [15:0] H_PTHREE  = 16'h4200; // +3.0
  localparam [15:0] H_NONE    = 16'hBC00; // -1.0
  localparam [15:0] H_NTWO    = 16'hC000; // -2.0
  localparam [15:0] H_INF     = 16'h7C00; // +Inf
  localparam [15:0] H_QNAN    = 16'h7E00; // qNaN (canonical)
  localparam [15:0] H_MIN_SUB = 16'h0001; // smallest subnormal
  localparam [15:0] H_2M12    = 16'h0C00; // 2^-12 (normal in FP16)

  // Handy FP32 constants
  localparam [31:0] F_PZERO     = 32'h00000000;
  localparam [31:0] F_NZERO     = 32'h80000000;
  localparam [31:0] F_PONE      = 32'h3F800000; // +1.0
  localparam [31:0] F_P1_ULP    = 32'h3F800001; // 1.0 + 1 ulp
  localparam [31:0] F_PTWO      = 32'h40000000; // +2.0
  localparam [31:0] F_PTHREE    = 32'h40400000; // +3.0
  localparam [31:0] F_PFOUR     = 32'h40800000; // +4.0
  localparam [31:0] F_P4_5      = 32'h40900000; // +4.5
  localparam [31:0] F_NFOUR     = 32'hC0800000; // -4.0
  localparam [31:0] F_P0_75     = 32'h3F400000; // +0.75
  localparam [31:0] F_QNAN      = 32'h7FC00000; // qNaN (canonical)
  localparam [31:0] F_PINF      = 32'h7F800000; // +Inf
  localparam [31:0] F_NINF      = 32'hFF800000; // -Inf
  localparam [31:0] F_MAXFIN    = 32'h7F7FFFFF; // max finite
  localparam [31:0] F_MIN_SUB1  = 32'h00000001; // smallest subnormal
  localparam [31:0] F_2M24      = 32'h33800000; // 2^-24

  // Vector memory
  integer N;
  integer k;
  reg [15:0] A_vec [0:255];
  reg [15:0] B_vec [0:255];
  reg [31:0] C_vec [0:255];
  reg [31:0] EXP_vec [0:255];

  // Fill test vectors
  initial begin
    N = 0;

    // 1) 1.0*2.0 + 1.0 = 3.0
    A_vec[N]   = H_PONE;  B_vec[N]   = H_PTWO;   C_vec[N]   = F_PONE;     EXP_vec[N] = F_PTHREE; N=N+1;

    // 2) 1.5*1.5 + 0.75 = 3.0
    A_vec[N]   = H_P1_5;  B_vec[N]   = H_P1_5;   C_vec[N]   = F_P0_75;    EXP_vec[N] = F_PTHREE; N=N+1;

    // 3) (-2.0)*3.0 + 2.0 = -4.0
    A_vec[N]   = H_NTWO;  B_vec[N]   = H_PTHREE; C_vec[N]   = F_PTWO;     EXP_vec[N] = F_NFOUR;  N=N+1;

    // 4) +Inf * 0 -> NaN ; + anything = NaN
    A_vec[N]   = H_INF;   B_vec[N]   = H_PZERO;  C_vec[N]   = F_PONE;     EXP_vec[N] = F_QNAN;   N=N+1;

    // 5) +Inf * 2.0 + 1.0 -> +Inf
    A_vec[N]   = H_INF;   B_vec[N]   = H_PTWO;   C_vec[N]   = F_PONE;     EXP_vec[N] = F_PINF;   N=N+1;

    // 6) 2.0*1.0 + +Inf -> +Inf
    A_vec[N]   = H_PTWO;  B_vec[N]   = H_PONE;   C_vec[N]   = F_PINF;     EXP_vec[N] = F_PINF;   N=N+1;

    // 7) DAZ on FP16 input: (min subnormal)*1.0 -> treated as 0 ; result = c32 (3.0)
    A_vec[N]   = H_MIN_SUB; B_vec[N] = H_PONE;   C_vec[N]   = F_PTHREE;   EXP_vec[N] = F_PTHREE; N=N+1;

    // 8) -0 * +0 = -0 ; -0 + -0 => -0 (both_zero sign rule)
    A_vec[N]   = H_NZERO; B_vec[N]   = H_PZERO;  C_vec[N]   = F_NZERO;    EXP_vec[N] = F_NZERO;  N=N+1;

    // 9) 1.0*1.0 + (-1.0) => +0 (cancellation, not both_zero => +0)
    A_vec[N]   = H_PONE;  B_vec[N]   = H_PONE;   C_vec[N]   = 32'hBF800000; EXP_vec[N]= F_PZERO; N=N+1;

    // 10) RN-even tie (even LSB): big=1.0, small=2^-24 => stays 1.0
    A_vec[N]   = H_2M12;  B_vec[N]   = H_2M12;   C_vec[N]   = F_PONE;     EXP_vec[N] = F_PONE;   N=N+1;

    // 11) RN-even tie (odd LSB): big=1.0+1ulp, small=2^-24 => rounds up to next even: 1.0+2ulp
    A_vec[N]   = H_2M12;  B_vec[N]   = H_2M12;   C_vec[N]   = F_P1_ULP;   EXP_vec[N] = 32'h3F800002; N=N+1;

    // 12) Addition overflow: (1.0) + maxfinite => +Inf
    A_vec[N]   = H_PONE;  B_vec[N]   = H_PONE;   C_vec[N]   = F_MAXFIN;   EXP_vec[N] = F_PINF;   N=N+1;

    // 13) NaN propagates: NaN * 1.0 + anything => NaN
    A_vec[N]   = H_QNAN;  B_vec[N]   = H_PONE;   C_vec[N]   = F_PTWO;     EXP_vec[N] = F_QNAN;   N=N+1;

    // 14) -maxfinite + (-1.0) via MAC: (-1.0)*1.0 + (-maxfinite) => -Inf
    A_vec[N]   = H_NONE;  B_vec[N]   = H_PONE;   C_vec[N]   = 32'hFF7FFFFF; EXP_vec[N]= F_NINF;  N=N+1;

    // 15) Mixed signs, no cancel: (3.0*2.0)=6.0 ; + (-1.5) = 4.5
    A_vec[N]   = H_PTHREE; B_vec[N]  = H_PTWO;   C_vec[N]   = 32'hBFC00000; EXP_vec[N]= F_P4_5; N=N+1;

    // 16) DAZ on FP32 input: c32 is subnormal -> treated as 0; (1.0*1.0)+sub -> 1.0
    A_vec[N]   = H_PONE;  B_vec[N]   = H_PONE;   C_vec[N]   = F_MIN_SUB1; EXP_vec[N] = F_PONE;  N=N+1;

    // 17) Inf + (-Inf) through adder: product=0 ; c32=+Inf ; next vector sets c32=-Inf to exercise NaN in adder
    //   17a: finite product + +Inf => +Inf
    A_vec[N]   = H_PONE;  B_vec[N]   = H_PONE;   C_vec[N]   = F_PINF;     EXP_vec[N] = F_PINF;   N=N+1;
    //   17b: same product + -Inf => NaN (inf - inf)
    A_vec[N]   = H_PONE;  B_vec[N]   = H_PONE;   C_vec[N]   = F_NINF;     EXP_vec[N] = F_QNAN;   N=N+1;

    // 18) Inf*finite + (-Inf) => NaN (inf - inf at adder)
    A_vec[N]   = H_INF;   B_vec[N]   = H_PONE;   C_vec[N]   = F_NINF;     EXP_vec[N] = F_QNAN;   N=N+1;

    // Zero-fill remaining
    for (k=N; k<256; k=k+1) begin
      A_vec[k]=16'h0; B_vec[k]=16'h0; C_vec[k]=32'h0; EXP_vec[k]=32'h0;
    end
  end

  // Drive and check
  integer idx_in, idx_out;
  integer pass_cnt, fail_cnt;
  reg [31:0] exp_now;

  initial begin
    idx_in   = 0;
    idx_out  = -4; // account for 4-cycle latency
    pass_cnt = 0;
    fail_cnt = 0;

    a16 = 16'h0000; b16 = 16'h0000; c32 = 32'h00000000;

    // Apply one vector per cycle (II=1)
    @(negedge clk);
    repeat (N + 8) begin
      // Drive inputs
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

      // After 4 cycles, start checking outputs
      if (idx_out >= 0 && idx_out < N) begin
        exp_now = EXP_vec[idx_out];
        // Compare exact 32-bit pattern
        if (result === exp_now) begin
          pass_cnt = pass_cnt + 1;
          $display("[%0t] PASS vec%0d: a=0x%04h b=0x%04h c=0x%08h -> res=0x%08h",
                   $time, idx_out, A_vec[idx_out], B_vec[idx_out], C_vec[idx_out], result);
        end else begin
          fail_cnt = fail_cnt + 1;
          $display("[%0t] FAIL vec%0d: a=0x%04h b=0x%04h c=0x%08h -> res=0x%08h exp=0x%08h",
                   $time, idx_out, A_vec[idx_out], B_vec[idx_out], C_vec[idx_out], result, exp_now);
        end
      end

      idx_out = idx_out + 1;
      @(negedge clk);
    end

    $display("---------------------------------------------------");
    $display("SUMMARY: PASS=%0d  FAIL=%0d  (Total=%0d)", pass_cnt, fail_cnt, N);
    if (fail_cnt==0) $display("ALL TESTS PASSED ✔");
    else             $display("SOME TESTS FAILED ✘");
    $finish;
  end

endmodule

`default_nettype wire
