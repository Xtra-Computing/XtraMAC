`timescale 1ns/1ps
`default_nettype none
////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_fp12_mac — II=1, 4-cycle latency, with dummy clocks & self-check
// FP12 per lane: [11]=sign, [10:5]=exp(6), [4:0]=frac(5), bias=31
////////////////////////////////////////////////////////////////////////////////

module tb_fp12_mac;

  // ---- Parameters ----
  parameter integer LAT        = 4;    // total pipeline latency (cycles)
  parameter integer N          = 20;   // number of test vectors
  parameter integer DUMMY_CLKS = 5;    // warm-up clocks

  // ---- DUT I/O ----
  reg         clk;
  reg  [23:0] a24;     // {hi[23:12], lo[11:0]}
  reg  [11:0] b12;     // shared
  reg  [23:0] c24;     // {hi, lo}
  wire [23:0] result;  // {hi, lo}

  // ---- Instantiate DUT (rename if your module name/ports differ) ----
  fp12_mac dut (
    .clk   (clk),
    .a24   (a24),
    .b12   (b12),
    .c24   (c24),
    .result(result)
  );

  // ---- Clock: 100 MHz ----
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ============================================================
  // Reference helpers (mirror DUT behavior)
  // ============================================================
  localparam integer EWIDTH = 6;
  localparam integer FWIDTH = 5;
  localparam integer MBITS  = 1 + FWIDTH;   // 6
  localparam integer BIAS   = 31;

  localparam [11:0] QNAN12  = 12'h7F0; // qNaN exemplar (exp=all1, frac MSB=1)
  localparam [11:0] PINF12  = 12'h7E0; // +Inf
  localparam [11:0] NINF12  = 12'hFE0; // -Inf
  localparam [11:0] PZERO12 = 12'h000; // +0
  localparam [11:0] NZERO12 = 12'h800; // -0

  // rshift for 6-bit mantissa (saturating), used in adder alignment
  function [MBITS-1:0] rshift6; input [MBITS-1:0] x; input [3:0] sh;
    begin
      case (sh)
        4'd0: rshift6 = x;
        4'd1: rshift6 = {1'b0,       x[5:1]};
        4'd2: rshift6 = {2'b00,      x[5:2]};
        4'd3: rshift6 = {3'b000,     x[5:3]};
        4'd4: rshift6 = {4'b0000,    x[5:4]};
        4'd5: rshift6 = {5'b00000,   x[5]};
        default: rshift6 = 6'b0; // sh>=6
      endcase
    end
  endfunction

  // CLZ for a 7-bit lane (0..7; 7 means zero)
  function [3:0] clz7; input [6:0] x;
    begin
      casex (x)
        7'b1xxxxxx: clz7 = 4'd0;
        7'b01xxxxx: clz7 = 4'd1;
        7'b001xxxx: clz7 = 4'd2;
        7'b0001xxx: clz7 = 4'd3;
        7'b00001xx: clz7 = 4'd4;
        7'b000001x: clz7 = 4'd5;
        7'b0000001: clz7 = 4'd6;
        default:     clz7 = 4'd7;
      endcase
    end
  endfunction

  // ---- FP12 multiply lane model (matches MAC packing & specials) ----
  function [11:0] fp12_mul_lane_model;
    input [11:0] a;
    input [11:0] b;
    reg sa,sb; reg [5:0] ea,eb; reg [4:0] fa,fb;
    reg a_nan,a_inf,a_zero;
    reg b_nan,b_inf,b_zero;
    reg        signp;
    integer    esum;             // signed for range
    reg [5:0]  Ma,Mb;            // 1+5 mantissas
    reg [11:0] prod;             // 6x6
    reg        carry;
    reg [4:0]  frac5;
    begin
      sa = a[11]; ea = a[10:5]; fa = a[4:0];
      sb = b[11]; eb = b[10:5]; fb = b[4:0];

      a_nan  = (ea==6'h3F) && (fa!=5'd0);
      a_inf  = (ea==6'h3F) && (fa==5'd0);
      a_zero = (ea==6'd0);  // FTZ
      b_nan  = (eb==6'h3F) && (fb!=5'd0);
      b_inf  = (eb==6'h3F) && (fb==5'd0);
      b_zero = (eb==6'd0);

      // Specials per DUT: NaN if NaN or Inf*0; Inf if any Inf (and not Inf*0); Zero if any zero (and not Inf*0)
      if (a_nan | b_nan | ((a_inf & b_zero) | (a_zero & b_inf))) begin
        fp12_mul_lane_model = QNAN12;
      end else if (a_inf | b_inf) begin
        fp12_mul_lane_model = {sa^sb, 6'h3F, 5'd0}; // signed Inf
      end else if (a_zero | b_zero) begin
        fp12_mul_lane_model = {(sa^sb), 11'h000};   // signed zero (XOR sign), DUT zero path
      end else begin
        // finite path
        signp = sa ^ sb;
        esum  = (ea + eb) - BIAS; // before carry normalize

        Ma    = {1'b1, fa};
        Mb    = {1'b1, fb};
        prod  = Ma * Mb;          // 12b
        carry = prod[11];
        frac5 = carry ? prod[10:6] : prod[9:5];

        esum  = esum + (carry ? 1 : 0);

        // overflow/underflow => signed Inf (to mirror MAC finite overflow clamp)
        if (esum < 0 || esum > 62) begin
          fp12_mul_lane_model = {signp, 6'h3F, 5'd0};
        end else begin
          fp12_mul_lane_model = {signp, esum[5:0], frac5};
        end
      end
    end
  endfunction

  // ---- FP12 adder model (Verilog-2001; sign-aware specials; FTZ; carry-right) ----
  function [11:0] fp12_add_model;
    input [11:0] a;
    input [11:0] b;
    reg sa,sb; reg [5:0] ea,eb; reg [4:0] fa,fb;

    reg isNaN_a, isNaN_b, isInf_a, isInf_b;

    reg zero_a0, zero_b0;
    reg [6:0] Ea0,Eb0; reg [5:0] Ma0,Mb0;
    reg swap0, sign_big_1, sign_sml_1;
    reg [6:0] E_big_1, E_sml_1, dE_1;
    reg [5:0] M_big_1, M_sml_1;
    reg diff_sign_1;

    reg [3:0]    shamt;
    reg [5:0]    M_sml_aligned; reg guard_bit;
    reg [6:0]    big7, sml7i;
    reg [7:0]    add_a, add_bi, add_b, sum8;
    reg same_sign, add_carry;
    reg [7:0]    sumC; reg [6:0] E_n;
    reg [6:0]    lane7; reg [3:0] lz; reg zero_af;
    reg [6:0]    laneN; reg [6:0] E_l;
    reg overflow, under_or_zero;
    reg [5:0]    mant_norm; reg [5:0] exp_pack; reg [4:0] frac_pack;
    reg [11:0]   norm_pack;
    begin
      sa = a[11]; ea = a[10:5]; fa = a[4:0];
      sb = b[11]; eb = b[10:5]; fb = b[4:0];

      isNaN_a = (ea==6'h3F) && (fa!=5'd0);
      isNaN_b = (eb==6'h3F) && (fb!=5'd0);
      isInf_a = (ea==6'h3F) && (fa==5'd0);
      isInf_b = (eb==6'h3F) && (fb==5'd0);

      // Sign-aware specials first
      if (isNaN_a || isNaN_b) begin
        fp12_add_model = QNAN12;
      end else if (isInf_a && isInf_b) begin
        fp12_add_model = (sa==sb) ? {sa, 6'h3F, 5'd0} : QNAN12;
      end else if (isInf_a && !isInf_b) begin
        fp12_add_model = {sa, 6'h3F, 5'd0};
      end else if (!isInf_a && isInf_b) begin
        fp12_add_model = {sb, 6'h3F, 5'd0};
      end else begin
        // finite path
        zero_a0 = (ea==6'd0);
        zero_b0 = (eb==6'd0);

        Ea0 = zero_a0 ? 7'd0 : {1'b0, ea};
        Eb0 = zero_b0 ? 7'd0 : {1'b0, eb};
        Ma0 = zero_a0 ? 6'd0 : {1'b1, fa};
        Mb0 = zero_b0 ? 6'd0 : {1'b1, fb};

        swap0       = (Ea0 < Eb0) || ((Ea0 == Eb0) && (Ma0 < Mb0));
        sign_big_1  = swap0 ? sb : sa;
        sign_sml_1  = swap0 ? sa : sb;
        E_big_1     = swap0 ? Eb0 : Ea0;
        E_sml_1     = swap0 ? Ea0 : Eb0;
        M_big_1     = swap0 ? Mb0 : Ma0;
        M_sml_1     = swap0 ? Ma0 : Mb0;

        dE_1  = (E_big_1 >= E_sml_1) ? (E_big_1 - E_sml_1) : 7'd0;
        shamt = (dE_1 >= 7'd6) ? 4'd6 : dE_1[3:0];

        M_sml_aligned = rshift6(M_sml_1, shamt);
        guard_bit     = (shamt == 4'd0) ? 1'b0 : M_sml_1[shamt-1];

        big7   = {M_big_1,       1'b0};
        sml7i  = {M_sml_aligned, guard_bit};

        add_a  = {1'b0, big7};
        add_bi = {1'b0, sml7i};
        diff_sign_1 = (sign_big_1 ^ sign_sml_1);
        add_b  = diff_sign_1 ? (~add_bi + 8'd1) : add_bi;

        sum8 = add_a + add_b;

        // carry-right only when same sign
        same_sign = ~diff_sign_1;
        add_carry = same_sign & sum8[7];

        sumC  = add_carry ? (sum8 >> 1) : sum8;
        E_n   = add_carry ? (E_big_1 + 7'd1) : E_big_1;

        lane7  = sumC[6:0];
        lz     = clz7(lane7);
        zero_af= (lz == 4'd7) | (E_n <= lz);

        laneN  = zero_af ? 7'd0 : (lane7 << lz);
        E_l    = zero_af ? 7'd0 : (E_n - lz);

        overflow      = (E_l[6]==1'b1) | (E_l > 7'd63);
        under_or_zero = (E_l == 7'd0)  | (laneN == 7'd0);

        mant_norm = laneN[6:1];        // keep 6-> drop LSB to 5 for frac
        exp_pack  = E_l[5:0];
        frac_pack = mant_norm[4:0];
        norm_pack = {sign_big_1, exp_pack, frac_pack};

        fp12_add_model = overflow      ? {sign_big_1, 6'h3F, 5'd0} :
                         under_or_zero ? PZERO12 :
                                         norm_pack;
      end
    end
  endfunction

  // ============================================================
  // Test vectors and golden computation
  // ============================================================
  reg [23:0]   avec [0:N-1];
  reg [11:0]   bvec [0:N-1];
  reg [23:0]   cvec [0:N-1];
  reg [23:0]   yexp [0:N-1];
  reg [8*96:1] name [0:N-1];

  integer gi;
  reg [11:0] prod_lo, prod_hi, sum_lo, sum_hi;

  // Handy FP12 constants
  localparam [11:0] FP12_P1_0  = 12'h3E0; // +1.0
  localparam [11:0] FP12_P2_0  = 12'h400; // +2.0
  localparam [11:0] FP12_P0_5  = 12'h3C0; // +0.5 (exp=BIAS-1, frac=0)
  localparam [11:0] FP12_P1_5  = 12'h3F0; // +1.5 (frac=0x10)
  localparam [11:0] FP12_P3_0  = 12'h410; // +3.0
  localparam [11:0] FP12_N1_0  = 12'hBE0; // -1.0
  localparam [11:0] FP12_N2_0  = 12'hC00; // -2.0
  localparam [11:0] FP12_MINSUB= 12'h001; // +min subnormal

  initial begin
    // V0: [1,1]*2 + [0,0] -> [2,2]
    name[0] = "V0: [1,1]*2 + [0,0]";
    avec[0] = {FP12_P1_0, FP12_P1_0}; bvec[0] = FP12_P2_0; cvec[0] = {PZERO12,PZERO12};

    // V1: [-1.5, +0.5]*1.5 + [1,-1]
    name[1] = "V1: [-1.5,0.5]*1.5 + [1,-1]";
    avec[1] = {12'hBF0, 12'h3C0}; bvec[1] = FP12_P1_5; cvec[1] = {FP12_P1_0, FP12_N1_0};

    // V2: [3, -2] * (-2) + [0.5,0.5]
    name[2] = "V2: [3,-2]*(-2) + [0.5,0.5]";
    avec[2] = {FP12_P3_0, FP12_N2_0}; bvec[2] = FP12_N2_0; cvec[2] = {FP12_P0_5, FP12_P0_5};

    // V3: [0,0] * 1.5 + [3,0.5] -> just c
    name[3] = "V3: [0,0]*1.5 + [3,0.5]";
    avec[3] = {PZERO12,PZERO12}; bvec[3] = FP12_P1_5; cvec[3] = {FP12_P3_0, 12'h3C0};

    // V4: large*large -> +Inf (specials via finite overflow)
    name[4] = "V4: +~max * ~max + 0 -> +Inf";
    avec[4] = {12'h7DF, 12'h7DF}; bvec[4] = 12'h7DF; cvec[4] = {PZERO12,PZERO12};

    // V5: [-2,-1] * (-0.5) + [2,-2]
    name[5] = "V5: [-2,-1]*(-0.5) + [2,-2]";
    avec[5] = {FP12_N2_0, FP12_N1_0}; bvec[5] = 12'h3C0; cvec[5] = {FP12_P2_0, FP12_N2_0};

    // V6: [1.5, 3.0] * 0.5 + [-1, +1]
    name[6] = "V6: [1.5,3]*0.5 + [-1,+1]";
    avec[6] = {FP12_P1_5, FP12_P3_0}; bvec[6] = FP12_P0_5; cvec[6] = {FP12_N1_0, FP12_P1_0};

    // V7: [-0.5, +1.5] * 3.0 + [0,0]
    name[7] = "V7: [-0.5,+1.5]*3 + [0,0]";
    avec[7] = {12'hBC0, FP12_P1_5}; bvec[7] = FP12_P3_0; cvec[7] = {PZERO12,PZERO12};

    // V8: (+Inf)*1 + (-0.25) -> +Inf
    name[8] = "V8: +Inf*1 + (-0.25) -> +Inf";
    avec[8] = {PINF12, PINF12}; bvec[8] = FP12_P1_0; cvec[8] = {12'hBA0,12'hBA0}; // -0.25 ~ exp=BIAS-2 frac=0

    // V9: (-Inf)*1 + (+0.25) -> -Inf
    name[9] = "V9: -Inf*1 + (+0.25) -> -Inf";
    avec[9] = {NINF12, NINF12}; bvec[9] = FP12_P1_0; cvec[9] = {12'h3A0,12'h3A0};

    // V10: (NaN)*anything -> NaN
    name[10] = "V10: qNaN*1 + 0 -> NaN";
    avec[10] = {QNAN12, QNAN12}; bvec[10]= FP12_P1_0; cvec[10]= {PZERO12,PZERO12};

    // V11: (Inf*0) -> NaN then +c (NaN dominates)
    name[11] = "V11: (Inf*0)+c -> NaN";
    avec[11] = {PINF12, PINF12}; bvec[11]= PZERO12; cvec[11]= {FP12_P1_0,FP12_N1_0};

    // V12: exact cancellation to 0
    name[12] = "V12: 1*2 + (-2) -> 0";
    avec[12] = {FP12_P1_0, FP12_P1_0}; bvec[12] = FP12_P2_0; cvec[12] = {FP12_N2_0, FP12_N2_0};

    // V13: sub * 2 + 1 -> ~1
    name[13] = "V13: minSub*2 + 1";
    avec[13] = {FP12_MINSUB, FP12_MINSUB}; bvec[13]= FP12_P2_0; cvec[13]= {FP12_P1_0, FP12_P1_0};

    // V14: 1*(-1) + 1 -> 0
    name[14] = "V14: 1*(-1) + 1 -> 0";
    avec[14] = {FP12_P1_0, FP12_P1_0}; bvec[14]= FP12_N1_0; cvec[14]= {FP12_P1_0, FP12_P1_0};

    // V15: (+Inf)+(-Inf) -> NaN (via adder)
    name[15] = "V15: +Inf + -Inf -> NaN";
    avec[15] = {FP12_P1_0, FP12_P1_0}; bvec[15]= FP12_P1_0; cvec[15]= {PINF12, NINF12};

    // V16: (-~max)*1 + (-0.5) -> -Inf (finite overflow path)
    name[16] = "V16: (-~max)*1 + (-0.5) -> -Inf";
    avec[16] = {12'hFDF, 12'hFDF}; bvec[16]= FP12_P1_0; cvec[16]= {12'hBC0, 12'hBC0};

    // V17: 0*1 + (-0) -> +0 (model returns +0)
    name[17] = "V17: 0*1 + (-0) -> +0";
    avec[17] = {PZERO12,PZERO12}; bvec[17]= FP12_P1_0; cvec[17]= {NZERO12,NZERO12};

    // V18: 0.5*0.5 + 3.0
    name[18] = "V18: 0.5*0.5 + 3.0";
    avec[18] = {FP12_P0_5, FP12_P0_5}; bvec[18]= FP12_P0_5; cvec[18]= {FP12_P3_0, FP12_P3_0};

    // V19: (-1)*(-2) + (-2) -> 0
    name[19] = "V19: (-1)*(-2) + (-2) -> 0";
    avec[19] = {FP12_N1_0, FP12_N1_0}; bvec[19]= FP12_N2_0; cvec[19]= {FP12_N2_0, FP12_N2_0};

    // Compute goldens
    for (gi = 0; gi < N; gi = gi + 1) begin
      prod_lo = fp12_mul_lane_model(avec[gi][11:0],   bvec[gi]);
      prod_hi = fp12_mul_lane_model(avec[gi][23:12],  bvec[gi]);
      sum_lo  = fp12_add_model(prod_lo, cvec[gi][11:0]);
      sum_hi  = fp12_add_model(prod_hi, cvec[gi][23:12]);
      yexp[gi]= {sum_hi, sum_lo};
    end
  end

  // ============================================================
  // Drive + Check (II=1)
  // ============================================================
  integer errors, i, idx;
  initial begin
    errors = 0;

    // Init + dummy clocks
    a24 = 24'h0; b12 = 12'h0; c24 = 24'h0;
    $display("\n--- FP12 MAC (II=1, LAT=%0d) ---", LAT);
    $display("Applying %0d dummy clocks before stimulus...", DUMMY_CLKS);
    repeat (DUMMY_CLKS) @(posedge clk);

    // Stream inputs & check after LAT cycles
    for (i = 0; i < N + LAT; i = i + 1) begin
      if (i < N) begin
        a24 <= avec[i];
        b12 <= bvec[i];
        c24 <= cvec[i];
      end else begin
        a24 <= 24'h0; b12 <= 12'h0; c24 <= 24'h0; // drain
      end

      @(posedge clk);

      if (i >= LAT) begin
        idx = i - LAT;
        if (result === yexp[idx]) begin
          $display("PASS: %0s  OUT=0x%06h", name[idx], result);
        end else begin
          $display("FAIL: %0s  got 0x%06h, expected 0x%06h", name[idx], result, yexp[idx]);
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
