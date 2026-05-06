`timescale 1ns/1ps
`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_int4_fp8e4m3_16_mac
//   - INT4 × FP8(E4M3) multiply, accumulate into FP16 lanes
//   - Mirrors datapath of int4_fp8e4m3_16_mac (II=1, latency=4)
////////////////////////////////////////////////////////////////////////////////
module tb_int4_fp8e4m3_16_mac;
  localparam integer LAT        = 4;
  localparam integer N          = 24;
  localparam integer DUMMY_CLKS = 6;

  reg         clk;
  reg  [7:0]  a_int4;
  reg  [15:0] b_fp8;
  reg  [63:0] c_fp16;
  wire [63:0] result;

  int4_fp8e4m3_16_mac dut (
      .clk   (clk),
      .a_int4(a_int4),
      .b_fp8 (b_fp8),
      .c_fp16(c_fp16),
      .result(result)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  localparam integer BIAS = 7;
  localparam [7:0] QNAN8      = 8'h79;
  localparam [7:0] FP8_P0_5   = 8'h30;
  localparam [7:0] FP8_P1_0   = 8'h38;
  localparam [7:0] FP8_N1_0   = 8'hB8;
  localparam [7:0] FP8_P1_5   = 8'h3C;
  localparam [7:0] FP8_P2_0   = 8'h40;
  localparam [7:0] FP8_N2_0   = 8'hC0;
  localparam [7:0] FP8_P3_0   = 8'h44;
  localparam [7:0] MAXFIN_POS = 8'h77;
  localparam [7:0] MAXFIN_NEG = 8'hF7;

  localparam [15:0] FP16_QNAN       = 16'h7E00;
  localparam [15:0] FP16_MAXFIN_POS = 16'h5B80;
  localparam [15:0] FP16_MAXFIN_NEG = 16'hDB80;

  function [3:0] int_to_int4; input integer val;
    integer clipped;
    begin
      clipped = (val > 7) ? 7 : ((val < -8) ? -8 : val);
      int_to_int4 = clipped[3:0];
    end
  endfunction

  function [15:0] pack2_8; input [7:0] hi; input [7:0] lo; begin pack2_8 = {hi, lo}; end endfunction
  function [31:0] pack4_8; input [7:0] y22,y21,y12,y11; begin pack4_8 = {y22,y21,y12,y11}; end endfunction
  function [63:0] pack4_16; input [15:0] y22,y21,y12,y11; begin pack4_16 = {y22,y21,y12,y11}; end endfunction

  function [7:0] int4_to_fp8e4m3_model; input [3:0] val4;
    reg  signed [4:0] sval;
    reg        sign;
    reg  [4:0] absval;
    reg  [2:0] msb_idx;
    reg  [3:0] mant4;
    reg  [4:0] exp_bias;
    begin
      sval = $signed({val4[3], val4});
      if (sval == 0) begin
        int4_to_fp8e4m3_model = 8'h00;
      end else begin
        sign   = sval[4];
        absval = sign ? -sval : sval;
        casex (absval[3:0])
          4'b1???: msb_idx = 3'd3;
          4'b01??: msb_idx = 3'd2;
          4'b001?: msb_idx = 3'd1;
          default: msb_idx = 3'd0;
        endcase
        mant4    = (absval[3:0] << (3 - msb_idx));
        exp_bias = msb_idx + BIAS;
        int4_to_fp8e4m3_model = {sign, exp_bias[3:0], mant4[2:0]};
      end
    end
  endfunction

  function [7:0] fp8e4m3_mul_lane_model; input [7:0] a; input [7:0] b;
    reg sa,sb; reg [3:0] ea,eb; reg [2:0] fa,fb;
    reg a_nan,a_zero,b_nan,b_zero; reg signp; integer esum; reg [3:0] Ma,Mb;
    reg [7:0] prod; reg carry; reg [2:0] frac3;
    begin
      sa=a[7]; ea=a[6:3]; fa=a[2:0];
      sb=b[7]; eb=b[6:3]; fb=b[2:0];
      a_nan=(ea==4'hF); a_zero=(ea==4'd0);
      b_nan=(eb==4'hF); b_zero=(eb==4'd0);
      if (a_nan | b_nan) begin
        fp8e4m3_mul_lane_model = QNAN8;
      end else if (a_zero | b_zero) begin
        fp8e4m3_mul_lane_model = {(sa^sb), 7'd0};
      end else begin
        signp = sa ^ sb;
        esum  = (ea + eb) - BIAS;
        Ma    = {1'b1, fa};
        Mb    = {1'b1, fb};
        prod  = Ma * Mb;
        carry = prod[7];
        frac3 = carry ? prod[6:4] : prod[5:3];
        esum  = esum + (carry ? 1 : 0);
        if (esum < 0 || esum > 14)
          fp8e4m3_mul_lane_model = signp ? MAXFIN_NEG : MAXFIN_POS;
        else
          fp8e4m3_mul_lane_model = {signp, esum[3:0], frac3};
      end
    end
  endfunction

  function [15:0] fp8e4m3_to_fp16; input [7:0] val;
    reg sign; reg [3:0] exp8; reg [2:0] frac3; reg [4:0] exp16;
    begin
      sign  = val[7];
      exp8  = val[6:3];
      frac3 = val[2:0];
      if (exp8 == 4'hF) begin
        fp8e4m3_to_fp16 = FP16_QNAN;
      end else if (exp8 == 4'd0) begin
        fp8e4m3_to_fp16 = {sign, 15'd0};
      end else begin
        exp16 = exp8 + 5'd8;
        fp8e4m3_to_fp16 = {sign, exp16[4:0], {frac3, 7'b0}};
      end
    end
  endfunction

  function [0:0] fp16_is_nan; input [15:0] v; begin fp16_is_nan = (v[14:10]==5'h1F) && (|v[9:0]); end endfunction
  function [0:0] fp16_is_inf; input [15:0] v; begin fp16_is_inf = (v[14:10]==5'h1F) && (v[9:0]==10'd0); end endfunction
  function [0:0] fp16_is_zero_or_sub; input [15:0] v; begin fp16_is_zero_or_sub = (v[14:10]==5'd0); end endfunction

  function [15:0] fp16_add_ref; input [15:0] a; input [15:0] b;
    reg sign_a, sign_b;
    reg [4:0] exp_a, exp_b;
    reg [9:0] frac_a, frac_b;
    reg [10:0] mant_a, mant_b;
    reg zero_a, zero_b;
    reg [4:0] exp_big, exp_small, exp_res;
    reg [10:0] mant_big, mant_small;
    reg sign_big, sign_small, sign_res;
    reg [12:0] mant_big_ext, mant_small_ext, mant_small_shifted, mant_sum;
    integer diff; integer shift; reg [15:0] res;
    begin : add_fn
      if (fp16_is_nan(a)) begin
        res = a[9:0] ? a : FP16_QNAN; fp16_add_ref = res; disable add_fn;
      end else if (fp16_is_nan(b)) begin
        res = b[9:0] ? b : FP16_QNAN; fp16_add_ref = res; disable add_fn;
      end else if (fp16_is_inf(a) && fp16_is_inf(b) && (a[15]!=b[15])) begin
        fp16_add_ref = FP16_QNAN; disable add_fn;
      end else if (fp16_is_inf(a)) begin
        fp16_add_ref = {a[15], 5'h1F, 10'h000}; disable add_fn;
      end else if (fp16_is_inf(b)) begin
        fp16_add_ref = {b[15], 5'h1F, 10'h000}; disable add_fn;
      end

      sign_a = a[15]; sign_b = b[15];
      exp_a  = a[14:10]; exp_b = b[14:10];
      frac_a = a[9:0];   frac_b = b[9:0];

      zero_a = fp16_is_zero_or_sub(a);
      zero_b = fp16_is_zero_or_sub(b);

      if (zero_a && zero_b) begin fp16_add_ref = {sign_a & sign_b, 15'd0}; disable add_fn; end
      if (zero_a) begin fp16_add_ref = b; disable add_fn; end
      if (zero_b) begin fp16_add_ref = a; disable add_fn; end

      mant_a = {1'b1, frac_a};
      mant_b = {1'b1, frac_b};

      if (exp_b > exp_a || (exp_b==exp_a && mant_b > mant_a)) begin
        exp_big = exp_b; exp_small = exp_a; mant_big = mant_b; mant_small = mant_a; sign_big = sign_b; sign_small = sign_a;
      end else begin
        exp_big = exp_a; exp_small = exp_b; mant_big = mant_a; mant_small = mant_b; sign_big = sign_a; sign_small = sign_b;
      end

      diff = exp_big - exp_small;
      mant_big_ext   = {2'b00, mant_big};
      mant_small_ext = {2'b00, mant_small};
      mant_small_shifted = (diff >= 13) ? 13'd0 : (mant_small_ext >> diff);

      exp_res  = exp_big;
      sign_res = sign_big;

      if (sign_big == sign_small) begin
        mant_sum = mant_big_ext + mant_small_shifted;
        if (mant_sum[11]) begin mant_sum = mant_sum >> 1; exp_res = exp_res + 1; end
        if (exp_res >= 31) begin fp16_add_ref = {sign_res, 5'h1F, 10'h000}; disable add_fn; end
        fp16_add_ref = {sign_res, exp_res[4:0], mant_sum[9:0]}; disable add_fn;
      end else begin
        mant_sum = mant_big_ext - mant_small_shifted;
        if (mant_sum == 13'd0) begin fp16_add_ref = 16'd0; disable add_fn; end
        for (shift = 0; (shift < 11) && (mant_sum[10]==1'b0) && (exp_res>0); shift = shift+1) begin
          mant_sum = mant_sum << 1; exp_res = exp_res - 1;
        end
        if (exp_res == 0) begin fp16_add_ref = {sign_res, 15'd0}; disable add_fn; end
        fp16_add_ref = {sign_res, exp_res[4:0], mant_sum[9:0]}; disable add_fn;
      end
    end
  endfunction

  // --------------------------------------------------------------------------
  // Stimulus / expectations
  // --------------------------------------------------------------------------
  reg [7:0]  avec  [0:N-1];
  reg [15:0] bvec  [0:N-1];
  reg [31:0] cvec8 [0:N-1];
  reg [63:0] cvec16[0:N-1];
  reg [63:0] yexp  [0:N-1];

  reg signed [4:0] int_choices [0:5];
  reg [7:0]        b_choices   [0:3];
  reg [7:0]        c_choices   [0:3];

  integer idx;
  integer sel_a0, sel_a1, sel_b0, sel_b1, sel_c;
  reg [7:0] a1_fp8_ref, a2_fp8_ref;
  reg [7:0] p11, p12, p21, p22;
  reg [15:0] prod11_fp16, prod12_fp16, prod21_fp16, prod22_fp16;
  reg [15:0] sum11, sum12, sum21, sum22;

  initial begin
    int_choices[0] = -8;
    int_choices[1] = -5;
    int_choices[2] = -3;
    int_choices[3] =  0;
    int_choices[4] =  2;
    int_choices[5] =  7;

    b_choices[0] = FP8_P1_0;
    b_choices[1] = FP8_N1_0;
    b_choices[2] = FP8_P0_5;
    b_choices[3] = FP8_P2_0;

    c_choices[0] = 8'h00;
    c_choices[1] = FP8_P1_0;
    c_choices[2] = FP8_N1_0;
    c_choices[3] = FP8_P0_5;

    for (idx = 0; idx < N; idx = idx + 1) begin
      sel_a0 = idx % 6;
      sel_a1 = (idx + 2) % 6;
      sel_b0 = idx % 4;
      sel_b1 = (idx + (idx>>1) + 1) % 4;
      sel_c  = idx % 4;

      avec[idx]  = {int_to_int4(int_choices[sel_a1]), int_to_int4(int_choices[sel_a0])};
      bvec[idx]  = pack2_8(b_choices[sel_b1], b_choices[sel_b0]);
      cvec8[idx] = pack4_8(
          c_choices[(sel_c + 3) % 4],
          c_choices[(sel_c + 2) % 4],
          c_choices[(sel_c + 1) % 4],
          c_choices[sel_c]
      );
    end

    avec[0]  = {int_to_int4(7),  int_to_int4(-8)};
    bvec[0]  = pack2_8(FP8_P0_5, FP8_N2_0);
    cvec8[0] = pack4_8(8'h00, FP8_P1_0, FP8_N1_0, 8'h00);

    avec[1]  = {int_to_int4(-1), int_to_int4(3)};
    bvec[1]  = pack2_8(FP8_P1_5, FP8_P1_0);
    cvec8[1] = pack4_8(FP8_P3_0, FP8_P0_5, FP8_P0_5, FP8_P3_0);

    avec[2]  = {int_to_int4(0),  int_to_int4(0)};
    bvec[2]  = pack2_8(FP8_P1_0, FP8_P2_0);
    cvec8[2] = pack4_8(FP8_N1_0, FP8_P1_0, FP8_N1_0, FP8_P1_0);

    avec[3]  = {int_to_int4(-8), int_to_int4(-8)};
    bvec[3]  = pack2_8(FP8_P2_0, FP8_P2_0);
    cvec8[3] = pack4_8(MAXFIN_POS, MAXFIN_POS, MAXFIN_POS, MAXFIN_POS);

    // Derive FP16 Cs
    for (idx = 0; idx < N; idx = idx + 1) begin
      cvec16[idx] = pack4_16(
          fp8e4m3_to_fp16(cvec8[idx][31:24]),
          fp8e4m3_to_fp16(cvec8[idx][23:16]),
          fp8e4m3_to_fp16(cvec8[idx][15:8]),
          fp8e4m3_to_fp16(cvec8[idx][7:0])
      );
    end

    // Golden model
    for (idx = 0; idx < N; idx = idx + 1) begin
      a1_fp8_ref = int4_to_fp8e4m3_model(avec[idx][3:0]);
      a2_fp8_ref = int4_to_fp8e4m3_model(avec[idx][7:4]);

      p11 = fp8e4m3_mul_lane_model(a1_fp8_ref, bvec[idx][7:0]);
      p12 = fp8e4m3_mul_lane_model(a1_fp8_ref, bvec[idx][15:8]);
      p21 = fp8e4m3_mul_lane_model(a2_fp8_ref, bvec[idx][7:0]);
      p22 = fp8e4m3_mul_lane_model(a2_fp8_ref, bvec[idx][15:8]);

      prod11_fp16 = fp8e4m3_to_fp16(p11);
      prod12_fp16 = fp8e4m3_to_fp16(p12);
      prod21_fp16 = fp8e4m3_to_fp16(p21);
      prod22_fp16 = fp8e4m3_to_fp16(p22);

      sum11 = fp16_add_ref(prod11_fp16, cvec16[idx][15:0]);
      sum12 = fp16_add_ref(prod12_fp16, cvec16[idx][31:16]);
      sum21 = fp16_add_ref(prod21_fp16, cvec16[idx][47:32]);
      sum22 = fp16_add_ref(prod22_fp16, cvec16[idx][63:48]);

      yexp[idx] = pack4_16(sum22, sum21, sum12, sum11);
    end
  end

  integer errors;
  integer i;
  integer idx_chk;
  initial begin
    errors = 0;
    a_int4 = 8'h00;
    b_fp8  = 16'h0000;
    c_fp16 = 64'h0;

    $display("\n--- INT4 × FP8(E4M3) → FP16 MAC (LAT=%0d, Vectors=%0d) ---", LAT, N);
    $display("Applying %0d dummy clocks before stimulus...", DUMMY_CLKS);
    repeat (DUMMY_CLKS) @(posedge clk);

    for (i = 0; i < N + LAT; i = i + 1) begin
      if (i < N) begin
        a_int4 <= avec[i];
        b_fp8  <= bvec[i];
        c_fp16 <= cvec16[i];
      end else begin
        a_int4 <= 8'h00;
        b_fp8  <= 16'h0000;
        c_fp16 <= 64'h0;
      end

      @(posedge clk);

      if (i >= LAT) begin
        idx_chk = i - LAT;
        if (result !== yexp[idx_chk]) begin
          errors = errors + 1;
          $display("Mismatch idx %0d : got %h expected %h (a=%02h b=%04h c=%016h)",
                   idx_chk, result, yexp[idx_chk], avec[idx_chk], bvec[idx_chk], cvec16[idx_chk]);
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
