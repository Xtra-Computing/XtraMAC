`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp16_add : Parameterized FP16 adder (LATENCY = 2 or 3)
//   LATENCY=2: 2-stage   (classify+align | normalize+round+pack)
//   LATENCY=3: 3-stage   (classify | align+add | normalize+round+pack)
//   FTZ/DAZ, NaN/Inf, signed zeros, RN-even
// =============================================================
module fp16_add #(
    parameter integer LATENCY = 2   // 2 or 3
) (
    input  wire        clk,
    input  wire [15:0] x16,
    input  wire [15:0] y16,
    output reg  [15:0] result
);

  // -------- helpers --------
  function is_nan;  input [15:0] x; begin is_nan = (x[14:10]==5'h1F) && (x[9:0]!=10'd0); end endfunction
  function is_inf;  input [15:0] x; begin is_inf = (x[14:10]==5'h1F) && (x[9:0]==10'd0); end endfunction
  function is_zero; input [15:0] x; begin is_zero = (x[14:10]==5'd0); end endfunction

  function [2:0] clz6;
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

  function sticky_from_norm;
    input [11:0] x; input [3:0] lz;
    reg [11:0] mask;
    begin
      mask = (lz == 4'd0) ? 12'd0 : (12'hFFF >> (12 - lz));
      sticky_from_norm = |(x & mask);
    end
  endfunction

  function [11:0] norm12_from_lod;
    input [11:0] x;
    begin
      casex (x)
        12'b1xxxxxxxxxxx: norm12_from_lod = x;
        12'b01xxxxxxxxxx: norm12_from_lod = {x[10:0], 1'b0};
        12'b001xxxxxxxxx: norm12_from_lod = {x[9:0],  2'b0};
        12'b0001xxxxxxxx: norm12_from_lod = {x[8:0],  3'b0};
        12'b00001xxxxxxx: norm12_from_lod = {x[7:0],  4'b0};
        12'b000001xxxxxx: norm12_from_lod = {x[6:0],  5'b0};
        12'b0000001xxxxx: norm12_from_lod = {x[5:0],  6'b0};
        12'b00000001xxxx: norm12_from_lod = {x[4:0],  7'b0};
        12'b000000001xxx: norm12_from_lod = {x[3:0],  8'b0};
        12'b0000000001xx: norm12_from_lod = {x[2:0],  9'b0};
        12'b00000000001x: norm12_from_lod = {x[1:0], 10'b0};
        12'b000000000001: norm12_from_lod = {x[0],   11'b0};
        default:          norm12_from_lod = 12'd0;
      endcase
    end
  endfunction

  localparam [15:0] QNAN16 = 16'h7E00;

  // ---- Unpack / classify (combinational) ----
  wire        sa0 = x16[15];
  wire [4:0]  ea0 = x16[14:10];
  wire [9:0]  fa0 = x16[9:0];
  wire        sb0 = y16[15];
  wire [4:0]  eb0 = y16[14:10];
  wire [9:0]  fb0 = y16[9:0];

  wire p_is_nan0  = (ea0==5'h1F) && (fa0!=10'd0);
  wire p_is_inf0  = (ea0==5'h1F) && (fa0==10'd0);
  wire p_is_zero0 = (ea0==5'd0);
  wire c_is_nan0  = is_nan(y16);
  wire c_is_inf0  = is_inf(y16);
  wire c_is_zero0 = is_zero(y16);

  wire special_is_nan =
      p_is_nan0 | c_is_nan0 |
      ((p_is_inf0 & c_is_inf0) && (sa0 ^ sb0));

  wire special_is_inf =
      (~special_is_nan) &
      ((p_is_inf0 & ~c_is_inf0 & ~c_is_nan0) |
       (~p_is_inf0 & ~p_is_nan0 & c_is_inf0) |
       (p_is_inf0 & c_is_inf0 & ~(sa0 ^ sb0)));

  wire special_inf_sign =
      (p_is_inf0 & ~c_is_inf0 & ~c_is_nan0) ? sa0 :
      (~p_is_inf0 & ~p_is_nan0 & c_is_inf0) ? sb0 : sa0;

  wire both_zero   = p_is_zero0 & c_is_zero0;
  wire zero_sign   = (sa0 & sb0);

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

  // =====================================================================
  generate
  if (LATENCY == 2) begin : gen_lat2
    // =========================================================
    // LATENCY = 2 : Stage A1 (register) | Stage A2 (register)
    // =========================================================

    // ---- Stage A1 registers ----
    reg        sign_big_r, diff_sign_r;
    reg [5:0]  E_big_r, dE_r;
    reg [10:0] M_big_r, M_sml_r;
    reg        short_nan_r, short_inf_r, short_inf_sign_r, short_zero_r, short_zero_sign_r;

    initial begin
      sign_big_r=0; diff_sign_r=0; E_big_r=0; dE_r=0; M_big_r=0; M_sml_r=0;
      short_nan_r=0; short_inf_r=0; short_inf_sign_r=0; short_zero_r=0; short_zero_sign_r=0;
    end

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

    // A1 combinational: align + add
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

    // ---- Stage A2 (normalize + round + pack) ----
    wire [11:0] lane12  = sumC[11:0];
    wire [3:0]  lz      = clz12(lane12);
    wire        zero_af = (lz == 4'd12) | (E_n <= lz);

    wire [11:0] laneN   = zero_af ? 12'd0 : (lane12 << lz);
    wire [5:0]  E_l     = zero_af ? 6'd0  : (E_n - lz);

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

  end else begin : gen_lat3
    // =========================================================
    // LATENCY = 3 : Stage A1 | Stage A2 | Stage A3
    // =========================================================

    // ---- Stage A1 registers ----
    reg sign_big_s1, diff_sign_s1;
    reg [5:0] E_big_s1, dE_s1;
    reg [10:0] M_big_s1, M_sml_s1;
    reg short_nan_s1, short_inf_s1, short_inf_sign_s1, short_zero_s1, short_zero_sign_s1;

    always @(posedge clk) begin
      short_nan_s1       <= special_is_nan;
      short_inf_s1       <= special_is_inf;
      short_inf_sign_s1  <= special_inf_sign;
      short_zero_s1      <= both_zero;
      short_zero_sign_s1 <= zero_sign;

      sign_big_s1  <= sign_big_1;
      diff_sign_s1 <= diff_sign_1;
      E_big_s1     <= E_big_1;
      dE_s1        <= dE_1;
      M_big_s1     <= M_big_1;
      M_sml_s1     <= M_sml_1;
    end

    // ---- Stage A2 (align + add/sub + carry + normalize-prep) ----
    wire [3:0]  shamt_s2       = dE_s1[3:0];
    wire [11:0] sml_ext_s2     = {M_sml_s1, 1'b0};
    wire [11:0] sml_shifted_s2 = (dE_s1 >= 6'd11) ? 12'd0 : (sml_ext_s2 >> shamt_s2);
    wire        guard_align_s2 = sml_shifted_s2[0];
    wire [10:0] M_sml_aln_s2   = sml_shifted_s2[11:1];

    wire [11:0] big12_s2       = {M_big_s1, 1'b0};
    wire [11:0] sml12_i_s2     = {M_sml_aln_s2, guard_align_s2};

    wire [12:0] add_a_s2       = {1'b0, big12_s2};
    wire [12:0] add_b_i_s2     = {1'b0, sml12_i_s2};
    wire [12:0] add_b_xor_s2   = add_b_i_s2 ^ {13{diff_sign_s1}};
    wire [12:0] sum13_s2       = add_a_s2 + add_b_xor_s2 + diff_sign_s1;

    wire        add_carry_s2   = (~diff_sign_s1) & sum13_s2[12];
    wire [12:0] sumC_s2_w      = add_carry_s2 ? (sum13_s2 >> 1) : sum13_s2;
    wire [5:0]  E_n_s2_w       = add_carry_s2 ? (E_big_s1 + 6'd1) : E_big_s1;

    wire [11:0] lane12_s2_w    = sumC_s2_w[11:0];
    wire [3:0]  lz_s2_w        = clz12(lane12_s2_w);
    wire [11:0] laneN_s2_w     = norm12_from_lod(lane12_s2_w);
    wire        lane12_zero_s2_w = (lane12_s2_w == 12'd0);
    wire        sticky_s2_w    = sticky_from_norm(lane12_s2_w, lz_s2_w);

    reg [11:0] laneN_s2;
    reg [5:0] E_n_s2;
    reg [3:0] lz_s2;
    reg lane12_zero_s2;
    reg sticky_s2;
    reg sign_big_s2;
    reg short_nan_s2, short_inf_s2, short_inf_sign_s2, short_zero_s2, short_zero_sign_s2;

    always @(posedge clk) begin
      laneN_s2  <= laneN_s2_w;
      E_n_s2    <= E_n_s2_w;
      lz_s2     <= lz_s2_w;
      lane12_zero_s2 <= lane12_zero_s2_w;
      sticky_s2 <= sticky_s2_w;
      sign_big_s2 <= sign_big_s1;

      short_nan_s2       <= short_nan_s1;
      short_inf_s2       <= short_inf_s1;
      short_inf_sign_s2  <= short_inf_sign_s1;
      short_zero_s2      <= short_zero_s1;
      short_zero_sign_s2 <= short_zero_sign_s1;
    end

    // ---- Stage A3 (round + pack + final select) ----
    wire        under_lz_s3        = lane12_zero_s2 | (E_n_s2 <= lz_s2);
    wire [5:0]  E_l_s3             = under_lz_s3 ? 6'd0 : (E_n_s2 - {2'd0, lz_s2});

    wire [10:0] mant_trunc_s3      = laneN_s2[11:1];
    wire        guard_s3           = laneN_s2[0];
    wire        round_inc_s3       = guard_s3 & (sticky_s2 | mant_trunc_s3[0]);

    wire [11:0] mant_round_wide_s3 = {1'b0, mant_trunc_s3} + {11'd0, round_inc_s3};
    wire        mant_ovf_s3        = mant_round_wide_s3[11];
    wire [10:0] mant_rounded_s3    = mant_ovf_s3 ? 11'b10000000000 : mant_round_wide_s3[10:0];
    wire [5:0]  E_rounded_s3       = mant_ovf_s3 ? (E_l_s3 + 6'd1) : E_l_s3;

    wire        overflow_s3        = (E_rounded_s3 > 6'd31);
    wire        under_or_zero_s3   = under_lz_s3 | (E_rounded_s3 == 6'd0) | (mant_rounded_s3 == 11'd0);
    wire [15:0] finite_out_s3      = {sign_big_s2, E_rounded_s3[4:0], mant_rounded_s3[9:0]};

    wire [15:0] normal_out_s3      = overflow_s3 ? {sign_big_s2, 5'h1F, 10'd0} :
                                      under_or_zero_s3 ? 16'h0000 : finite_out_s3;

    always @(posedge clk) begin
      if (short_nan_s2) begin
        result <= QNAN16;
      end else if (short_inf_s2) begin
        result <= {short_inf_sign_s2, 5'h1F, 10'd0};
      end else if (short_zero_s2) begin
        result <= {short_zero_sign_s2, 15'h0000};
      end else begin
        result <= normal_out_s3;
      end
    end

  end
  endgenerate

endmodule

`default_nettype wire
