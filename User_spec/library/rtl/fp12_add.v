`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp12_add (Verilog-2001; sign-aware specials; FTZ; same-sign carry-right)
// - One internal register stage to mirror bf16_add timing.
// - Overflow => signed Inf (dominant sign)
// - Underflow/zero => +0 (change to preserve sign by replacing with {sign_big_1, 11'h000})
// =============================================================
module fp12_add (
    input  wire        clk,
    input  wire [11:0] a12,
    input  wire [11:0] b12,
    output wire [11:0] c12
);
  localparam integer EWIDTH = 6;
  localparam integer FWIDTH = 5;
  localparam integer MBITS  = 1 + FWIDTH; // 6

  // Stage reg (S3)
  reg [11:0] a_r, b_r;
  always @(posedge clk) begin
    a_r <= a12;
    b_r <= b12;
  end

  // ---------- Helpers ----------
  function [MBITS-1:0] rshift_m;
    input [MBITS-1:0] x;
    input [3:0]       sh; // 0..6
    begin
      case (sh)
        4'd0: rshift_m = x;
        4'd1: rshift_m = {1'b0,        x[MBITS-1:1]};
        4'd2: rshift_m = {2'b00,       x[MBITS-1:2]};
        4'd3: rshift_m = {3'b000,      x[MBITS-1:3]};
        4'd4: rshift_m = {4'b0000,     x[MBITS-1:4]};
        4'd5: rshift_m = {5'b00000,    x[MBITS-1:5]};
        default: rshift_m = {MBITS{1'b0}}; // sh>=6
      endcase
    end
  endfunction

  function [3:0] clz7;
    input [6:0] x;
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

  // ---------- Combinational S4 ----------
  reg [11:0] c_comb;

  // All temps declared at module scope (Verilog-2001 compliant)
  reg                 sa, sb;
  reg [EWIDTH-1:0]    ea, eb;
  reg [FWIDTH-1:0]    fa, fb;

  reg isNaN_a, isNaN_b, isInf_a, isInf_b;

  reg                 zero_a0, zero_b0;
  reg [EWIDTH:0]      Ea0, Eb0;          // 7-bit exponents (with leading 0)
  reg [MBITS-1:0]     Ma0, Mb0;          // 6-bit mantissas (1+5)

  reg                 swap0, sign_big_1, sign_sml_1;
  reg [EWIDTH:0]      E_big_1, E_sml_1, dE_1;
  reg [MBITS-1:0]     M_big_1, M_sml_1;
  reg                 diff_sign_1;

  reg [3:0]           shamt;
  reg [MBITS-1:0]     M_sml_aligned; 
  reg                 guard_bit;
  reg [MBITS:0]       bigX, smlXi;       // 7-bit mant+guard

  reg [MBITS+1:0]     add_a, add_bi, add_b, sumW; // width 8
  reg                 same_sign, add_carry;
  reg [MBITS+1:0]     sumC; 
  reg [EWIDTH:0]      E_n;

  reg [MBITS:0]       lane;
  reg [3:0]           lz;
  reg                 zero_af;

  reg [MBITS:0]       laneN; 
  reg [EWIDTH:0]      E_l;

  reg                 overflow, under_or_zero;
  reg [MBITS-1:0]     mant_norm;
  reg [EWIDTH-1:0]    exp_pack;
  reg [FWIDTH-1:0]    frac_pack;
  reg [11:0]          norm_pack;

  always @* begin
    // unpack
    sa = a_r[11]; ea = a_r[10:5]; fa = a_r[4:0];
    sb = b_r[11]; eb = b_r[10:5]; fb = b_r[4:0];

    // classes
    isNaN_a = (ea == {EWIDTH{1'b1}}) && (fa != {FWIDTH{1'b0}});
    isNaN_b = (eb == {EWIDTH{1'b1}}) && (fb != {FWIDTH{1'b0}});
    isInf_a = (ea == {EWIDTH{1'b1}}) && (fa == {FWIDTH{1'b0}});
    isInf_b = (eb == {EWIDTH{1'b1}}) && (fb == {FWIDTH{1'b0}});

    // Sign-aware specials
    if (isNaN_a || isNaN_b) begin
      c_comb = {1'b0, {EWIDTH{1'b1}}, {1'b1, {FWIDTH-1{1'b0}}}}; // qNaN exemplar
    end
    else if (isInf_a && isInf_b) begin
      c_comb = (sa == sb) ? {sa, {EWIDTH{1'b1}}, {FWIDTH{1'b0}}}
                          : {1'b0, {EWIDTH{1'b1}}, {1'b1, {FWIDTH-1{1'b0}}}}; // NaN
    end
    else if (isInf_a && !isInf_b) begin
      c_comb = {sa, {EWIDTH{1'b1}}, {FWIDTH{1'b0}}};
    end
    else if (!isInf_a && isInf_b) begin
      c_comb = {sb, {EWIDTH{1'b1}}, {FWIDTH{1'b0}}};
    end
    else begin
      // ---------- Normal finite path ----------
      zero_a0 = (ea == {EWIDTH{1'b0}});
      zero_b0 = (eb == {EWIDTH{1'b0}});

      Ea0 = zero_a0 ? { (EWIDTH+1){1'b0} } : {1'b0, ea};
      Eb0 = zero_b0 ? { (EWIDTH+1){1'b0} } : {1'b0, eb};
      Ma0 = zero_a0 ? {MBITS{1'b0}}        : {1'b1, fa};
      Mb0 = zero_b0 ? {MBITS{1'b0}}        : {1'b1, fb};

      // order by magnitude
      swap0       = (Ea0 < Eb0) || ((Ea0 == Eb0) && (Ma0 < Mb0));
      sign_big_1  = swap0 ? sb : sa;
      sign_sml_1  = swap0 ? sa : sb;
      E_big_1     = swap0 ? Eb0 : Ea0;
      E_sml_1     = swap0 ? Ea0 : Eb0;
      M_big_1     = swap0 ? Mb0 : Ma0;
      M_sml_1     = swap0 ? Ma0 : Mb0;

      // align small (saturate at 6)
      dE_1  = (E_big_1 >= E_sml_1) ? (E_big_1 - E_sml_1) : { (EWIDTH+1){1'b0} };
      shamt = (dE_1 >= 7'd6) ? 4'd6 : dE_1[3:0];

      M_sml_aligned = rshift_m(M_sml_1, shamt);
      guard_bit     = (shamt == 4'd0) ? 1'b0 : M_sml_1[shamt-1];

      bigX   = {M_big_1,        1'b0}; // 7b
      smlXi  = {M_sml_aligned,  guard_bit};

      add_a  = {1'b0, bigX};
      add_bi = {1'b0, smlXi};
      diff_sign_1 = (sign_big_1 ^ sign_sml_1);
      add_b  = diff_sign_1 ? ((~add_bi) + {{(MBITS+1){1'b0}} + 1'b1}) : add_bi;

      sumW = add_a + add_b;

      // carry-right only when same sign
      same_sign = ~diff_sign_1;
      add_carry = same_sign & sumW[MBITS+1];

      sumC = add_carry ? (sumW >> 1) : sumW;
      E_n  = add_carry ? (E_big_1 + {{EWIDTH{1'b0}},1'b1}) : E_big_1;

      lane   = sumC[MBITS:0];           // 7-bit lane
      lz     = clz7(lane);
      zero_af= (lz == 4'd7) | (E_n <= lz);

      laneN  = zero_af ? { (MBITS+1){1'b0} } : (lane << lz);
      E_l    = zero_af ? { (EWIDTH+1){1'b0} } : (E_n - lz);

      // overflow/underflow
      overflow      = (E_l[EWIDTH] == 1'b1) | (E_l > {1'b0, {EWIDTH{1'b1}}});
      under_or_zero = (E_l == { (EWIDTH+1){1'b0} }) | (laneN == { (MBITS+1){1'b0} });

      mant_norm = laneN[MBITS:1];
      exp_pack  = E_l[EWIDTH-1:0];
      frac_pack = mant_norm[FWIDTH-1:0];
      norm_pack = {sign_big_1, exp_pack, frac_pack};

      // Final selection:
      if (overflow)           c_comb = {sign_big_1, {EWIDTH{1'b1}}, {FWIDTH{1'b0}}}; // signed Inf
      else if (under_or_zero) c_comb = 12'h000;                                       // +0 (change if you want signed zero)
      else                    c_comb = norm_pack;
    end
  end

  assign c12 = c_comb;

endmodule

`default_nettype wire
