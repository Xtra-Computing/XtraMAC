`timescale 1ns/1ps
`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_int4_fp8e5m2_mac
//   - Verifies INT4 → FP8(E5M2) MAC wrapper against reference models
////////////////////////////////////////////////////////////////////////////////
module tb_int4_fp8e5m2_mac;
  // --------------------------------------------------------------------------
  // Parameters
  // --------------------------------------------------------------------------
  parameter integer LAT        = 4;
  parameter integer N          = 24;
  parameter integer DUMMY_CLKS = 6;

  // --------------------------------------------------------------------------
  // DUT I/O
  // --------------------------------------------------------------------------
  reg         clk;
  reg  [7:0]  a_int4;   // {a2[7:4], a1[3:0]} INT4 lanes
  reg  [15:0] b_fp8;    // {b2[15:8], b1[7:0]} FP8(E5M2)
  reg  [31:0] c_fp8;    // {c22,c21,c12,c11} FP8(E5M2)
  wire [31:0] result;   // {y22,y21,y12,y11}

  int4_fp8e5m2_mac dut (
      .clk   (clk),
      .a_int4(a_int4),
      .b_fp8 (b_fp8),
      .c_fp8 (c_fp8),
      .result(result)
  );

  // --------------------------------------------------------------------------
  // Clock (100 MHz)
  // --------------------------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // --------------------------------------------------------------------------
  // FP8(E5M2) constants / helpers (mirror DUT behavior)
  // --------------------------------------------------------------------------
  localparam integer EWIDTH = 5;
  localparam integer FWIDTH = 2;
  localparam integer MBITS  = 1 + FWIDTH;   // 3
  localparam integer BIAS   = 15;

  localparam [7:0] QNAN8  = 8'h7D;
  localparam [7:0] PINF8  = 8'h7C;
  localparam [7:0] NINF8  = 8'hFC;
  localparam [7:0] PZERO8 = 8'h00;
  localparam [7:0] NZERO8 = 8'h80;

  localparam [7:0] FP8_P0_5 = 8'h38;
  localparam [7:0] FP8_N0_5 = 8'hB8;
  localparam [7:0] FP8_P1_0 = 8'h3C;
  localparam [7:0] FP8_N1_0 = 8'hBC;
  localparam [7:0] FP8_P1_5 = 8'h3E;
  localparam [7:0] FP8_N1_5 = 8'hBE;
  localparam [7:0] FP8_P2_0 = 8'h40;
  localparam [7:0] FP8_N2_0 = 8'hC0;
  localparam [7:0] FP8_P3_0 = 8'h42;
  localparam [7:0] FP8_N3_0 = 8'hC2;

  function [3:0] int_to_int4; input integer val;
    integer clipped;
    begin
      clipped = (val > 7) ? 7 : ((val < -8) ? -8 : val);
      int_to_int4 = clipped[3:0];
    end
  endfunction

  function [15:0] pack2_8; input [7:0] hi; input [7:0] lo;
    begin
      pack2_8 = {hi, lo};
    end
  endfunction

  function [31:0] pack4_8; input [7:0] y22,y21,y12,y11;
    begin
      pack4_8 = {y22, y21, y12, y11};
    end
  endfunction

  function [MBITS-1:0] rshift3; input [MBITS-1:0] x; input [1:0] sh;
    begin
      case (sh)
        2'd0: rshift3 = x;
        2'd1: rshift3 = {1'b0,  x[2:1]};
        2'd2: rshift3 = {2'b00, x[2]};
        default: rshift3 = 3'b0;
      endcase
    end
  endfunction

  function [1:0] clz4; input [3:0] x;
    begin
      casex (x)
        4'b1xxx: clz4 = 2'd0;
        4'b01xx: clz4 = 2'd1;
        4'b001x: clz4 = 2'd2;
        4'b0001: clz4 = 2'd3;
        default: clz4 = 2'd3;
      endcase
    end
  endfunction

  function [7:0] int4_to_fp8e5m2_model; input [3:0] val4;
    reg  signed [4:0] sval;
    reg        sign;
    reg  [4:0] absval;
    reg  [2:0] msb_idx;
    integer    shift_amt;
    reg  [2:0] mant3;
    reg  [5:0] exp_bias;
    begin
      sval = $signed({val4[3], val4});
      if (sval == 0) begin
        int4_to_fp8e5m2_model = 8'h00;
      end else begin
        sign   = sval[4];
        absval = sign ? -sval : sval;
        casex (absval[3:0])
          4'b1???: msb_idx = 3'd3;
          4'b01??: msb_idx = 3'd2;
          4'b001?: msb_idx = 3'd1;
          default: msb_idx = 3'd0;
        endcase
        shift_amt = 2 - msb_idx;
        if (shift_amt >= 0) begin
          mant3 = (absval[3:0] << shift_amt);
        end else begin
          mant3 = (absval[3:0] >> (-shift_amt));
        end
        exp_bias = msb_idx + BIAS;
        int4_to_fp8e5m2_model = {sign, exp_bias[4:0], mant3[1:0]};
      end
    end
  endfunction

  function [7:0] fp8_mul_lane_model;
    input [7:0] a;
    input [7:0] b;
    reg sa,sb; reg [4:0] ea,eb; reg [1:0] fa,fb;
    reg a_nan,a_inf,a_zero,b_nan,b_inf,b_zero;
    reg signp; integer esum;
    reg [2:0] Ma,Mb; reg [5:0] prod; reg carry; reg [1:0] frac2;
    begin
      sa=a[7]; ea=a[6:2]; fa=a[1:0];
      sb=b[7]; eb=b[6:2]; fb=b[1:0];
      a_nan=(ea==5'h1F)&&(fa!=2'd0); a_inf=(ea==5'h1F)&&(fa==2'd0); a_zero=(ea==5'd0);
      b_nan=(eb==5'h1F)&&(fb!=2'd0); b_inf=(eb==5'h1F)&&(fb==2'd0); b_zero=(eb==5'd0);
      if (a_nan | b_nan | ((a_inf & b_zero) | (a_zero & b_inf))) begin
        fp8_mul_lane_model = QNAN8;
      end else if (a_inf | b_inf) begin
        fp8_mul_lane_model = {sa^sb, 5'h1F, 2'b00};
      end else if (a_zero | b_zero) begin
        fp8_mul_lane_model = {(sa^sb), 7'd0};
      end else begin
        signp = sa ^ sb;
        esum  = (ea + eb) - BIAS;
        Ma    = {1'b1, fa};
        Mb    = {1'b1, fb};
        prod  = Ma * Mb;
        carry = prod[5];
        frac2 = carry ? prod[4:3] : prod[3:2];
        esum  = esum + (carry ? 1 : 0);
        if (esum < 0 || esum > 30)
          fp8_mul_lane_model = {signp, 5'h1F, 2'b00};
        else
          fp8_mul_lane_model = {signp, esum[4:0], frac2};
      end
    end
  endfunction

  function [7:0] fp8_add_model;
    input [7:0] a;
    input [7:0] b;
    reg sa,sb; reg [4:0] ea,eb; reg [1:0] fa,fb;
    reg isNaN_a,isNaN_b,isInf_a,isInf_b;
    reg zero_a0, zero_b0;
    reg [5:0] Ea0,Eb0; reg [2:0] Ma0,Mb0; // 1+2 mantissa
    reg swap0, sign_big_1, sign_sml_1;
    reg [5:0] E_big_1, E_sml_1, dE_1;
    reg [2:0] M_big_1, M_sml_1;
    reg diff_sign_1;
    reg [1:0] shamt;
    reg [2:0] M_sml_aligned; reg guard_bit;
    reg [3:0] big4, sml4i;
    reg [4:0] sumW;
    reg same_sign, add_carry;
    reg [5:0] E_n;
    reg [3:0] lane4; reg [1:0] lz; reg zero_af;
    reg [3:0] laneN; reg [5:0] E_l;
    reg overflow, under_or_zero;
    reg [2:0] mant_norm; reg [7:0] norm_pack;
    begin
      sa=a[7]; ea=a[6:2]; fa=a[1:0];
      sb=b[7]; eb=b[6:2]; fb=b[1:0];

      isNaN_a=(ea==5'h1F)&&(fa!=2'd0); isNaN_b=(eb==5'h1F)&&(fb!=2'd0);
      isInf_a=(ea==5'h1F)&&(fa==2'd0); isInf_b=(eb==5'h1F)&&(fb==2'd0);

      if (isNaN_a || isNaN_b) begin
        fp8_add_model = QNAN8;
      end else if (isInf_a && isInf_b) begin
        fp8_add_model = (sa==sb) ? {sa,5'h1F,2'b00} : QNAN8;
      end else if (isInf_a && !isInf_b) begin
        fp8_add_model = {sa,5'h1F,2'b00};
      end else if (!isInf_a && isInf_b) begin
        fp8_add_model = {sb,5'h1F,2'b00};
      end else begin
        zero_a0 = (ea==5'd0);
        zero_b0 = (eb==5'd0);

        Ea0 = zero_a0 ? 6'd0 : {1'b0,ea};
        Eb0 = zero_b0 ? 6'd0 : {1'b0,eb};
        Ma0 = zero_a0 ? 3'd0 : {1'b1,fa};
        Mb0 = zero_b0 ? 3'd0 : {1'b1,fb};

        swap0       = (Ea0 < Eb0) || ((Ea0==Eb0)&&(Ma0<Mb0));
        sign_big_1  = swap0 ? sb : sa;
        sign_sml_1  = swap0 ? sa : sb;
        E_big_1     = swap0 ? Eb0 : Ea0;
        E_sml_1     = swap0 ? Ea0 : Eb0;
        M_big_1     = swap0 ? Mb0 : Ma0;
        M_sml_1     = swap0 ? Ma0 : Mb0;

        dE_1  = (E_big_1 >= E_sml_1) ? (E_big_1 - E_sml_1) : 6'd0;
        shamt = (dE_1 >= 6'd3) ? 2'd3 : dE_1[1:0];
        M_sml_aligned = rshift3(M_sml_1, shamt);
        guard_bit     = (shamt==2'd0) ? 1'b0 : M_sml_1[shamt-1];

        big4  = {M_big_1,       1'b0};
        sml4i = {M_sml_aligned, guard_bit};

        same_sign = (sign_big_1 == sign_sml_1);
        sumW      = {1'b0,big4} + (same_sign ? {1'b0,sml4i} : (~{1'b0,sml4i}+5'd1));
        add_carry = same_sign & sumW[4];

        E_n   = add_carry ? (E_big_1 + 6'd1) : E_big_1;
        lane4 = same_sign ? (add_carry ? sumW[4:1] : sumW[3:0]) : (big4 - sml4i);

        lz    = clz4(lane4);
        zero_af = (lane4==4'd0) || (E_n <= {4'd0,lz});
        laneN = zero_af ? 4'd0 : (lane4 << lz);
        E_l   = zero_af ? 6'd0 : (E_n - {4'd0,lz});

        overflow      = (E_l[5]==1'b1) | (E_l > 6'd31);
        under_or_zero = (E_l == 6'd0) | (laneN == 4'd0);

        mant_norm = laneN[3:1];
        norm_pack = {sign_big_1, E_l[4:0], mant_norm[1:0]};

        fp8_add_model = overflow      ? {sign_big_1,5'h1F,2'b00} :
                        under_or_zero ? PZERO8 :
                                        norm_pack;
      end
    end
  endfunction

  // --------------------------------------------------------------------------
  // Stimulus / golden storage
  // --------------------------------------------------------------------------
  reg [7:0]  avec [0:N-1];
  reg [15:0] bvec [0:N-1];
  reg [31:0] cvec [0:N-1];
  reg [31:0] yexp [0:N-1];

  reg signed [4:0] int_choices [0:5];
  reg [7:0]        b_choices  [0:4];
  reg [7:0]        c_choices  [0:5];

  integer idx;
  integer sel_a0;
  integer sel_a1;
  integer sel_b0;
  integer sel_b1;
  integer sel_c;
  reg [7:0] a1_fp8_ref, a2_fp8_ref;
  reg [7:0] p11,p12,p21,p22;
  reg [7:0] s11,s12,s21,s22;

  initial begin
    int_choices[0] = -8;
    int_choices[1] = -5;
    int_choices[2] = -2;
    int_choices[3] =  0;
    int_choices[4] =  3;
    int_choices[5] =  7;

    b_choices[0] = FP8_P1_0;
    b_choices[1] = FP8_N1_0;
    b_choices[2] = FP8_P0_5;
    b_choices[3] = FP8_P2_0;
    b_choices[4] = PINF8;

    c_choices[0] = PZERO8;
    c_choices[1] = FP8_P1_0;
    c_choices[2] = FP8_N1_0;
    c_choices[3] = FP8_P0_5;
    c_choices[4] = QNAN8;
    c_choices[5] = PINF8;

    for (idx = 0; idx < N; idx = idx + 1) begin
      sel_a0 = idx % 6;
      sel_a1 = (idx + 3) % 6;
      sel_b0 = idx % 5;
      sel_b1 = (idx + (idx >> 1) + 2) % 5;
      sel_c  = idx % 6;

      avec[idx] = {int_to_int4(int_choices[sel_a1]), int_to_int4(int_choices[sel_a0])};
      bvec[idx] = pack2_8(b_choices[sel_b1], b_choices[sel_b0]);
      cvec[idx] = pack4_8(
          c_choices[(sel_c + 3) % 6],
          c_choices[(sel_c + 2) % 6],
          c_choices[(sel_c + 1) % 6],
          c_choices[sel_c]
      );
    end

    // Directed overrides for coverage of Inf/NaN and zero handling
    avec[0] = {int_to_int4(7),  int_to_int4(-8)};
    bvec[0] = pack2_8(PINF8, FP8_N2_0);
    cvec[0] = pack4_8(PZERO8, FP8_P1_0, FP8_N1_0, PZERO8);

    avec[1] = {int_to_int4(-1), int_to_int4(3)};
    bvec[1] = pack2_8(FP8_P1_5, FP8_P1_0);
    cvec[1] = pack4_8(FP8_P3_0, FP8_P0_5, FP8_P0_5, FP8_P3_0);

    avec[2] = {int_to_int4(0),  int_to_int4(0)};
    bvec[2] = pack2_8(QNAN8, FP8_P2_0);
    cvec[2] = pack4_8(FP8_N1_0, FP8_P1_0, FP8_N1_0, FP8_P1_0);

    avec[3] = {int_to_int4(-8), int_to_int4(-8)};
    bvec[3] = pack2_8(FP8_P2_0, FP8_P2_0);
    cvec[3] = pack4_8(PINF8, PINF8, PINF8, PINF8);

    // Golden computation
    for (idx = 0; idx < N; idx = idx + 1) begin
      a1_fp8_ref = int4_to_fp8e5m2_model(avec[idx][3:0]);
      a2_fp8_ref = int4_to_fp8e5m2_model(avec[idx][7:4]);

      p11 = fp8_mul_lane_model(a1_fp8_ref, bvec[idx][7:0]);
      p12 = fp8_mul_lane_model(a1_fp8_ref, bvec[idx][15:8]);
      p21 = fp8_mul_lane_model(a2_fp8_ref, bvec[idx][7:0]);
      p22 = fp8_mul_lane_model(a2_fp8_ref, bvec[idx][15:8]);

      s11 = fp8_add_model(p11, cvec[idx][7:0]);
      s12 = fp8_add_model(p12, cvec[idx][15:8]);
      s21 = fp8_add_model(p21, cvec[idx][23:16]);
      s22 = fp8_add_model(p22, cvec[idx][31:24]);

      yexp[idx] = pack4_8(s22, s21, s12, s11);
    end
  end

  // --------------------------------------------------------------------------
  // Drive + Check
  // --------------------------------------------------------------------------
  integer errors;
  integer i;
  integer idx_chk;
  initial begin
    errors = 0;
    a_int4 = 8'h00;
    b_fp8  = 16'h0000;
    c_fp8  = 32'h00000000;

    $display("\n--- INT4 x FP8(E5M2) MAC (LAT=%0d, Vectors=%0d) ---", LAT, N);
    $display("Applying %0d dummy clocks before stimulus...", DUMMY_CLKS);
    repeat (DUMMY_CLKS) @(posedge clk);

    for (i = 0; i < N + LAT; i = i + 1) begin
      if (i < N) begin
        a_int4 <= avec[i];
        b_fp8  <= bvec[i];
        c_fp8  <= cvec[i];
      end else begin
        a_int4 <= 8'h00;
        b_fp8  <= 16'h0000;
        c_fp8  <= 32'h00000000;
      end

      @(posedge clk);

      if (i >= LAT) begin
        idx_chk = i - LAT;
        if (result !== yexp[idx_chk]) begin
          errors = errors + 1;
          $display("Mismatch idx %0d : got %h expected %h (a=%02h b=%04h c=%08h)",
                   idx_chk, result, yexp[idx_chk], avec[idx_chk], bvec[idx_chk], cvec[idx_chk]);
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
