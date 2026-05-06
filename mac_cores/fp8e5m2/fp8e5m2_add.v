`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// fp8e5m2_add -- Parameterized single-lane FP8(E5M2) adder
//   E=5, F=2, MBITS=3, bias=15
//   HAS Infinity (exp=0x1F, frac=0) and NaN (exp=0x1F, frac!=0)
//   FTZ on inputs (exp==0 -> zero)
//
//   LATENCY parameter -- exact number of register stages (input -> output):
//     LATENCY = 1 : input register + combinational datapath -> wire output
//     LATENCY = 2 : input register + mid register (post-datapath) -> wire
//                   output [2 registers total, 2 cycles]
//     LATENCY = 3 : input register + mid register + output register
//                   [3 registers total, 3 cycles]
// ======================================================================
module fp8e5m2_add #(
    parameter integer LATENCY = 1   // 1, 2, or 3
) (
    input  wire       clk,
    input  wire [7:0] a8,
    input  wire [7:0] b8,
    output wire [7:0] c8
);

  localparam integer EWIDTH = 5;
  localparam integer FWIDTH = 2;
  localparam integer MBITS  = 1 + FWIDTH; // 3

  // ========= Pipeline input regs (always present) =========
  reg [7:0] a_r, b_r;
  always @(posedge clk) begin
    a_r <= a8;
    b_r <= b8;
  end

  // ========= Small helpers =========
  // 3-bit saturating right shift (0..3)
  function [MBITS-1:0] rshift3;
    input [MBITS-1:0] x;
    input [1:0]       sh; // 0..3
    begin
      case (sh)
        2'd0: rshift3 = x;
        2'd1: rshift3 = {1'b0,   x[2:1]};
        2'd2: rshift3 = {2'b00,  x[2]};
        default: rshift3 = 3'b000; // sh>=3
      endcase
    end
  endfunction

  // Priority-encoder CLZ for 4-bit vector
  function [1:0] clz4;
    input [3:0] x;
    begin
      if      (x[3]) clz4 = 2'd0;
      else if (x[2]) clz4 = 2'd1;
      else if (x[1]) clz4 = 2'd2;
      else if (x[0]) clz4 = 2'd3;
      else           clz4 = 2'd3; // treat zero as 3 (gated separately)
    end
  endfunction

  // ========= Comb datapath (from input regs a_r/b_r to c_comb) =========
  reg [7:0]  c_comb;

  // Unpacked fields
  reg        sa, sb;
  reg [4:0]  ea, eb;
  reg [1:0]  fa, fb;

  // Classes
  reg isNaN_a, isNaN_b, isInf_a, isInf_b;
  reg zero_a0, zero_b0;

  // Finite path (FTZ)
  reg [5:0]  Ea0, Eb0;   // 6-bit exp (leading 0 for finite)
  reg [2:0]  Ma0, Mb0;   // 1+2 mant (or 0 if FTZ)

  // Magnitude order
  reg        swap0;
  reg        sign_big, sign_sml;
  reg [5:0]  E_big, E_sml;
  reg [2:0]  M_big, M_sml;

  // Align
  reg [5:0]  dE;
  reg [1:0]  shamt;          // 0..3
  reg [2:0]  M_sml_aligned;
  reg        guard_bit;

  // 4-bit lanes (mantissa+guard)
  reg [3:0]  big4, sml4i;

  // Add/Sub select
  reg        same_sign;
  reg [4:0]  sum5;           // add path
  reg [3:0]  diff4;          // subtract path
  reg        add_carry;
  reg [5:0]  E_n;

  // Normalize
  reg [3:0]  lane4;
  reg [1:0]  lz4;
  reg        zero_af;
  reg [3:0]  laneN;
  reg [5:0]  E_l;

  // Pack
  reg        overflow, under_or_zero;
  reg [2:0]  mant_norm; // 1+2
  reg [7:0]  norm_pack;

  always @* begin
    // ---------- Unpack ----------
    sa = a_r[7]; ea = a_r[6:2]; fa = a_r[1:0];
    sb = b_r[7]; eb = b_r[6:2]; fb = b_r[1:0];

    // ---------- Classes ----------
    isNaN_a = (ea==5'h1F) && (fa!=2'd0);
    isNaN_b = (eb==5'h1F) && (fb!=2'd0);
    isInf_a = (ea==5'h1F) && (fa==2'd0);
    isInf_b = (eb==5'h1F) && (fb==2'd0);

    // ---------- Specials ----------
    if (isNaN_a || isNaN_b) begin
      c_comb = 8'h7D; // qNaN
    end else if (isInf_a && isInf_b) begin
      c_comb = (sa==sb) ? {sa,5'h1F,2'b00} : 8'h7D; // +Inf + -Inf -> NaN
    end else if (isInf_a && !isInf_b) begin
      c_comb = {sa,5'h1F,2'b00};
    end else if (!isInf_a && isInf_b) begin
      c_comb = {sb,5'h1F,2'b00};
    end else begin
      // ---------- Finite path (FTZ) ----------
      zero_a0 = (ea==5'd0);
      zero_b0 = (eb==5'd0);

      Ea0 = zero_a0 ? 6'd0 : {1'b0,ea};
      Eb0 = zero_b0 ? 6'd0 : {1'b0,eb};
      Ma0 = zero_a0 ? 3'd0 : {1'b1,fa};
      Mb0 = zero_b0 ? 3'd0 : {1'b1,fb};

      // ---------- Order by magnitude ----------
      swap0   = (Ea0 < Eb0) || ((Ea0==Eb0) && (Ma0 < Mb0));
      sign_big= swap0 ? sb   : sa;
      sign_sml= swap0 ? sa   : sb;
      E_big   = swap0 ? Eb0  : Ea0;
      E_sml   = swap0 ? Ea0  : Eb0;
      M_big   = swap0 ? Mb0  : Ma0;
      M_sml   = swap0 ? Ma0  : Mb0;

      // ---------- Align small ----------
      dE       = (E_big >= E_sml) ? (E_big - E_sml) : 6'd0;
      shamt    = (dE >= 6'd3) ? 2'd3 : dE[1:0];
      M_sml_aligned = rshift3(M_sml, shamt);
      guard_bit     = (shamt==2'd0) ? 1'b0 : M_sml[shamt-1];

      big4  = {M_big,       1'b0};
      sml4i = {M_sml_aligned, guard_bit};

      // ---------- Add / Sub by sign ----------
      same_sign = (sign_big == sign_sml);

      // ADD path
      sum5      = {1'b0,big4} + {1'b0,sml4i}; // 5-bit
      add_carry = sum5[4] & same_sign;

      // SUB path (big - small)
      diff4     = big4 - sml4i;

      // Exponent pre-update
      E_n = same_sign ? (add_carry ? (E_big + 6'd1) : E_big) : E_big;

      // Select lane before normalization
      lane4 = same_sign ? (add_carry ? sum5[4:1] : sum5[3:0]) // carry-right if needed
                        : diff4;

      // ---------- Normalize ----------
      lz4     = clz4(lane4);
      zero_af = (lane4==4'd0) || (E_n <= {4'd0,lz4}); // if shift would wipe exponent

      laneN = zero_af ? 4'd0 : (lane4 << lz4);
      E_l   = zero_af ? 6'd0 : (E_n - {4'd0,lz4});

      // ---------- Overflow / Underflow ----------
      overflow      = (E_l[5]==1'b1) | (E_l > 6'd31);
      under_or_zero = (E_l == 6'd0) | (laneN == 4'd0);

      // ---------- Pack ----------
      mant_norm = laneN[3:1]; // 1+2
      norm_pack = {sign_big, E_l[4:0], mant_norm[1:0]};

      if (overflow)           c_comb = {sign_big, 5'h1F, 2'b00}; // signed Inf
      else if (under_or_zero) c_comb = 8'h00;                    // +0
      else                    c_comb = norm_pack;
    end
  end

  // ========= Output mux: LATENCY=1 wire, LATENCY=2 one extra reg,
  //                       LATENCY=3 two extra regs (= 3 total regs) =========
  generate
    if (LATENCY == 1) begin : gen_lat1
      assign c8 = c_comb;
    end else if (LATENCY == 2) begin : gen_lat2
      reg [7:0] c_reg;
      always @(posedge clk) begin
        c_reg <= c_comb;
      end
      assign c8 = c_reg;
    end else begin : gen_lat3
      reg [7:0] c_reg1, c_reg2;
      always @(posedge clk) begin
        c_reg1 <= c_comb;
        c_reg2 <= c_reg1;
      end
      assign c8 = c_reg2;
    end
  endgenerate

endmodule

`default_nettype wire
