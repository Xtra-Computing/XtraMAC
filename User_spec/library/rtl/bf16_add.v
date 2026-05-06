// =============================================================
// bf16_add
//   2-stage BF16 adder:
//     S3: unpack/order/classify (registered)
//     S4: align + add/sub + normalize + RN-even round + pack (combinational)
//   Output c16 is a WIRE (combinational from S3 regs).
//   - FTZ subnormals (inputs with exp==0 treated as zero magnitude)
//   - DAZ on output (underflow/zero -> +0)
//   - Any exp==0xFF with frac==0 => Inf; frac!=0 => NaN (qNaN canonical)
//   - +Inf + -Inf => NaN
//   - Carry-right only when same sign (matches fp16 path)
//   - RN-even rounding (guard + sticky-from-left-normalization; no alignment-sticky)
// =============================================================
module bf16_add (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    output wire [15:0] c16    // wire (comb S4)
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

  function is_zero; // FTZ for inputs: subnormals count as zero
    input [15:0] x;
    begin is_zero = (x[14:7]==8'd0); end
  endfunction

  // CLZ for 9-bit lane (0..9; 9 means zero)
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
              default:       clz9 = 4'd9; // zero
          endcase
      end
  endfunction

  // right shift for 8-bit mantissa (saturating to zero when sh>=8)
  function [7:0] rshift8;
      input [7:0] x; input [3:0] sh;
      begin
          case (sh)
              4'd0 :  rshift8 = x;
              4'd1 :  rshift8 = {1'b0,       x[7:1]};
              4'd2 :  rshift8 = {2'b00,      x[7:2]};
              4'd3 :  rshift8 = {3'b000,     x[7:3]};
              4'd4 :  rshift8 = {4'b0000,    x[7:4]};
              4'd5 :  rshift8 = {5'b00000,   x[7:5]};
              4'd6 :  rshift8 = {6'b000000,  x[7:6]};
              4'd7 :  rshift8 = {7'b0000000, x[7]};
              default: rshift8 = 8'b0; // sh>=8
          endcase
      end
  endfunction

  // sticky for bits shifted out by LEFT-normalization (like fp16 path)
  function sticky_from_norm9;
    input [8:0] x; input [3:0] lz; // 0..9
    reg [8:0] mask;
    begin
      mask = (lz==4'd0) ? 9'd0 : (9'h1FF >> (9 - lz));
      sticky_from_norm9 = |(x & mask);
    end
  endfunction

  localparam [15:0] QNAN16 = 16'h7FC0; // canonical qNaN for BF16 (exp=FF, frac[6]=1)

  // ====================== S3: unpack/order/classify (REG) ======================
  wire sa0 = a16[15];  wire [7:0] ea0 = a16[14:7];  wire [6:0] fa0 = a16[6:0];
  wire sb0 = b16[15];  wire [7:0] eb0 = b16[14:7];  wire [6:0] fb0 = b16[6:0];

  // classify
  wire a_is_nan  = is_nan(a16);
  wire b_is_nan  = is_nan(b16);
  wire a_is_inf  = is_inf(a16);
  wire b_is_inf  = is_inf(b16);
  wire a_is_zero = is_zero(a16); // FTZ (subnormals included)
  wire b_is_zero = is_zero(b16);

  wire special_is_nan_0 =
      a_is_nan | b_is_nan | ((a_is_inf & b_is_inf) & (sa0 ^ sb0)); // +Inf + -Inf

  wire special_is_inf_0 =
      (~special_is_nan_0) &
      ((a_is_inf & ~b_is_inf & ~b_is_nan) |
       (~a_is_inf & ~a_is_nan & b_is_inf) |
       (a_is_inf & b_is_inf & ~(sa0 ^ sb0)));

  wire special_inf_sign_0 =
      (a_is_inf & ~b_is_inf & ~b_is_nan) ? sa0 :
      (~a_is_inf & ~a_is_nan & b_is_inf) ? sb0 :
                                           sa0; // same-sign infs

  wire both_zero_0  = a_is_zero & b_is_zero;
  wire zero_sign_0  = (sa0 & sb0); // only -0 + -0 => -0

  // effective magnitudes (FTZ zeros)
  wire [8:0]  Ea0 = a_is_zero ? 9'd0 : {1'b0, ea0};
  wire [8:0]  Eb0 = b_is_zero ? 9'd0 : {1'b0, eb0};
  wire [7:0]  Ma0 = a_is_zero ? 8'd0 : {1'b1, fa0}; // 1.f
  wire [7:0]  Mb0 = b_is_zero ? 8'd0 : {1'b1, fb0};

  // order by magnitude
  wire swap0 = (Ea0 < Eb0) || ((Ea0 == Eb0) && (Ma0 < Mb0));

  wire        sign_big_1 = swap0 ? sb0 : sa0;
  wire        sign_sml_1 = swap0 ? sa0 : sb0;
  wire [8:0]  E_big_1    = swap0 ? Eb0 : Ea0;
  wire [8:0]  E_sml_1    = swap0 ? Ea0 : Eb0;
  wire [7:0]  M_big_1    = swap0 ? Mb0 : Ma0;
  wire [7:0]  M_sml_1    = swap0 ? Ma0 : Mb0;

  wire [8:0]  dE_1       = (E_big_1 >= E_sml_1) ? (E_big_1 - E_sml_1) : 9'd0;
  wire        diff_sign_1 = (sign_big_1 ^ sign_sml_1);

  // S3 latches
  reg        sign_big_r, diff_sign_r;
  reg [8:0]  E_big_r, dE_r;
  reg [7:0]  M_big_r, M_sml_r;
  reg        short_nan_r, short_inf_r, short_inf_sign_r, short_zero_r, short_zero_sign_r;

  initial begin
    sign_big_r=1'b0; diff_sign_r=1'b0;
    E_big_r=9'd0; dE_r=9'd0; M_big_r=8'd0; M_sml_r=8'd0;
    short_nan_r=1'b0; short_inf_r=1'b0; short_inf_sign_r=1'b0; short_zero_r=1'b0; short_zero_sign_r=1'b0;
  end

  always @(posedge clk) begin
    sign_big_r  <= sign_big_1;
    diff_sign_r <= diff_sign_1;
    E_big_r     <= E_big_1;
    dE_r        <= dE_1;
    M_big_r     <= M_big_1;
    M_sml_r     <= M_sml_1;

    short_nan_r       <= special_is_nan_0;
    short_inf_r       <= special_is_inf_0;
    short_inf_sign_r  <= special_inf_sign_0;
    short_zero_r      <= both_zero_0;
    short_zero_sign_r <= zero_sign_0;
  end

  // ====================== S4: align + add/sub + normalize + RN-even + pack (COMB) ======================
  // Align small to big (single guard; no alignment-sticky, to mirror fp16 design choice)
  wire [3:0] shamt         = (dE_r >= 9'd8) ? 4'd8 : dE_r[3:0];
  wire [7:0] M_sml_aligned = rshift8(M_sml_r, shamt);
  wire       guard_bit     = (shamt == 4'd0) ? 1'b0 : M_sml_r[shamt-1];

  // Add/sub with explicit guard fed into LSB
  wire [8:0] big9   = {M_big_r,        1'b0};
  wire [8:0] sml9_i = {M_sml_aligned,  guard_bit};

  wire [9:0] add_a  = {1'b0, big9};
  wire [9:0] add_bi = {1'b0, sml9_i};
  wire [9:0] add_b  = diff_sign_r ? (~add_bi + 10'd1) : add_bi;

  wire [9:0] sum10  = add_a + add_b;

  wire same_sign = ~diff_sign_r;
  wire add_carry = same_sign & sum10[9];

  // Normalize initial carry (right shift by 1 if carry & same-sign)
  wire [9:0] sumC  = add_carry ? (sum10 >> 1) : sum10;
  wire [8:0] E_n   = add_carry ? (E_big_r + 9'd1) : E_big_r;

  // Left-normalize
  wire [8:0] lane9   = sumC[8:0];
  wire [3:0] lz      = clz9(lane9);
  wire       zero_af = (lz == 4'd9) | (E_n <= lz);

  wire [8:0] laneN   = zero_af ? 9'd0 : (lane9 << lz);
  wire [8:0] E_l     = zero_af ? 9'd0 : (E_n - lz);

  // RN-even (guard/sticky derived after left-normalization, mirroring fp16)
  wire [7:0] mant_trunc = laneN[8:1];  // 1.f -> [8:1] keeps 8 bits (hidden+7 frac)
  wire       guardF     = laneN[0];
  wire       stickyF    = sticky_from_norm9(lane9, lz);

  wire       lsb_bit    = mant_trunc[0];
  wire       round_inc  = guardF & (stickyF | lsb_bit);

  wire [8:0] mant_round_wide = {1'b0, mant_trunc} + {8'd0, round_inc};
  wire       mant_ovf        = mant_round_wide[8];
  wire [7:0] mant_rounded    = mant_ovf ? 8'b1000_0000 : mant_round_wide[7:0];
  wire [8:0] E_rounded       = mant_ovf ? (E_l + 9'd1) : E_l;

  // Pack / special selections
  wire overflow_pack  = (E_rounded > 9'd255);
  wire under_or_zero  = (E_rounded == 9'd0) | (mant_rounded == 8'd0);

  wire [7:0] exp_pack  = E_rounded[7:0];
  wire [6:0] frac_pack = mant_rounded[6:0];
  wire [15:0] finite_out = {sign_big_r, exp_pack, frac_pack};

  assign c16 =
      short_nan_r       ? QNAN16 :
      short_inf_r       ? {short_inf_sign_r, 8'hFF, 7'd0} :
      short_zero_r      ? {short_zero_sign_r, 15'h0000} :
      overflow_pack     ? {sign_big_r, 8'hFF, 7'd0} :    // ±Inf on overflow
      under_or_zero     ? 16'h0000 :                     // DAZ → +0
                          finite_out;

endmodule