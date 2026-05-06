`timescale 1ns/1ps
`default_nettype none

`include "fp4_fp8_mac_common.vh"

module tb_fp4_fp8e5m2_16_mac_base #(
    parameter integer FP4_MODE = `FP4_MODE_E3M0
);
  localparam integer LAT        = 4;
  localparam integer N          = 24;
  localparam integer DUMMY_CLKS = 6;

  reg         clk;
  reg  [7:0]  a_fp4;
  reg  [15:0] b_fp8;
  reg  [63:0] c_fp16;
  wire [63:0] result;

  generate
    if (FP4_MODE == `FP4_MODE_E3M0) begin : GEN_E3M0
      fp4e3m0_fp8e5m2_16_mac dut (
          .clk   (clk),
          .a_fp4 (a_fp4),
          .b_fp8 (b_fp8),
          .c64   (c_fp16),
          .result(result)
      );
    end else if (FP4_MODE == `FP4_MODE_E2M1) begin : GEN_E2M1
      fp4e2m1_fp8e5m2_16_mac dut (
          .clk   (clk),
          .a_fp4 (a_fp4),
          .b_fp8 (b_fp8),
          .c64   (c_fp16),
          .result(result)
      );
    end else begin : GEN_E1M2
      fp4e1m2_fp8e5m2_16_mac dut (
          .clk   (clk),
          .a_fp4 (a_fp4),
          .b_fp8 (b_fp8),
          .c64   (c_fp16),
          .result(result)
      );
    end
  endgenerate

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---------------------------------------------------------------------------
  // Conversion helpers
  // ---------------------------------------------------------------------------
  localparam [7:0] QNAN8 = 8'h7D;
  localparam [7:0] PINF8 = 8'h7C;
  localparam [7:0] NINF8 = 8'hFC;

  localparam [15:0] FP16_QNAN = 16'h7E00;
  localparam [15:0] FP16_PINF = 16'h7C00;
  localparam [15:0] FP16_NINF = 16'hFC00;

  function automatic [7:0] fp4_to_fp8e5m2_model;
    input [3:0] lane;
    reg sign;
    reg [2:0] exp3;
    reg [1:0] exp2;
    reg       frac1;
    reg [1:0] frac2;
    reg [4:0] exp_final;
    begin
      sign = lane[3];
      case (FP4_MODE)
        `FP4_MODE_E3M0: begin
          exp3 = lane[2:0];
          if (exp3 == 3'd7)
            fp4_to_fp8e5m2_model = {sign, 5'h1F, 2'b00};
          else if (exp3 == 3'd0)
            fp4_to_fp8e5m2_model = {sign, 5'd0, 2'b00};
          else begin
            exp_final = exp3 + 5'd12;
            fp4_to_fp8e5m2_model = {sign, exp_final[4:0], 2'b00};
          end
        end
        `FP4_MODE_E2M1: begin
          exp2  = lane[2:1];
          frac1 = lane[0];
          if (exp2 == 2'b11)
            fp4_to_fp8e5m2_model = (frac1 == 1'b0) ? {sign, 5'h1F, 2'b00} : QNAN8;
          else if (exp2 == 2'b00)
            fp4_to_fp8e5m2_model = (frac1 == 1'b0) ? {sign, 5'd0, 2'b00}
                                                   : {sign, 5'd14, 2'b00};
          else begin
            exp_final = 5'd14 + exp2;
            fp4_to_fp8e5m2_model = {sign, exp_final[4:0], {frac1, 1'b0}};
          end
        end
        default: begin
          frac2 = lane[1:0];
          if ((lane[2] == 1'b0) && (frac2 == 2'b00))
            fp4_to_fp8e5m2_model = {sign, 5'd0, 2'b00};
          else
            fp4_to_fp8e5m2_model = {sign, 5'd15, frac2};
        end
      endcase
    end
  endfunction

  function automatic [63:0] pack4_16;
    input [15:0] y22;
    input [15:0] y21;
    input [15:0] y12;
    input [15:0] y11;
    begin
      pack4_16 = {y22, y21, y12, y11};
    end
  endfunction

  function automatic [7:0] fp8e5m2_mul_lane_model;
    input [7:0] a;
    input [7:0] b;
    reg sa,sb;
    reg [4:0] ea,eb;
    reg [1:0] fa,fb;
    reg a_nan,a_inf,a_zero,b_nan,b_inf,b_zero;
    reg signp;
    integer esum;
    reg [2:0] Ma,Mb;
    reg [5:0] prod;
    reg carry;
    reg [1:0] frac2;
    begin
      sa=a[7]; ea=a[6:2]; fa=a[1:0];
      sb=b[7]; eb=b[6:2]; fb=b[1:0];
      a_nan=(ea==5'h1F)&&(fa!=2'd0); a_inf=(ea==5'h1F)&&(fa==2'd0); a_zero=(ea==5'd0);
      b_nan=(eb==5'h1F)&&(fb!=2'd0); b_inf=(eb==5'h1F)&&(fb==2'd0); b_zero=(eb==5'd0);
      if (a_nan | b_nan | ((a_inf & b_zero) | (a_zero & b_inf))) begin
        fp8e5m2_mul_lane_model = QNAN8;
      end else if (a_inf | b_inf) begin
        fp8e5m2_mul_lane_model = {sa^sb, 5'h1F, 2'b00};
      end else if (a_zero | b_zero) begin
        fp8e5m2_mul_lane_model = {sa^sb, 7'd0};
      end else begin
        signp = sa ^ sb;
        esum  = (ea + eb) - 15;
        Ma    = {1'b1, fa};
        Mb    = {1'b1, fb};
        prod  = Ma * Mb;
        carry = prod[5];
        frac2 = carry ? prod[4:3] : prod[3:2];
        esum  = esum + (carry ? 1 : 0);
        if (esum < 0 || esum > 30)
          fp8e5m2_mul_lane_model = {signp, 5'h1F, 2'b00};
        else
          fp8e5m2_mul_lane_model = {signp, esum[4:0], frac2};
      end
    end
  endfunction

  function automatic [15:0] fp8e5m2_to_fp16;
    input [7:0] val;
    reg sign;
    reg [4:0] exp8;
    reg [1:0] frac2;
    begin
      sign = val[7];
      exp8 = val[6:2];
      frac2= val[1:0];
      if (exp8 == 5'h1F) begin
        fp8e5m2_to_fp16 = (frac2 == 2'b00) ? {sign, 5'h1F, 10'h000} : FP16_QNAN;
      end else if (exp8 == 5'd0) begin
        fp8e5m2_to_fp16 = {sign, 15'd0};
      end else begin
        fp8e5m2_to_fp16 = {sign, exp8, {frac2, 8'b0}};
      end
    end
  endfunction

  function automatic [0:0] fp16_is_nan;
    input [15:0] v;
    begin
      fp16_is_nan = (v[14:10]==5'h1F) && (|v[9:0]);
    end
  endfunction

  function automatic [0:0] fp16_is_inf;
    input [15:0] v;
    begin
      fp16_is_inf = (v[14:10]==5'h1F) && (v[9:0]==10'd0);
    end
  endfunction

  function automatic [0:0] fp16_is_zero_or_sub;
    input [15:0] v;
    begin
      fp16_is_zero_or_sub = (v[14:10]==5'd0);
    end
  endfunction

  function automatic [15:0] fp16_add_ref;
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

      mant_small_shifted = (diff >= 13) ? 13'd0 : (mant_small_ext >> diff);

      exp_res  = exp_big;
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

  // ---------------------------------------------------------------------------
  // Stimulus / scoreboard
  // ---------------------------------------------------------------------------
  reg [7:0]  avec [0:N-1];
  reg [15:0] bvec [0:N-1];
  reg [63:0] cvec [0:N-1];
  reg [63:0] yexp [0:N-1];

  reg [3:0] a_choices [0:5];
  reg [7:0] b_choices [0:5];
  reg [15:0] c_choices [0:3];

  integer idx;
  integer sel_a0, sel_a1, sel_b0, sel_b1, sel_c;

  reg [7:0] a1_fp8_ref, a2_fp8_ref;
  reg [7:0] p11, p12, p21, p22;
  reg [15:0] prod11_fp16, prod12_fp16, prod21_fp16, prod22_fp16;
  reg [15:0] sum11, sum12, sum21, sum22;

  integer errors;
  integer i;
  integer idx_chk;

  initial begin
    a_fp4   = 8'h00;
    b_fp8   = 16'h0000;
    c_fp16  = 64'h0;
    errors  = 0;

    // FP4 lane choices per mode
    case (FP4_MODE)
      `FP4_MODE_E3M0: begin
        a_choices[0] = 4'h0; // +0
        a_choices[1] = 4'h1; // +exp1
        a_choices[2] = 4'h2; // +exp2
        a_choices[3] = 4'h4; // +exp4
        a_choices[4] = 4'h7; // +Inf
        a_choices[5] = 4'hF; // -Inf
      end
      `FP4_MODE_E2M1: begin
        a_choices[0] = 4'h0; // +0
        a_choices[1] = 4'h1; // +subnormal?
        a_choices[2] = 4'h2; // +normal 01.0
        a_choices[3] = 4'h6; // +normal 10.?
        a_choices[4] = 4'h7; // NaN
        a_choices[5] = 4'hB; // -normal
      end
      default: begin
        a_choices[0] = 4'h0; // +0
        a_choices[1] = 4'h1; // +frac 01
        a_choices[2] = 4'h2; // +frac 10
        a_choices[3] = 4'h3; // +frac 11
        a_choices[4] = 4'h4; // NaN
        a_choices[5] = 4'hC; // -value
      end
    endcase

    // FP8 lane choices (E5M2)
    b_choices[0] = 8'h3C; // +1.0
    b_choices[1] = 8'hBC; // -1.0
    b_choices[2] = 8'h38; // +0.5
    b_choices[3] = 8'hC0; // -2.0
    b_choices[4] = PINF8;
    b_choices[5] = NINF8;

    // FP16 C lane choices
    c_choices[0] = 16'h0000; // 0
    c_choices[1] = 16'h3C00; // +1.0
    c_choices[2] = 16'hBC00; // -1.0
    c_choices[3] = 16'h3800; // +0.5

    for (idx = 0; idx < N; idx = idx + 1) begin
      sel_a0 = idx % 6;
      sel_a1 = (idx + 2) % 6;
      sel_b0 = idx % 6;
      sel_b1 = (idx + (idx>>1) + 1) % 6;
      sel_c  = idx % 4;

      avec[idx] = {a_choices[sel_a1], a_choices[sel_a0]};
      bvec[idx] = {b_choices[sel_b1], b_choices[sel_b0]};
      cvec[idx] = pack4_16(
          c_choices[(sel_c + 3) % 4],
          c_choices[(sel_c + 2) % 4],
          c_choices[(sel_c + 1) % 4],
          c_choices[sel_c]
      );
    end

    // Golden model
    for (idx = 0; idx < N; idx = idx + 1) begin
      a1_fp8_ref = fp4_to_fp8e5m2_model(avec[idx][3:0]);
      a2_fp8_ref = fp4_to_fp8e5m2_model(avec[idx][7:4]);

      p11 = fp8e5m2_mul_lane_model(a1_fp8_ref, bvec[idx][7:0]);
      p12 = fp8e5m2_mul_lane_model(a1_fp8_ref, bvec[idx][15:8]);
      p21 = fp8e5m2_mul_lane_model(a2_fp8_ref, bvec[idx][7:0]);
      p22 = fp8e5m2_mul_lane_model(a2_fp8_ref, bvec[idx][15:8]);

      prod11_fp16 = fp8e5m2_to_fp16(p11);
      prod12_fp16 = fp8e5m2_to_fp16(p12);
      prod21_fp16 = fp8e5m2_to_fp16(p21);
      prod22_fp16 = fp8e5m2_to_fp16(p22);

      sum11 = fp16_add_ref(prod11_fp16, cvec[idx][15:0]);
      sum12 = fp16_add_ref(prod12_fp16, cvec[idx][31:16]);
      sum21 = fp16_add_ref(prod21_fp16, cvec[idx][47:32]);
      sum22 = fp16_add_ref(prod22_fp16, cvec[idx][63:48]);

      yexp[idx] = pack4_16(sum22, sum21, sum12, sum11);

    end

    $display("\n--- FP4 × FP8(E5M2) → FP16 MAC (MODE=%0d, LAT=%0d, Vectors=%0d) ---",
             FP4_MODE, LAT, N);
    $display("Applying %0d dummy clocks before stimulus...", DUMMY_CLKS);
    repeat (DUMMY_CLKS) @(posedge clk);

    for (i = 0; i < N + LAT; i = i + 1) begin
      if (i < N) begin
        a_fp4  <= avec[i];
        b_fp8  <= bvec[i];
        c_fp16 <= cvec[i];
      end else begin
        a_fp4  <= 8'h00;
        b_fp8  <= 16'h0000;
        c_fp16 <= 64'h0;
      end

      @(posedge clk);

      if (i >= LAT) begin
        idx_chk = i - LAT;
        if (result !== yexp[idx_chk]) begin
          errors = errors + 1;
          $display("Mismatch idx %0d : got %h expected %h (a=%02h b=%04h c=%016h)",
                   idx_chk, result, yexp[idx_chk],
                   avec[idx_chk], bvec[idx_chk], cvec[idx_chk]);
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
