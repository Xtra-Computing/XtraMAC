`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// fp8e4m3_add -- Parameterized FP8 E4M3 adder
//   E=4, F=3, MBITS=4 (FTZ, no Infinity -- exp=1111 is NaN)
//
//   LATENCY parameter -- exact number of register stages (input -> output):
//     LATENCY = 1 : input register + combinational datapath -> wire output
//     LATENCY = 2 : input register + output register (2 regs total)
//     LATENCY = 3 : input register + 2 output registers (3 regs total)
//
//   - FTZ on inputs (exp==0 -> zero)
//   - NaN handling (exp=1111 => NaN)
//   - Same-sign: add with carry-right normalization
//   - Diff-sign: magnitude subtract (big - small), then left-normalize
//   - Overflow => saturate to max finite with sign (exp=14, frac=111)
//   - Underflow/zero => +0
// ======================================================================
module fp8e4m3_add #(
    parameter integer LATENCY = 1  // 1, 2, or 3
) (
    input  wire       clk,
    input  wire [7:0] a8,
    input  wire [7:0] b8,
    output wire [7:0] c8
);
  localparam integer EWIDTH = 4;
  localparam integer FWIDTH = 3;
  localparam integer MBITS  = 1 + FWIDTH; // 4

  localparam [7:0] QNAN8      = 8'h79;
  localparam [7:0] MAXFIN_POS = {1'b0, 4'hE, 3'b111};
  localparam [7:0] MAXFIN_NEG = {1'b1, 4'hE, 3'b111};

  // ========= Small helpers =========
  // 4-bit saturating right shift (0..4)
  function [MBITS-1:0] rshift4;
    input [MBITS-1:0] x;
    input [2:0]       sh; // 0..4
    begin
      case (sh)
        3'd0: rshift4 = x;
        3'd1: rshift4 = {1'b0,    x[3:1]};
        3'd2: rshift4 = {2'b00,   x[3:2]};
        3'd3: rshift4 = {3'b000,  x[3]};
        default: rshift4 = 4'b0000; // sh>=4
      endcase
    end
  endfunction

  // Priority-encoder CLZ for 5-bit vector
  function [2:0] clz5; // returns 0..5
    input [4:0] x;
    begin
      if      (x[4]) clz5 = 3'd0;
      else if (x[3]) clz5 = 3'd1;
      else if (x[2]) clz5 = 3'd2;
      else if (x[1]) clz5 = 3'd3;
      else if (x[0]) clz5 = 3'd4;
      else           clz5 = 3'd5;
    end
  endfunction

  // ========= Stage-1 input registers (always present) =========
  reg [7:0] a_r, b_r;
  always @(posedge clk) begin
    a_r <= a8;
    b_r <= b8;
  end

  // ========= Combinational datapath from (a_r,b_r) to c_comb =========
  reg [7:0]  c_comb;

  reg        sa, sb;
  reg [3:0]  ea, eb;
  reg [2:0]  fa, fb;

  reg isNaN_a, isNaN_b;
  reg zero_a0, zero_b0;

  reg [4:0]  Ea0, Eb0;
  reg [3:0]  Ma0, Mb0;

  reg        swap0;
  reg        sign_big, sign_sml;
  reg [4:0]  E_big, E_sml;
  reg [3:0]  M_big, M_sml;

  reg [4:0]  dE;
  reg [2:0]  shamt;
  reg [3:0]  M_sml_aligned;
  reg        guard_bit;

  reg [4:0]  big5, sml5i;

  reg        same_sign;
  reg [5:0]  sum6;
  reg [4:0]  diff5;
  reg        add_carry;
  reg [4:0]  E_n;

  reg [4:0]  lane5;
  reg [2:0]  lz5;
  reg        zero_af;
  reg [4:0]  laneN;
  reg [4:0]  E_l;

  reg        overflow, under_or_zero;
  reg [3:0]  mant_norm;
  reg [7:0]  norm_pack;

  always @* begin
    sa = a_r[7]; ea = a_r[6:3]; fa = a_r[2:0];
    sb = b_r[7]; eb = b_r[6:3]; fb = b_r[2:0];

    isNaN_a = (ea == 4'hF);
    isNaN_b = (eb == 4'hF);

    if (isNaN_a || isNaN_b) begin
      c_comb = QNAN8;
    end else begin
      zero_a0 = (ea == 4'd0);
      zero_b0 = (eb == 4'd0);

      Ea0 = zero_a0 ? 5'd0 : {1'b0, ea};
      Eb0 = zero_b0 ? 5'd0 : {1'b0, eb};
      Ma0 = zero_a0 ? 4'd0 : {1'b1, fa};
      Mb0 = zero_b0 ? 4'd0 : {1'b1, fb};

      swap0    = (Ea0 < Eb0) || ((Ea0 == Eb0) && (Ma0 < Mb0));
      sign_big = swap0 ? sb   : sa;
      sign_sml = swap0 ? sa   : sb;
      E_big    = swap0 ? Eb0  : Ea0;
      E_sml    = swap0 ? Ea0  : Eb0;
      M_big    = swap0 ? Mb0  : Ma0;
      M_sml    = swap0 ? Ma0  : Mb0;

      dE    = (E_big >= E_sml) ? (E_big - E_sml) : 5'd0;
      shamt = (dE[2:0] >= 3'd4) ? 3'd4 : dE[2:0];
      M_sml_aligned = rshift4(M_sml, shamt);
      guard_bit     = (shamt == 3'd0) ? 1'b0 : M_sml[shamt-1];

      big5  = {M_big, 1'b0};
      sml5i = {M_sml_aligned, guard_bit};

      same_sign = (sign_big == sign_sml);

      sum6      = {1'b0, big5} + {1'b0, sml5i};
      add_carry = sum6[5] & same_sign;

      diff5 = big5 - sml5i;

      E_n = same_sign ? (add_carry ? (E_big + 5'd1) : E_big) : E_big;

      lane5 = same_sign ? (add_carry ? sum6[5:1] : sum6[4:0])
                        : diff5;

      lz5     = clz5(lane5);
      zero_af = (lz5 == 3'd5) || (E_n <= {2'b00, lz5});

      laneN = zero_af ? 5'd0 : (lane5 << lz5);
      E_l   = zero_af ? 5'd0 : (E_n - {2'b00, lz5});

      overflow      = (E_l[4] == 1'b1) | (E_l > 5'd14);
      under_or_zero = (E_l == 5'd0) | (laneN == 5'd0);

      mant_norm = laneN[4:1];
      norm_pack = {sign_big, E_l[3:0], mant_norm[2:0]};

      if (overflow)           c_comb = sign_big ? MAXFIN_NEG : MAXFIN_POS;
      else if (under_or_zero) c_comb = 8'h00;
      else                    c_comb = norm_pack;
    end
  end

  // ========= Output staging =========
  generate
    if (LATENCY == 1) begin : gen_lat1
      assign c8 = c_comb;
    end else if (LATENCY == 2) begin : gen_lat2
      reg [7:0] c_reg;
      always @(posedge clk) c_reg <= c_comb;
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
