`timescale 1ns/1ps
`default_nettype none
////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_fp8e5m2_mac — II=1, 4-cycle latency, DSP-packed (2×2) with self-check
// FP8(E5M2) per lane: [7]=sign, [6:2]=exp(5), [1:0]=frac(2), bias=15
////////////////////////////////////////////////////////////////////////////////

module tb_fp8e5m2_mac;

  // ---- Parameters ----
  parameter integer LAT        = 4;    // total pipeline latency (cycles)
  parameter integer N          = 16;   // number of test vectors
  parameter integer DUMMY_CLKS = 6;    // warm-up clocks

  // ---- DUT I/O ----
  reg         clk;
  reg  [31:0] a18;     // {xx, xx, a2[15:8], a1[7:0]}  (DUT uses low 16 bits)
  reg  [15:0] b18;     // {b2[15:8], b1[7:0]}
  reg  [31:0] c36;     // {c22[31:24], c21[23:16], c12[15:8], c11[7:0]}
  wire [31:0] result;  // {y22, y21, y12, y11}

  // ---- Instantiate DUT ----
  fp8e5m2_mac dut (
    .clk   (clk),
    .a18   (a18),
    .b18   (b18),
    .c36   (c36),
    .result(result)
  );

  // ---- Clock: 100 MHz ----
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ============================================================
  // Reference helpers (mirror DUT behavior)
  // ============================================================
  localparam integer EWIDTH = 5;
  localparam integer FWIDTH = 2;
  localparam integer MBITS  = 1 + FWIDTH;   // 3
  localparam integer BIAS   = 15;

  localparam [7:0] QNAN8  = 8'h7D; // exp=11111, frac!=0
  localparam [7:0] PINF8  = 8'h7C; // +Inf
  localparam [7:0] NINF8  = 8'hFC; // -Inf
  localparam [7:0] PZERO8 = 8'h00; // +0
  localparam [7:0] NZERO8 = 8'h80; // -0 (note: adder outputs +0 on underflow/zero)

  // Handy FP8 finite constants (packed E5M2)
  // bias=15, 1.0 => exp=15 (0x0F), frac=00
  localparam [7:0] FP8_P1_0  = 8'h3C; // +1.0  (0_01111_00)
  localparam [7:0] FP8_N1_0  = 8'hBC; // -1.0  (1_01111_00)
  localparam [7:0] FP8_P2_0  = 8'h40; // +2.0  (0_10000_00)
  localparam [7:0] FP8_N2_0  = 8'hC0; // -2.0
  localparam [7:0] FP8_P0_5  = 8'h38; // +0.5  (0_01110_00)
  localparam [7:0] FP8_N0_5  = 8'hB8; // -0.5
  localparam [7:0] FP8_P1_5  = 8'h3E; // +1.5  (0_01111_10)
  localparam [7:0] FP8_N1_5  = 8'hBE; // -1.5
  localparam [7:0] FP8_P3_0  = 8'h42; // +3.0  (0_10000_10)
  localparam [7:0] FP8_N3_0  = 8'hC2; // -3.0  (1_10000_10)
  localparam [7:0] FP8_SUBMIN= 8'h01; // +min subnormal (FTZ→0)

  // 3-bit saturating right shift for adder alignment
  function [MBITS-1:0] rshift3; input [MBITS-1:0] x; input [1:0] sh;
    begin
      case (sh)
        2'd0: rshift3 = x;
        2'd1: rshift3 = {1'b0,   x[2:1]};
        2'd2: rshift3 = {2'b00,  x[2]};
        default: rshift3 = 3'b0; // sh>=3
      endcase
    end
  endfunction

  // CLZ for a 4-bit lane (0..4; treat 0 as 3, gated separately)
  function [1:0] clz4; input [3:0] x;
    begin
      casex (x)
        4'b1xxx: clz4 = 2'd0;
        4'b01xx: clz4 = 2'd1;
        4'b001x: clz4 = 2'd2;
        4'b0001: clz4 = 2'd3;
        default:  clz4 = 2'd3;
      endcase
    end
  endfunction

  // ---- FP8 lane multiply model ----
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

      a_nan=(ea==5'h1F)&&(fa!=2'd0); a_inf=(ea==5'h1F)&&(fa==2'd0); a_zero=(ea==5'd0); // FTZ
      b_nan=(eb==5'h1F)&&(fb!=2'd0); b_inf=(eb==5'h1F)&&(fb==2'd0); b_zero=(eb==5'd0);

      if (a_nan | b_nan | ((a_inf & b_zero) | (a_zero & b_inf))) begin
        fp8_mul_lane_model = QNAN8;
      end else if (a_inf | b_inf) begin
        fp8_mul_lane_model = {sa^sb, 5'h1F, 2'b00};
      end else if (a_zero | b_zero) begin
        fp8_mul_lane_model = {(sa^sb), 7'd0}; // signed zero (XOR) — adder will produce +0
      end else begin
        signp = sa ^ sb;
        esum  = (ea + eb) - BIAS;

        Ma    = {1'b1, fa};          // 1+2
        Mb    = {1'b1, fb};
        prod  = Ma * Mb;              // 3x3 -> 6b
        carry = prod[5];
        frac2 = carry ? prod[4:3] : prod[3:2];
        esum  = esum + (carry ? 1 : 0);

        // clamp to signed Inf on under/overflow (mirror DUT policy)
        if (esum < 0 || esum > 30) fp8_mul_lane_model = {signp, 5'h1F, 2'b00};
        else                       fp8_mul_lane_model = {signp, esum[4:0], frac2};
      end
    end
  endfunction

  // ---- FP8 adder model (FTZ, guard+align, same-sign carry-right) ----
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
        // finite path (FTZ)
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

        // add/sub by sign
        same_sign = (sign_big_1 == sign_sml_1);
        sumW      = {1'b0,big4} + (same_sign ? {1'b0,sml4i} : (~{1'b0,sml4i}+5'd1));
        add_carry = same_sign & sumW[4];

        // exponent update and carry-right
        E_n   = add_carry ? (E_big_1 + 6'd1) : E_big_1;
        lane4 = same_sign ? (add_carry ? sumW[4:1] : sumW[3:0]) : (big4 - sml4i);

        // normalize
        lz    = clz4(lane4);
        zero_af = (lane4==4'd0) || (E_n <= {4'd0,lz});
        laneN = zero_af ? 4'd0 : (lane4 << lz);
        E_l   = zero_af ? 6'd0 : (E_n - {4'd0,lz});

        overflow      = (E_l[5]==1'b1) | (E_l > 6'd31);
        under_or_zero = (E_l == 6'd0) | (laneN == 4'd0);

        mant_norm = laneN[3:1];         // 1+2
        norm_pack = {sign_big_1, E_l[4:0], mant_norm[1:0]};

        fp8_add_model = overflow      ? {sign_big_1,5'h1F,2'b00} :
                        under_or_zero ? PZERO8 :
                                        norm_pack;
      end
    end
  endfunction

  // ============================================================
  // Test vectors and golden computation
  // ============================================================
  reg [31:0]  avec [0:N-1];  // we will write into low 16 bits only
  reg [15:0]  bvec [0:N-1];
  reg [31:0]  cvec [0:N-1];
  reg [31:0]  yexp [0:N-1];
  reg [8*96:1] name [0:N-1];

  integer gi;
  reg [7:0] p11,p12,p21,p22, s11,s12,s21,s22;

  // pack helpers for bench readability
  function [15:0] pack2_8; input [7:0] hi; input [7:0] lo; begin pack2_8 = {hi, lo}; end endfunction
  function [31:0] pack4_8; input [7:0] y22,y21,y12,y11; begin pack4_8 = {y22,y21,y12,y11}; end endfunction

  initial begin
    // V0: [a1=+1,a2=+1] x [b1=+2,b2=+0.5] + C=0
    name[0] = "V0: a=[1,1], b=[2,0.5], C=0";
    avec[0] = {16'h0, pack2_8(FP8_P1_0, FP8_P1_0)};
    bvec[0] = pack2_8(FP8_P0_5, FP8_P2_0); // hi=b2=0.5, lo=b1=2.0
    cvec[0] = pack4_8(PZERO8,PZERO8,PZERO8,PZERO8);

    // V1: mix signs, finite
    name[1] = "V1: mix signs, finite";
    avec[1] = {16'h0, pack2_8(FP8_P0_5, FP8_N1_5)};   // a2=+0.5, a1=-1.5
    bvec[1] = pack2_8(FP8_N1_0, FP8_P1_5);           // b2=-1.0, b1=+1.5
    cvec[1] = pack4_8(FP8_N1_0,FP8_P1_0,FP8_N1_0,FP8_P1_0);

    // V2: finite mix 2
    name[2] = "V2: finite mix 2";
    avec[2] = {16'h0, pack2_8(FP8_N2_0, FP8_P3_0)};   // a2=-2, a1=+3
    bvec[2] = pack2_8(FP8_P0_5, FP8_N2_0);           // b2=+0.5, b1=-2
    cvec[2] = pack4_8(FP8_P0_5,FP8_P0_5,FP8_P0_5,FP8_P0_5);

    // V3: zeros in A, pass-through C
    name[3] = "V3: A zeros, pass C";
    avec[3] = {16'h0, pack2_8(PZERO8, PZERO8)};
    bvec[3] = pack2_8(FP8_P1_5, FP8_P1_0);
    cvec[3] = pack4_8(FP8_P3_0,FP8_P0_5,FP8_P2_0,FP8_P1_0);

    // V4: Inf * finite -> Inf (sign)
    name[4] = "V4: Inf*finite => signed Inf";
    avec[4] = {16'h0, pack2_8(PINF8, FP8_N1_0)};
    bvec[4] = pack2_8(FP8_P1_0, PINF8); // b2=+1, b1=+Inf
    cvec[4] = pack4_8(PZERO8,PZERO8,PZERO8,PZERO8);

    // V5: Inf * 0 => NaN (mult special)
    name[5] = "V5: Inf*0 => NaN";
    avec[5] = {16'h0, pack2_8(PINF8, FP8_P1_0)};
    bvec[5] = pack2_8(PZERO8, PZERO8);
    cvec[5] = pack4_8(PZERO8,PZERO8,PZERO8,PZERO8);

    // V6: NaN anywhere => NaN
    name[6] = "V6: NaN propagation";
    avec[6] = {16'h0, pack2_8(QNAN8, FP8_P1_0)};
    bvec[6] = pack2_8(FP8_P1_0, QNAN8);
    cvec[6] = pack4_8(PZERO8,PZERO8,PZERO8,PZERO8);

    // V7: finite -> +Inf (mul overflow) (near-max finite)
    name[7] = "V7: finite -> +Inf (mul overflow)";
    // near-max finite: exp=30 (0x1E), frac=3 (0b11)
    avec[7] = {16'h0, pack2_8({1'b0,5'h1E,2'b11}, {1'b0,5'h1E,2'b11})};
    bvec[7] = pack2_8({1'b0,5'h1E,2'b11}, {1'b0,5'h1E,2'b11});
    cvec[7] = pack4_8(PZERO8,PZERO8,PZERO8,PZERO8);

    // V8: adder exact cancellation -> 0
    name[8] = "V8: 1*2 + (-2) -> 0 (all lanes)";
    avec[8] = {16'h0, pack2_8(FP8_P1_0, FP8_P1_0)};
    bvec[8] = pack2_8(FP8_P2_0, FP8_P2_0);
    cvec[8] = pack4_8(FP8_N2_0,FP8_N2_0,FP8_N2_0,FP8_N2_0);

    // V9: subnormal FTZ (acts as zero)
    name[9] = "V9: subnormal FTZ";
    avec[9] = {16'h0, pack2_8(FP8_SUBMIN, FP8_SUBMIN)};
    bvec[9] = pack2_8(FP8_P2_0, FP8_N2_0);
    cvec[9] = pack4_8(PZERO8,PZERO8,PZERO8,PZERO8);

    // V10: adder overflow to signed Inf
    name[10] = "V10: adder overflow";
    avec[10] = {16'h0, pack2_8(FP8_P3_0, FP8_P3_0)};
    bvec[10] = pack2_8(FP8_P3_0, FP8_P3_0);
    cvec[10] = pack4_8(PINF8,PINF8,PINF8,PINF8);

    // V11: +Inf + -Inf -> NaN (adder)
    name[11] = "V11: +Inf + -Inf -> NaN";
    avec[11] = {16'h0, pack2_8(FP8_P1_0, FP8_P1_0)};
    bvec[11] = pack2_8(FP8_P1_0, FP8_P1_0);
    cvec[11] = pack4_8(NINF8,NINF8,PINF8,NINF8);

    // V12: signed zeros (mult zero path keeps XOR sign), adder gives +0
    name[12] = "V12: zero mix";
    avec[12] = {16'h0, pack2_8(PZERO8, NZERO8)};
    bvec[12] = pack2_8(NZERO8, PZERO8);
    cvec[12] = pack4_8(PZERO8,PZERO8,PZERO8,PZERO8);

    // V13: mixed signs, finite stable
    name[13] = "V13: finite mix 3";
    avec[13] = {16'h0, pack2_8(FP8_N1_0, FP8_P1_5)};
    bvec[13] = pack2_8(FP8_P0_5, FP8_N1_0);
    cvec[13] = pack4_8(FP8_P1_0,FP8_P0_5,FP8_N1_0,FP8_P0_5);

    // V14: (-3)*(-2) + (-2) -> positive then minus -> check
    name[14] = "V14: corner finite";
    avec[14] = {16'h0, pack2_8(FP8_N3_0, FP8_N3_0)};
    bvec[14] = pack2_8(FP8_N2_0, FP8_N2_0);
    cvec[14] = pack4_8(FP8_N2_0,FP8_N2_0,FP8_N2_0,FP8_N2_0);

    // V15: (-Inf)*1 + (+0.5) -> -Inf (mult special dominates)
    name[15] = "V15: -Inf dominates";
    avec[15] = {16'h0, pack2_8(NINF8, NINF8)};
    bvec[15] = pack2_8(FP8_P1_0, FP8_P1_0);
    cvec[15] = pack4_8(FP8_P0_5,FP8_P0_5,FP8_P0_5,FP8_P0_5);

    // ---- Compute goldens ----
    for (gi = 0; gi < N; gi = gi + 1) begin
      // lanes mapping: y = {y22,y21,y12,y11}
      p11 = fp8_mul_lane_model(avec[gi][ 7: 0], bvec[gi][ 7: 0]);
      p12 = fp8_mul_lane_model(avec[gi][ 7: 0], bvec[gi][15: 8]);
      p21 = fp8_mul_lane_model(avec[gi][15: 8], bvec[gi][ 7: 0]);
      p22 = fp8_mul_lane_model(avec[gi][15: 8], bvec[gi][15: 8]);

      s11 = fp8_add_model(p11, cvec[gi][ 7: 0]);
      s12 = fp8_add_model(p12, cvec[gi][15: 8]);
      s21 = fp8_add_model(p21, cvec[gi][23:16]);
      s22 = fp8_add_model(p22, cvec[gi][31:24]);

      yexp[gi] = pack4_8(s22,s21,s12,s11);
    end
  end

  // ============================================================
  // Drive + Check (II=1)
  // ============================================================
  integer errors, i, idx;
  initial begin
    errors = 0;

    // Init + dummy clocks
    a18 = 32'h0; b18 = 16'h0; c36 = 32'h0;
    $display("\n--- FP8(E5M2) MAC (II=1, LAT=%0d) ---", LAT);
    $display("Applying %0d dummy clocks before stimulus...", DUMMY_CLKS);
    repeat (DUMMY_CLKS) @(posedge clk);

    // Stream inputs & check after LAT cycles
    for (i = 0; i < N + LAT; i = i + 1) begin
      if (i < N) begin
        a18 <= {16'h0, avec[i][15:0]}; // only low 16 used by DUT
        b18 <= bvec[i];
        c36 <= cvec[i];
      end else begin
        a18 <= 32'h0; b18 <= 16'h0; c36 <= 32'h0; // drain
      end

      @(posedge clk);

      if (i >= LAT) begin
        idx = i - LAT;
        if (result === yexp[idx]) begin
          $display("PASS: %0s  OUT=0x%08h", name[idx], result);
        end else begin
          $display("FAIL: %0s  got 0x%08h, expected 0x%08h", name[idx], result, yexp[idx]);
          errors = errors + 1;
        end
      end
    end

    if (errors == 0)
      $display("--- All %0d tests PASS ---\n", N);
    else
      $display("--- %0d / %0d tests FAILED ---\n", errors, N);

    $finish;
  end

endmodule

`default_nettype wire
