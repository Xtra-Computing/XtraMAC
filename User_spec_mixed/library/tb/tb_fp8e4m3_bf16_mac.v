`timescale 1ns/1ps
`default_nettype none

module tb_fp8e4m3_bf16_mac;
  localparam CLK_PERIOD  = 10;
  localparam NUM_VECTORS = 4;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg [31:0] a_data;
  reg [15:0] b_data;
  reg [63:0] c_data;
  wire [63:0] result;

  fp8e4m3_bf16_mac dut (
      .clk (clk),
      .a18 (a_data),
      .b18 (b_data),
      .c64 (c_data),
      .result(result)
  );

  reg        feed_valid;
  reg [3:0]  valid_pipe;
  reg [63:0] exp_pipe0, exp_pipe1, exp_pipe2, exp_pipe3;
  reg [63:0] exp_in;
  integer idx, checks, errors;

  localparam [15:0] BF16_QNAN      = 16'h7FC0;
  localparam [15:0] BF16_POS_ONE   = 16'h3F80;
  localparam [15:0] BF16_NEG_ONE   = 16'hBF80;
  localparam [15:0] BF16_POS_HALF  = 16'h3F00;
  localparam [15:0] BF16_POS_TWO   = 16'h4000;
  localparam [15:0] BF16_NEG_HALF  = 16'hBF00;
  localparam [15:0] BF16_POS_THREE = 16'h4040;
  localparam [15:0] BF16_POS_ONEP5 = 16'h3FC0;

  function automatic [31:0] pack_fp8_pair(input [7:0] hi, input [7:0] lo);
    pack_fp8_pair = {16'd0, hi, lo};
  endfunction

  reg [31:0] vec_a [0:NUM_VECTORS-1];
  reg [15:0] vec_b [0:NUM_VECTORS-1];
  reg [63:0] vec_c [0:NUM_VECTORS-1];

  initial begin
    vec_a[0]=pack_fp8_pair(8'h3A,8'h32);
    vec_b[0]={8'h3C,8'h30};
    vec_c[0]={BF16_POS_ONE,BF16_NEG_ONE,BF16_POS_HALF,BF16_POS_TWO};

    vec_a[1]=pack_fp8_pair(8'h2A,8'h1A);
    vec_b[1]={8'h39,8'h21};
    vec_c[1]={BF16_NEG_ONE,BF16_POS_ONEP5,16'h0000,BF16_NEG_HALF};

    vec_a[2]=pack_fp8_pair(8'h40,8'h20);
    vec_b[2]={8'h40,8'h20};
    vec_c[2]={BF16_POS_ONE,BF16_POS_TWO,BF16_NEG_ONE,BF16_NEG_ONE};

    vec_a[3]=pack_fp8_pair(8'h10,8'h30);
    vec_b[3]={8'h28,8'h18};
    vec_c[3]={BF16_POS_THREE,BF16_POS_ONE,BF16_NEG_HALF,BF16_NEG_HALF};
  end

  function automatic bf16_is_nan;
    input [15:0] x;
    begin
      bf16_is_nan = (x[14:7]==8'hFF) && (x[6:0]!=7'd0);
    end
  endfunction

  function automatic bf16_is_inf;
    input [15:0] x;
    begin
      bf16_is_inf = (x[14:7]==8'hFF) && (x[6:0]==7'd0);
    end
  endfunction

  function automatic bf16_is_zero;
    input [15:0] x;
    begin
      bf16_is_zero = (x[14:7]==8'd0);
    end
  endfunction

  function automatic [3:0] clz9(input [8:0] x);
    casex (x)
      9'b1xxxxxxxx: clz9 = 4'd0;
      9'b01xxxxxxx: clz9 = 4'd1;
      9'b001xxxxxx: clz9 = 4'd2;
      9'b0001xxxxx: clz9 = 4'd3;
      9'b00001xxxx: clz9 = 4'd4;
      9'b000001xxx: clz9 = 4'd5;
      9'b0000001xx: clz9 = 4'd6;
      9'b00000001x: clz9 = 4'd7;
      9'b000000001: clz9 = 4'd8;
      default:       clz9 = 4'd9;
    endcase
  endfunction

  function automatic [7:0] rshift8(input [7:0] x, input [3:0] sh);
    case (sh)
      4'd0 : rshift8 = x;
      4'd1 : rshift8 = {1'b0,       x[7:1]};
      4'd2 : rshift8 = {2'b00,      x[7:2]};
      4'd3 : rshift8 = {3'b000,     x[7:3]};
      4'd4 : rshift8 = {4'b0000,    x[7:4]};
      4'd5 : rshift8 = {5'b00000,   x[7:5]};
      4'd6 : rshift8 = {6'b000000,  x[7:6]};
      4'd7 : rshift8 = {7'b0000000, x[7]};
      default: rshift8 = 8'b0;
    endcase
  endfunction

  function automatic sticky_from_norm9;
    input [8:0] x;
    input [3:0] lz;
    reg [8:0] mask;
    begin
      mask = (lz==4'd0) ? 9'd0 : (9'h1FF >> (9 - lz));
      sticky_from_norm9 = |(x & mask);
    end
  endfunction

  function automatic [15:0] bf16_add_func(input [15:0] a16, input [15:0] b16);
    reg sa0, sb0;
    reg [7:0] ea0, eb0;
    reg [6:0] fa0, fb0;
    reg a_is_nan, b_is_nan, a_is_inf, b_is_inf, a_is_zero, b_is_zero;
    reg special_is_nan_0, special_is_inf_0, special_inf_sign_0;
    reg both_zero_0, zero_sign_0;
    reg [8:0] Ea0, Eb0, E_big_1, E_sml_1, dE_1, dE_r, E_big, E_n, E_l, E_rounded;
    reg [7:0] Ma0, Mb0, M_big_1, M_sml_1, M_big, M_sml, M_sml_aligned, mant_trunc, mant_rounded;
    reg [3:0] shamt, lz;
    reg swap0, sign_big_1, sign_sml_1, sign_big, diff_sign_1, diff_sign;
    reg guard_bit, guardF, stickyF, lsb_bit, round_inc, same_sign, add_carry, mant_ovf;
    reg overflow_pack, under_or_zero;
    reg short_nan_r, short_inf_r, short_inf_sign_r, short_zero_r, short_zero_sign_r;
    reg [15:0] finite_out;
    reg [8:0] big9, sml9_i, lane9, laneN;
    reg [9:0] add_a, add_bi, add_b, sum10, sumC;
    begin
      sa0 = a16[15]; ea0 = a16[14:7]; fa0 = a16[6:0];
      sb0 = b16[15]; eb0 = b16[14:7]; fb0 = b16[6:0];

      a_is_nan  = bf16_is_nan(a16);
      b_is_nan  = bf16_is_nan(b16);
      a_is_inf  = bf16_is_inf(a16);
      b_is_inf  = bf16_is_inf(b16);
      a_is_zero = bf16_is_zero(a16);
      b_is_zero = bf16_is_zero(b16);

      special_is_nan_0 = a_is_nan | b_is_nan | ((a_is_inf & b_is_inf) & (sa0 ^ sb0));

      special_is_inf_0 =
          (~special_is_nan_0) &
          ((a_is_inf & ~b_is_inf & ~b_is_nan) |
           (~a_is_inf & ~a_is_nan & b_is_inf) |
           (a_is_inf & b_is_inf & ~(sa0 ^ sb0)));

      special_inf_sign_0 =
          (a_is_inf & ~b_is_inf & ~b_is_nan) ? sa0 :
          (~a_is_inf & ~a_is_nan & b_is_inf) ? sb0 :
                                               sa0;

      both_zero_0 = a_is_zero & b_is_zero;
      zero_sign_0 = (sa0 & sb0);

      Ea0 = a_is_zero ? 9'd0 : {1'b0, ea0};
      Eb0 = b_is_zero ? 9'd0 : {1'b0, eb0};
      Ma0 = a_is_zero ? 8'd0 : {1'b1, fa0};
      Mb0 = b_is_zero ? 8'd0 : {1'b1, fb0};

      swap0 = (Ea0 < Eb0) || ((Ea0 == Eb0) && (Ma0 < Mb0));
      sign_big_1 = swap0 ? sb0 : sa0;
      sign_sml_1 = swap0 ? sa0 : sb0;
      E_big_1    = swap0 ? Eb0 : Ea0;
      E_sml_1    = swap0 ? Ea0 : Eb0;
      M_big_1    = swap0 ? Mb0 : Ma0;
      M_sml_1    = swap0 ? Ma0 : Mb0;

      dE_1 = (E_big_1 >= E_sml_1) ? (E_big_1 - E_sml_1) : 9'd0;
      diff_sign_1 = (sign_big_1 ^ sign_sml_1);

      sign_big = sign_big_1;
      dE_r     = dE_1;
      diff_sign = diff_sign_1;
      E_big    = E_big_1;
      M_big    = M_big_1;
      M_sml    = M_sml_1;
      short_nan_r       = special_is_nan_0;
      short_inf_r       = special_is_inf_0;
      short_inf_sign_r  = special_inf_sign_0;
      short_zero_r      = both_zero_0;
      short_zero_sign_r = zero_sign_0;

      shamt         = (dE_r >= 9'd8) ? 4'd8 : dE_r[3:0];
      M_sml_aligned = rshift8(M_sml, shamt);
      guard_bit     = (shamt == 4'd0) ? 1'b0 : M_sml[shamt-1];

      big9   = {M_big,          1'b0};
      sml9_i = {M_sml_aligned,  guard_bit};

      add_a  = {1'b0, big9};
      add_bi = {1'b0, sml9_i};
      add_b  = diff_sign ? (~add_bi + 10'd1) : add_bi;
      sum10  = add_a + add_b;

      same_sign = ~diff_sign;
      add_carry = same_sign & sum10[9];

      sumC  = add_carry ? (sum10 >> 1) : sum10;
      E_n   = add_carry ? (E_big + 9'd1) : E_big;

      lane9   = sumC[8:0];
      lz      = clz9(lane9);
      begin : blk_norm
        reg zero_af;
        zero_af = (lz == 4'd9) | (E_n <= lz);
        laneN   = zero_af ? 9'd0 : (lane9 << lz);
        E_l     = zero_af ? 9'd0 : (E_n - lz);
      end

      mant_trunc = laneN[8:1];
      guardF     = laneN[0];
      stickyF    = sticky_from_norm9(lane9, lz);

      lsb_bit    = mant_trunc[0];
      round_inc  = guardF & (stickyF | lsb_bit);

      begin : blk_round
        reg [8:0] mant_round_wide;
        mant_round_wide = {1'b0, mant_trunc} + {8'd0, round_inc};
        mant_ovf        = mant_round_wide[8];
        mant_rounded    = mant_ovf ? 8'b1000_0000 : mant_round_wide[7:0];
        E_rounded       = mant_ovf ? (E_l + 9'd1) : E_l;
      end

      overflow_pack  = (E_rounded > 9'd255);
      under_or_zero  = (E_rounded == 9'd0) | (mant_rounded == 8'd0);

      finite_out = {sign_big, E_rounded[7:0], mant_rounded[6:0]};

      if (short_nan_r)
        bf16_add_func = BF16_QNAN;
      else if (short_inf_r)
        bf16_add_func = {short_inf_sign_r, 8'hFF, 7'd0};
      else if (short_zero_r)
        bf16_add_func = {short_zero_sign_r, 15'h0000};
      else if (overflow_pack)
        bf16_add_func = {sign_big, 8'hFF, 7'd0};
      else if (under_or_zero)
        bf16_add_func = 16'h0000;
      else
        bf16_add_func = finite_out;
    end
  endfunction

  function automatic [15:0] fp8_prod_to_bf16_ref;
    input        sign_in;
    input signed [6:0] exp_unbias;
    input [10:0] mant_norm;
    input        nan_in;
    input        zero_in;
    reg [6:0] frac_pre;
    reg guard_bit, sticky_bits, round_up;
    reg [7:0] frac_round;
    reg frac_carry;
    reg [6:0] frac_final;
    reg signed [8:0] exp_adj;
    reg signed [9:0] exp_biased;
    begin
      if (nan_in) begin
        fp8_prod_to_bf16_ref = BF16_QNAN;
      end else if (zero_in) begin
        fp8_prod_to_bf16_ref = {sign_in, 15'd0};
      end else begin
        frac_pre   = mant_norm[9:3];
        guard_bit  = mant_norm[2];
        sticky_bits= |mant_norm[1:0];
        round_up   = guard_bit & (sticky_bits | frac_pre[0]);
        frac_round = {1'b0, frac_pre} + {7'd0, round_up};
        frac_carry = frac_round[7];
        frac_final = frac_carry ? 7'd0 : frac_round[6:0];
        exp_adj    = exp_unbias + (frac_carry ? 9'sd1 : 9'sd0);
        exp_biased = exp_adj + 10'sd127;
        if (exp_biased >= 10'sd255)
          fp8_prod_to_bf16_ref = {sign_in, 8'hFF, 7'd0};
        else if (exp_biased <= 10'sd0)
          fp8_prod_to_bf16_ref = {sign_in, 15'd0};
        else
          fp8_prod_to_bf16_ref = {sign_in, exp_biased[7:0], frac_final};
      end
    end
  endfunction

  function automatic [63:0] calc_expected (
      input [31:0] a_bus,
      input [15:0] b_bus,
      input [63:0] c_bus
  );
    reg [7:0] a1, a2, b1, b2;
    reg sa1, sa2, sb1, sb2;
    reg [3:0] ea1, ea2, eb1, eb2;
    reg [2:0] fa1, fa2, fb1, fb2;
    reg a1_nan, a2_nan, b1_nan, b2_nan;
    reg a1_zero, a2_zero, b1_zero, b2_zero;
    reg s11, s12, s21, s22;
    reg signed [6:0] e11_s1, e12_s1, e21_s1, e22_s1;
    reg [3:0] Ma1, Ma2, Mb1, Mb2;
    reg [7:0] P11, P12, P21, P22;
    reg        c11_carry, c12_carry, c21_carry, c22_carry;
    reg [11:0] c11_mant_nocarry, c12_mant_nocarry, c21_mant_nocarry, c22_mant_nocarry;
    reg [10:0] c11_mant_norm, c12_mant_norm, c21_mant_norm, c22_mant_norm;
    reg signed [6:0] c11_es, c12_es, c21_es, c22_es;
    reg nan_11, nan_12, nan_21, nan_22;
    reg zer_11, zer_12, zer_21, zer_22;
    reg [15:0] prod11_bf16, prod12_bf16, prod21_bf16, prod22_bf16;
    reg [15:0] sum11_bf16, sum12_bf16, sum21_bf16, sum22_bf16;
    begin
      a1 = a_bus[7:0];
      a2 = a_bus[15:8];
      b1 = b_bus[7:0];
      b2 = b_bus[15:8];

      sa1 = a1[7]; sa2 = a2[7];
      sb1 = b1[7]; sb2 = b2[7];
      ea1 = a1[6:3]; ea2 = a2[6:3]; eb1 = b1[6:3]; eb2 = b2[6:3];
      fa1 = a1[2:0]; fa2 = a2[2:0]; fb1 = b1[2:0]; fb2 = b2[2:0];

      a1_nan = (ea1 == 4'hF);
      a2_nan = (ea2 == 4'hF);
      b1_nan = (eb1 == 4'hF);
      b2_nan = (eb2 == 4'hF);

      a1_zero = (ea1 == 4'd0);
      a2_zero = (ea2 == 4'd0);
      b1_zero = (eb1 == 4'd0);
      b2_zero = (eb2 == 4'd0);

      s11 = sa1 ^ sb1;
      s12 = sa1 ^ sb2;
      s21 = sa2 ^ sb1;
      s22 = sa2 ^ sb2;

      e11_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb1}) - 7'sd7;
      e12_s1 = $signed({3'd0,ea1}) + $signed({3'd0,eb2}) - 7'sd7;
      e21_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb1}) - 7'sd7;
      e22_s1 = $signed({3'd0,ea2}) + $signed({3'd0,eb2}) - 7'sd7;

      Ma1 = a1_zero ? 4'd0 : {1'b1, fa1};
      Ma2 = a2_zero ? 4'd0 : {1'b1, fa2};
      Mb1 = b1_zero ? 4'd0 : {1'b1, fb1};
      Mb2 = b2_zero ? 4'd0 : {1'b1, fb2};

      P11 = Ma1 * Mb1;
      P12 = Ma1 * Mb2;
      P21 = Ma2 * Mb1;
      P22 = Ma2 * Mb2;

      c11_carry = P11[7];
      c12_carry = P12[7];
      c21_carry = P21[7];
      c22_carry = P22[7];

      c11_mant_nocarry = {P11, 4'b0};
      c12_mant_nocarry = {P12, 4'b0};
      c21_mant_nocarry = {P21, 4'b0};
      c22_mant_nocarry = {P22, 4'b0};

      c11_mant_norm = c11_carry ? {P11, 3'b0} : c11_mant_nocarry[10:0];
      c12_mant_norm = c12_carry ? {P12, 3'b0} : c12_mant_nocarry[10:0];
      c21_mant_norm = c21_carry ? {P21, 3'b0} : c21_mant_nocarry[10:0];
      c22_mant_norm = c22_carry ? {P22, 3'b0} : c22_mant_nocarry[10:0];

      c11_es = e11_s1 + (c11_carry ? 7'sd1 : 7'sd0);
      c12_es = e12_s1 + (c12_carry ? 7'sd1 : 7'sd0);
      c21_es = e21_s1 + (c21_carry ? 7'sd1 : 7'sd0);
      c22_es = e22_s1 + (c22_carry ? 7'sd1 : 7'sd0);

      nan_11 = a1_nan | b1_nan;
      nan_12 = a1_nan | b2_nan;
      nan_21 = a2_nan | b1_nan;
      nan_22 = a2_nan | b2_nan;

      zer_11 = ~nan_11 & (a1_zero | b1_zero);
      zer_12 = ~nan_12 & (a1_zero | b2_zero);
      zer_21 = ~nan_21 & (a2_zero | b1_zero);
      zer_22 = ~nan_22 & (a2_zero | b2_zero);

      prod11_bf16 = fp8_prod_to_bf16_ref(s11, c11_es, c11_mant_norm, nan_11, zer_11);
      prod12_bf16 = fp8_prod_to_bf16_ref(s12, c12_es, c12_mant_norm, nan_12, zer_12);
      prod21_bf16 = fp8_prod_to_bf16_ref(s21, c21_es, c21_mant_norm, nan_21, zer_21);
      prod22_bf16 = fp8_prod_to_bf16_ref(s22, c22_es, c22_mant_norm, nan_22, zer_22);

      sum11_bf16 = bf16_add_func(prod11_bf16, c_bus[15:0]);
      sum12_bf16 = bf16_add_func(prod12_bf16, c_bus[31:16]);
      sum21_bf16 = bf16_add_func(prod21_bf16, c_bus[47:32]);
      sum22_bf16 = bf16_add_func(prod22_bf16, c_bus[63:48]);

      calc_expected = {sum22_bf16, sum21_bf16, sum12_bf16, sum11_bf16};
    end
  endfunction

  always @(posedge clk) begin
    valid_pipe <= {valid_pipe[2:0], feed_valid};
    exp_pipe3  <= exp_pipe2;
    exp_pipe2  <= exp_pipe1;
    exp_pipe1  <= exp_pipe0;
    exp_pipe0  <= exp_in;
  end

  always @(posedge clk) begin
    if (valid_pipe[3]) begin
      checks <= checks + 1;
      if (result !== exp_pipe3) begin
        errors <= errors + 1;
        $display("[%0t] ERROR exp=%h got=%h", $time, exp_pipe3, result);
      end else begin
        $display("[%0t] PASS  result=%h", $time, result);
      end
    end
  end

  initial begin
    a_data = 32'd0; b_data = 16'd0; c_data = 64'd0;
    feed_valid = 1'b0; valid_pipe = 4'd0;
    exp_pipe0 = 0; exp_pipe1 = 0; exp_pipe2 = 0; exp_pipe3 = 0;
    exp_in = 0; checks = 0; errors = 0;

    repeat (5) @(posedge clk);

    for (idx = 0; idx < NUM_VECTORS; idx = idx + 1) begin
      a_data    <= vec_a[idx];
      b_data    <= vec_b[idx];
      c_data    <= vec_c[idx];
      exp_in    <= calc_expected(vec_a[idx], vec_b[idx], vec_c[idx]);
      feed_valid <= 1'b1;
      @(posedge clk);
    end

    feed_valid <= 1'b0;
    exp_in     <= 64'd0;
    while (checks < NUM_VECTORS) @(posedge clk);

    $display("====================================================");
    $display("fp8e4m3_bf16_mac TB: %0d checks, %0d errors", checks, errors);
    if (errors == 0) $display("All tests PASSED");
    else             $display("TEST FAILED");
    $display("====================================================");
    $finish;
  end
endmodule

`default_nettype wire
