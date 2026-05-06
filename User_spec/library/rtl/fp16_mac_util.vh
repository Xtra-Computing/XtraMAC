`ifndef FP16_MAC_UTIL_VH
`define FP16_MAC_UTIL_VH

localparam [15:0] FP16_QNAN = 16'h7E00;

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

function [15:0] fp8e4m3_to_fp16;
  input [7:0] val;
  reg sign;
  reg [3:0] exp8;
  reg [2:0] frac3;
  reg [4:0] exp16;
  begin
    sign  = val[7];
    exp8  = val[6:3];
    frac3 = val[2:0];
    if (exp8 == 4'hF) begin
      fp8e4m3_to_fp16 = 16'h7E00;
    end else if (exp8 == 4'd0) begin
      fp8e4m3_to_fp16 = {sign, 15'd0};
    end else begin
      exp16 = exp8 + 5'd8;
      fp8e4m3_to_fp16 = {sign, exp16[4:0], {frac3, 7'b0}};
    end
  end
endfunction

function [15:0] fp8e5m2_to_fp16;
  input [7:0] val;
  reg sign;
  reg [4:0] exp8;
  reg [1:0] frac2;
  begin
    sign  = val[7];
    exp8  = val[6:2];
    frac2 = val[1:0];
    if (exp8 == 5'h1F) begin
      if (frac2 == 2'b00)
        fp8e5m2_to_fp16 = {sign, 5'h1F, 10'h000};
      else
        fp8e5m2_to_fp16 = 16'h7E00;
    end else if (exp8 == 5'd0) begin
      if (frac2 == 2'b00)
        fp8e5m2_to_fp16 = {sign, 15'd0};
      else
        fp8e5m2_to_fp16 = {sign, 15'd0};
    end else begin
      fp8e5m2_to_fp16 = {sign, exp8[4:0], {frac2, 8'b0}};
    end
  end
endfunction

function [15:0] fp16_mul;
  input [15:0] a;
  input [15:0] b;
  reg sign_a, sign_b, sign_res;
  reg [4:0] exp_a, exp_b;
  reg [9:0] frac_a, frac_b;
  reg [10:0] mant_a, mant_b;
  reg [21:0] mant_prod;
  integer exp_sum;
  reg [4:0] exp_res;
  reg [10:0] mant_norm;
  begin
    sign_a = a[15];
    sign_b = b[15];
    exp_a  = a[14:10];
    exp_b  = b[14:10];
    frac_a = a[9:0];
    frac_b = b[9:0];
    sign_res = sign_a ^ sign_b;

    if (fp16_is_nan(a))
      fp16_mul = a[9:0] ? a : FP16_QNAN;
    else if (fp16_is_nan(b))
      fp16_mul = b[9:0] ? b : FP16_QNAN;
    else if ((fp16_is_inf(a) && fp16_is_zero_or_sub(b)) ||
             (fp16_is_inf(b) && fp16_is_zero_or_sub(a)))
      fp16_mul = FP16_QNAN;
    else if (fp16_is_inf(a) || fp16_is_inf(b))
      fp16_mul = {sign_res, 5'h1F, 10'h000};
    else if (fp16_is_zero_or_sub(a) || fp16_is_zero_or_sub(b))
      fp16_mul = {sign_res, 15'd0};
    else begin
      mant_a = {1'b1, frac_a};
      mant_b = {1'b1, frac_b};
      mant_prod = mant_a * mant_b;
      exp_sum = exp_a + exp_b - 5'd15;

      if (mant_prod[21]) begin
        mant_norm = mant_prod[21:11];
        exp_sum   = exp_sum + 1;
      end else begin
        mant_norm = mant_prod[20:10];
      end

      if (exp_sum >= 31)
        fp16_mul = {sign_res, 5'h1F, 10'h000};
      else if (exp_sum <= 0)
        fp16_mul = {sign_res, 15'd0};
      else
        fp16_mul = {sign_res, exp_sum[4:0], mant_norm[9:0]};
    end
  end
endfunction

function [15:0] fp16_add;
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
      fp16_add = res;
      disable add_fn;
    end else if (fp16_is_nan(b)) begin
      res = b[9:0] ? b : FP16_QNAN;
      fp16_add = res;
      disable add_fn;
    end else if (fp16_is_inf(a) && fp16_is_inf(b) && (a[15] != b[15])) begin
      fp16_add = FP16_QNAN;
      disable add_fn;
    end else if (fp16_is_inf(a)) begin
      fp16_add = {a[15], 5'h1F, 10'h000};
      disable add_fn;
    end else if (fp16_is_inf(b)) begin
      fp16_add = {b[15], 5'h1F, 10'h000};
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
      fp16_add = {sign_a & sign_b, 15'd0};
      disable add_fn;
    end else if (zero_a) begin
      fp16_add = b;
      disable add_fn;
    end else if (zero_b) begin
      fp16_add = a;
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
        fp16_add = {sign_res, 5'h1F, 10'h000};
        disable add_fn;
      end
      fp16_add = {sign_res, exp_res[4:0], mant_sum[9:0]};
      disable add_fn;
    end else begin
      mant_sum = mant_big_ext - mant_small_shifted;
      if (mant_sum == 13'd0) begin
        fp16_add = 16'd0;
        disable add_fn;
      end
      for (shift = 0; (shift < 11) && (mant_sum[10] == 1'b0) && (exp_res > 0); shift = shift + 1) begin
        mant_sum = mant_sum << 1;
        exp_res  = exp_res - 1;
      end
      if (exp_res == 0) begin
        fp16_add = {sign_res, 15'd0};
        disable add_fn;
      end
      fp16_add = {sign_res, exp_res[4:0], mant_sum[9:0]};
      disable add_fn;
    end
  end
endfunction

`endif // FP16_MAC_UTIL_VH
