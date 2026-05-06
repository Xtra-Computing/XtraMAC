`timescale 1ns/1ps
`default_nettype none

// DUT prototype:
//
// module fp16_mac (
//   input  wire        clk,
//   input  wire [15:0] a16,
//   input  wire [15:0] b16,
//   input  wire [15:0] c16,
//   output reg  [15:0] result
// );

module tb_fp16_mac;

  // ---------------- Parameters ----------------
  localparam CLK_PERIOD = 10;   // 100 MHz
  localparam LATENCY    = 5;    // 4-cycle MAC + 1-cycle print alignment

  // ---------------- DUT I/O ----------------
  reg         clk;
  reg  [15:0] a16;
  reg  [15:0] b16;
  reg  [15:0] c16;
  wire [15:0] result;

  fp16_mac dut (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .c16   (c16),
    .result(result)
  );

  // ---------------- Clock ----------------
  initial clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ---------------- 5-cycle pipelines ----------------
  reg [15:0] exp_d1, exp_d2, exp_d3, exp_d4, exp_d5;
  reg [15:0] a_d1,a_d2,a_d3,a_d4,a_d5;
  reg [15:0] b_d1,b_d2,b_d3,b_d4,b_d5;
  reg [15:0] c_d1,c_d2,c_d3,c_d4,c_d5;

  reg  [2:0] pipe_cnt;   // counts to LATENCY
  reg        pipe_full;  // goes high when pipeline is full
  reg [15:0] err_cnt;    // 16-bit counter (no 'integer')

  // Drive one vector; shift expected & input-echo; compare/print when full
  task apply_and_expect;
    input [15:0] AA, BB, CC, EXP;
    begin
      @(posedge clk);
      a16 <= AA; b16 <= BB; c16 <= CC;

      // expected pipeline (5-deep)
      exp_d5 <= exp_d4; exp_d4 <= exp_d3; exp_d3 <= exp_d2; exp_d2 <= exp_d1; exp_d1 <= EXP;

      // input echo pipeline (so prints align with DUT/EXP at k+5)
      a_d5 <= a_d4; a_d4 <= a_d3; a_d3 <= a_d2; a_d2 <= a_d1; a_d1 <= AA;
      b_d5 <= b_d4; b_d4 <= b_d3; b_d3 <= b_d2; b_d2 <= b_d1; b_d1 <= BB;
      c_d5 <= c_d4; c_d4 <= c_d3; c_d3 <= c_d2; c_d2 <= c_d1; c_d1 <= CC;

      if (!pipe_full) begin
        if (pipe_cnt == (LATENCY-1)) pipe_full <= 1'b1;
        pipe_cnt <= pipe_cnt + 3'd1;
      end else begin
        if (result !== exp_d5) begin
          err_cnt <= err_cnt + 16'd1;
          $display("[%0t] MISMATCH: a=%h b=%h c=%h -> dut=%h exp=%h",
                   $time, a_d5, b_d5, c_d5, result, exp_d5);
        end else begin
          $display("[%0t] MATCH   : a=%h b=%h c=%h -> dut=%h exp=%h",
                   $time, a_d5, b_d5, c_d5, result, exp_d5);
        end
      end
    end
  endtask

  // ---------------- Stimulus with PRECOMPUTED expected outputs ----------------
  initial begin
    // init
    a16=16'h0000; b16=16'h0000; c16=16'h0000;
    exp_d1=16'h0000; exp_d2=16'h0000; exp_d3=16'h0000; exp_d4=16'h0000; exp_d5=16'h0000;
    a_d1=16'h0000; a_d2=16'h0000; a_d3=16'h0000; a_d4=16'h0000; a_d5=16'h0000;
    b_d1=16'h0000; b_d2=16'h0000; b_d3=16'h0000; b_d4=16'h0000; b_d5=16'h0000;
    c_d1=16'h0000; c_d2=16'h0000; c_d3=16'h0000; c_d4=16'h0000; c_d5=16'h0000;
    pipe_cnt=3'd0; pipe_full=1'b0; err_cnt=16'd0;

    @(posedge clk); @(posedge clk);

    // ================= Core sanity =================
    // 1) 1.0*2.0 + 0.5 = 2.5 -> 0x4100 (not 0x4200)
    apply_and_expect(16'h3C00,16'h4000,16'h3800,16'h4100);

    // 2) (-3.0)*(-2.0) + (-1.0) = 5.0 -> 0x4500
    apply_and_expect(16'hC200,16'hC000,16'hBC00,16'h4500);

    // 3) 0 * 9.0 + 1.5 = 1.5 -> 0x3E00
    apply_and_expect(16'h0000,16'h4880,16'h3E00,16'h3E00);

    // 4) 4.0 * 0.5 + 0.25 = 2.25 -> 0x4080
    apply_and_expect(16'h4400,16'h3800,16'h3400,16'h4080);

    // ================= Adder guard/cancellation paths =================
    // 5) Guard-bit corner: 1.0*1.0 + (-0.9995…) -> 2^-11 = 0x1000
    apply_and_expect(16'h3C00,16'h3C00,16'hBBFF,16'h1000);

    // 6) 1.0*1.0 + (-0.5) = 0.5 -> 0x3800
    apply_and_expect(16'h3C00,16'h3C00,16'hB800,16'h3800);

    // 7) Near-cancel: (1.0*1.0) + (-1.0) = 0 -> 0x0000
    apply_and_expect(16'h3C00,16'h3C00,16'hBC00,16'h0000);

    // 8) (1.5*1.0) + (-1.0) = 0.5 -> 0x3800
    apply_and_expect(16'h3E00,16'h3C00,16'hBC00,16'h3800);

    // 9) (1.25*1.0) + (-1.0) = 0.25 -> 0x3400
    apply_and_expect(16'h3D00,16'h3C00,16'hBC00,16'h3400);

    // ================= Large gap / alignment =================
    // 10) (8.0*1.0) + 0.25 = 8.25 -> expected as given
    apply_and_expect(16'h4000,16'h4800,16'h3400,16'h4C10);

    // 11) (3.2e4-ish*1.0) + 0.25 -> ~3.2e4 -> 0x6B00
    apply_and_expect(16'h6B00,16'h3C00,16'h3400,16'h6B00);

    // ================= Negative products / sums =================
    // 12) (-2.0*3.0) + 2.0 = -4.0 -> 0xC400
    apply_and_expect(16'hC000,16'h4200,16'h4000,16'hC400);

    // 13) (-2.0*1.5) + 2.0 = -1.0 -> 0xBC00
    apply_and_expect(16'hC000,16'h3E00,16'h4000,16'hBC00);

    // 14) (-1.5 * -2.0) + (-0.5) = 2.5 -> 0x4100
    apply_and_expect(16'hBE00,16'hC000,16'hB800,16'h4100);

    // ================= Special cases =================
    // 16) max + max via add: (max*1.0) + max -> +Inf
    apply_and_expect(16'h7BFF,16'h3C00,16'h7BFF,16'h7FFF); // using your expected token

    // 17) Addend is +Inf → result +Inf
    apply_and_expect(16'h3C00,16'h4000,16'h7C00,16'h7C00);

    // 18) Multiply overflow to +Inf: (max * 2.0) + 0 = +Inf
    apply_and_expect(16'h7BFF,16'h4000,16'h0000,16'h7C00);

    // ================= Zero / denorm handling =================
    // 20) 0 * x + 0 = 0
    apply_and_expect(16'h0000,16'h4000,16'h0000,16'h0000);

    // 21) Denorm addend flushed: (1*1)+subnormal(≈0) = 1.0
    apply_and_expect(16'h3C00,16'h3C00,16'h0005,16'h3C00);

    // 22) Denorm multiplicand flushed: (subnorm * 2.0) + 1.0 = 1.0
    apply_and_expect(16'h0001,16'h4000,16'h3C00,16'h3C00);

    // ================= More regular mixes =================
    // 23) (2.0*2.0) + 0 = 4.0 -> 0x4400
    apply_and_expect(16'h4000,16'h4000,16'h0000,16'h4400);

    // 24) (3.0*0.5) + 0.25 = 1.75 -> expected as given
    apply_and_expect(16'h4200,16'h3800,16'h3400,16'h3F00);

    // 25) (2.5*1.0) + 0.5 = 3.0 -> 0x4200
    apply_and_expect(16'h4100,16'h3C00,16'h3800,16'h4200);

    // 26) (1.0*9.0) + (-8.0) = 1.0 -> 0x3C00
    apply_and_expect(16'h3C00,16'h4880,16'hC800,16'h3C00);

    // 27) (1.0*1.0) + (0.25) = 1.25 -> 0x3D00
    apply_and_expect(16'h3C00,16'h3C00,16'h3400,16'h3D00);

    // 28) (-1.0*2.5) + 3.5 = 1.0 -> 0x3C00
    apply_and_expect(16'hBC00,16'h4100,16'h4300,16'h3C00);

    // 29) (0.5*0.5) + 0.5 = 0.75 -> 0x3A00
    apply_and_expect(16'h3800,16'h3800,16'h3800,16'h3A00);

    // 30) (-0.5*2.0) + (-0.5) = -1.5 -> 0xBE00
    apply_and_expect(16'hB800,16'h4000,16'hB800,16'hBE00);

    // ---------------- Drain pipeline (5 extra cycles) ----------------
    apply_and_expect(16'h0000,16'h0000,16'h0000,16'h0000);
    apply_and_expect(16'h0000,16'h0000,16'h0000,16'h0000);
    apply_and_expect(16'h0000,16'h0000,16'h0000,16'h0000);
    apply_and_expect(16'h0000,16'h0000,16'h0000,16'h0000);
    apply_and_expect(16'h0000,16'h0000,16'h0000,16'h0000);

    if (err_cnt == 16'd0)
      $display("ALL PRECOMPUTED MAC TESTS PASSED ✅  (latency=%0d)", LATENCY);
    else
      $display("TESTS FAILED ❌  mismatches=%0d", err_cnt);

    $finish;
  end

endmodule

`default_nettype wire
