`timescale 1ns/1ps
`default_nettype none

module tb_fp8e5m2_16_mac;
  localparam integer LAT        = 8;
  localparam integer N          = 14;
  localparam integer DUMMY_CLKS = 4;

  reg         clk;
  reg  [31:0] a18;
  reg  [15:0] b18;
  reg  [63:0] c64;
  wire [63:0] result;

  fp8e5m2_16_mac dut (
      .clk (clk),
      .a18 (a18),
      .b18 (b18),
      .c64 (c64),
      .result(result)
  );

  reg [15:0] a_vec [0:N-1];
  reg [15:0] b_vec [0:N-1];
  reg [63:0] c_vec [0:N-1];
  reg [63:0] yexp  [0:N-1];

  integer errors;
  integer i;
  integer idx_chk;

  localparam [7:0] QNAN8  = 8'h7D;
  localparam [7:0] PINF8  = 8'h7C;
  localparam [7:0] NINF8  = 8'hFC;

  localparam [15:0] H_QNAN = 16'h7E00;
  localparam [15:0] H_PINF = 16'h7C00;
  localparam [15:0] H_NINF = 16'hFC00;
  localparam [15:0] H_PONE = 16'h3C00;
  localparam [15:0] H_MONE = 16'hBC00;
  localparam [15:0] H_PTWO = 16'h4000;
  localparam [15:0] H_MTWO = 16'hC000;
  localparam [15:0] H_HALF = 16'h3800;
  localparam [15:0] FP16_QNAN = 16'h7E00;
  localparam [15:0] FP16_PINF = 16'h7C00;
  localparam [15:0] FP16_NINF = 16'hFC00;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  function [63:0] pack4_16;
    input [15:0] y22;
    input [15:0] y21;
    input [15:0] y12;
    input [15:0] y11;
    begin
      pack4_16 = {y22, y21, y12, y11};
    end
  endfunction

  function [0:0] fp16_is_nan;
    input [15:0] val;
    begin
      fp16_is_nan = (val[14:10] == 5'h1F) && (|val[9:0]);
    end
  endfunction

  function [0:0] fp16_is_inf;
    input [15:0] val;
    begin
      fp16_is_inf = (val[14:10] == 5'h1F) && (val[9:0] == 10'd0);
    end
  endfunction

  function [0:0] fp16_is_zero_or_sub;
    input [15:0] val;
    begin
      fp16_is_zero_or_sub = (val[14:10] == 5'd0);
    end
  endfunction

  function [15:0] fp16_add_ref;
    input [15:0] a;
    input [15:0] b;
    reg sign_a, sign_b;
    reg [4:0] exp_a, exp_b;
    reg [9:0] frac_a, frac_b;
    reg [10:0] mant_a, mant_b;
    reg zero_a, zero_b;
    reg [4:0] exp_big, exp_small, exp_res;
    reg [10:0] mant_big, mant_small;
    reg sign_big, sign_small, sign_res;
    reg [12:0] mant_big_ext, mant_small_ext, mant_small_shifted, mant_sum;
    integer diff;
    integer shift;
    reg [15:0] res;
    begin : add_fn
      if (fp16_is_nan(a)) begin
        res = a[9:0] ? a : FP16_QNAN;
        fp16_add_ref = res;
        disable add_fn;
      end else if (fp16_is_nan(b)) begin
        res = b[9:0] ? b : FP16_QNAN;
        fp16_add_ref = res;
        disable add_fn;
      end else if (fp16_is_inf(a) && fp16_is_inf(b) && (a[15] != b[15])) begin
        fp16_add_ref = FP16_QNAN;
        disable add_fn;
      end else if (fp16_is_inf(a)) begin
        fp16_add_ref = {a[15], 5'h1F, 10'h000};
        disable add_fn;
      end else if (fp16_is_inf(b)) begin
        fp16_add_ref = {b[15], 5'h1F, 10'h000};
        disable add_fn;
      end

      sign_a = a[15];
      sign_b = b[15];
      exp_a  = a[14:10];
      exp_b  = b[14:10];
      frac_a = a[9:0];
      frac_b = b[9:0];

      zero_a = fp16_is_zero_or_sub(a);
      zero_b = fp16_is_zero_or_sub(b);

      if (zero_a && zero_b) begin
        fp16_add_ref = {sign_a & sign_b, 15'd0};
        disable add_fn;
      end else if (zero_a) begin
        fp16_add_ref = b;
        disable add_fn;
      end else if (zero_b) begin
        fp16_add_ref = a;
        disable add_fn;
      end

      mant_a = {1'b1, frac_a};
      mant_b = {1'b1, frac_b};

      if (exp_b > exp_a || (exp_b == exp_a && mant_b > mant_a)) begin
        exp_big   = exp_b;
        exp_small = exp_a;
        mant_big  = mant_b;
        mant_small= mant_a;
        sign_big  = sign_b;
        sign_small= sign_a;
      end else begin
        exp_big   = exp_a;
        exp_small = exp_b;
        mant_big  = mant_a;
        mant_small= mant_b;
        sign_big  = sign_a;
        sign_small= sign_b;
      end

      diff = exp_big - exp_small;
      mant_big_ext   = {2'b00, mant_big};
      mant_small_ext = {2'b00, mant_small};

      if (diff >= 13)
        mant_small_shifted = 13'd0;
      else
        mant_small_shifted = mant_small_ext >> diff;

      exp_res = exp_big;
      sign_res = sign_big;

      if (sign_big == sign_small) begin
        mant_sum = mant_big_ext + mant_small_shifted;
        if (mant_sum[11]) begin
          mant_sum = mant_sum >> 1;
          exp_res  = exp_res + 1;
        end
        if (exp_res >= 31) begin
          fp16_add_ref = {sign_res, 5'h1F, 10'h000};
          disable add_fn;
        end
        fp16_add_ref = {sign_res, exp_res[4:0], mant_sum[9:0]};
        disable add_fn;
      end else begin
        mant_sum = mant_big_ext - mant_small_shifted;
        if (mant_sum == 13'd0) begin
          fp16_add_ref = 16'd0;
          disable add_fn;
        end
        for (shift = 0; (shift < 11) && (mant_sum[10] == 1'b0) && (exp_res > 0); shift = shift + 1) begin
          mant_sum = mant_sum << 1;
          exp_res  = exp_res - 1;
        end
        if (exp_res == 0) begin
          fp16_add_ref = {sign_res, 15'd0};
          disable add_fn;
        end
        fp16_add_ref = {sign_res, exp_res[4:0], mant_sum[9:0]};
        disable add_fn;
      end
    end
  endfunction

  function [15:0] fp8e5m2_mul_lane_to_fp16;
    input [7:0] a;
    input [7:0] b;
    reg sa,sb;
    reg [4:0] ea,eb;
    reg [1:0] fa,fb;
    reg a_nan,a_zero,a_inf;
    reg b_nan,b_zero,b_inf;
    reg signp;
    integer es;
    reg [2:0] Ma,Mb;
    reg [5:0] prod;
    reg carry;
    reg [10:0] mant;
    reg [11:0] mant_pre;
    reg [15:0] inf_val;
    begin
      sa=a[7]; ea=a[6:2]; fa=a[1:0];
      sb=b[7]; eb=b[6:2]; fb=b[1:0];
      a_nan=(ea==5'h1F)&&(fa!=2'd0);
      b_nan=(eb==5'h1F)&&(fb!=2'd0);
      a_inf=(ea==5'h1F)&&(fa==2'd0);
      b_inf=(eb==5'h1F)&&(fb==2'd0);
      a_zero=(ea==5'd0);
      b_zero=(eb==5'd0);
      signp = sa ^ sb;
      inf_val = signp ? H_NINF : H_PINF;

      if (a_nan | b_nan | ((a_inf & b_zero) | (a_zero & b_inf))) begin
        fp8e5m2_mul_lane_to_fp16 = FP16_QNAN;
      end else if (a_inf | b_inf) begin
        fp8e5m2_mul_lane_to_fp16 = inf_val;
      end else if (a_zero | b_zero) begin
        fp8e5m2_mul_lane_to_fp16 = {signp, 15'd0};
      end else begin
        es    = (ea + eb) - 15;
        Ma    = {1'b1, fa};
        Mb    = {1'b1, fb};
        prod  = Ma * Mb;
        carry = prod[5];
        if (carry) begin
          mant = {prod, 5'b00000};
          es   = es + 1;
        end else begin
          mant_pre = {prod, 6'b000000};
          mant     = mant_pre[10:0];
        end

        if (es < 0 || es > 30)
          fp8e5m2_mul_lane_to_fp16 = inf_val;
        else
          fp8e5m2_mul_lane_to_fp16 = {signp, es[4:0], mant[9:0]};
      end
    end
  endfunction
  reg [15:0] prod11, prod12, prod21, prod22;
  reg [15:0] sum11, sum12, sum21, sum22;

  initial begin : init_vectors
    a_vec[0] = {8'h3C, 8'h3C};
    b_vec[0] = {8'h40, 8'h34};
    c_vec[0] = pack4_16(16'h0000, 16'h0000, 16'h0000, 16'h0000);

    a_vec[1] = {8'hBC, 8'h3C};
    b_vec[1] = {8'h3C, 8'hBC};
    c_vec[1] = pack4_16(H_PONE, H_MONE, H_PONE, H_MONE);

    a_vec[2] = {8'h3C, 8'h00};
    b_vec[2] = {8'h00, 8'h3C};
    c_vec[2] = pack4_16(H_PTWO, H_PTWO, H_PONE, H_PONE);

    a_vec[3] = {8'h00, 8'h00};
    b_vec[3] = {8'h3C, 8'h3C};
    c_vec[3] = pack4_16(H_HALF, H_HALF, H_HALF, H_HALF);

    a_vec[4] = {8'h7C, 8'hFC};
    b_vec[4] = {8'h3C, 8'hBC};
    c_vec[4] = pack4_16(H_PONE, H_MONE, H_PONE, H_MONE);

    a_vec[5] = {8'h3C, 8'h3C};
    b_vec[5] = {8'h7C, 8'h3C};
    c_vec[5] = pack4_16(H_PONE, H_PONE, H_PONE, H_PONE);

    a_vec[6] = {8'h7D, 8'h3C};
    b_vec[6] = {8'h3C, 8'h3C};
    c_vec[6] = pack4_16(16'h0000, 16'h0000, 16'h0000, 16'h0000);

    a_vec[7] = {8'h3C, 8'h3C};
    b_vec[7] = {8'h7D, 8'h3C};
    c_vec[7] = pack4_16(H_PONE, H_PONE, H_PONE, H_PONE);

    a_vec[8]  = {8'h42, 8'h3E};
    b_vec[8]  = {8'h3E, 8'h42};
    c_vec[8]  = pack4_16(H_PTWO, H_PTWO, H_PTWO, H_PTWO);

    a_vec[9]  = {8'h3C, 8'h3C};
    b_vec[9]  = {8'h3C, 8'h3C};
    c_vec[9]  = pack4_16(H_QNAN, H_PONE, H_PINF, H_MONE);

    a_vec[10] = {8'h3C, 8'h00};
    b_vec[10] = {8'h7C, 8'h00};
    c_vec[10] = pack4_16(H_PONE, H_PONE, H_PONE, H_PONE);

    a_vec[11] = {8'h3C, 8'h3C};
    b_vec[11] = {8'hFC, 8'hFC};
    c_vec[11] = pack4_16(H_PONE, H_MONE, H_PONE, H_MONE);

    a_vec[12] = {8'h3C, 8'h3C};
    b_vec[12] = {8'h00, 8'h00};
    c_vec[12] = pack4_16(16'h0000, H_PTWO, H_PONE, 16'h0000);

    a_vec[13] = {8'h00, 8'h3C};
    b_vec[13] = {8'h00, 8'h00};
    c_vec[13] = pack4_16(H_PINF, H_NINF, H_QNAN, H_PONE);

    for (i = 0; i < N; i = i + 1) begin
      prod11 = fp8e5m2_mul_lane_to_fp16(a_vec[i][7:0],  b_vec[i][7:0]);
      prod12 = fp8e5m2_mul_lane_to_fp16(a_vec[i][7:0],  b_vec[i][15:8]);
      prod21 = fp8e5m2_mul_lane_to_fp16(a_vec[i][15:8], b_vec[i][7:0]);
      prod22 = fp8e5m2_mul_lane_to_fp16(a_vec[i][15:8], b_vec[i][15:8]);
      sum11  = fp16_add_ref(prod11, c_vec[i][15:0]);
      sum12  = fp16_add_ref(prod12, c_vec[i][31:16]);
      sum21  = fp16_add_ref(prod21, c_vec[i][47:32]);
      sum22  = fp16_add_ref(prod22, c_vec[i][63:48]);
      yexp[i] = pack4_16(sum22, sum21, sum12, sum11);
    end
  end

  initial begin : run_test
    errors = 0;
    a18 = 32'h0000_0000;
    b18 = 16'h0000;
    c64 = 64'h0;

    $display("\n--- FP8(E5M2)->FP16 MAC (LAT=%0d, Vectors=%0d) ---", LAT, N);
    $display("Applying %0d dummy clocks before stimulus...", DUMMY_CLKS);
    repeat (DUMMY_CLKS) @(posedge clk);

    for (i = 0; i < N + LAT; i = i + 1) begin
      if (i < N) begin
        a18 <= {16'h0000, a_vec[i]};
        b18 <= b_vec[i];
        c64 <= c_vec[i];
      end else begin
        a18 <= 32'h0000_0000;
        b18 <= 16'h0000;
        c64 <= 64'h0;
      end

      @(posedge clk);

      if (i >= LAT) begin
        idx_chk = i - LAT;
        if (result !== yexp[idx_chk]) begin
          errors = errors + 1;
          $display("Mismatch idx %0d : got %h expected %h (a=%04h b=%04h c=%016h)", idx_chk,
                   result, yexp[idx_chk], a_vec[idx_chk], b_vec[idx_chk], c_vec[idx_chk]);
        end
      end
    end

    if (errors == 0)
      $display("PASS: All %0d vectors matched expectations.", N);
    else
      $display("FAIL: %0d mismatches detected out of %0d vectors.", errors, N);

    $finish;
  end

endmodule

`default_nettype wire
