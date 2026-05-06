`timescale 1ns/1ps
`default_nettype none
////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_fp8e4m3_mac — II=1, 4-cycle latency, DSP-packed (2×2) with self-check
// FP8(E4M3) per lane: [7]=sign, [6:3]=exp(4), [2:0]=frac(3), bias=7
// Notes: No Infinity in E4M3. exp=1111 encodes NaN (any frac); overflow saturates to max finite.
////////////////////////////////////////////////////////////////////////////////

module tb_fp8e4m3_mac;

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
  fp8e4m3_mac dut (
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
  localparam integer FWIDTH = 3;
  localparam integer MBITS  = 1 + FWIDTH;   // 4
  localparam integer BIAS   = 7;

  // Specials (no Infinity)
  localparam [7:0] QNAN8      = 8'h79;                      // exp=1111, frac!=0
  localparam [7:0] PZERO8     = 8'h00;                      // +0
  localparam [7:0] NZERO8     = 8'h80;                      // -0
  localparam [7:0] MAXFIN_POS = {1'b0, 4'hE, 3'b111};       // 0x77
  localparam [7:0] MAXFIN_NEG = {1'b1, 4'hE, 3'b111};       // 0xF7

  // Handy FP8(E4M3) finite constants (bias=7)
  localparam [7:0] FP8_P1_0  = 8'h38; // +1.0  (0_0111_000)
  localparam [7:0] FP8_N1_0  = 8'hB8; // -1.0
  localparam [7:0] FP8_P2_0  = 8'h40; // +2.0  (0_1000_000)
  localparam [7:0] FP8_N2_0  = 8'hC0; // -2.0
  localparam [7:0] FP8_P0_5  = 8'h30; // +0.5  (0_0110_000)
  localparam [7:0] FP8_N0_5  = 8'hB0; // -0.5
  localparam [7:0] FP8_P1_5  = 8'h3C; // +1.5  (0_0111_100)
  localparam [7:0] FP8_N1_5  = 8'hBC; // -1.5
  localparam [7:0] FP8_P3_0  = 8'h44; // +3.0  (0_1000_100)
  localparam [7:0] FP8_N3_0  = 8'hC4; // -3.0
  localparam [7:0] FP8_SUBMIN= 8'h01; // +min subnormal (FTZ→0)

  // 4-bit saturating right shift for adder alignment
  function [MBITS-1:0] rshift4; input [MBITS-1:0] x; input [2:0] sh;
    begin
      case (sh)
        3'd0: rshift4 = x;
        3'd1: rshift4 = {1'b0,    x[3:1]};
        3'd2: rshift4 = {2'b00,   x[3:2]};
        3'd3: rshift4 = {3'b000,  x[3]};
        default: rshift4 = 4'b0; // sh>=4
      endcase
    end
  endfunction

  // CLZ for a 5-bit lane (0..5; 5 means zero)
  function [2:0] clz5; input [4:0] x;
    begin
      casex (x)
        5'b1xxxx: clz5 = 3'd0;
        5'b01xxx: clz5 = 3'd1;
        5'b001xx: clz5 = 3'd2;
        5'b0001x: clz5 = 3'd3;
        5'b00001: clz5 = 3'd4;
        default:   clz5 = 3'd5;
      endcase
    end
  endfunction

  // ---- FP8 lane multiply model (E4M3) ----
  function [7:0] fp8e4m3_mul_lane_model;
    input [7:0] a;
    input [7:0] b;
    reg sa,sb; reg [3:0] ea,eb; reg [2:0] fa,fb;
    reg a_nan,a_zero,b_nan,b_zero;
    reg signp; integer esum;
    reg [3:0] Ma,Mb; reg [7:0] prod; reg carry; reg [2:0] frac3;
    begin
      sa=a[7]; ea=a[6:3]; fa=a[2:0];
      sb=b[7]; eb=b[6:3]; fb=b[2:0];

      a_nan=(ea==4'hF); a_zero=(ea==4'd0); // FTZ
      b_nan=(eb==4'hF); b_zero=(eb==4'd0);

      if (a_nan | b_nan) begin
        fp8e4m3_mul_lane_model = QNAN8;
      end else if (a_zero | b_zero) begin
        fp8e4m3_mul_lane_model = {(sa^sb), 7'd0}; // signed zero (XOR) — adder returns +0
      end else begin
        signp = sa ^ sb;
        esum  = (ea + eb) - BIAS;

        Ma    = {1'b1, fa};          // 1+3
        Mb    = {1'b1, fb};
        prod  = Ma * Mb;              // 4x4 -> 8b
        carry = prod[7];
        // select top 3 bits after carry-right if carry
        frac3 = carry ? prod[6:4] : prod[5:3];
        esum  = esum + (carry ? 1 : 0);

        // Over/underflow => saturate to max finite with sign
        if (esum < 0 || esum > 14) fp8e4m3_mul_lane_model = signp ? MAXFIN_NEG : MAXFIN_POS;
        else                       fp8e4m3_mul_lane_model = {signp, esum[3:0], frac3};
      end
    end
  endfunction

  // ---- FP8 adder model (FTZ, guard+align, same-sign carry-right, sat on overflow) ----
  function [7:0] fp8e4m3_add_model;
    input [7:0] a;
    input [7:0] b;
    reg sa,sb; reg [3:0] ea,eb; reg [2:0] fa,fb;
    reg isNaN_a,isNaN_b;
    reg zero_a0, zero_b0;
    reg [4:0] Ea0,Eb0; reg [3:0] Ma0,Mb0; // 1+3 mantissa
    reg swap0, sign_big_1, sign_sml_1;
    reg [4:0] E_big_1, E_sml_1, dE_1;
    reg [3:0] M_big_1, M_sml_1;
    reg diff_sign_1;
    reg [2:0] shamt;
    reg [3:0] M_sml_aligned; reg guard_bit;
    reg [4:0] big5, sml5i;
    reg [5:0] sumW;
    reg same_sign, add_carry;
    reg [4:0] E_n;
    reg [4:0] lane5; reg [2:0] lz; reg zero_af;
    reg [4:0] laneN; reg [4:0] E_l;
    reg overflow, under_or_zero;
    reg [3:0] mant_norm; reg [7:0] norm_pack;
    begin
      sa=a[7]; ea=a[6:3]; fa=a[2:0];
      sb=b[7]; eb=b[6:3]; fb=b[2:0];

      isNaN_a=(ea==4'hF); isNaN_b=(eb==4'hF);

      if (isNaN_a || isNaN_b) begin
        fp8e4m3_add_model = QNAN8;
      end else begin
        // finite path (FTZ)
        zero_a0 = (ea==4'd0);
        zero_b0 = (eb==4'd0);

        Ea0 = zero_a0 ? 5'd0 : {1'b0,ea};
        Eb0 = zero_b0 ? 5'd0 : {1'b0,eb};
        Ma0 = zero_a0 ? 4'd0 : {1'b1,fa};
        Mb0 = zero_b0 ? 4'd0 : {1'b1,fb};

        swap0       = (Ea0 < Eb0) || ((Ea0==Eb0)&&(Ma0<Mb0));
        sign_big_1  = swap0 ? sb : sa;
        sign_sml_1  = swap0 ? sa : sb;
        E_big_1     = swap0 ? Eb0 : Ea0;
        E_sml_1     = swap0 ? Ea0 : Eb0;
        M_big_1     = swap0 ? Mb0 : Ma0;
        M_sml_1     = swap0 ? Ma0 : Mb0;

        dE_1  = (E_big_1 >= E_sml_1) ? (E_big_1 - E_sml_1) : 5'd0;
        shamt = (dE_1 >= 5'd4) ? 3'd4 : dE_1[2:0];
        M_sml_aligned = rshift4(M_sml_1, shamt);
        guard_bit     = (shamt==3'd0) ? 1'b0 : M_sml_1[shamt-1];

        big5  = {M_big_1,       1'b0};
        sml5i = {M_sml_aligned, guard_bit};

        // add/sub by sign
        same_sign = (sign_big_1 == sign_sml_1);
        sumW      = {1'b0,big5} + (same_sign ? {1'b0,sml5i} : (~{1'b0,sml5i}+6'd1));
        add_carry = same_sign & sumW[5];

        // exponent update and carry-right
        E_n   = add_carry ? (E_big_1 + 5'd1) : E_big_1;
        lane5 = same_sign ? (add_carry ? sumW[5:1] : sumW[4:0]) : (big5 - sml5i);

        // normalize
        lz    = clz5(lane5);
        zero_af = (lz==3'd5) || (E_n <= {2'b00,lz});
        laneN = zero_af ? 5'd0 : (lane5 << lz);
        E_l   = zero_af ? 5'd0 : (E_n - {2'b00,lz});

        overflow      = (E_l[4]==1'b1) | (E_l > 5'd14);
        under_or_zero = (E_l == 5'd0) | (laneN == 5'd0);

        mant_norm = laneN[4:1];         // 1+3
        norm_pack = {sign_big_1, E_l[3:0], mant_norm[2:0]};

        fp8e4m3_add_model = overflow      ? (sign_big_1 ? MAXFIN_NEG : MAXFIN_POS) :
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

    // V4: NaN in A * finite -> NaN
    name[4] = "V4: NaN * finite => NaN";
    avec[4] = {16'h0, pack2_8(QNAN8, FP8_N1_0)};
    bvec[4] = pack2_8(FP8_P1_0, FP8_P1_0);
    cvec[4] = pack4_8(PZERO8,PZERO8,PZERO8,PZERO8);

    // V5: finite * NaN -> NaN
    name[5] = "V5: finite * NaN => NaN";
    avec[5] = {16'h0, pack2_8(FP8_P1_0, FP8_P1_0)};
    bvec[5] = pack2_8(QNAN8, QNAN8);
    cvec[5] = pack4_8(PZERO8,PZERO8,PZERO8,PZERO8);

    // V6: NaN anywhere => NaN
    name[6] = "V6: NaN propagation";
    avec[6] = {16'h0, pack2_8(QNAN8, FP8_P1_0)};
    bvec[6] = pack2_8(FP8_P1_0, QNAN8);
    cvec[6] = pack4_8(PZERO8,PZERO8,PZERO8,PZERO8);

    // V7: finite -> saturate (mul overflow) (near-max finite)
    name[7] = "V7: finite -> saturate (mul overflow)";
    // near-max finite: exp=14 (0xE), frac=7 (0b111)
    avec[7] = {16'h0, pack2_8(MAXFIN_POS, MAXFIN_POS)};
    bvec[7] = pack2_8(MAXFIN_POS, MAXFIN_POS);
    cvec[7] = pack4_8(PZERO8,PZERO8,PZERO8,PZERO8);

    // V8: adder exact cancellation -> +0
    name[8] = "V8: 1*2 + (-2) -> 0 (all lanes)";
    avec[8] = {16'h0, pack2_8(FP8_P1_0, FP8_P1_0)};
    bvec[8] = pack2_8(FP8_P2_0, FP8_P2_0);
    cvec[8] = pack4_8(FP8_N2_0,FP8_N2_0,FP8_N2_0,FP8_N2_0);

    // V9: subnormal FTZ (acts as zero)
    name[9] = "V9: subnormal FTZ";
    avec[9] = {16'h0, pack2_8(FP8_SUBMIN, FP8_SUBMIN)};
    bvec[9] = pack2_8(FP8_P2_0, FP8_N2_0);
    cvec[9] = pack4_8(PZERO8,PZERO8,PZERO8,PZERO8);

    // V10: adder overflow -> saturate
    name[10] = "V10: adder overflow -> saturate";
    avec[10] = {16'h0, pack2_8(FP8_P3_0, FP8_P3_0)};
    bvec[10] = pack2_8(FP8_P3_0, FP8_P3_0);
    cvec[10] = pack4_8(MAXFIN_POS,MAXFIN_POS,MAXFIN_POS,MAXFIN_POS);

    // V11: NaN + finite -> NaN (adder)
    name[11] = "V11: NaN + finite -> NaN";
    avec[11] = {16'h0, pack2_8(FP8_P1_0, FP8_P1_0)};
    bvec[11] = pack2_8(FP8_P1_0, FP8_P1_0);
    cvec[11] = pack4_8(QNAN8,QNAN8,QNAN8,QNAN8);

    // V12: signed zeros in mult path, adder gives +0
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

    // V15: NaN dominates
    name[15] = "V15: NaN dominates";
    avec[15] = {16'h0, pack2_8(QNAN8, QNAN8)};
    bvec[15] = pack2_8(FP8_P1_0, FP8_P1_0);
    cvec[15] = pack4_8(FP8_P0_5,FP8_P0_5,FP8_P0_5,FP8_P0_5);

    // ---- Compute goldens ----
    for (gi = 0; gi < N; gi = gi + 1) begin
      // lanes mapping: y = {y22,y21,y12,y11}
      p11 = fp8e4m3_mul_lane_model(avec[gi][ 7: 0], bvec[gi][ 7: 0]);
      p12 = fp8e4m3_mul_lane_model(avec[gi][ 7: 0], bvec[gi][15: 8]);
      p21 = fp8e4m3_mul_lane_model(avec[gi][15: 8], bvec[gi][ 7: 0]);
      p22 = fp8e4m3_mul_lane_model(avec[gi][15: 8], bvec[gi][15: 8]);

      s11 = fp8e4m3_add_model(p11, cvec[gi][ 7: 0]);
      s12 = fp8e4m3_add_model(p12, cvec[gi][15: 8]);
      s21 = fp8e4m3_add_model(p21, cvec[gi][23:16]);
      s22 = fp8e4m3_add_model(p22, cvec[gi][31:24]);

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
    $display("\n--- FP8(E4M3) MAC (II=1, LAT=%0d) ---", LAT);
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
