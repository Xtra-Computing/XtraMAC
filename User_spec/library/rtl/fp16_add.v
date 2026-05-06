// =============================================================
// fp16_add : 3-stage FP16 add/normalize/round/pack  (latency = 3)
//   - Stage A0: register inputs & classify
//   - Stage A1: align + add (variable shift + guard)
//   - Stage A2: normalize + RN-even round + pack
//   - FTZ/DAZ, NaN/Inf, signed zeros, RN-even
// =============================================================
module fp16_add (
    input  wire        clk,
    input  wire [15:0] x16,
    input  wire [15:0] y16,
    output reg  [15:0] result
);

  // -------- Small helpers (FTZ: subnormals count as zero) --------
  function is_nan;  input [15:0] x; begin is_nan = (x[14:10]==5'h1F) && (x[9:0]!=10'd0); end endfunction
  function is_inf;  input [15:0] x; begin is_inf = (x[14:10]==5'h1F) && (x[9:0]==10'd0); end endfunction
  function is_zero; input [15:0] x; begin is_zero = (x[14:10]==5'd0); end endfunction

  // [OPT] CLZ(12) via two-level tree
  function [2:0] clz6; // 0..6
      input [5:0] x;
      begin
          casex (x)
              6'b1xxxxx: clz6 = 3'd0;
              6'b01xxxx: clz6 = 3'd1;
              6'b001xxx: clz6 = 3'd2;
              6'b0001xx: clz6 = 3'd3;
              6'b00001x: clz6 = 3'd4;
              6'b000001: clz6 = 3'd5;
              default  : clz6 = 3'd6;
          endcase
      end
  endfunction

  function [3:0] clz12;
      input [11:0] x;
      reg [5:0] hi, lo;
      begin
          hi = x[11:6];
          lo = x[5:0];
          clz12 = (hi != 6'd0) ? {1'b0, clz6(hi)} : (4'd6 + {1'b0, clz6(lo)});
      end
  endfunction

  // [OPT] sticky from left-normalization via mask and reduce
  function sticky_from_norm;
    input [11:0] x; input [3:0] lz; // 0..12
    reg [11:0] mask;
    begin
      mask = (lz == 4'd0) ? 12'd0 : (12'hFFF >> (12 - lz));
      sticky_from_norm = |(x & mask);
    end
  endfunction

  localparam [15:0] QNAN16 = 16'h7E00;

  // ===============================================
  // Unpack and classify (combinational)
  // ===============================================
  wire        sa0 = x16[15];
  wire [4:0]  ea0 = x16[14:10];
  wire [9:0]  fa0 = x16[9:0];

  wire        sb0 = y16[15];
  wire [4:0]  eb0 = y16[14:10];
  wire [9:0]  fb0 = y16[9:0];

  // Classify inputs (FTZ for zeros)
  wire p_is_nan0  = (ea0==5'h1F) && (fa0!=10'd0);
  wire p_is_inf0  = (ea0==5'h1F) && (fa0==10'd0);
  wire p_is_zero0 = (ea0==5'd0);
  wire c_is_nan0  = is_nan(y16);
  wire c_is_inf0  = is_inf(y16);
  wire c_is_zero0 = is_zero(y16);

  // ---- Special-combination short-circuits ----
  wire special_is_nan =
      p_is_nan0 | c_is_nan0 |
      ((p_is_inf0 & c_is_inf0) && (sa0 ^ sb0)); // +Inf + -Inf

  wire special_is_inf =
      (~special_is_nan) &
      ((p_is_inf0 & ~c_is_inf0 & ~c_is_nan0) |
       (~p_is_inf0 & ~p_is_nan0 & c_is_inf0) |
       (p_is_inf0 & c_is_inf0 & ~(sa0 ^ sb0)));

  wire special_inf_sign =
      (p_is_inf0 & ~c_is_inf0 & ~c_is_nan0) ? sa0 :
      (~p_is_inf0 & ~p_is_nan0 & c_is_inf0) ? sb0 :
                                              sa0 ;

  wire both_zero   = p_is_zero0 & c_is_zero0;
  wire zero_sign   = (sa0 & sb0); // both -0 → -0, else +0

  // choose magnitudes (big/small), FTZ zeros
  wire [5:0]  Ea0_eff = p_is_zero0 ? 6'd0 : {1'b0, ea0};
  wire [5:0]  Eb0_eff = c_is_zero0 ? 6'd0 : {1'b0, eb0};
  wire [10:0] Ma0_eff = p_is_zero0 ? 11'd0 : {1'b1, fa0};
  wire [10:0] Mb0_eff = c_is_zero0 ? 11'd0 : {1'b1, fb0};

  wire swap0 = (Ea0_eff < Eb0_eff) || ((Ea0_eff == Eb0_eff) && (Ma0_eff < Mb0_eff));

  wire        sign_big_1 = swap0 ? sb0 : sa0;
  wire        sign_sml_1 = swap0 ? sa0 : sb0;
  wire [5:0]  E_big_1    = swap0 ? Eb0_eff : Ea0_eff;
  wire [5:0]  E_sml_1    = swap0 ? Ea0_eff : Eb0_eff;
  wire [10:0] M_big_1    = swap0 ? Mb0_eff : Ma0_eff;
  wire [10:0] M_sml_1    = swap0 ? Ma0_eff : Mb0_eff;

  wire [5:0]  dE_1       = (E_big_1 >= E_sml_1) ? (E_big_1 - E_sml_1) : 6'd0;
  wire        diff_sign_1 = (sign_big_1 ^ sign_sml_1);

  // =========================================================
  //                Adder Stage A1 (ALIGN + ADD)
  // =========================================================
  reg        sign_big_r, diff_sign_r;
  reg [5:0]  E_big_r, dE_r;
  reg [10:0] M_big_r, M_sml_r;
  reg        short_nan_r, short_inf_r, short_inf_sign_r, short_zero_r, short_zero_sign_r;

  initial begin
    sign_big_r=0; diff_sign_r=0; E_big_r=0; dE_r=0; M_big_r=0; M_sml_r=0;
    short_nan_r=0; short_inf_r=0; short_inf_sign_r=0; short_zero_r=0; short_zero_sign_r=0;
  end

  // latch inputs to A1 (Stage 1)
  always @(posedge clk) begin
    short_nan_r       <= special_is_nan;
    short_inf_r       <= special_is_inf;
    short_inf_sign_r  <= special_inf_sign;
    short_zero_r      <= both_zero;
    short_zero_sign_r <= zero_sign;

    sign_big_r  <= sign_big_1;
    diff_sign_r <= diff_sign_1;
    E_big_r     <= E_big_1;
    dE_r        <= dE_1;
    M_big_r     <= M_big_1;
    M_sml_r     <= M_sml_1;
  end

  // A1 combinational: align + add → register
  wire [3:0]  shamt         = (dE_r >= 6'd11) ? 4'd11 : dE_r[3:0];
  wire [11:0] sml_ext       = {M_sml_r, 1'b0};
  wire [11:0] sml_shifted   = (shamt >= 4'd11) ? 12'd0 : (sml_ext >> shamt);
  wire        guard_align   = sml_shifted[0];
  wire [10:0] M_sml_aligned = sml_shifted[11:1];

  wire [11:0] big12   = {M_big_r,        1'b0};
  wire [11:0] sml12_i = {M_sml_aligned,  guard_align};

  wire [12:0] add_a   = {1'b0, big12};
  wire [12:0] add_b_i = {1'b0, sml12_i};
  wire [12:0] add_b   = diff_sign_r ? (~add_b_i + 13'd1) : add_b_i;
  wire [12:0] sum13   = add_a + add_b;

  wire same_sign = ~diff_sign_r;
  wire add_carry = same_sign & sum13[12];

  wire [12:0] sumC = add_carry ? (sum13 >> 1) : sum13;
  wire [5:0]  E_n  = add_carry ? (E_big_r + 6'd1) : E_big_r;

  // =========================================================
  //                Adder Stage A2 (NORMALIZE + ROUND + PACK)
  // =========================================================
  wire [11:0] lane12  = sumC[11:0];
  wire [3:0]  lz      = clz12(lane12);
  wire        zero_af = (lz == 4'd12) | (E_n <= lz);

  wire [11:0] laneN   = zero_af ? 12'd0 : (lane12 << lz);
  wire [5:0]  E_l     = zero_af ? 6'd0  : (E_n - lz);

  // RN-even rounding
  wire [10:0] mant_trunc = laneN[11:1];
  wire        guardF     = laneN[0];
  wire        stickyF    = sticky_from_norm(lane12, lz);

  wire        lsb_bit    = mant_trunc[0];
  wire        round_inc  = guardF & (stickyF | lsb_bit);

  wire [11:0] mant_round_wide = {1'b0, mant_trunc} + {11'd0, round_inc};
  wire        mant_ovf        = mant_round_wide[11];
  wire [10:0] mant_rounded    = mant_ovf ? 11'b10000000000 : mant_round_wide[10:0];
  wire [5:0]  E_rounded       = mant_ovf ? (E_l + 6'd1) : E_l;

  wire overflow_pack  = (E_rounded > 6'd31);
  wire under_or_zero  = (E_rounded == 6'd0) | (mant_rounded==11'd0);

  wire [4:0]  exp_pack  = E_rounded[4:0];
  wire [9:0]  frac_pack = mant_rounded[9:0];
  wire [15:0] finite_out= {sign_big_r, exp_pack, frac_pack};

  // Final select
  always @(posedge clk) begin
    if (short_nan_r) begin
      result <= QNAN16;
    end else if (short_inf_r) begin
      result <= {short_inf_sign_r, 5'h1F, 10'd0};
    end else if (short_zero_r) begin
      result <= {short_zero_sign_r, 15'h0000};
    end else begin
      result <= overflow_pack ? {sign_big_r, 5'h1F, 10'd0} :
                under_or_zero ? 16'h0000 :
                                finite_out;
    end
  end
endmodule
