`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// fp9_add (lean, same latency) — E=4, F=4, MBITS=5
// - Latency: 1 cycle (input regs only, comb output)
// - FTZ on inputs (exp==0 -> zero)
// - NaN/Inf handling (Inf+(-Inf) -> NaN)
// - Same-sign: add, carry-right normalization
// - Diff-sign: magnitude subtract (big - small), then normalize
// - Overflow => signed Inf, Underflow/zero => +0
// ======================================================================
module fp9_add (
    input  wire       clk,
    input  wire [8:0] a9,
    input  wire [8:0] b9,
    output wire [8:0] c9
);
  localparam integer EWIDTH = 4;
  localparam integer FWIDTH = 4;
  localparam integer MBITS  = 1 + FWIDTH; // 5

  // ========= Pipeline input regs (1-cycle latency) =========
  reg [8:0] a_r, b_r;
  always @(posedge clk) begin
    a_r <= a9;
    b_r <= b9;
  end

  // ========= Small helpers =========
  // 5-bit saturating right shift (0..5)
  function [MBITS-1:0] rshift5;
    input [MBITS-1:0] x;
    input [2:0]       sh; // 0..5
    begin
      case (sh)
        3'd0: rshift5 = x;
        3'd1: rshift5 = {1'b0,       x[4:1]};
        3'd2: rshift5 = {2'b00,      x[4:2]};
        3'd3: rshift5 = {3'b000,     x[4:3]};
        3'd4: rshift5 = {4'b0000,    x[4]};
        default: rshift5 = 5'b0; // sh>=5
      endcase
    end
  endfunction

  // Priority-encoder CLZ for 6-bit vector
  function [2:0] clz6; // returns 0..6
    input [5:0] x;
    begin
      if      (x[5]) clz6 = 3'd0;
      else if (x[4]) clz6 = 3'd1;
      else if (x[3]) clz6 = 3'd2;
      else if (x[2]) clz6 = 3'd3;
      else if (x[1]) clz6 = 3'd4;
      else if (x[0]) clz6 = 3'd5;
      else           clz6 = 3'd6;
    end
  endfunction

  // ========= Comb datapath (temps declared at module scope) =========
  reg [8:0]  c_comb;

  // Unpacked fields
  reg        sa, sb;
  reg [3:0]  ea, eb;
  reg [3:0]  fa, fb;

  // Classes
  reg isNaN_a, isNaN_b, isInf_a, isInf_b;
  reg zero_a0, zero_b0;

  // Finite path (FTZ)
  reg [4:0]  Ea0, Eb0;   // 5-bit exp (leading 0 for finite)
  reg [4:0]  Ma0, Mb0;   // 1+4 mant (or 0 if FTZ)

  // Magnitude order
  reg        swap0;
  reg        sign_big, sign_sml;
  reg [4:0]  E_big, E_sml;
  reg [4:0]  M_big, M_sml;

  // Align
  reg [4:0]  dE;
  reg [2:0]  shamt;          // 0..5
  reg [4:0]  M_sml_aligned;
  reg        guard_bit;

  // 6-bit lanes (mantissa+guard)
  reg [5:0]  big6, sml6i;

  // Add/Sub select
  reg        same_sign;
  reg [6:0]  sum7;           // add path
  reg [5:0]  diff6;          // subtract path
  reg        add_carry;
  reg [4:0]  E_n;

  // Normalize
  reg [5:0]  lane6;
  reg [2:0]  lz6;
  reg        zero_af;
  reg [5:0]  laneN;
  reg [4:0]  E_l;

  // Pack
  reg        overflow, under_or_zero;
  reg [4:0]  mant_norm; // 1+4
  reg [8:0]  norm_pack;

  always @* begin
    // ---------- Unpack ----------
    sa = a_r[8]; ea = a_r[7:4]; fa = a_r[3:0];
    sb = b_r[8]; eb = b_r[7:4]; fb = b_r[3:0];

    // ---------- Classes ----------
    isNaN_a = (ea==4'hF) && (fa!=4'd0);
    isNaN_b = (eb==4'hF) && (fb!=4'd0);
    isInf_a = (ea==4'hF) && (fa==4'd0);
    isInf_b = (eb==4'hF) && (fb==4'd0);

    // ---------- Specials ----------
    if (isNaN_a || isNaN_b) begin
      c_comb = 9'h0F8; // qNaN
    end else if (isInf_a && isInf_b) begin
      c_comb = (sa==sb) ? {sa,4'hF,4'h0} : 9'h0F8; // +Inf + -Inf -> NaN
    end else if (isInf_a && !isInf_b) begin
      c_comb = {sa,4'hF,4'h0};
    end else if (!isInf_a && isInf_b) begin
      c_comb = {sb,4'hF,4'h0};
    end else begin
      // ---------- Finite path (FTZ) ----------
      zero_a0 = (ea==4'd0);
      zero_b0 = (eb==4'd0);

      Ea0 = zero_a0 ? 5'd0 : {1'b0,ea};
      Eb0 = zero_b0 ? 5'd0 : {1'b0,eb};
      Ma0 = zero_a0 ? 5'd0 : {1'b1,fa};
      Mb0 = zero_b0 ? 5'd0 : {1'b1,fb};

      // ---------- Order by magnitude ----------
      swap0   = (Ea0 < Eb0) || ((Ea0==Eb0) && (Ma0 < Mb0));
      sign_big= swap0 ? sb   : sa;
      sign_sml= swap0 ? sa   : sb;
      E_big   = swap0 ? Eb0  : Ea0;
      E_sml   = swap0 ? Ea0  : Eb0;
      M_big   = swap0 ? Mb0  : Ma0;
      M_sml   = swap0 ? Ma0  : Mb0;

      // ---------- Align small ----------
      dE       = (E_big >= E_sml) ? (E_big - E_sml) : 5'd0;
      shamt    = (dE[4:0] >= 5'd5) ? 3'd5 : dE[2:0];
      M_sml_aligned = rshift5(M_sml, shamt);
      guard_bit     = (shamt==3'd0) ? 1'b0 : M_sml[shamt-1];

      big6  = {M_big, 1'b0};
      sml6i = {M_sml_aligned, guard_bit};

      // ---------- Add / Sub by sign ----------
      same_sign = (sign_big == sign_sml);

      // ADD path
      sum7      = {1'b0,big6} + {1'b0,sml6i}; // 7-bit
      add_carry = sum7[6] & same_sign;

      // SUB path (big - small)
      diff6     = big6 - sml6i;

      // Exponent pre-update
      E_n = same_sign ? (add_carry ? (E_big + 5'd1) : E_big) : E_big;

      // Select lane before normalization
      lane6 = same_sign ? (add_carry ? sum7[6:1] : sum7[5:0]) // carry-right if needed
                        : diff6;

      // ---------- Normalize ----------
      lz6     = clz6(lane6);
      zero_af = (lz6==3'd6) || (E_n <= {2'b00,lz6});

      laneN = zero_af ? 6'd0 : (lane6 << lz6);
      E_l   = zero_af ? 5'd0 : (E_n - {2'b00,lz6});

      // ---------- Overflow / Underflow ----------
      overflow      = (E_l[4]==1'b1) | (E_l > 5'd15);
      under_or_zero = (E_l == 5'd0) | (laneN == 6'd0);

      // ---------- Pack ----------
      mant_norm = laneN[5:1]; // 1+4
      norm_pack = {sign_big, E_l[3:0], mant_norm[3:0]};

      if (overflow)           c_comb = {sign_big, 4'hF, 4'h0}; // signed Inf
      else if (under_or_zero) c_comb = 9'h000;                 // +0
      else                    c_comb = norm_pack;
    end
  end

  assign c9 = c_comb; // 1-cycle latency total

endmodule