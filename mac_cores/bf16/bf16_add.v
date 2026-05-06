`timescale 1ns/1ps
`default_nettype none
// =============================================================
// bf16_add : Parameterized single-lane BF16 adder
//
//   LATENCY parameter -- exact number of register stages (input -> output):
//     LATENCY = 1 : input register + combinational datapath -> wire out
//                   (1 register, 1 cycle)
//     LATENCY = 2 : input register + output register around combinational
//                   datapath (2 registers, 2 cycles)
//     LATENCY = 3 : 3-stage pipeline:
//                     S1 REG: unpack/order/classify
//                     S2 REG: align + add/sub + LOD-normalize
//                     S3 REG: round + pack
//                   (3 registers, 3 cycles)
//
//   FTZ/DAZ, NaN/Inf rules, RN-even rounding.
// =============================================================
module bf16_add #(
    parameter LATENCY = 2  // 1, 2, or 3
)(
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    output wire [15:0] c16
);

  // ---- helpers ----
  function is_nan;
    input [15:0] x;
    begin is_nan = (x[14:7]==8'hFF) && (x[6:0]!=7'd0); end
  endfunction

  function is_inf;
    input [15:0] x;
    begin is_inf = (x[14:7]==8'hFF) && (x[6:0]==7'd0); end
  endfunction

  function is_zero;
    input [15:0] x;
    begin is_zero = (x[14:7]==8'd0); end
  endfunction

  function [3:0] clz9;
    input [8:0] x;
    begin
      casex (x)
        9'b1xxxxxxxx: clz9 = 4'd0;
        9'b01xxxxxxx: clz9 = 4'd1;
        9'b001xxxxxx: clz9 = 4'd2;
        9'b0001xxxxx: clz9 = 4'd3;
        9'b00001xxxx: clz9 = 4'd4;
        9'b000001xxx: clz9 = 4'd5;
        9'b0000001xx: clz9 = 4'd6;
        9'b00000001x: clz9 = 4'd7;
        9'b000000001: clz9 = 4'd8;
        default:      clz9 = 4'd9;
      endcase
    end
  endfunction

  function [7:0] rshift8;
    input [7:0] x;
    input [3:0] sh;
    begin
      case (sh)
        4'd0:  rshift8 = x;
        4'd1:  rshift8 = {1'b0,       x[7:1]};
        4'd2:  rshift8 = {2'b00,      x[7:2]};
        4'd3:  rshift8 = {3'b000,     x[7:3]};
        4'd4:  rshift8 = {4'b0000,    x[7:4]};
        4'd5:  rshift8 = {5'b00000,   x[7:5]};
        4'd6:  rshift8 = {6'b000000,  x[7:6]};
        4'd7:  rshift8 = {7'b0000000, x[7]};
        default: rshift8 = 8'b0;
      endcase
    end
  endfunction

  function sticky_from_norm9;
    input [8:0] x;
    input [3:0] lz;
    reg [8:0] mask;
    begin
      mask = (lz == 4'd0) ? 9'd0 : (9'h1FF >> (9 - lz));
      sticky_from_norm9 = |(x & mask);
    end
  endfunction

  // Only used for LATENCY=3
  function [8:0] norm9_from_lod;
    input [8:0] x;
    begin
      casex (x)
        9'b1xxxxxxxx: norm9_from_lod = x;
        9'b01xxxxxxx: norm9_from_lod = {x[7:0], 1'b0};
        9'b001xxxxxx: norm9_from_lod = {x[6:0], 2'b0};
        9'b0001xxxxx: norm9_from_lod = {x[5:0], 3'b0};
        9'b00001xxxx: norm9_from_lod = {x[4:0], 4'b0};
        9'b000001xxx: norm9_from_lod = {x[3:0], 5'b0};
        9'b0000001xx: norm9_from_lod = {x[2:0], 6'b0};
        9'b00000001x: norm9_from_lod = {x[1:0], 7'b0};
        9'b000000001: norm9_from_lod = {x[0],   8'b0};
        default:      norm9_from_lod = 9'd0;
      endcase
    end
  endfunction

  localparam [15:0] QNAN16 = 16'h7FC0;

  generate
  // =========================================================================
  // LATENCY = 1 or 2 : input register + (comb datapath) [+ output register]
  // =========================================================================
  if (LATENCY == 1 || LATENCY == 2) begin : gen_lat12

    // ---- Stage-1: input register ----
    reg [15:0] a_r, b_r;
    always @(posedge clk) begin
      a_r <= a16;
      b_r <= b16;
    end

    // ---- Combinational datapath ----
    wire sa0 = a_r[15];  wire [7:0] ea0 = a_r[14:7];  wire [6:0] fa0 = a_r[6:0];
    wire sb0 = b_r[15];  wire [7:0] eb0 = b_r[14:7];  wire [6:0] fb0 = b_r[6:0];

    wire a_is_nan  = is_nan(a_r);
    wire b_is_nan  = is_nan(b_r);
    wire a_is_inf  = is_inf(a_r);
    wire b_is_inf  = is_inf(b_r);
    wire a_is_zero = is_zero(a_r);
    wire b_is_zero = is_zero(b_r);

    wire special_is_nan_c =
        a_is_nan | b_is_nan | ((a_is_inf & b_is_inf) & (sa0 ^ sb0));

    wire special_is_inf_c =
        (~special_is_nan_c) &
        ((a_is_inf & ~b_is_inf & ~b_is_nan) |
         (~a_is_inf & ~a_is_nan & b_is_inf) |
         (a_is_inf & b_is_inf & ~(sa0 ^ sb0)));

    wire special_inf_sign_c =
        (a_is_inf & ~b_is_inf & ~b_is_nan) ? sa0 :
        (~a_is_inf & ~a_is_nan & b_is_inf) ? sb0 : sa0;

    wire both_zero_c = a_is_zero & b_is_zero;
    wire zero_sign_c = sa0 & sb0;

    wire [8:0] Ea0_c = a_is_zero ? 9'd0 : {1'b0, ea0};
    wire [8:0] Eb0_c = b_is_zero ? 9'd0 : {1'b0, eb0};
    wire [7:0] Ma0_c = a_is_zero ? 8'd0 : {1'b1, fa0};
    wire [7:0] Mb0_c = b_is_zero ? 8'd0 : {1'b1, fb0};

    wire swap_c = (Ea0_c < Eb0_c) || ((Ea0_c == Eb0_c) && (Ma0_c < Mb0_c));

    wire        sign_big_c  = swap_c ? sb0  : sa0;
    wire [8:0]  E_big_c     = swap_c ? Eb0_c : Ea0_c;
    wire [8:0]  E_sml_c     = swap_c ? Ea0_c : Eb0_c;
    wire [7:0]  M_big_c     = swap_c ? Mb0_c : Ma0_c;
    wire [7:0]  M_sml_c     = swap_c ? Ma0_c : Mb0_c;
    wire [8:0]  dE_c        = (E_big_c >= E_sml_c) ? (E_big_c - E_sml_c) : 9'd0;
    wire        diff_sign_c = (swap_c ? sb0 : sa0) ^ (swap_c ? sa0 : sb0);

    wire [3:0] shamt_c       = (dE_c >= 9'd8) ? 4'd8 : dE_c[3:0];
    wire [7:0] M_sml_aln_c   = rshift8(M_sml_c, shamt_c);
    wire       guard_align_c = (shamt_c == 4'd0) ? 1'b0 : M_sml_c[shamt_c-1];

    wire [8:0] big9_c   = {M_big_c, 1'b0};
    wire [8:0] sml9_i_c = {M_sml_aln_c, guard_align_c};

    wire [9:0] add_a_c   = {1'b0, big9_c};
    wire [9:0] add_b_i_c = {1'b0, sml9_i_c};

    wire [9:0] add_b_c = diff_sign_c ? (~add_b_i_c + 10'd1) : add_b_i_c;
    wire [9:0] sum10   = add_a_c + add_b_c;

    wire same_sign = ~diff_sign_c;
    wire add_carry = same_sign & sum10[9];

    wire [9:0] sumC = add_carry ? (sum10 >> 1) : sum10;
    wire [8:0] E_n  = add_carry ? (E_big_c + 9'd1) : E_big_c;

    wire [8:0] lane9   = sumC[8:0];
    wire [3:0] lz      = clz9(lane9);
    wire       zero_af = (lz == 4'd9) | (E_n <= lz);

    wire [8:0] laneN = zero_af ? 9'd0 : (lane9 << lz);
    wire [8:0] E_l   = zero_af ? 9'd0 : (E_n - lz);

    wire [7:0] mant_trunc = laneN[8:1];
    wire       guardF     = laneN[0];
    wire       stickyF    = sticky_from_norm9(lane9, lz);

    wire       lsb_bit   = mant_trunc[0];
    wire       round_inc = guardF & (stickyF | lsb_bit);

    wire [8:0] mant_round_wide = {1'b0, mant_trunc} + {8'd0, round_inc};
    wire       mant_ovf        = mant_round_wide[8];
    wire [7:0] mant_rounded    = mant_ovf ? 8'b1000_0000 : mant_round_wide[7:0];
    wire [8:0] E_rounded       = mant_ovf ? (E_l + 9'd1) : E_l;

    wire overflow_pack  = (E_rounded > 9'd255);
    wire under_or_zero  = (E_rounded == 9'd0) | (mant_rounded == 8'd0);

    wire [7:0]  exp_pack  = E_rounded[7:0];
    wire [6:0]  frac_pack = mant_rounded[6:0];
    wire [15:0] finite_out = {sign_big_c, exp_pack, frac_pack};

    wire [15:0] c_comb =
        special_is_nan_c   ? QNAN16 :
        special_is_inf_c   ? {special_inf_sign_c, 8'hFF, 7'd0} :
        both_zero_c        ? {zero_sign_c, 15'h0000} :
        overflow_pack      ? {sign_big_c, 8'hFF, 7'd0} :
        under_or_zero      ? 16'h0000 :
                             finite_out;

    if (LATENCY == 1) begin : gen_out_comb
      assign c16 = c_comb;
    end else begin : gen_out_reg
      reg [15:0] c_reg;
      always @(posedge clk) c_reg <= c_comb;
      assign c16 = c_reg;
    end

  end // gen_lat12
  // =========================================================================
  // LATENCY = 3 : full 3-stage pipeline
  //   S1 REG: unpack/order/classify
  //   S2 REG: align + add/sub + LOD-normalize
  //   S3 REG: round + pack
  // =========================================================================
  else begin : gen_lat3

    // ====== S1 combinational (before input register) ======
    wire sa0 = a16[15];  wire [7:0] ea0 = a16[14:7];  wire [6:0] fa0 = a16[6:0];
    wire sb0 = b16[15];  wire [7:0] eb0 = b16[14:7];  wire [6:0] fb0 = b16[6:0];

    wire a_is_nan  = is_nan(a16);
    wire b_is_nan  = is_nan(b16);
    wire a_is_inf  = is_inf(a16);
    wire b_is_inf  = is_inf(b16);
    wire a_is_zero = is_zero(a16);
    wire b_is_zero = is_zero(b16);

    wire special_is_nan_0 =
        a_is_nan | b_is_nan | ((a_is_inf & b_is_inf) & (sa0 ^ sb0));

    wire special_is_inf_0 =
        (~special_is_nan_0) &
        ((a_is_inf & ~b_is_inf & ~b_is_nan) |
         (~a_is_inf & ~a_is_nan & b_is_inf) |
         (a_is_inf & b_is_inf & ~(sa0 ^ sb0)));

    wire special_inf_sign_0 =
        (a_is_inf & ~b_is_inf & ~b_is_nan) ? sa0 :
        (~a_is_inf & ~a_is_nan & b_is_inf) ? sb0 : sa0;

    wire both_zero_0 = a_is_zero & b_is_zero;
    wire zero_sign_0 = sa0 & sb0;

    wire [8:0] Ea0 = a_is_zero ? 9'd0 : {1'b0, ea0};
    wire [8:0] Eb0 = b_is_zero ? 9'd0 : {1'b0, eb0};
    wire [7:0] Ma0 = a_is_zero ? 8'd0 : {1'b1, fa0};
    wire [7:0] Mb0 = b_is_zero ? 8'd0 : {1'b1, fb0};

    wire swap0 = (Ea0 < Eb0) || ((Ea0 == Eb0) && (Ma0 < Mb0));

    wire        sign_big_1  = swap0 ? sb0 : sa0;
    wire [8:0]  E_big_1     = swap0 ? Eb0 : Ea0;
    wire [8:0]  E_sml_1     = swap0 ? Ea0 : Eb0;
    wire [7:0]  M_big_1     = swap0 ? Mb0 : Ma0;
    wire [7:0]  M_sml_1     = swap0 ? Ma0 : Mb0;
    wire [8:0]  dE_1        = (E_big_1 >= E_sml_1) ? (E_big_1 - E_sml_1) : 9'd0;
    wire        diff_sign_1 = (swap0 ? sb0 : sa0) ^ (swap0 ? sa0 : sb0);

    reg sign_big_s1, diff_sign_s1;
    reg [8:0] E_big_s1, dE_s1;
    reg [7:0] M_big_s1, M_sml_s1;
    reg short_nan_s1, short_inf_s1, short_inf_sign_s1, short_zero_s1, short_zero_sign_s1;

    initial begin
      sign_big_s1 = 1'b0; diff_sign_s1 = 1'b0;
      E_big_s1 = 9'd0; dE_s1 = 9'd0; M_big_s1 = 8'd0; M_sml_s1 = 8'd0;
      short_nan_s1 = 1'b0; short_inf_s1 = 1'b0; short_inf_sign_s1 = 1'b0;
      short_zero_s1 = 1'b0; short_zero_sign_s1 = 1'b0;
    end

    always @(posedge clk) begin
      sign_big_s1  <= sign_big_1;
      diff_sign_s1 <= diff_sign_1;
      E_big_s1     <= E_big_1;
      dE_s1        <= dE_1;
      M_big_s1     <= M_big_1;
      M_sml_s1     <= M_sml_1;

      short_nan_s1       <= special_is_nan_0;
      short_inf_s1       <= special_is_inf_0;
      short_inf_sign_s1  <= special_inf_sign_0;
      short_zero_s1      <= both_zero_0;
      short_zero_sign_s1 <= zero_sign_0;
    end

    // ====== S2 combinational: align + add/sub + LOD ======
    wire [3:0] shamt_c       = (dE_s1 >= 9'd8) ? 4'd8 : dE_s1[3:0];
    wire [7:0] M_sml_aln_c   = rshift8(M_sml_s1, shamt_c);
    wire       guard_align_c = (shamt_c == 4'd0) ? 1'b0 : M_sml_s1[shamt_c-1];

    wire [8:0] big9_c        = {M_big_s1, 1'b0};
    wire [8:0] sml9_i_c      = {M_sml_aln_c, guard_align_c};

    wire [9:0] add_a_c       = {1'b0, big9_c};
    wire [9:0] add_b_i_c     = {1'b0, sml9_i_c};

    wire [9:0] add_b_xor_c = add_b_i_c ^ {10{diff_sign_s1}};
    wire [9:0] sum10_c     = add_a_c + add_b_xor_c + {{9{1'b0}}, diff_sign_s1};

    wire       add_carry_c  = (~diff_sign_s1) & sum10_c[9];
    wire [9:0] sumC_c       = add_carry_c ? (sum10_c >> 1) : sum10_c;
    wire [8:0] E_n_c        = add_carry_c ? (E_big_s1 + 9'd1) : E_big_s1;

    wire [8:0] lane9_c      = sumC_c[8:0];
    wire [3:0] lz_c         = clz9(lane9_c);
    wire [8:0] laneN_c      = norm9_from_lod(lane9_c);
    wire       lane9_zero_c = (lane9_c == 9'd0);
    wire       sticky_c     = sticky_from_norm9(lane9_c, lz_c);

    reg [8:0] laneN_s2;
    reg [8:0] E_n_s2;
    reg [3:0] lz_s2;
    reg lane9_zero_s2;
    reg sticky_s2;
    reg sign_big_s2;
    reg short_nan_s2, short_inf_s2, short_inf_sign_s2, short_zero_s2, short_zero_sign_s2;

    always @(posedge clk) begin
      laneN_s2      <= laneN_c;
      E_n_s2        <= E_n_c;
      lz_s2         <= lz_c;
      lane9_zero_s2 <= lane9_zero_c;
      sticky_s2     <= sticky_c;
      sign_big_s2   <= sign_big_s1;

      short_nan_s2       <= short_nan_s1;
      short_inf_s2       <= short_inf_s1;
      short_inf_sign_s2  <= short_inf_sign_s1;
      short_zero_s2      <= short_zero_s1;
      short_zero_sign_s2 <= short_zero_sign_s1;
    end

    // ====== S3 combinational: round / pack / select ======
    wire       under_lz_s3     = lane9_zero_s2 | (E_n_s2 <= lz_s2);
    wire [8:0] E_l_s3          = under_lz_s3 ? 9'd0 : (E_n_s2 - lz_s2);

    wire [7:0] mant_trunc_s3   = laneN_s2[8:1];
    wire       guard_s3        = laneN_s2[0];
    wire       round_inc_s3    = guard_s3 & (sticky_s2 | mant_trunc_s3[0]);

    wire [8:0] mant_round_s3   = {1'b0, mant_trunc_s3} + {8'd0, round_inc_s3};
    wire       mant_ovf_s3     = mant_round_s3[8];
    wire [7:0] mant_rounded_s3 = mant_ovf_s3 ? 8'b1000_0000 : mant_round_s3[7:0];
    wire [8:0] E_rounded_s3    = mant_ovf_s3 ? (E_l_s3 + 9'd1) : E_l_s3;

    wire       overflow_s3      = (E_rounded_s3 > 9'd255);
    wire       under_or_zero_s3 = under_lz_s3 | (E_rounded_s3 == 9'd0) | (mant_rounded_s3 == 8'd0);
    wire [15:0] finite_out_s3   = {sign_big_s2, E_rounded_s3[7:0], mant_rounded_s3[6:0]};

    wire [15:0] normal_out_s3 = overflow_s3 ? {sign_big_s2, 8'hFF, 7'd0} :
                                under_or_zero_s3 ? 16'h0000 : finite_out_s3;

    reg [15:0] c16_r;
    always @(posedge clk) begin
      if (short_nan_s2)
        c16_r <= QNAN16;
      else if (short_inf_s2)
        c16_r <= {short_inf_sign_s2, 8'hFF, 7'd0};
      else if (short_zero_s2)
        c16_r <= {short_zero_sign_s2, 15'h0000};
      else
        c16_r <= normal_out_s3;
    end

    assign c16 = c16_r;

  end // gen_lat3
  endgenerate

endmodule

`default_nettype wire
