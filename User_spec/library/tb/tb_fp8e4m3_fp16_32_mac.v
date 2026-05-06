`timescale 1ns/1ps
`default_nettype none

module tb_fp8e4m3_fp16_32_mac;
  localparam integer VEC_COUNT = 14;
  localparam integer LATENCY   = 4;
  localparam [31:0]  QNAN32    = 32'h7FC0_0000;

  reg         clk;
  reg  [15:0] a16;
  reg  [15:0] b16;
  reg  [63:0] c64;
  wire [63:0] result;

  wire [31:0] res_lo32 = result[31:0];
  wire [31:0] res_hi32 = result[63:32];

  fp8e4m3_fp16_32_mac dut (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .c64   (c64),
    .result(result)
  );

  // Clock
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // ------------------------------------------------------------------
  // FP8 decode (E4M3)
  // ------------------------------------------------------------------
  wire [7:0] a_lo8 = a16[7:0];
  wire [7:0] a_hi8 = a16[15:8];

  wire        g_a_lo_sign = a_lo8[7];
  wire [3:0]  g_a_lo_exp  = a_lo8[6:3];
  wire [2:0]  g_a_lo_frac = a_lo8[2:0];
  wire        g_a_lo_nan  = (g_a_lo_exp == 4'hF);
  wire        g_a_lo_zero = (g_a_lo_exp == 4'd0);
  wire        g_a_lo_inf  = 1'b0;
  wire signed [11:0] g_a_lo_exp_unbias = $signed({8'd0, g_a_lo_exp}) - 12'sd7;
  wire [3:0]  g_a_lo_mant = (g_a_lo_zero || g_a_lo_nan) ? 4'd0 : {1'b1, g_a_lo_frac};

  wire        g_a_hi_sign = a_hi8[7];
  wire [3:0]  g_a_hi_exp  = a_hi8[6:3];
  wire [2:0]  g_a_hi_frac = a_hi8[2:0];
  wire        g_a_hi_nan  = (g_a_hi_exp == 4'hF);
  wire        g_a_hi_zero = (g_a_hi_exp == 4'd0);
  wire        g_a_hi_inf  = 1'b0;
  wire signed [11:0] g_a_hi_exp_unbias = $signed({8'd0, g_a_hi_exp}) - 12'sd7;
  wire [3:0]  g_a_hi_mant = (g_a_hi_zero || g_a_hi_nan) ? 4'd0 : {1'b1, g_a_hi_frac};

  // Shared FP16 operand classification
  wire        g_b_sign    = b16[15];
  wire [4:0]  g_b_exp     = b16[14:10];
  wire [9:0]  g_b_frac    = b16[9:0];
  wire        g_b_nan     = (g_b_exp == 5'h1F) && (g_b_frac != 10'd0);
  wire        g_b_inf     = (g_b_exp == 5'h1F) && (g_b_frac == 10'd0);
  wire        g_b_zero    = (g_b_exp == 5'd0);
  wire [10:0] g_man_b_eff = g_b_zero ? 11'd0 : {1'b1, g_b_frac};

  // ------------------------------------------------------------------
  // Golden pipeline mirroring the DUT
  // ------------------------------------------------------------------
  reg [26:0] g_man_a_s1;
  reg [17:0] g_man_b_s1;
  reg signed [11:0] g_exp_lo_s1, g_exp_hi_s1;
  reg        g_sign_lo_s1, g_sign_hi_s1;
  reg        g_a_lo_zero_s1, g_a_hi_zero_s1;
  reg        g_a_lo_nan_s1,  g_a_hi_nan_s1;
  reg        g_b_zero_s1, g_b_nan_s1, g_b_inf_s1;
  reg [31:0] g_c_lo_s1, g_c_hi_s1;

  always @(posedge clk) begin
    g_man_a_s1 <= {8'd0, g_a_hi_mant, 11'd0, g_a_lo_mant};
    g_man_b_s1 <= {7'd0, g_man_b_eff};

    g_exp_lo_s1 <= (g_a_lo_zero || g_a_lo_nan || g_b_zero || g_b_nan)
                   ? 12'sd0 : (g_a_lo_exp_unbias + ($signed({1'b0, g_b_exp}) - 12'sd15));
    g_exp_hi_s1 <= (g_a_hi_zero || g_a_hi_nan || g_b_zero || g_b_nan)
                   ? 12'sd0 : (g_a_hi_exp_unbias + ($signed({1'b0, g_b_exp}) - 12'sd15));

    g_sign_lo_s1 <= g_a_lo_sign ^ g_b_sign;
    g_sign_hi_s1 <= g_a_hi_sign ^ g_b_sign;

    g_a_lo_zero_s1 <= g_a_lo_zero;
    g_a_hi_zero_s1 <= g_a_hi_zero;
    g_a_lo_nan_s1  <= g_a_lo_nan;
    g_a_hi_nan_s1  <= g_a_hi_nan;

    g_b_zero_s1 <= g_b_zero;
    g_b_nan_s1  <= g_b_nan;
    g_b_inf_s1  <= g_b_inf;

    g_c_lo_s1 <= c64[31:0];
    g_c_hi_s1 <= c64[63:32];
  end

  wire [44:0] g_prod_w = g_man_a_s1 * g_man_b_s1;

  reg signed [11:0] g_exp_lo_s2, g_exp_hi_s2;
  reg        g_sign_lo_s2, g_sign_hi_s2;
  reg        g_a_lo_zero_s2, g_a_hi_zero_s2;
  reg        g_a_lo_nan_s2,  g_a_hi_nan_s2;
  reg        g_b_zero_s2, g_b_nan_s2, g_b_inf_s2;
  reg [31:0] g_c_lo_s2, g_c_hi_s2;
  reg [21:0] g_mul_lo_s2, g_mul_hi_s2;

  wire [14:0] g_mul_lo_raw = g_prod_w[14:0];
  wire [14:0] g_mul_hi_raw = g_prod_w[29:15];

  always @(posedge clk) begin
    g_exp_lo_s2 <= g_exp_lo_s1;
    g_exp_hi_s2 <= g_exp_hi_s1;
    g_sign_lo_s2 <= g_sign_lo_s1;
    g_sign_hi_s2 <= g_sign_hi_s1;

    g_a_lo_zero_s2 <= g_a_lo_zero_s1;
    g_a_hi_zero_s2 <= g_a_hi_zero_s1;
    g_a_lo_nan_s2  <= g_a_lo_nan_s1;
    g_a_hi_nan_s2  <= g_a_hi_nan_s1;

    g_b_zero_s2 <= g_b_zero_s1;
    g_b_nan_s2  <= g_b_nan_s1;
    g_b_inf_s2  <= g_b_inf_s1;

    g_c_lo_s2 <= g_c_lo_s1;
    g_c_hi_s2 <= g_c_hi_s1;

    g_mul_lo_s2 <= {g_mul_lo_raw, 7'd0};
    g_mul_hi_s2 <= {g_mul_hi_raw, 7'd0};
  end

  wire [31:0] g_lo_prod32_w = lane_fp16_mul_to_fp32(
                                g_mul_lo_s2,
                                g_exp_lo_s2,
                                g_sign_lo_s2,
                                g_a_lo_zero_s2,
                                g_b_zero_s2,
                                g_b_nan_s2 | g_a_lo_nan_s2,
                                g_b_inf_s2 | g_a_lo_inf);

  wire [31:0] g_hi_prod32_w = lane_fp16_mul_to_fp32(
                                g_mul_hi_s2,
                                g_exp_hi_s2,
                                g_sign_hi_s2,
                                g_a_hi_zero_s2,
                                g_b_zero_s2,
                                g_b_nan_s2 | g_a_hi_nan_s2,
                                g_b_inf_s2 | g_a_hi_inf);

  wire [31:0] gold_sum_lo_w;
  wire [31:0] gold_sum_hi_w;

  fp32_add u_gold_add_lo (
    .clk   (clk),
    .x32   (g_lo_prod32_w),
    .y32   (g_c_lo_s2),
    .result(gold_sum_lo_w)
  );

  fp32_add u_gold_add_hi (
    .clk   (clk),
    .x32   (g_hi_prod32_w),
    .y32   (g_c_hi_s2),
    .result(gold_sum_hi_w)
  );

  reg [31:0] gold_lo32, gold_hi32;
  always @(posedge clk) begin
    gold_lo32 <= gold_sum_lo_w;
    gold_hi32 <= gold_sum_hi_w;
  end

  // Test vectors
  reg [15:0] A_vec [0:VEC_COUNT-1];
  reg [15:0] B_vec [0:VEC_COUNT-1];
  reg [63:0] C_vec [0:VEC_COUNT-1];

  initial begin
    A_vec[0]  = 16'h3830; B_vec[0]  = 16'h3C00; C_vec[0]  = {32'h3F800000, 32'h00000000};
    A_vec[1]  = 16'h4038; B_vec[1]  = 16'hBC00; C_vec[1]  = {32'h00000000, 32'hBFC00000};
    A_vec[2]  = 16'h3880; B_vec[2]  = 16'h4000; C_vec[2]  = {32'h3F000000, 32'h3F000000};
    A_vec[3]  = 16'hFF38; B_vec[3]  = 16'h3C00; C_vec[3]  = {32'hBF800000, 32'h3F800000};
    A_vec[4]  = 16'h0101; B_vec[4]  = 16'h3C00; C_vec[4]  = 64'h0000_0000_0000_0000;
    A_vec[5]  = 16'h4848; B_vec[5]  = 16'h3E00; C_vec[5]  = {32'h3E800000, 32'hBE800000};
    A_vec[6]  = 16'h7878; B_vec[6]  = 16'h3C00; C_vec[6]  = 64'h0000_0000_0000_0000;
    A_vec[7]  = 16'h0080; B_vec[7]  = 16'hC000; C_vec[7]  = {32'h3F800000, 32'hBF800000};
    A_vec[8]  = 16'h2431; B_vec[8]  = 16'h0000; C_vec[8]  = {32'h3F800000, 32'hBF800000};
    A_vec[9]  = 16'h3C88; B_vec[9]  = 16'h7E01; C_vec[9]  = 64'h0000_0000_0000_0000;
    A_vec[10] = 16'h3C08; B_vec[10] = 16'h7C00; C_vec[10] = 64'h0000_0000_0000_0000;
    A_vec[11] = 16'h0001; B_vec[11] = 16'h7C00; C_vec[11] = {32'h3F800000, 32'h3F800000};
    A_vec[12] = 16'h8000; B_vec[12] = 16'h3C00; C_vec[12] = {32'h3F800000, 32'h3F800000};
    A_vec[13] = 16'h12F0; B_vec[13] = 16'hB800; C_vec[13] = {32'h3F800000, 32'hBF800000};
  end

  integer idx_in;
  integer cycle;
  integer pass_cnt, fail_cnt;
  reg [15:0] next_a;
  reg [15:0] next_b;
  reg [63:0] next_c;

  initial begin
    idx_in   = 0;
    cycle    = 0;
    pass_cnt = 0;
    fail_cnt = 0;

    a16 = 16'h0000;
    b16 = 16'h0000;
    c64 = 64'h0000_0000_0000_0000;

    repeat (VEC_COUNT + LATENCY + 2) begin
      if (idx_in < VEC_COUNT) begin
        next_a = A_vec[idx_in];
        next_b = B_vec[idx_in];
        next_c = C_vec[idx_in];
      end else begin
        next_a = 16'h0000;
        next_b = 16'h0000;
        next_c = 64'h0000_0000_0000_0000;
      end

      @(posedge clk);
      a16 <= next_a;
      b16 <= next_b;
      c64 <= next_c;

      if (idx_in < VEC_COUNT)
        idx_in = idx_in + 1;

      if ((cycle >= LATENCY) && ((cycle - LATENCY) < VEC_COUNT)) begin
        if ((res_hi32 === gold_hi32) && (res_lo32 === gold_lo32)) begin
          pass_cnt = pass_cnt + 1;
        end else begin
          fail_cnt = fail_cnt + 1;
          $display("[%0t] FAIL vec%0d: res_hi=0x%08h res_lo=0x%08h exp_hi=0x%08h exp_lo=0x%08h",
                   $time, cycle-LATENCY, res_hi32, res_lo32, gold_hi32, gold_lo32);
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

  function automatic [31:0] lane_fp16_mul_to_fp32;
    input      [21:0] mul22;
    input signed [11:0] exp_unbiased_in;
    input               sign;
    input               a_is_zero;
    input               b_is_zero;
    input               b_is_nan;
    input               b_is_inf;
    reg         leading2;
    reg signed [12:0] exp_norm;
    reg signed [12:0] exp_biased;
    reg [21:0]  norm22;
    reg [24:0]  sig_ext;
    reg [23:0]  sig24;
    begin
      if (b_is_nan || (b_is_inf && (a_is_zero || b_is_zero))) begin
        lane_fp16_mul_to_fp32 = QNAN32;
      end else if (b_is_inf) begin
        lane_fp16_mul_to_fp32 = {sign, 8'hFF, 23'd0};
      end else if (a_is_zero || b_is_zero) begin
        lane_fp16_mul_to_fp32 = {sign, 31'd0};
      end else begin
        leading2 = mul22[21];
        norm22   = leading2 ? (mul22 >> 1) : mul22;
        exp_norm = exp_unbiased_in + (leading2 ? 13'sd1 : 13'sd0);
        exp_biased = exp_norm + 13'sd127;

        if (exp_biased >= 13'sd255) begin
          lane_fp16_mul_to_fp32 = {sign, 8'hFF, 23'd0};
        end else if (exp_biased <= 13'sd0) begin
          lane_fp16_mul_to_fp32 = {sign, 31'd0};
        end else begin
          sig_ext = {norm22, 3'b000};
          sig24   = sig_ext[23:0];
          lane_fp16_mul_to_fp32 = {sign, exp_biased[7:0], sig24[22:0]};
        end
      end
    end
  endfunction
endmodule

`default_nettype wire
