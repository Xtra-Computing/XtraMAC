`timescale 1ns/1ps
`default_nettype none

`include "fp4_fp8_mac_common.vh"

module tb_fp4_fp8e4m3_16_mac_base #(
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
      fp4e3m0_fp8e4m3_16_mac dut (
          .clk   (clk),
          .a_fp4 (a_fp4),
          .b_fp8 (b_fp8),
          .c64   (c_fp16),
          .result(result)
      );
    end else if (FP4_MODE == `FP4_MODE_E2M1) begin : GEN_E2M1
      fp4e2m1_fp8e4m3_16_mac dut (
          .clk   (clk),
          .a_fp4 (a_fp4),
          .b_fp8 (b_fp8),
          .c64   (c_fp16),
          .result(result)
      );
    end else begin : GEN_E1M2
      fp4e1m2_fp8e4m3_16_mac dut (
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
  // Conversion helpers (mirrors behavioural model)
  // ---------------------------------------------------------------------------
  localparam [7:0]  QNAN8           = 8'h79;
  localparam [15:0] FP16_QNAN       = 16'h7E00;
  localparam [15:0] FP16_MAXFIN_POS = 16'h5B80;
  localparam [15:0] FP16_MAXFIN_NEG = 16'hDB80;
  localparam [15:0] FP16_PINF       = 16'h7C00;
  localparam [15:0] FP16_NINF       = 16'hFC00;

  function automatic [7:0] fp4_to_fp8e4m3_model;
    input [3:0] lane;
    reg sign;
    reg [2:0] exp3;
    reg [1:0] exp2;
    reg       frac1;
    reg [1:0] frac2;
    reg [3:0] exp_final;
    reg [2:0] frac_final;
    begin
      sign = lane[3];
      case (FP4_MODE)
        `FP4_MODE_E3M0: begin
          exp3 = lane[2:0];
          if (exp3 == 3'd7)
            fp4_to_fp8e4m3_model = QNAN8;
          else if (exp3 == 3'd0)
            fp4_to_fp8e4m3_model = {sign, 7'd0};
          else begin
            exp_final = exp3 + 4'd1;
            fp4_to_fp8e4m3_model = {sign, exp_final[3:0], 3'b000};
          end
        end
        `FP4_MODE_E2M1: begin
          exp2  = lane[2:1];
          frac1 = lane[0];
          if (exp2 == 2'b11)
            fp4_to_fp8e4m3_model = QNAN8;
          else if (exp2 == 2'b00)
            fp4_to_fp8e4m3_model = {sign, 7'd0};
          else begin
            exp_final  = {2'b00, exp2} + 4'd4;
            frac_final = {frac1, 2'b00};
            fp4_to_fp8e4m3_model = {sign, exp_final[3:0], frac_final};
          end
        end
        default: begin
          if (lane[2] == 1'b1)
            fp4_to_fp8e4m3_model = QNAN8;
          else begin
            frac2 = lane[1:0];
            if (frac2 == 2'b00)
              fp4_to_fp8e4m3_model = {sign, 7'd0};
            else
              fp4_to_fp8e4m3_model = {sign, 4'd6, frac2, 1'b0};
          end
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

  function automatic [15:0] lane_fp16_from_e4_model;
    input        sign_in;
    input signed [6:0] exp_unb_in;
    input [7:0]  prod_q8;
    input        is_zero;
    input        is_nan;
    reg signed [6:0] exp_adj;
    reg [11:0] mant_shift;
    reg [11:0] mant_norm_full;
    reg [10:0] mant_norm;
    reg [4:0]  exp16;
    begin
      if (is_nan) begin
        lane_fp16_from_e4_model = FP16_QNAN;
      end else if (is_zero) begin
        lane_fp16_from_e4_model = {sign_in, 15'd0};
      end else begin
        exp_adj = exp_unb_in + (prod_q8[7] ? 7'sd1 : 7'sd0);
        if ((exp_adj < 7'sd0) || (exp_adj > 7'sd14)) begin
          lane_fp16_from_e4_model = sign_in ? FP16_MAXFIN_NEG : FP16_MAXFIN_POS;
        end else begin
          exp16          = exp_adj[4:0] + 5'd8;
          mant_shift     = {prod_q8, 4'b0000};
          mant_norm_full = prod_q8[7] ? (mant_shift >> 1) : mant_shift;
          mant_norm      = mant_norm_full[10:0];
          lane_fp16_from_e4_model = {sign_in, exp16, mant_norm[9:0]};
        end
      end
    end
  endfunction

  function automatic [15:0] fp8e4m3_to_fp16;
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
        fp8e4m3_to_fp16 = FP16_QNAN;
      end else if (exp8 == 4'd0) begin
        fp8e4m3_to_fp16 = {sign, 15'd0};
      end else begin
        exp16 = exp8 + 5'd8;
        fp8e4m3_to_fp16 = {sign, exp16[4:0], {frac3, 7'b0}};
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
  reg [7:0] c_choices [0:3];

  integer idx;
  integer sel_a0, sel_a1, sel_b0, sel_b1, sel_c;

  reg [7:0] a1_fp8_ref, a2_fp8_ref;
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

    case (FP4_MODE)
      `FP4_MODE_E3M0: begin
        a_choices[0] = 4'h0;
        a_choices[1] = 4'h1;
        a_choices[2] = 4'h2;
        a_choices[3] = 4'h4;
        a_choices[4] = 4'h7;
        a_choices[5] = 4'hF;
      end
      `FP4_MODE_E2M1: begin
        a_choices[0] = 4'h0;
        a_choices[1] = 4'h1;
        a_choices[2] = 4'h2;
        a_choices[3] = 4'h6;
        a_choices[4] = 4'h7;
        a_choices[5] = 4'hB;
      end
      default: begin
        a_choices[0] = 4'h0;
        a_choices[1] = 4'h1;
        a_choices[2] = 4'h2;
        a_choices[3] = 4'h3;
        a_choices[4] = 4'h4;
        a_choices[5] = 4'hC;
      end
    endcase

    b_choices[0] = 8'h30; // +0.5
    b_choices[1] = 8'h38; // +1.0
    b_choices[2] = 8'hB8; // -1.0
    b_choices[3] = 8'h3C; // +1.5
    b_choices[4] = 8'h40; // +2.0
    b_choices[5] = 8'hC0; // -2.0

    c_choices[0] = 8'h00;
    c_choices[1] = 8'h38;
    c_choices[2] = 8'hB8;
    c_choices[3] = 8'h30;

    for (idx = 0; idx < N; idx = idx + 1) begin
      sel_a0 = idx % 6;
      sel_a1 = (idx + 3) % 6;
      sel_b0 = idx % 6;
      sel_b1 = (idx + (idx>>1) + 2) % 6;
      sel_c  = idx % 4;

      avec[idx] = {a_choices[sel_a1], a_choices[sel_a0]};
      bvec[idx] = {b_choices[sel_b1], b_choices[sel_b0]};
      cvec[idx] = pack4_16(
          fp8e4m3_to_fp16(c_choices[(sel_c + 3)%4]),
          fp8e4m3_to_fp16(c_choices[(sel_c + 2)%4]),
          fp8e4m3_to_fp16(c_choices[(sel_c + 1)%4]),
          fp8e4m3_to_fp16(c_choices[sel_c])
      );
    end

    for (idx = 0; idx < N; idx = idx + 1) begin
      a1_fp8_ref = fp4_to_fp8e4m3_model(avec[idx][3:0]);
      a2_fp8_ref = fp4_to_fp8e4m3_model(avec[idx][7:4]);

      begin : lane_compute
        reg [7:0] b1_lane, b2_lane;
        reg [3:0] ea1, ea2, eb1, eb2;
        reg [2:0] fa1, fa2, fb1, fb2;
        reg       s11, s12, s21, s22;
        reg       a1_zero, a2_zero, b1_zero, b2_zero;
        reg       a1_nan, a2_nan, b1_nan, b2_nan;
        reg signed [6:0] e11_unb, e12_unb, e21_unb, e22_unb;
        reg [7:0] prod11_q, prod12_q, prod21_q, prod22_q;
        b1_lane = bvec[idx][7:0];
        b2_lane = bvec[idx][15:8];

        ea1 = a1_fp8_ref[6:3];
        ea2 = a2_fp8_ref[6:3];
        eb1 = b1_lane[6:3];
        eb2 = b2_lane[6:3];

        fa1 = a1_fp8_ref[2:0];
        fa2 = a2_fp8_ref[2:0];
        fb1 = b1_lane[2:0];
        fb2 = b2_lane[2:0];

        a1_zero = (ea1 == 4'd0);
        a2_zero = (ea2 == 4'd0);
        b1_zero = (eb1 == 4'd0);
        b2_zero = (eb2 == 4'd0);
        b1_nan  = (eb1 == 4'hF);
        b2_nan  = (eb2 == 4'hF);
        a1_nan  = (ea1 == 4'hF);
        a2_nan  = (ea2 == 4'hF);

        s11 = a1_fp8_ref[7] ^ b1_lane[7];
        s12 = a1_fp8_ref[7] ^ b2_lane[7];
        s21 = a2_fp8_ref[7] ^ b1_lane[7];
        s22 = a2_fp8_ref[7] ^ b2_lane[7];

        e11_unb = $signed({3'd0, ea1}) + $signed({3'd0, eb1}) - $signed(7);
        e12_unb = $signed({3'd0, ea1}) + $signed({3'd0, eb2}) - $signed(7);
        e21_unb = $signed({3'd0, ea2}) + $signed({3'd0, eb1}) - $signed(7);
        e22_unb = $signed({3'd0, ea2}) + $signed({3'd0, eb2}) - $signed(7);

        prod11_q = {1'b1, fa1} * {1'b1, fb1};
        prod12_q = {1'b1, fa1} * {1'b1, fb2};
        prod21_q = {1'b1, fa2} * {1'b1, fb1};
        prod22_q = {1'b1, fa2} * {1'b1, fb2};

        prod11_fp16 = lane_fp16_from_e4_model(s11, e11_unb, prod11_q,
                           (~(a1_nan | b1_nan)) & (a1_zero | b1_zero),
                           (a1_nan | b1_nan));
        prod12_fp16 = lane_fp16_from_e4_model(s12, e12_unb, prod12_q,
                           (~(a1_nan | b2_nan)) & (a1_zero | b2_zero),
                           (a1_nan | b2_nan));
        prod21_fp16 = lane_fp16_from_e4_model(s21, e21_unb, prod21_q,
                           (~(a2_nan | b1_nan)) & (a2_zero | b1_zero),
                           (a2_nan | b1_nan));
        prod22_fp16 = lane_fp16_from_e4_model(s22, e22_unb, prod22_q,
                           (~(a2_nan | b2_nan)) & (a2_zero | b2_zero),
                           (a2_nan | b2_nan));
      end

      sum11 = fp16_add_ref(prod11_fp16, cvec[idx][15:0]);
      sum12 = fp16_add_ref(prod12_fp16, cvec[idx][31:16]);
      sum21 = fp16_add_ref(prod21_fp16, cvec[idx][47:32]);
      sum22 = fp16_add_ref(prod22_fp16, cvec[idx][63:48]);

      yexp[idx] = pack4_16(sum22, sum21, sum12, sum11);
    end

    $display("\n--- FP4 × FP8(E4M3) → FP16 MAC (MODE=%0d, LAT=%0d, Vectors=%0d) ---",
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
