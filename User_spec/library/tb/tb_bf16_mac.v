`timescale 1ns/1ps
`default_nettype none
//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_bf16_mac — II=1, 4-cycle latency, with dummy clocks & self-check
//////////////////////////////////////////////////////////////////////////////////

module tb_bf16_mac;

  // ---- Parameters ----
  parameter integer LAT        = 4;   // total pipeline latency (cycles)
  parameter integer N          = 24;  // number of test vectors (was 8)
  parameter integer DUMMY_CLKS = 5;   // warm-up clocks

  // ---- DUT I/O ----
  reg         clk;
  reg  [31:0] a32;
  reg  [15:0] b16;
  reg  [31:0] c32;
  wire [31:0] result;

  // ---- Instantiate DUT ----
  bf16_mac dut (
    .clk   (clk),
    .a32   (a32),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

  // ---- Clock: 100 MHz ----
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ============================================================
  // Reference helpers (mirror DUT behavior)
  // ============================================================

  // 8-bit saturating right shift for adder alignment
  function [7:0] rshift8; input [7:0] x; input [3:0] sh;
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

  // CLZ for a 9-bit lane (0..9; 9 means zero)
  function [3:0] clz9; input [8:0] x;
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
        default:       clz9 = 4'd9;
      endcase
    end
  endfunction

  // ---- BF16 lane multiply model (matches DUT packing & overflow checks) ----
  function [15:0] bf16_mul_lane_model;
    input [15:0] a16;
    input [15:0] b16_;
    reg sa,sb; reg [7:0] ea,eb; reg [6:0] fa,fb;
    reg        zero_a;
    reg [8:0]  esum;         // signed 9-bit
    reg [7:0]  Ma,Mb;
    reg [15:0] prod;
    reg        carry;
    reg [6:0]  frac7;
    reg        signp;
    begin
      sa = a16[15]; ea = a16[14:7]; fa = a16[6:0];
      sb = b16_[15]; eb = b16_[14:7]; fb = b16_[6:0];
      zero_a = (ea == 8'd0);

      if (zero_a) begin
        bf16_mul_lane_model = 16'h0000;
      end else begin
        signp = sa ^ sb;
        esum  = {1'b0,ea} + {1'b0,eb} - 9'd127;

        // 1+7 mantissas
        Ma    = {1'b1, fa};
        Mb    = {1'b1, fb};
        prod  = Ma * Mb;              // 8x8 -> 16b
        carry = prod[15];
        frac7 = carry ? prod[14:8] : prod[13:7];

        // NOTE: matches DUT: treat esum<0 OR esum>254 as +Inf (we keep sign bit to match model)
        if (esum[8] | (esum > 9'd254)) begin
          bf16_mul_lane_model = {signp, 8'hFF, 7'b0};
        end else begin
          bf16_mul_lane_model = {signp, (esum[7:0] + {7'd0,carry}), frac7};
        end
      end
    end
  endfunction

  // ---- BF16 adder model (Verilog-2001; sign-aware specials; FTZ, guard+align) ----
  function [15:0] bf16_add_model;
    input [15:0] a16;
    input [15:0] b16_;
    reg sa,sb; reg [7:0] ea,eb; reg [6:0] fa,fb;

    // class flags
    reg isNaN_a, isNaN_b, isInf_a, isInf_b;

    // normal-path locals
    reg zero_a0, zero_b0;
    reg [8:0] Ea0,Eb0; reg [7:0] Ma0,Mb0;
    reg swap0, sign_big_1, sign_sml_1;
    reg [8:0] E_big_1, E_sml_1, dE_1;
    reg [7:0] M_big_1, M_sml_1;
    reg diff_sign_1;

    reg [3:0] shamt;
    reg [7:0] M_sml_aligned; reg guard_bit;
    reg [8:0] big9, sml9i;
    reg [9:0] add_a, add_bi, add_b, sum10;
    reg same_sign, add_carry;
    reg [9:0] sumC; reg [8:0] E_n;
    reg [8:0] lane9; reg [3:0] lz; reg zero_af;
    reg [8:0] laneN; reg [8:0] E_l;
    reg overflow, under_or_zero;
    reg [7:0] mant_norm; reg [7:0] exp_pack; reg [6:0] frac_pack;
    reg [15:0] norm_pack;

    reg [15:0] result;
  begin
    // unpack
    sa = a16[15]; ea = a16[14:7]; fa = a16[6:0];
    sb = b16_[15]; eb = b16_[14:7]; fb = b16_[6:0];

    // classes
    isNaN_a = (ea == 8'hFF) && (fa != 7'd0);
    isNaN_b = (eb == 8'hFF) && (fb != 7'd0);
    isInf_a = (ea == 8'hFF) && (fa == 7'd0);
    isInf_b = (eb == 8'hFF) && (fb == 7'd0);

    // ---------- Sign-aware specials ----------
    if (isNaN_a || isNaN_b) begin
      result = 16'h7FC1; // qNaN
    end else if (isInf_a && isInf_b) begin
      // Inf + Inf: same sign => that Inf; opposite sign => NaN
      if (sa == sb) result = {sa, 8'hFF, 7'b0};
      else          result = 16'h7FC1; // NaN
    end else if (isInf_a && !isInf_b) begin
      // Inf + finite
      result = {sa, 8'hFF, 7'b0};
    end else if (!isInf_a && isInf_b) begin
      // finite + Inf
      result = {sb, 8'hFF, 7'b0};
    end else begin
      // ---------- Normal finite path ----------
      zero_a0 = (ea == 8'd0);
      zero_b0 = (eb == 8'd0);

      Ea0 = zero_a0 ? 9'd0 : {1'b0, ea};
      Eb0 = zero_b0 ? 9'd0 : {1'b0, eb};
      Ma0 = zero_a0 ? 8'd0 : {1'b1, fa};
      Mb0 = zero_b0 ? 8'd0 : {1'b1, fb};

      // order by magnitude (exp, then mant)
      swap0       = (Ea0 < Eb0) || ((Ea0 == Eb0) && (Ma0 < Mb0));
      sign_big_1  = swap0 ? sb : sa;
      sign_sml_1  = swap0 ? sa : sb;
      E_big_1     = swap0 ? Eb0 : Ea0;
      E_sml_1     = swap0 ? Ea0 : Eb0;
      M_big_1     = swap0 ? Mb0 : Ma0;
      M_sml_1     = swap0 ? Ma0 : Mb0;

      dE_1        = (E_big_1 >= E_sml_1) ? (E_big_1 - E_sml_1) : 9'd0;
      diff_sign_1 = (sign_big_1 ^ sign_sml_1);

      // align small (saturate shift at 8)
      shamt         = (dE_1 >= 9'd8) ? 4'd8 : dE_1[3:0];
      M_sml_aligned = rshift8(M_sml_1, shamt);
      guard_bit     = (shamt == 4'd0) ? 1'b0 : M_sml_1[shamt-1];

      big9   = {M_big_1,        1'b0};
      sml9i  = {M_sml_aligned,  guard_bit};

      add_a  = {1'b0, big9};
      add_bi = {1'b0, sml9i};
      add_b  = diff_sign_1 ? (~add_bi + 10'd1) : add_bi;

      sum10 = add_a + add_b;

      // carry-right only when same sign
      same_sign = ~diff_sign_1;
      add_carry = same_sign & sum10[9];

      sumC  = add_carry ? (sum10 >> 1) : sum10;
      E_n   = add_carry ? (E_big_1 + 9'd1) : E_big_1;

      lane9  = sumC[8:0];
      lz     = clz9(lane9);
      zero_af= (lz == 4'd9) | (E_n <= lz);

      laneN  = zero_af ? 9'd0 : (lane9 << lz);
      E_l    = zero_af ? 9'd0 : (E_n - lz);

      overflow       = (E_l[8] == 1'b1) | (E_l > 9'd255);
      under_or_zero  = (E_l == 9'd0) | (laneN == 9'd0);

      mant_norm = laneN[8:1];
      exp_pack  = E_l[7:0];
      frac_pack = mant_norm[6:0];
      norm_pack = {sign_big_1, exp_pack, frac_pack};

      // Final selection:
      // - overflow => signed Inf using dominant sign (sign_big_1)
      // - underflow/zero => +0
      // - otherwise normalized
      if (overflow)       result = {sign_big_1, 8'hFF, 7'b0};
      else if (under_or_zero) result = 16'h0000;
      else                result = norm_pack;
    end

    bf16_add_model = result;
  end
  endfunction

  // ============================================================
  // Test vectors and golden computation
  // ============================================================
  reg [31:0]   avec [0:N-1];
  reg [15:0]   bvec [0:N-1];
  reg [31:0]   cvec [0:N-1];
  reg [31:0]   yexp [0:N-1];
  reg [8*96:1] name [0:N-1];

  integer gi;
  reg [15:0] prod_lo, prod_hi, sum_lo, sum_hi;

  initial begin
    // V0: [1.0, 1.0] * 2.0 + [0,0] -> [2.0,2.0]
    name[0] = "V0: [1.0,1.0]*2.0 + [0,0]";
    avec[0] = {16'h3F80, 16'h3F80}; bvec[0] = 16'h4000; cvec[0] = {16'h0000,16'h0000};

    // V1: [-1.5, 0.5] * 1.25 + [1.0,-1.0]
    name[1] = "V1: [-1.5,0.5]*1.25 + [1.0,-1.0]";
    avec[1] = {16'hBFC0, 16'h3F00}; bvec[1] = 16'h3FA0; cvec[1] = {16'h3F80,16'hBF80};

    // V2: [3.0, -2.0] * (-4.0) + [0.25,0.25]
    name[2] = "V2: [3.0,-2.0]*(-4.0) + [0.25,0.25]";
    avec[2] = {16'h4040, 16'hC000}; bvec[2] = 16'hC080; cvec[2] = {16'h3E80,16'h3E80};

    // V3: [0,0] * 1.5 + [3.0,0.5] -> just c
    name[3] = "V3: [0,0]*1.5 + [3.0,0.5]";
    avec[3] = {16'h0000, 16'h0000}; bvec[3] = 16'h3FC0; cvec[3] = {16'h4040,16'h3F00};

    // V4: large*large -> +Inf (specials)
    name[4] = "V4: [~max,~max]*~max + [0,0] -> +Inf";
    avec[4] = {16'h7F7F, 16'h7F7F}; bvec[4] = 16'h7F7F; cvec[4] = {16'h0000,16'h0000};

    // V5: [-8.0,-1.0] * (-0.5) + [2.0,-2.0]
    name[5] = "V5: [-8.0,-1.0]*(-0.5) + [2.0,-2.0]";
    avec[5] = {16'hC100, 16'hBF80}; bvec[5] = 16'hBF00; cvec[5] = {16'h4000,16'hC000};

    // V6: [5.5, 7.25] * 0.75 + [-1.0, +1.0]
    name[6] = "V6: [5.5,7.25]*0.75 + [-1.0,+1.0]";
    avec[6] = {16'h40B0, 16'h40E8}; bvec[6] = 16'h3F40; cvec[6] = {16'hBF80,16'h3F80};

    // V7: [-0.75, +0.3125] * 3.5 + [0,0]
    name[7] = "V7: [-0.75,+0.3125]*3.5 + [0,0]";
    avec[7] = {16'hBE40, 16'h3E20}; bvec[7] = 16'h4060; cvec[7] = {16'h0000,16'h0000};

    // -------- Added BF16-directed coverage (V8..V23) --------

    // V8: exact cancellation to zeros on both lanes
    name[8]  = "V8: [1.0,-1.0]*1.0 + [-1.0,+1.0] -> [0,0]";
    avec[8]  = {16'h3F80, 16'hBF80}; bvec[8]  = 16'h3F80; cvec[8]  = {16'hBF80,16'h3F80};

    // V9: same-sign large add triggers carry-right (mantissa overflow -> exp+1)
    name[9]  = "V9: [1.5,1.5]*1.5 + [1.5,1.5]";
    avec[9]  = {16'h3FC0, 16'h3FC0}; bvec[9]  = 16'h3FC0; cvec[9]  = {16'h3FC0,16'h3FC0};

    // V10: FTZ path — subnormals in A -> product=0; output just C
    name[10] = "V10: [sub,sub]*1.0 + [1.0,-1.0] -> C";
    avec[10] = {16'h0001, 16'h0001}; bvec[10] = 16'h3F80; cvec[10] = {16'h3F80,16'hBF80};

    // V11: product overflow to ±Inf, then add finite C (special path)
    name[11] = "V11: [~max,~max]*~max + [1.0,-1.0] -> Inf handling";
    avec[11] = {16'h7F7F, 16'h7F7F}; bvec[11] = 16'h7F7F; cvec[11] = {16'h3F80,16'hBF80};

    // V12: product finite then cancel with C -> zeros
    name[12] = "V12: [2.0,-2.0]*2.0 + [-4.0,+4.0] -> [0,0]";
    avec[12] = {16'h4000, 16'hC000}; bvec[12] = 16'h4000; cvec[12] = {16'hC080,16'h4080};

    // V13: zeros with explicit signs in C (exercise +0/-0 handling in adder)
    name[13] = "V13: [0,0]*2.0 + [+0,-0] -> [+0,-0]";
    avec[13] = {16'h0000, 16'h0000}; bvec[13] = 16'h4000; cvec[13] = {16'h0000,16'h8000};

    // V14: small product added to larger |C| with opposite signs
    name[14] = "V14: [0.5,0.5]*0.5 + [3.0,-3.0]";
    avec[14] = {16'h3F00, 16'h3F00}; bvec[14] = 16'h3F00; cvec[14] = {16'h4040,16'hC040};

    // V15: exact cancellation to zeros from product and C
    name[15] = "V15: [1.0,1.0]*2.0 + [-2.0,-2.0] -> [0,0]";
    avec[15] = {16'h3F80, 16'h3F80}; bvec[15] = 16'h4000; cvec[15] = {16'hC000,16'hC000};

    // V16: product negative, add +C same magnitude -> zeros
    name[16] = "V16: [-1.0,-1.0]*1.0 + [1.0,1.0] -> [0,0]";
    avec[16] = {16'hBF80, 16'hBF80}; bvec[16] = 16'h3F80; cvec[16] = {16'h3F80,16'h3F80};

    // V17: mixed signs, moderate values
    name[17] = "V17: [-1.5,+1.5]*(-2.0) + [0.5,-0.5]";
    avec[17] = {16'hBFC0, 16'h3FC0}; bvec[17] = 16'hC000; cvec[17] = {16'h3F00,16'hBF00};

    // V18: tiny C should not change 1.0 due to alignment/guard
    name[18] = "V18: [1.0,1.0]*1.0 + [minSub,minSub] -> ~1.0";
    avec[18] = {16'h3F80, 16'h3F80}; bvec[18] = 16'h3F80; cvec[18] = {16'h0001,16'h0001};

    // V19: opposite-sign near-cancel but not exact (0.75*3.0 ≈ 2.25; add -2.0)
    name[19] = "V19: [0.75,0.75]*3.0 + [-2.0,-2.0]";
    avec[19] = {16'h3F40, 16'h3F40}; bvec[19] = 16'h4040; cvec[19] = {16'hC000,16'hC000};

    // V20: one lane tends to +Inf, the other stays finite
    name[20] = "V20: [~max,1.0]*~max + [0,0]";
    avec[20] = {16'h7F7F, 16'h3F80}; bvec[20] = 16'h7F7F; cvec[20] = {16'h0000,16'h0000};

    // V21: negative large finite (~-max) * ~max -> -Inf (product), add small C
    name[21] = "V21: [-~max,~max]*~max + [0.25,-0.25]";
    avec[21] = {16'hFF7F, 16'h7F7F}; bvec[21] = 16'h7F7F; cvec[21] = {16'h3E80,16'hBE80};

    // V22: both lanes subnormal A, finite B, finite C
    name[22] = "V22: [sub,sub]*2.0 + [0.25,0.5] -> ~C";
    avec[22] = {16'h0002, 16'h0001}; bvec[22] = 16'h4000; cvec[22] = {16'h3E80,16'h3F00};

    // V23: moderate finite multiply plus finite C, mixed signs
    name[23] = "V23: [5.5,7.25]*(-0.5) + [2.0,-2.0]";
    avec[23] = {16'h40B0, 16'h40E8}; bvec[23] = 16'hBF00; cvec[23] = {16'h4000,16'hC000};

    // Compute goldens
    for (gi = 0; gi < N; gi = gi + 1) begin
      prod_lo = bf16_mul_lane_model(avec[gi][15:0],   bvec[gi]);
      prod_hi = bf16_mul_lane_model(avec[gi][31:16],  bvec[gi]);
      sum_lo  = bf16_add_model(prod_lo, cvec[gi][15:0]);
      sum_hi  = bf16_add_model(prod_hi, cvec[gi][31:16]);
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
    a32 = 32'h0; b16 = 16'h0; c32 = 32'h0;
    $display("\n--- BF16 MAC (II=1, LAT=%0d) ---", LAT);
    $display("Applying %0d dummy clocks before stimulus...", DUMMY_CLKS);
    repeat (DUMMY_CLKS) @(posedge clk);

    // Stream inputs & check after LAT cycles
    for (i = 0; i < N + LAT; i = i + 1) begin
      if (i < N) begin
        a32 <= avec[i];
        b16 <= bvec[i];
        c32 <= cvec[i];
      end else begin
        a32 <= 32'h0; b16 <= 16'h0; c32 <= 32'h0; // drain
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
