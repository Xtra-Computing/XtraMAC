`timescale 1ns/1ps
`default_nettype none
////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_fp9_mac — II=1, 4-cycle latency, DSP-packed (2×2) with self-check
// FP9 per lane: [8]=sign, [7:4]=exp(4), [3:0]=frac(4), bias=7
////////////////////////////////////////////////////////////////////////////////

module tb_fp9_mac;

  // ---- Parameters ----
  parameter integer LAT        = 4;    // total pipeline latency (cycles)
  parameter integer N          = 16;   // number of test vectors
  parameter integer DUMMY_CLKS = 6;    // warm-up clocks

  // ---- DUT I/O ----
  reg         clk;
  reg  [17:0] a18;     // {a2[17:9], a1[8:0]}
  reg  [17:0] b18;     // {b2[17:9], b1[8:0]}
  reg  [35:0] c36;     // {c22[35:27], c21[26:18], c12[17:9], c11[8:0]}
  wire [35:0] result;  // {y22, y21, y12, y11}

  // ---- Instantiate DUT ----
  fp9_mac dut (
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
  localparam integer EWIDTH = 4;
  localparam integer FWIDTH = 4;
  localparam integer MBITS  = 1 + FWIDTH;   // 5
  localparam integer BIAS   = 7;

  localparam [8:0] QNAN9  = 9'h0F8; // exp=1111, frac!=0
  localparam [8:0] PINF9  = 9'h0F0; // +Inf
  localparam [8:0] NINF9  = 9'h1F0; // -Inf
  localparam [8:0] PZERO9 = 9'h000; // +0
  localparam [8:0] NZERO9 = 9'h100; // -0

  // Handy FP9 finite constants (packed)
  localparam [8:0] FP9_P1_0  = {1'b0, 4'd7,  4'h0}; // +1.0
  localparam [8:0] FP9_N1_0  = {1'b1, 4'd7,  4'h0}; // -1.0
  localparam [8:0] FP9_P2_0  = {1'b0, 4'd8,  4'h0}; // +2.0
  localparam [8:0] FP9_N2_0  = {1'b1, 4'd8,  4'h0}; // -2.0
  localparam [8:0] FP9_P0_5  = {1'b0, 4'd6,  4'h0}; // +0.5
  localparam [8:0] FP9_N0_5  = {1'b1, 4'd6,  4'h0}; // -0.5
  localparam [8:0] FP9_P1_5  = {1'b0, 4'd7,  4'h8}; // +1.5
  localparam [8:0] FP9_N1_5  = {1'b1, 4'd7,  4'h8}; // -1.5
  localparam [8:0] FP9_P3_0  = {1'b0, 4'd8,  4'h8}; // +3.0
  localparam [8:0] FP9_N3_0  = {1'b1, 4'd8,  4'h8}; // -3.0
  localparam [8:0] FP9_SUBMIN= {1'b0, 4'd0,  4'h1}; // +min subnormal (FTZ→0)

  // 5-bit saturating right shift for adder alignment
  function [MBITS-1:0] rshift5; input [MBITS-1:0] x; input [3:0] sh;
    begin
      case (sh)
        4'd0: rshift5 = x;
        4'd1: rshift5 = {1'b0,       x[4:1]};
        4'd2: rshift5 = {2'b00,      x[4:2]};
        4'd3: rshift5 = {3'b000,     x[4:3]};
        4'd4: rshift5 = {4'b0000,    x[4]};
        default: rshift5 = 5'b0; // sh>=5
      endcase
    end
  endfunction

  // CLZ for a 6-bit lane (0..6; 6 means zero)
  function [3:0] clz6; input [5:0] x;
    begin
      casex (x)
        6'b1xxxxx: clz6 = 4'd0;
        6'b01xxxx: clz6 = 4'd1;
        6'b001xxx: clz6 = 4'd2;
        6'b0001xx: clz6 = 4'd3;
        6'b00001x: clz6 = 4'd4;
        6'b000001: clz6 = 4'd5;
        default:    clz6 = 4'd6;
      endcase
    end
  endfunction

  // ---- FP9 lane multiply model ----
  function [8:0] fp9_mul_lane_model;
    input [8:0] a;
    input [8:0] b;
    reg sa,sb; reg [3:0] ea,eb; reg [3:0] fa,fb;
    reg a_nan,a_inf,a_zero,b_nan,b_inf,b_zero;
    reg signp; integer esum;
    reg [4:0] Ma,Mb; reg [9:0] prod; reg carry; reg [3:0] frac4;
    begin
      sa=a[8]; ea=a[7:4]; fa=a[3:0];
      sb=b[8]; eb=b[7:4]; fb=b[3:0];

      a_nan=(ea==4'hF)&&(fa!=4'd0); a_inf=(ea==4'hF)&&(fa==4'd0); a_zero=(ea==4'd0); // FTZ
      b_nan=(eb==4'hF)&&(fb!=4'd0); b_inf=(eb==4'hF)&&(fb==4'd0); b_zero=(eb==4'd0);

      if (a_nan | b_nan | ((a_inf & b_zero) | (a_zero & b_inf))) begin
        fp9_mul_lane_model = QNAN9;
      end else if (a_inf | b_inf) begin
        fp9_mul_lane_model = {sa^sb, 4'hF, 4'h0};
      end else if (a_zero | b_zero) begin
        fp9_mul_lane_model = {(sa^sb), 8'h00}; // signed zero (XOR)
      end else begin
        signp = sa ^ sb;
        esum  = (ea + eb) - BIAS;

        Ma = {1'b1, fa};
        Mb = {1'b1, fb};
        prod  = Ma * Mb;                  // 5x5 -> 10b
        carry = prod[9];
        frac4 = carry ? prod[8:5] : prod[7:4];
        esum  = esum + (carry ? 1 : 0);

        // clamp to signed Inf on under/overflow (mirror DUT policy)
        if (esum < 0 || esum > 14) fp9_mul_lane_model = {signp, 4'hF, 4'h0};
        else                       fp9_mul_lane_model = {signp, esum[3:0], frac4};
      end
    end
  endfunction

  // ---- FP9 adder model (FTZ, guard+align, same-sign carry-right) ----
  function [8:0] fp9_add_model;
    input [8:0] a;
    input [8:0] b;
    reg sa,sb; reg [3:0] ea,eb; reg [3:0] fa,fb;
    reg isNaN_a,isNaN_b,isInf_a,isInf_b;
    reg zero_a0, zero_b0;
    reg [4:0] Ea0,Eb0; reg [4:0] Ma0,Mb0; // 1+4 mantissa
    reg swap0, sign_big_1, sign_sml_1;
    reg [4:0] E_big_1, E_sml_1, dE_1;
    reg [4:0] M_big_1, M_sml_1;
    reg diff_sign_1;
    reg [3:0] shamt;
    reg [4:0] M_sml_aligned; reg guard_bit;
    reg [5:0] big6, sml6i;
    reg [6:0] add_a, add_bi, add_b, sumW;
    reg same_sign, add_carry;
    reg [6:0] sumC; reg [4:0] E_n;
    reg [5:0] lane6; reg [3:0] lz; reg zero_af;
    reg [5:0] laneN; reg [4:0] E_l;
    reg overflow, under_or_zero;
    reg [4:0] mant_norm; reg [3:0] exp_pack; reg [3:0] frac_pack;
    reg [8:0] norm_pack;
    begin
      sa=a[8]; ea=a[7:4]; fa=a[3:0];
      sb=b[8]; eb=b[7:4]; fb=b[3:0];

      isNaN_a=(ea==4'hF)&&(fa!=4'd0); isNaN_b=(eb==4'hF)&&(fb!=4'd0);
      isInf_a=(ea==4'hF)&&(fa==4'd0); isInf_b=(eb==4'hF)&&(fb==4'd0);

      if (isNaN_a || isNaN_b) begin
        fp9_add_model = QNAN9;
      end else if (isInf_a && isInf_b) begin
        fp9_add_model = (sa==sb) ? {sa,4'hF,4'h0} : QNAN9;
      end else if (isInf_a && !isInf_b) begin
        fp9_add_model = {sa,4'hF,4'h0};
      end else if (!isInf_a && isInf_b) begin
        fp9_add_model = {sb,4'hF,4'h0};
      end else begin
        // finite path (FTZ)
        zero_a0 = (ea==4'd0);
        zero_b0 = (eb==4'd0);

        Ea0 = zero_a0 ? 5'd0 : {1'b0,ea};
        Eb0 = zero_b0 ? 5'd0 : {1'b0,eb};
        Ma0 = zero_a0 ? 5'd0 : {1'b1,fa};
        Mb0 = zero_b0 ? 5'd0 : {1'b1,fb};

        swap0       = (Ea0 < Eb0) || ((Ea0==Eb0)&&(Ma0<Mb0));
        sign_big_1  = swap0 ? sb : sa;
        sign_sml_1  = swap0 ? sa : sb;
        E_big_1     = swap0 ? Eb0 : Ea0;
        E_sml_1     = swap0 ? Ea0 : Eb0;
        M_big_1     = swap0 ? Mb0 : Ma0;
        M_sml_1     = swap0 ? Ma0 : Mb0;

        dE_1  = (E_big_1 >= E_sml_1) ? (E_big_1 - E_sml_1) : 5'd0;
        shamt = (dE_1 >= 5'd5) ? 4'd5 : dE_1[3:0];
        M_sml_aligned = rshift5(M_sml_1, shamt);
        guard_bit     = (shamt==4'd0) ? 1'b0 : M_sml_1[shamt-1];

        big6  = {M_big_1,       1'b0};
        sml6i = {M_sml_aligned, guard_bit};

        add_a = {1'b0, big6};
        add_bi= {1'b0, sml6i};
        diff_sign_1 = (sign_big_1 ^ sign_sml_1);
        add_b = diff_sign_1 ? (~add_bi + 7'd1) : add_bi;

        sumW = add_a + add_b;

        same_sign = ~diff_sign_1;
        add_carry = same_sign & sumW[6];

        sumC = add_carry ? (sumW >> 1) : sumW;
        E_n  = add_carry ? (E_big_1 + 5'd1) : E_big_1;

        lane6  = sumC[5:0];
        lz     = clz6(lane6);
        zero_af= (lz == 4'd6) | (E_n <= lz);

        laneN  = zero_af ? 6'd0 : (lane6 << lz);
        E_l    = zero_af ? 5'd0 : (E_n - lz);

        overflow      = (E_l[4]==1'b1) | (E_l > 5'd15);
        under_or_zero = (E_l == 5'd0) | (laneN == 6'd0);

        mant_norm = laneN[5:1];         // 5b (1+4)
        exp_pack  = E_l[3:0];
        frac_pack = mant_norm[3:0];

        norm_pack = {sign_big_1, exp_pack, frac_pack};

        fp9_add_model = overflow      ? {sign_big_1,4'hF,4'h0} :
                        under_or_zero ? PZERO9 :
                                        norm_pack;
      end
    end
  endfunction

  // ============================================================
  // Test vectors and golden computation
  // ============================================================
  reg [17:0]  avec [0:N-1];
  reg [17:0]  bvec [0:N-1];
  reg [35:0]  cvec [0:N-1];
  reg [35:0]  yexp [0:N-1];
  reg [8*96:1] name [0:N-1];

  integer gi;
  reg [8:0] p11,p12,p21,p22, s11,s12,s21,s22;

  // pack helpers for bench readability
  function [17:0] pack2; input [8:0] hi; input [8:0] lo; begin pack2 = {hi, lo}; end endfunction
  function [35:0] pack4; input [8:0] y22,y21,y12,y11; begin pack4 = {y22,y21,y12,y11}; end endfunction

  initial begin
    // V0: [a1=+1,a2=+1] x [b1=+2,b2=+0.5] + C=0
    name[0] = "V0: a=[1,1], b=[2,0.5], C=0";
    avec[0] = pack2(FP9_P1_0, FP9_P1_0);
    bvec[0] = pack2(FP9_P0_5, FP9_P2_0); // hi=b2=0.5, lo=b1=2.0  (order note)
    cvec[0] = pack4(PZERO9,PZERO9,PZERO9,PZERO9);

    // V1: a=[-1.5,+0.5], b=[+1.5,-1], C=[+1,-1,+1,-1]
    name[1] = "V1: mix signs, finite";
    avec[1] = pack2(FP9_P0_5, FP9_N1_5);   // a2=+0.5, a1=-1.5
    bvec[1] = pack2(FP9_N1_0, FP9_P1_5);   // b2=-1.0, b1=+1.5
    cvec[1] = pack4(FP9_N1_0,FP9_P1_0,FP9_N1_0,FP9_P1_0);

    // V2: a=[+3,-2], b=[-2,+0.5], C=[0.5,0.5,0.5,0.5]
    name[2] = "V2: finite mix 2";
    avec[2] = pack2(FP9_N2_0, FP9_P3_0);   // a2=-2, a1=+3
    bvec[2] = pack2(FP9_P0_5, FP9_N2_0);   // b2=+0.5, b1=-2
    cvec[2] = pack4(FP9_P0_5,FP9_P0_5,FP9_P0_5,FP9_P0_5);

    // V3: zeros in A, pass-through C
    name[3] = "V3: A zeros, pass C";
    avec[3] = pack2(PZERO9, PZERO9);
    bvec[3] = pack2(FP9_P1_5, FP9_P1_0);
    cvec[3] = pack4(FP9_P3_0,FP9_P0_5,FP9_P2_0,FP9_P1_0);

    // V4: Inf * finite -> Inf (sign)
    name[4] = "V4: Inf*finite => signed Inf";
    avec[4] = pack2(PINF9, FP9_N1_0);
    bvec[4] = pack2(FP9_P1_0, PINF9); // b2=+1, b1=+Inf  (so a1*Inf=NaN? no: a1=+Inf; here b1=+Inf -> a1*+Inf=+Inf)
    cvec[4] = pack4(PZERO9,PZERO9,PZERO9,PZERO9);

    // V5: Inf * 0 => NaN (mult special)
    name[5] = "V5: Inf*0 => NaN";
    avec[5] = pack2(PINF9, FP9_P1_0);
    bvec[5] = pack2(PZERO9, PZERO9);  // b2=+0, b1=+0
    cvec[5] = pack4(PZERO9,PZERO9,PZERO9,PZERO9);

    // V6: NaN anywhere => NaN
    name[6] = "V6: NaN propagation";
    avec[6] = pack2(QNAN9, FP9_P1_0);
    bvec[6] = pack2(FP9_P1_0, QNAN9);
    cvec[6] = pack4(PZERO9,PZERO9,PZERO9,PZERO9);

    // V7: finite overflow to Inf via multiplier (near-max * near-max)
    name[7] = "V7: finite -> +Inf (mul overflow)";
    // build near-max finite: exp=14 (0xE), frac=0xF
    avec[7] = pack2({1'b0,4'hE,4'hF},{1'b0,4'hE,4'hF});
    bvec[7] = pack2({1'b0,4'hE,4'hF},{1'b0,4'hE,4'hF});
    cvec[7] = pack4(PZERO9,PZERO9,PZERO9,PZERO9);

    // V8: adder exact cancellation -> 0
    name[8] = "V8: 1*2 + (-2) -> 0 (all lanes)";
    avec[8] = pack2(FP9_P1_0, FP9_P1_0);
    bvec[8] = pack2(FP9_P2_0, FP9_P2_0);
    cvec[8] = pack4(FP9_N2_0,FP9_N2_0,FP9_N2_0,FP9_N2_0);

    // V9: subnormal FTZ (acts as zero)
    name[9] = "V9: subnormal FTZ";
    avec[9] = pack2(FP9_SUBMIN, FP9_SUBMIN);
    bvec[9] = pack2(FP9_P2_0, FP9_N2_0);
    cvec[9] = pack4(PZERO9,PZERO9,PZERO9,PZERO9);

    // V10: adder overflow to signed Inf
    name[10] = "V10: adder overflow";
    avec[10] = pack2(FP9_P3_0, FP9_P3_0);
    bvec[10] = pack2(FP9_P3_0, FP9_P3_0);
    cvec[10] = pack4(PINF9,PINF9,PINF9,PINF9); // adding +Inf -> stays +Inf

    // V11: +Inf + -Inf -> NaN (adder)
    name[11] = "V11: +Inf + -Inf -> NaN";
    avec[11] = pack2(FP9_P1_0, FP9_P1_0);
    bvec[11] = pack2(FP9_P1_0, FP9_P1_0);
    cvec[11] = pack4(NINF9,NINF9,PINF9,NINF9);

    // V12: signed zeros (mult zero path keeps XOR sign), adder gives +0
    name[12] = "V12: zero mix";
    avec[12] = pack2(PZERO9, NZERO9);
    bvec[12] = pack2(NZERO9, PZERO9);
    cvec[12] = pack4(PZERO9,PZERO9,PZERO9,PZERO9);

    // V13: mixed signs, finite stable
    name[13] = "V13: finite mix 3";
    avec[13] = pack2(FP9_N1_0, FP9_P1_5);
    bvec[13] = pack2(FP9_P0_5, FP9_N1_0);
    cvec[13] = pack4(FP9_P1_0,FP9_P0_5,FP9_N1_0,FP9_P0_5);

    // V14: (-3)*(-2) + (-2) -> positive then minus -> check
    name[14] = "V14: corner finite";
    avec[14] = pack2(FP9_N3_0, FP9_N3_0);
    bvec[14] = pack2(FP9_N2_0, FP9_N2_0);
    cvec[14] = pack4(FP9_N2_0,FP9_N2_0,FP9_N2_0,FP9_N2_0);

    // V15: (-Inf)*1 + (+0.5) -> -Inf (mult special dominates)
    name[15] = "V15: -Inf dominates";
    avec[15] = pack2(NINF9, NINF9);
    bvec[15] = pack2(FP9_P1_0, FP9_P1_0);
    cvec[15] = pack4(FP9_P0_5,FP9_P0_5,FP9_P0_5,FP9_P0_5);

    // ---- Compute goldens ----
    for (gi = 0; gi < N; gi = gi + 1) begin
      // unpack lanes
      // lanes mapping: y = {y22,y21,y12,y11}
      p11 = fp9_mul_lane_model(avec[gi][ 8: 0], bvec[gi][ 8: 0]);
      p12 = fp9_mul_lane_model(avec[gi][ 8: 0], bvec[gi][17: 9]);
      p21 = fp9_mul_lane_model(avec[gi][17: 9], bvec[gi][ 8: 0]);
      p22 = fp9_mul_lane_model(avec[gi][17: 9], bvec[gi][17: 9]);

      s11 = fp9_add_model(p11, cvec[gi][ 8: 0]);
      s12 = fp9_add_model(p12, cvec[gi][17: 9]);
      s21 = fp9_add_model(p21, cvec[gi][26:18]);
      s22 = fp9_add_model(p22, cvec[gi][35:27]);

      yexp[gi] = pack4(s22,s21,s12,s11);
    end
  end

  // ============================================================
  // Drive + Check (II=1)
  // ============================================================
  integer errors, i, idx;
  initial begin
    errors = 0;

    // Init + dummy clocks
    a18 = 18'h0; b18 = 18'h0; c36 = 36'h0;
    $display("\n--- FP9 MAC (II=1, LAT=%0d) ---", LAT);
    $display("Applying %0d dummy clocks before stimulus...", DUMMY_CLKS);
    repeat (DUMMY_CLKS) @(posedge clk);

    // Stream inputs & check after LAT cycles
    for (i = 0; i < N + LAT; i = i + 1) begin
      if (i < N) begin
        a18 <= avec[i];
        b18 <= bvec[i];
        c36 <= cvec[i];
      end else begin
        a18 <= 18'h0; b18 <= 18'h0; c36 <= 36'h0; // drain
      end

      @(posedge clk);

      if (i >= LAT) begin
        idx = i - LAT;
        if (result === yexp[idx]) begin
          $display("PASS: %0s  OUT=0x%09h", name[idx], result);
        end else begin
          $display("FAIL: %0s  got 0x%09h, expected 0x%09h", name[idx], result, yexp[idx]);
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
