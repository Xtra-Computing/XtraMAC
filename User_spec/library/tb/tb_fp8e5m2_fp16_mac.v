`timescale 1ns/1ps
`default_nettype none

module tb_fp8e5m2_fp16_mac;
  localparam integer VEC_COUNT = 14;
  localparam integer LATENCY   = 4;
  localparam [15:0]  QNAN16    = 16'h7E00;

  reg         clk;
  reg  [15:0] a16;
  reg  [15:0] b16;
  reg  [31:0] c32;
  wire [31:0] result;

  wire [15:0] res_lo16 = result[15:0];
  wire [15:0] res_hi16 = result[31:16];

  fp8e5m2_fp16_mac dut (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

  wire [15:0] gold_a_lo16 = fp8e5m2_lane_to_fp16(a16[7:0]);
  wire [15:0] gold_a_hi16 = fp8e5m2_lane_to_fp16(a16[15:8]);

  wire [15:0] gold_lo16;
  wire [15:0] gold_hi16;

  fp16_mac u_gold_lo (
    .clk   (clk),
    .a16   (gold_a_lo16),
    .b16   (b16),
    .c16   (c32[15:0]),
    .result(gold_lo16)
  );

  fp16_mac u_gold_hi (
    .clk   (clk),
    .a16   (gold_a_hi16),
    .b16   (b16),
    .c16   (c32[31:16]),
    .result(gold_hi16)
  );

  // Clock generation
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Test vectors
  reg [15:0] A_vec [0:VEC_COUNT-1];
  reg [15:0] B_vec [0:VEC_COUNT-1];
  reg [31:0] C_vec [0:VEC_COUNT-1];

  initial begin
    A_vec[0]  = 16'h3C34; B_vec[0]  = 16'h3C00; C_vec[0]  = {16'h3C00, 16'h0000};
    A_vec[1]  = 16'h443C; B_vec[1]  = 16'hB800; C_vec[1]  = {16'hBC00, 16'h3800};
    A_vec[2]  = 16'h3C80; B_vec[2]  = 16'h4000; C_vec[2]  = {16'h3800, 16'h3800};
    A_vec[3]  = 16'hFC3C; B_vec[3]  = 16'h3C00; C_vec[3]  = {16'hBC00, 16'h3C00};
    A_vec[4]  = 16'h7CB8; B_vec[4]  = 16'h3C00; C_vec[4]  = 32'h0000_0000;
    A_vec[5]  = 16'h7DB8; B_vec[5]  = 16'h3C00; C_vec[5]  = {16'h3C00, 16'h3C00};
    A_vec[6]  = 16'h0101; B_vec[6]  = 16'h3C00; C_vec[6]  = 32'h0000_0000;
    A_vec[7]  = 16'h4848; B_vec[7]  = 16'h3E00; C_vec[7]  = {16'h3400, 16'hB400};
    A_vec[8]  = 16'h7878; B_vec[8]  = 16'h3C00; C_vec[8]  = 32'h0000_0000;
    A_vec[9]  = 16'h0080; B_vec[9]  = 16'hC000; C_vec[9]  = {16'h3C00, 16'hBC00};
    A_vec[10] = 16'h7C00; B_vec[10] = 16'h0000; C_vec[10] = 32'h0000_0000;
    A_vec[11] = 16'h3C12; B_vec[11] = 16'h7E01; C_vec[11] = 32'h0000_0000;
    A_vec[12] = 16'h2C34; B_vec[12] = 16'h7C00; C_vec[12] = 32'h0000_0000;
    A_vec[13] = 16'h7DFF; B_vec[13] = 16'h3C00; C_vec[13] = {16'h3C00, 16'hBC00};
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
        if ((res_hi16 === gold_hi16) && (res_lo16 === gold_lo16)) begin
          pass_cnt = pass_cnt + 1;
        end else begin
          fail_cnt = fail_cnt + 1;
          $display("[%0t] FAIL vec%0d: res_hi=0x%04h res_lo=0x%04h exp_hi=0x%04h exp_lo=0x%04h",
                   $time, cycle-LATENCY, res_hi16, res_lo16, gold_hi16, gold_lo16);
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

  function automatic [15:0] fp8e5m2_lane_to_fp16;
    input [7:0] fp8;
    reg        sign;
    reg [4:0]  exp_fp8;
    reg [1:0]  frac_fp8;
    begin
      sign     = fp8[7];
      exp_fp8  = fp8[6:2];
      frac_fp8 = fp8[1:0];

      if (exp_fp8 == 5'h1F) begin
        fp8e5m2_lane_to_fp16 = (frac_fp8 == 2'd0) ? {sign, 5'h1F, 10'd0} : QNAN16;
      end else if (exp_fp8 == 5'd0) begin
        fp8e5m2_lane_to_fp16 = {sign, 15'd0};
      end else begin
        fp8e5m2_lane_to_fp16 = {sign, exp_fp8[4:0], {frac_fp8, 8'b0}};
      end
    end
  endfunction
endmodule

`default_nettype wire
