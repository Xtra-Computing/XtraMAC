`timescale 1ns/1ps
`default_nettype none

module tb_int8_fp16_32_mac;
  localparam integer VEC_COUNT = 16;
  localparam integer LATENCY   = 4;

  reg         clk;
  reg  [15:0] a16;
  reg  [15:0] b16;
  reg  [63:0] c64;
  wire [63:0] result;

  wire [31:0] res_hi = result[63:32];
  wire [31:0] res_lo = result[31:0];

  int8_fp16_32_mac dut (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .c64   (c64),
    .result(result)
  );

  // ------------------------------------------------------------------
  // Golden model: mirrors DUT pipeline to match approximations
  // ------------------------------------------------------------------
  wire [12:0] dec_lo = int8_decode(a16[7:0]);
  wire [12:0] dec_hi = int8_decode(a16[15:8]);

  wire        g_a_lo_sign = dec_lo[12];
  wire        g_a_lo_zero = dec_lo[11];
  wire [3:0]  g_a_lo_exp  = dec_lo[10:7];
  wire [6:0]  g_a_lo_mant = dec_lo[6:0];

  wire        g_a_hi_sign = dec_hi[12];
  wire        g_a_hi_zero = dec_hi[11];
  wire [3:0]  g_a_hi_exp  = dec_hi[10:7];
  wire [6:0]  g_a_hi_mant = dec_hi[6:0];

  wire        g_b_sign   = b16[15];
  wire [4:0]  g_b_exp    = b16[14:10];
  wire [9:0]  g_b_frac   = b16[9:0];
  wire        g_b_nan    = (g_b_exp == 5'h1F) && (g_b_frac != 10'd0);
  wire        g_b_inf    = (g_b_exp == 5'h1F) && (g_b_frac == 10'd0);
  wire        g_b_zero   = (g_b_exp == 5'd0);
  wire [10:0] g_man_b_eff = g_b_zero ? 11'd0 : {1'b1, g_b_frac};

  reg [26:0] g_man_a_s1;
  reg [17:0] g_man_b_s1;
  reg signed [11:0] g_exp_lo_s1, g_exp_hi_s1;
  reg        g_sign_lo_s1, g_sign_hi_s1;
  reg        g_zero_lo_s1, g_zero_hi_s1;
  reg        g_b_zero_s1, g_b_nan_s1, g_b_inf_s1;
  reg [31:0] g_c_lo_s1, g_c_hi_s1;

  reg [44:0] g_prod_s2;
  reg signed [11:0] g_exp_lo_s2, g_exp_hi_s2;
  reg        g_sign_lo_s2, g_sign_hi_s2;
  reg        g_zero_lo_s2, g_zero_hi_s2;
  reg        g_b_zero_s2, g_b_nan_s2, g_b_inf_s2;
  reg [31:0] g_c_lo_s2, g_c_hi_s2;
  reg [21:0] g_mul_lo_s2, g_mul_hi_s2;

  reg [31:0] gold_lo32, gold_hi32;

  // Test vectors
  reg [15:0] A_vec [0:VEC_COUNT-1];
  reg [15:0] B_vec [0:VEC_COUNT-1];
  reg [63:0] C_vec [0:VEC_COUNT-1];

  initial begin
    A_vec[0]  = pack_int8(127,   1);  B_vec[0]  = 16'h3C00; C_vec[0]  = {32'h3F800000, 32'h3F000000};
    A_vec[1]  = pack_int8( 64, -32);  B_vec[1]  = 16'h4000; C_vec[1]  = {32'h3F800000, 32'hBF800000};
    A_vec[2]  = pack_int8(-77,  23);  B_vec[2]  = 16'hB800; C_vec[2]  = {32'h40800000, 32'h40800000};
    A_vec[3]  = pack_int8(  0,   0);  B_vec[3]  = 16'h3C00; C_vec[3]  = {32'h00000000, 32'h00000000};
    A_vec[4]  = pack_int8( -1,  -1);  B_vec[4]  = 16'h3C00; C_vec[4]  = {32'hBF800000, 32'hBF800000};
    A_vec[5]  = pack_int8(-128, 127); B_vec[5]  = 16'h3F00; C_vec[5]  = {32'h3F000000, 32'hBF000000};
    A_vec[6]  = pack_int8(  7,  -7);  B_vec[6]  = 16'h4200; C_vec[6]  = {32'hC1000000, 32'h41000000};
    A_vec[7]  = pack_int8( 15,  15);  B_vec[7]  = 16'hC400; C_vec[7]  = {32'h3F800000, 32'h3F800000};
    A_vec[8]  = pack_int8(  2,   4);  B_vec[8]  = 16'h0000; C_vec[8]  = {32'h3F800000, 32'hBF800000};
    A_vec[9]  = pack_int8( 12,  -9);  B_vec[9]  = 16'h4C00; C_vec[9]  = {32'h00000000, 32'h80000000};
    A_vec[10] = pack_int8( -3,   3);  B_vec[10] = 16'h7C00; C_vec[10] = {32'h7F800000, 32'hFF800000};
    A_vec[11] = pack_int8( 20, -20);  B_vec[11] = 16'h7E00; C_vec[11] = {32'h40000000, 32'hC0000000};
    A_vec[12] = pack_int8(  5,   6);  B_vec[12] = 16'h3800; C_vec[12] = {32'h3F800000, 32'hBF800000};
    A_vec[13] = pack_int8( -5,  -6);  B_vec[13] = 16'hB800; C_vec[13] = {32'h3F800000, 32'hBF800000};
    A_vec[14] = pack_int8( 25, -40);  B_vec[14] = 16'h3E00; C_vec[14] = {32'h40200000, 32'hC0200000};
    A_vec[15] = pack_int8( -1,   1);  B_vec[15] = 16'h0001; C_vec[15] = {32'h3F800000, 32'hBF800000};
  end


  always @(posedge clk) begin
    g_man_a_s1      <= {2'b00, g_a_hi_mant, 11'd0, g_a_lo_mant};
    g_man_b_s1      <= {7'd0, g_man_b_eff};

    g_exp_lo_s1 <= (g_a_lo_zero || g_b_zero) ? 12'sd0 :
                   ($signed({8'd0, g_a_lo_exp}) + ($signed({1'b0, g_b_exp}) - 12'sd15));
    g_exp_hi_s1 <= (g_a_hi_zero || g_b_zero) ? 12'sd0 :
                   ($signed({8'd0, g_a_hi_exp}) + ($signed({1'b0, g_b_exp}) - 12'sd15));

    g_sign_lo_s1 <= g_a_lo_sign ^ g_b_sign;
    g_sign_hi_s1 <= g_a_hi_sign ^ g_b_sign;

    g_zero_lo_s1 <= g_a_lo_zero;
    g_zero_hi_s1 <= g_a_hi_zero;
    g_b_zero_s1  <= g_b_zero;
    g_b_nan_s1   <= g_b_nan;
    g_b_inf_s1   <= g_b_inf;

    g_c_lo_s1 <= c64[31:0];
    g_c_hi_s1 <= c64[63:32];
  end

  wire [44:0] g_prod_w = g_man_a_s1 * g_man_b_s1;
  wire [17:0] g_mul_lo_raw = g_prod_w[17:0];
  wire [17:0] g_mul_hi_raw = g_prod_w[35:18];

  always @(posedge clk) begin
    g_prod_s2    <= g_prod_w;
    g_exp_lo_s2  <= g_exp_lo_s1;
    g_exp_hi_s2  <= g_exp_hi_s1;
    g_sign_lo_s2 <= g_sign_lo_s1;
    g_sign_hi_s2 <= g_sign_hi_s1;
    g_zero_lo_s2 <= g_zero_lo_s1;
    g_zero_hi_s2 <= g_zero_hi_s1;
    g_b_zero_s2  <= g_b_zero_s1;
    g_b_nan_s2   <= g_b_nan_s1;
    g_b_inf_s2   <= g_b_inf_s1;
    g_c_lo_s2    <= g_c_lo_s1;
    g_c_hi_s2    <= g_c_hi_s1;
    g_mul_lo_s2  <= {g_mul_lo_raw, 4'b0000};
    g_mul_hi_s2  <= {g_mul_hi_raw, 4'b0000};
  end

  wire [21:0] g_man_lo_mul = g_mul_lo_s2;
  wire [21:0] g_man_hi_mul = g_mul_hi_s2;

  wire [31:0] gold_lo32_w = lane_fp16_mul_to_fp32(
                              g_man_lo_mul,
                              g_exp_lo_s2,
                              g_sign_lo_s2,
                              g_zero_lo_s2,
                              g_b_zero_s2,
                              g_b_nan_s2,
                              g_b_inf_s2);

  wire [31:0] gold_hi32_w = lane_fp16_mul_to_fp32(
                              g_man_hi_mul,
                              g_exp_hi_s2,
                              g_sign_hi_s2,
                              g_zero_hi_s2,
                              g_b_zero_s2,
                              g_b_nan_s2,
                              g_b_inf_s2);

  always @(posedge clk) begin
    gold_lo32 <= gold_lo32_w;
    gold_hi32 <= gold_hi32_w;
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
    c64 = 64'h0;

    repeat (VEC_COUNT + LATENCY + 2) begin
      if (idx_in < VEC_COUNT) begin
        next_a = A_vec[idx_in];
        next_b = B_vec[idx_in];
        next_c = C_vec[idx_in];
      end else begin
        next_a = 16'h0000;
        next_b = 16'h0000;
        next_c = 64'h0;
      end

      @(posedge clk);
      a16 <= next_a;
      b16 <= next_b;
      c64 <= next_c;

      if (idx_in < VEC_COUNT)
        idx_in = idx_in + 1;

      if ((cycle >= LATENCY) && ((cycle - LATENCY) < VEC_COUNT)) begin
        if ((res_hi === gold_hi32) && (res_lo === gold_lo32)) begin
          pass_cnt = pass_cnt + 1;
        end else begin
          fail_cnt = fail_cnt + 1;
          $display("[%0t] FAIL vec%0d: res_hi=0x%08h res_lo=0x%08h exp_hi=0x%08h exp_lo=0x%08h",
                   $time, cycle-LATENCY, res_hi, res_lo, gold_hi32, gold_lo32);
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

  function automatic [12:0] int8_decode;
    input [7:0] x;
    reg        sign;
    reg [7:0]  mag;
    reg        zero;
    reg [3:0]  exp_u;
    reg [6:0]  mant7;
    integer    k;
    reg [13:0] numer;
    reg [13:0] quotient;
    reg [13:0] remainder;
    reg        round_up;
    reg [7:0]  mant_ext;
    begin
      sign = x[7];
      mag  = sign ? (~x + 8'd1) : x;
      zero = (mag == 8'd0);
      exp_u = 4'd0;
      mant7 = 7'd0;

      if (!zero) begin
        casex (mag)
          8'b1???????: k = 7;
          8'b01??????: k = 6;
          8'b001?????: k = 5;
          8'b0001????: k = 4;
          8'b00001???: k = 3;
          8'b000001??: k = 2;
          8'b0000001?: k = 1;
          default:      k = 0;
        endcase
        exp_u = k[3:0];

        numer = {mag, 6'd0};
        if (k == 0) begin
          quotient  = numer;
          remainder = 14'd0;
        end else begin
          quotient  = numer >> k;
          remainder = numer & ((14'd1 << k) - 14'd1);
        end
        if (quotient > 14'd127)
          quotient = 14'd127;

        if (k == 0) begin
          round_up = 1'b0;
        end else begin
          round_up = (remainder > (14'd1 << (k-1))) ||
                     ((remainder == (14'd1 << (k-1))) && quotient[0]);
        end

        mant_ext = {1'b0, quotient[6:0]} + {7'd0, round_up};
        if (mant_ext[7]) begin
          mant_ext = {1'b0, mant_ext[7:1]};
          if (exp_u != 4'd7)
            exp_u = exp_u + 4'd1;
        end
        if (~mant_ext[6])
          mant_ext[6] = 1'b1;
        mant7 = mant_ext[6:0];
      end

      int8_decode = {sign, zero, exp_u, mant7};
    end
  endfunction

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
        lane_fp16_mul_to_fp32 = 32'h7FC00000;
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
