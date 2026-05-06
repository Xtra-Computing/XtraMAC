`timescale 1ns/1ps
`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_int4_fp8e4m3_mac
//   - INT4 (two's complement) lanes converted to FP8(E4M3) inside DUT
//   - Re-uses functional models from fp8e4m3_mac testbench for self-check
////////////////////////////////////////////////////////////////////////////////
module tb_int4_fp8e4m3_mac;
  // --------------------------------------------------------------------------
  // Parameters
  // --------------------------------------------------------------------------
  parameter integer LAT        = 4;   // pipeline latency from fp8e4m3_mac
  parameter integer N          = 24;  // number of test vectors
  parameter integer DUMMY_CLKS = 6;   // warm-up clocks

  // --------------------------------------------------------------------------
  // DUT I/O
  // --------------------------------------------------------------------------
  reg         clk;
  reg  [7:0]  a_int4;   // {a2[7:4], a1[3:0]} INT4 lanes
  reg  [15:0] b_fp8;    // {b2[15:8], b1[7:0]} FP8(E4M3)
  reg  [31:0] c_fp8;    // {c22,c21,c12,c11} FP8(E4M3)
  wire [31:0] result;   // {y22,y21,y12,y11}

  int4_fp8e4m3_mac dut (
      .clk   (clk),
      .a_int4(a_int4),
      .b_fp8 (b_fp8),
      .c_fp8 (c_fp8),
      .result(result)
  );

  // --------------------------------------------------------------------------
  // Clock (100 MHz)
  // --------------------------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // --------------------------------------------------------------------------
  // FP8(E4M3) constants (mirror production design)
  // --------------------------------------------------------------------------
  localparam integer EWIDTH = 4;
  localparam integer FWIDTH = 3;
  localparam integer MBITS  = 1 + FWIDTH;   // 4
  localparam integer BIAS   = 7;

  localparam [7:0] QNAN8      = 8'h79;
  localparam [7:0] PZERO8     = 8'h00;
  localparam [7:0] NZERO8     = 8'h80;
  localparam [7:0] MAXFIN_POS = {1'b0, 4'hE, 3'b111};
  localparam [7:0] MAXFIN_NEG = {1'b1, 4'hE, 3'b111};

  // Handy finite constants used in stimuli
  localparam [7:0] FP8_P0_5 = 8'h30;
  localparam [7:0] FP8_P1_0 = 8'h38;
  localparam [7:0] FP8_N1_0 = 8'hB8;
  localparam [7:0] FP8_P1_5 = 8'h3C;
  localparam [7:0] FP8_P2_0 = 8'h40;
  localparam [7:0] FP8_N2_0 = 8'hC0;
  localparam [7:0] FP8_P3_0 = 8'h44;

  // --------------------------------------------------------------------------
  // Helper functions
  // --------------------------------------------------------------------------
  function [3:0] int_to_int4; input integer val;
    integer clipped;
    begin
      clipped = (val > 7) ? 7 : ((val < -8) ? -8 : val);
      int_to_int4 = clipped[3:0];
    end
  endfunction

  function [15:0] pack2_8; input [7:0] hi; input [7:0] lo;
    begin
      pack2_8 = {hi, lo};
    end
  endfunction

  function [31:0] pack4_8; input [7:0] y22,y21,y12,y11;
    begin
      pack4_8 = {y22, y21, y12, y11};
    end
  endfunction

  function [MBITS-1:0] rshift4; input [MBITS-1:0] x; input [2:0] sh;
    begin
      case (sh)
        3'd0: rshift4 = x;
        3'd1: rshift4 = {1'b0,    x[3:1]};
        3'd2: rshift4 = {2'b00,   x[3:2]};
        3'd3: rshift4 = {3'b000,  x[3]};
        default: rshift4 = 4'b0;
      endcase
    end
  endfunction

  function [2:0] clz5; input [4:0] x;
    begin
      casex (x)
        5'b1xxxx: clz5 = 3'd0;
        5'b01xxx: clz5 = 3'd1;
        5'b001xx: clz5 = 3'd2;
        5'b0001x: clz5 = 3'd3;
        5'b00001: clz5 = 3'd4;
        default:   clz5 = 3'd5;
      endcase
    end
  endfunction

  function [7:0] int4_to_fp8e4m3_model; input [3:0] val4;
    reg  signed [4:0] sval;
    reg        sign;
    reg  [4:0] absval;
    reg  [2:0] msb_idx;
    reg  [3:0] mant4;
    reg  [4:0] exp_bias;
    begin
      sval = $signed({val4[3], val4});
      if (sval == 0) begin
        int4_to_fp8e4m3_model = 8'h00;
      end else begin
        sign   = sval[4];
        absval = sign ? -sval : sval;
        casex (absval[3:0])
          4'b1???: msb_idx = 3'd3;
          4'b01??: msb_idx = 3'd2;
          4'b001?: msb_idx = 3'd1;
          default: msb_idx = 3'd0;
        endcase
        mant4    = (absval[3:0] << (3 - msb_idx));
        exp_bias = msb_idx + BIAS;
        int4_to_fp8e4m3_model = {sign, exp_bias[3:0], mant4[2:0]};
      end
    end
  endfunction

  function [7:0] fp8e4m3_mul_lane_model;
    input [7:0] a;
    input [7:0] b;
    reg sa,sb;
    reg [3:0] ea,eb;
    reg [2:0] fa,fb;
    reg a_nan,a_zero,b_nan,b_zero;
    reg signp;
    integer esum;
    reg [3:0] Ma,Mb;
    reg [7:0] prod;
    reg carry;
    reg [2:0] frac3;
    begin
      sa=a[7]; ea=a[6:3]; fa=a[2:0];
      sb=b[7]; eb=b[6:3]; fb=b[2:0];
      a_nan=(ea==4'hF); a_zero=(ea==4'd0);
      b_nan=(eb==4'hF); b_zero=(eb==4'd0);
      if (a_nan | b_nan) begin
        fp8e4m3_mul_lane_model = QNAN8;
      end else if (a_zero | b_zero) begin
        fp8e4m3_mul_lane_model = {(sa^sb), 7'd0};
      end else begin
        signp = sa ^ sb;
        esum  = (ea + eb) - BIAS;
        Ma    = {1'b1, fa};
        Mb    = {1'b1, fb};
        prod  = Ma * Mb;
        carry = prod[7];
        frac3 = carry ? prod[6:4] : prod[5:3];
        esum  = esum + (carry ? 1 : 0);
        if (esum < 0 || esum > 14)
          fp8e4m3_mul_lane_model = signp ? MAXFIN_NEG : MAXFIN_POS;
        else
          fp8e4m3_mul_lane_model = {signp, esum[3:0], frac3};
      end
    end
  endfunction

  function [7:0] fp8e4m3_add_model;
    input [7:0] a;
    input [7:0] b;
    reg sa,sb; reg [3:0] ea,eb; reg [2:0] fa,fb;
    reg isNaN_a,isNaN_b;
    reg zero_a0, zero_b0;
    reg [4:0] Ea0,Eb0; reg [3:0] Ma0,Mb0; // 1+3 mantissa
    reg swap0, sign_big_1, sign_sml_1;
    reg [4:0] E_big_1, E_sml_1, dE_1;
    reg [3:0] M_big_1, M_sml_1;
    reg diff_sign_1;
    reg [2:0] shamt;
    reg [3:0] M_sml_aligned; reg guard_bit;
    reg [4:0] big5, sml5i;
    reg [5:0] sumW;
    reg same_sign, add_carry;
    reg [4:0] E_n;
    reg [4:0] lane5; reg [2:0] lz; reg zero_af;
    reg [4:0] laneN; reg [4:0] E_l;
    reg overflow, under_or_zero;
    reg [3:0] mant_norm; reg [7:0] norm_pack;
    begin
      sa=a[7]; ea=a[6:3]; fa=a[2:0];
      sb=b[7]; eb=b[6:3]; fb=b[2:0];

      isNaN_a=(ea==4'hF); isNaN_b=(eb==4'hF);

      if (isNaN_a || isNaN_b) begin
        fp8e4m3_add_model = QNAN8;
      end else begin
        // finite path (FTZ)
        zero_a0 = (ea==4'd0);
        zero_b0 = (eb==4'd0);

        Ea0 = zero_a0 ? 5'd0 : {1'b0,ea};
        Eb0 = zero_b0 ? 5'd0 : {1'b0,eb};
        Ma0 = zero_a0 ? 4'd0 : {1'b1,fa};
        Mb0 = zero_b0 ? 4'd0 : {1'b1,fb};

        swap0       = (Ea0 < Eb0) || ((Ea0==Eb0)&&(Ma0<Mb0));
        sign_big_1  = swap0 ? sb : sa;
        sign_sml_1  = swap0 ? sa : sb;
        E_big_1     = swap0 ? Eb0 : Ea0;
        E_sml_1     = swap0 ? Ea0 : Eb0;
        M_big_1     = swap0 ? Mb0 : Ma0;
        M_sml_1     = swap0 ? Ma0 : Mb0;

        dE_1  = (E_big_1 >= E_sml_1) ? (E_big_1 - E_sml_1) : 5'd0;
        shamt = (dE_1 >= 5'd4) ? 3'd4 : dE_1[2:0];
        M_sml_aligned = rshift4(M_sml_1, shamt);
        guard_bit     = (shamt==3'd0) ? 1'b0 : M_sml_1[shamt-1];

        big5  = {M_big_1,       1'b0};
        sml5i = {M_sml_aligned, guard_bit};

        // add/sub by sign
        same_sign = (sign_big_1 == sign_sml_1);
        sumW      = {1'b0,big5} + (same_sign ? {1'b0,sml5i} : (~{1'b0,sml5i}+6'd1));
        add_carry = same_sign & sumW[5];

        // exponent update and carry-right
        E_n   = add_carry ? (E_big_1 + 5'd1) : E_big_1;
        lane5 = same_sign ? (add_carry ? sumW[5:1] : sumW[4:0]) : (big5 - sml5i);

        // normalize
        lz    = clz5(lane5);
        zero_af = (lz==3'd5) || (E_n <= {2'b00,lz});
        laneN = zero_af ? 5'd0 : (lane5 << lz);
        E_l   = zero_af ? 5'd0 : (E_n - {2'b00,lz});

        overflow      = (E_l[4]==1'b1) | (E_l > 5'd14);
        under_or_zero = (E_l == 5'd0) | (laneN == 5'd0);

        mant_norm = laneN[4:1];         // 1+3
        norm_pack = {sign_big_1, E_l[3:0], mant_norm[2:0]};

        fp8e4m3_add_model = overflow      ? (sign_big_1 ? MAXFIN_NEG : MAXFIN_POS) :
                             under_or_zero ? PZERO8 :
                                              norm_pack;
      end
    end
  endfunction

  // --------------------------------------------------------------------------
  // Stimulus / expectation storage
  // --------------------------------------------------------------------------
  reg [7:0]  avec [0:N-1];
  reg [15:0] bvec [0:N-1];
  reg [31:0] cvec [0:N-1];
  reg [31:0] yexp [0:N-1];

  reg signed [4:0] int_choices [0:5];
  reg [7:0]        b_choices  [0:3];
  reg [7:0]        c_choices  [0:3];

  integer idx;
  reg [7:0] a1_fp8_ref, a2_fp8_ref;
  reg [7:0] p11,p12,p21,p22;
  reg [7:0] s11,s12,s21,s22;
  
  integer sel_a0;
  integer sel_a1;
  integer sel_b0;
  integer sel_b1;
  integer sel_c;

  initial begin
    // Base value tables
    int_choices[0] = -8;
    int_choices[1] = -5;
    int_choices[2] = -3;
    int_choices[3] =  0;
    int_choices[4] =  2;
    int_choices[5] =  7;

    b_choices[0] = FP8_P1_0;
    b_choices[1] = FP8_N1_0;
    b_choices[2] = FP8_P0_5;
    b_choices[3] = FP8_P2_0;

    c_choices[0] = PZERO8;
    c_choices[1] = FP8_P1_0;
    c_choices[2] = FP8_N1_0;
    c_choices[3] = FP8_P0_5;

    // Auto-generate a spread of stimuli
    for (idx = 0; idx < N; idx = idx + 1) begin
      sel_a0 = idx % 6;
      sel_a1 = (idx + 2) % 6;
      sel_b0 = idx % 4;
      sel_b1 = (idx + (idx >> 1) + 1) % 4;
      sel_c  = idx % 4;

      avec[idx] = {int_to_int4(int_choices[sel_a1]), int_to_int4(int_choices[sel_a0])};
      bvec[idx] = pack2_8(b_choices[sel_b1], b_choices[sel_b0]);
      cvec[idx] = pack4_8(
          c_choices[(sel_c + 3) % 4],
          c_choices[(sel_c + 2) % 4],
          c_choices[(sel_c + 1) % 4],
          c_choices[sel_c]
      );
    end

    // A few directed overrides for corner cases
    avec[0] = {int_to_int4(7),  int_to_int4(-8)};
    bvec[0] = pack2_8(FP8_P0_5, FP8_N2_0);
    cvec[0] = pack4_8(PZERO8, FP8_P1_0, FP8_N1_0, PZERO8);

    avec[1] = {int_to_int4(-1), int_to_int4(3)};
    bvec[1] = pack2_8(FP8_P1_5, FP8_P1_0);
    cvec[1] = pack4_8(FP8_P3_0, FP8_P0_5, FP8_P0_5, FP8_P3_0);

    avec[2] = {int_to_int4(0),  int_to_int4(0)};
    bvec[2] = pack2_8(FP8_P1_0, FP8_P2_0);
    cvec[2] = pack4_8(FP8_N1_0, FP8_P1_0, FP8_N1_0, FP8_P1_0);

    avec[3] = {int_to_int4(-8), int_to_int4(-8)};
    bvec[3] = pack2_8(FP8_P2_0, FP8_P2_0);
    cvec[3] = pack4_8(MAXFIN_POS, MAXFIN_POS, MAXFIN_POS, MAXFIN_POS);

    // Compute golden results
    for (idx = 0; idx < N; idx = idx + 1) begin
      a1_fp8_ref = int4_to_fp8e4m3_model(avec[idx][3:0]);
      a2_fp8_ref = int4_to_fp8e4m3_model(avec[idx][7:4]);

      p11 = fp8e4m3_mul_lane_model(a1_fp8_ref, bvec[idx][7:0]);
      p12 = fp8e4m3_mul_lane_model(a1_fp8_ref, bvec[idx][15:8]);
      p21 = fp8e4m3_mul_lane_model(a2_fp8_ref, bvec[idx][7:0]);
      p22 = fp8e4m3_mul_lane_model(a2_fp8_ref, bvec[idx][15:8]);

      s11 = fp8e4m3_add_model(p11, cvec[idx][7:0]);
      s12 = fp8e4m3_add_model(p12, cvec[idx][15:8]);
      s21 = fp8e4m3_add_model(p21, cvec[idx][23:16]);
      s22 = fp8e4m3_add_model(p22, cvec[idx][31:24]);

      yexp[idx] = pack4_8(s22, s21, s12, s11);
    end
  end

  // --------------------------------------------------------------------------
  // Drive + Check
  // --------------------------------------------------------------------------
  integer errors;
  integer i;
  integer idx_chk;
  initial begin
    errors = 0;

    a_int4 = 8'h00;
    b_fp8  = 16'h0000;
    c_fp8  = 32'h00000000;

    $display("\n--- INT4 x FP8(E4M3) MAC (LAT=%0d, Vectors=%0d) ---", LAT, N);
    $display("Applying %0d dummy clocks before stimulus...", DUMMY_CLKS);
    repeat (DUMMY_CLKS) @(posedge clk);

    for (i = 0; i < N + LAT; i = i + 1) begin
      if (i < N) begin
        a_int4 <= avec[i];
        b_fp8  <= bvec[i];
        c_fp8  <= cvec[i];
      end else begin
        a_int4 <= 8'h00;
        b_fp8  <= 16'h0000;
        c_fp8  <= 32'h00000000;
      end

      @(posedge clk);

      if (i >= LAT) begin
        idx_chk = i - LAT;
        if (result !== yexp[idx_chk]) begin
          errors = errors + 1;
          $display("Mismatch idx %0d : got %h expected %h (a=%02h b=%04h c=%08h)",
                   idx_chk, result, yexp[idx_chk], avec[idx_chk], bvec[idx_chk], cvec[idx_chk]);
        end
      end
    end

    if (errors == 0)
      $display("PASS: All %0d vectors matched expectations.", N);
    else
      $display("FAIL: %0d mismatches detected out of %0d vectors.", errors, N);

    $finish;
  end

endmodule

`default_nettype wire
