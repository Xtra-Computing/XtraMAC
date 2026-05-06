`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// int4_fp8e5m2_16_mac
//   - Two signed INT4 lanes × two FP8(E5M2) lanes
//   - DSP packing mirrors int4_fp8e5m2_mac
//   - Products converted to FP16 and accumulated with FP16 inputs
//   - II=1, Latency=4 cycles
// ==========================================================================
module int4_fp8e5m2_16_mac (
    input  wire        clk,
    input  wire [7:0]  a_int4,
    input  wire [15:0] b_fp8,
    input  wire [63:0] c_fp16,
    output reg  [63:0] result
);
  `include "int4_fp8_common.vh"
  `DECL_INT4_DECODE_FP8_FIELDS

  localparam integer EWIDTH = 5;
  localparam integer FWIDTH = 2;
  localparam integer MBITS  = 1 + FWIDTH; // 3
  localparam integer BIAS   = 15;

  localparam [7:0] QNAN8 = 8'h7D;
  localparam [7:0] PINF8 = 8'h7C;
  localparam [7:0] NINF8 = 8'hFC;

  localparam [15:0] FP16_QNAN = 16'h7E00;
  localparam [15:0] FP16_PINF = 16'h7C00;
  localparam [15:0] FP16_NINF = 16'hFC00;

  // Derive a normalized 3-bit mantissa (1.xx) for the INT4 lane that matches
  // the behavioural model used in the reference testbench.
  function [2:0] int4_mant3;
    input [3:0] exp_unb;
    input [2:0] frac_core;
    reg [3:0] mant4;
    reg [3:0] abs_val;
    reg [3:0] tmp_shift;
    begin
      mant4 = {1'b1, frac_core};
      case (exp_unb)
        4'd3: begin
          abs_val     = mant4;
          int4_mant3  = mant4[3:1];
        end
        4'd2: begin
          abs_val     = mant4 >> 1;
          int4_mant3  = abs_val[2:0];
        end
        4'd1: begin
          abs_val     = mant4 >> 2;
          tmp_shift   = abs_val << 1;
          int4_mant3  = tmp_shift[2:0];
        end
        default: begin
          abs_val     = mant4 >> 3;
          tmp_shift   = abs_val << 2;
          int4_mant3  = tmp_shift[2:0];
        end
      endcase
    end
  endfunction

  // ---- INT4 decode ----
  wire [8:0] a1_core = int4_decode_fp8_fields(a_int4[3:0]);
  wire [8:0] a2_core = int4_decode_fp8_fields(a_int4[7:4]);

  wire a1_zero = a1_core[8];
  wire a2_zero = a2_core[8];
  wire sa1     = a1_core[7];
  wire sa2     = a2_core[7];
  wire [3:0] ea1_unb = a1_core[6:3];
  wire [3:0] ea2_unb = a2_core[6:3];
  wire [2:0] fa1_core = a1_core[2:0];
  wire [2:0] fa2_core = a2_core[2:0];

  wire [5:0] ea1_bias = {2'b00, ea1_unb} + 6'd15;
  wire [5:0] ea2_bias = {2'b00, ea2_unb} + 6'd15;
  wire [EWIDTH-1:0] ea1 = a1_zero ? 5'd0 : ea1_bias[4:0];
  wire [EWIDTH-1:0] ea2 = a2_zero ? 5'd0 : ea2_bias[4:0];

  wire [2:0] mant3_a1 = int4_mant3(ea1_unb, fa1_core);
  wire [2:0] mant3_a2 = int4_mant3(ea2_unb, fa2_core);

  wire [MBITS-1:0] Ma1 = a1_zero ? 3'd0 : {1'b1, mant3_a1[1:0]};
  wire [MBITS-1:0] Ma2 = a2_zero ? 3'd0 : {1'b1, mant3_a2[1:0]};

  // ---- FP8 B lanes ----
  wire [7:0] b1 = b_fp8[7:0];
  wire [7:0] b2 = b_fp8[15:8];

  wire sb1 = b1[7];
  wire sb2 = b2[7];
  wire [EWIDTH-1:0] eb1 = b1[6:2];
  wire [EWIDTH-1:0] eb2 = b2[6:2];
  wire [FWIDTH-1:0] fb1 = b1[1:0];
  wire [FWIDTH-1:0] fb2 = b2[1:0];

  wire b1_nan  = (eb1 == 5'h1F) && (fb1 != 2'd0);
  wire b2_nan  = (eb2 == 5'h1F) && (fb2 != 2'd0);
  wire b1_inf  = (eb1 == 5'h1F) && (fb1 == 2'd0);
  wire b2_inf  = (eb2 == 5'h1F) && (fb2 == 2'd0);
  wire b1_zero = (eb1 == 5'd0);
  wire b2_zero = (eb2 == 5'd0);

  // ---- Signs & exponent sums ----
  wire s11 = sa1 ^ sb1;
  wire s12 = sa1 ^ sb2;
  wire s21 = sa2 ^ sb1;
  wire s22 = sa2 ^ sb2;

  wire signed [7:0] e11_s1 = $signed({3'd0, ea1}) + $signed({3'd0, eb1}) - $signed(8'd15);
  wire signed [7:0] e12_s1 = $signed({3'd0, ea1}) + $signed({3'd0, eb2}) - $signed(8'd15);
  wire signed [7:0] e21_s1 = $signed({3'd0, ea2}) + $signed({3'd0, eb1}) - $signed(8'd15);
  wire signed [7:0] e22_s1 = $signed({3'd0, ea2}) + $signed({3'd0, eb2}) - $signed(8'd15);

  // ---- FP16 C lanes ----
  wire [15:0] c11 = c_fp16[15:0];
  wire [15:0] c12 = c_fp16[31:16];
  wire [15:0] c21 = c_fp16[47:32];
  wire [15:0] c22 = c_fp16[63:48];

  // ---- S1 registers ----
  reg [26:0] A_pack;
  reg [17:0] B_pack;

  reg        s11_s2, s12_s2, s21_s2, s22_s2;
  reg signed [7:0] e11_s2, e12_s2, e21_s2, e22_s2;

  reg a1_zero_s2, a2_zero_s2;
  reg b1_zero_s2, b2_zero_s2;
  reg b1_nan_s2,  b2_nan_s2;
  reg b1_inf_s2,  b2_inf_s2;

  reg [15:0] c11_s2, c12_s2, c21_s2, c22_s2;

  always @(posedge clk) begin
    A_pack <= {12'b0, Ma2, 9'b0, Ma1};
    B_pack <= {9'b0, (b2_zero ? 3'd0 : {1'b1, fb2}), 3'b0, (b1_zero ? 3'd0 : {1'b1, fb1})};

    s11_s2 <= s11;  s12_s2 <= s12;  s21_s2 <= s21;  s22_s2 <= s22;
    e11_s2 <= e11_s1; e12_s2 <= e12_s1; e21_s2 <= e21_s1; e22_s2 <= e22_s1;

    a1_zero_s2 <= a1_zero;
    a2_zero_s2 <= a2_zero;
    b1_zero_s2 <= b1_zero;
    b2_zero_s2 <= b2_zero;
    b1_nan_s2  <= b1_nan;
    b2_nan_s2  <= b2_nan;
    b1_inf_s2  <= b1_inf;
    b2_inf_s2  <= b2_inf;

    c11_s2 <= c11;
    c12_s2 <= c12;
    c21_s2 <= c21;
    c22_s2 <= c22;

  end

  // ---- DSP multiply ----
  wire [44:0] product45;
  (* use_dsp = "yes" *)
  dsp_usage u_dsp (
      .clk    (clk),
      .a      (A_pack),
      .b      (B_pack),
      .product(product45)
  );

  reg [23:0] dsp_p;
  always @(posedge clk) begin
    dsp_p <= product45[23:0];
  end

  // ---- S3 alignment ----
  reg        s11_s3, s12_s3, s21_s3, s22_s3;
  reg signed [7:0] e11_s3, e12_s3, e21_s3, e22_s3;

  reg a1_zero_s3, a2_zero_s3;
  reg b1_zero_s3, b2_zero_s3;
  reg b1_nan_s3,  b2_nan_s3;
  reg b1_inf_s3,  b2_inf_s3;

  reg [15:0] c11_s3, c12_s3, c21_s3, c22_s3;

  always @(posedge clk) begin
    s11_s3 <= s11_s2; s12_s3 <= s12_s2; s21_s3 <= s21_s2; s22_s3 <= s22_s2;
    e11_s3 <= e11_s2; e12_s3 <= e12_s2; e21_s3 <= e21_s2; e22_s3 <= e22_s2;

    a1_zero_s3 <= a1_zero_s2;
    a2_zero_s3 <= a2_zero_s2;
    b1_zero_s3 <= b1_zero_s2;
    b2_zero_s3 <= b2_zero_s2;
    b1_nan_s3  <= b1_nan_s2;
    b2_nan_s3  <= b2_nan_s2;
    b1_inf_s3  <= b1_inf_s2;
    b2_inf_s3  <= b2_inf_s2;

    c11_s3 <= c11_s2;
    c12_s3 <= c12_s2;
    c21_s3 <= c21_s2;
    c22_s3 <= c22_s2;

  end

  // ---- Product windows ----
  wire [5:0] P11 = dsp_p[5:0];
  wire [5:0] P12 = dsp_p[11:6];
  wire [5:0] P21 = dsp_p[17:12];
  wire [5:0] P22 = dsp_p[23:18];

  // ---- Special handling ----
  wire nan_11 = b1_nan_s3 | (b1_inf_s3 & a1_zero_s3);
  wire nan_12 = b2_nan_s3 | (b2_inf_s3 & a1_zero_s3);
  wire nan_21 = b1_nan_s3 | (b1_inf_s3 & a2_zero_s3);
  wire nan_22 = b2_nan_s3 | (b2_inf_s3 & a2_zero_s3);

  wire inf_11 = ~nan_11 & b1_inf_s3;
  wire inf_12 = ~nan_12 & b2_inf_s3;
  wire inf_21 = ~nan_21 & b1_inf_s3;
  wire inf_22 = ~nan_22 & b2_inf_s3;

  wire zer_11 = ~nan_11 & ~inf_11 & (a1_zero_s3 | b1_zero_s3);
  wire zer_12 = ~nan_12 & ~inf_12 & (a1_zero_s3 | b2_zero_s3);
  wire zer_21 = ~nan_21 & ~inf_21 & (a2_zero_s3 | b1_zero_s3);
  wire zer_22 = ~nan_22 & ~inf_22 & (a2_zero_s3 | b2_zero_s3);

  wire        c11_carry = P11[5];
  wire [1:0]  c11_frac2 = c11_carry ? P11[4:3] : P11[3:2];
  wire signed [7:0] c11_es  = e11_s3 + (c11_carry ? 8'sd1 : 8'sd0);
  wire        c11_ovf  = (c11_es < 8'sd0) || (c11_es > 8'sd30);

  wire        c12_carry = P12[5];
  wire [1:0]  c12_frac2 = c12_carry ? P12[4:3] : P12[3:2];
  wire signed [7:0] c12_es  = e12_s3 + (c12_carry ? 8'sd1 : 8'sd0);
  wire        c12_ovf  = (c12_es < 8'sd0) || (c12_es > 8'sd30);

  wire        c21_carry = P21[5];
  wire [1:0]  c21_frac2 = c21_carry ? P21[4:3] : P21[3:2];
  wire signed [7:0] c21_es  = e21_s3 + (c21_carry ? 8'sd1 : 8'sd0);
  wire        c21_ovf  = (c21_es < 8'sd0) || (c21_es > 8'sd30);

  wire        c22_carry = P22[5];
  wire [1:0]  c22_frac2 = c22_carry ? P22[4:3] : P22[3:2];
  wire signed [7:0] c22_es  = e22_s3 + (c22_carry ? 8'sd1 : 8'sd0);
  wire        c22_ovf  = (c22_es < 8'sd0) || (c22_es > 8'sd30);

  wire [7:0] prod11_fin = c11_ovf ? {s11_s3, 5'h1F, 2'b00}
                                  : {s11_s3, c11_es[4:0], c11_frac2};
  wire [7:0] prod12_fin = c12_ovf ? {s12_s3, 5'h1F, 2'b00}
                                  : {s12_s3, c12_es[4:0], c12_frac2};
  wire [7:0] prod21_fin = c21_ovf ? {s21_s3, 5'h1F, 2'b00}
                                  : {s21_s3, c21_es[4:0], c21_frac2};
  wire [7:0] prod22_fin = c22_ovf ? {s22_s3, 5'h1F, 2'b00}
                                  : {s22_s3, c22_es[4:0], c22_frac2};

  wire [7:0] prod11_fp8 = nan_11 ? QNAN8 :
                          inf_11 ? {s11_s3, 5'h1F, 2'b00} :
                          zer_11 ? {s11_s3, 5'd0, 2'd0} :
                                   prod11_fin;

  wire [7:0] prod12_fp8 = nan_12 ? QNAN8 :
                          inf_12 ? {s12_s3, 5'h1F, 2'b00} :
                          zer_12 ? {s12_s3, 5'd0, 2'd0} :
                                   prod12_fin;

  wire [7:0] prod21_fp8 = nan_21 ? QNAN8 :
                          inf_21 ? {s21_s3, 5'h1F, 2'b00} :
                          zer_21 ? {s21_s3, 5'd0, 2'd0} :
                                   prod21_fin;

  wire [7:0] prod22_fp8 = nan_22 ? QNAN8 :
                          inf_22 ? {s22_s3, 5'h1F, 2'b00} :
                          zer_22 ? {s22_s3, 5'd0, 2'd0} :
                                   prod22_fin;

  function automatic [15:0] fp8e5_to_fp16;
    input [7:0] val8;
    reg sign;
    reg [4:0] exp8;
    reg [1:0] frac2;
    begin
      sign = val8[7];
      exp8 = val8[6:2];
      frac2= val8[1:0];
      if (exp8 == 5'h1F) begin
        fp8e5_to_fp16 = (frac2 == 2'b00) ? (sign ? FP16_NINF : FP16_PINF) : FP16_QNAN;
      end else if (exp8 == 5'd0) begin
        fp8e5_to_fp16 = {sign, 15'd0};
      end else begin
        fp8e5_to_fp16 = {sign, exp8, {frac2, 8'b0}};
      end
    end
  endfunction

  wire [15:0] prod11_fp16 = fp8e5_to_fp16(prod11_fp8);
  wire [15:0] prod12_fp16 = fp8e5_to_fp16(prod12_fp8);
  wire [15:0] prod21_fp16 = fp8e5_to_fp16(prod21_fp8);
  wire [15:0] prod22_fp16 = fp8e5_to_fp16(prod22_fp8);

  wire [15:0] sum11_w, sum12_w, sum21_w, sum22_w;

  fp16_add u_add11 (.clk(clk), .x16(prod11_fp16), .y16(c11_s3), .result(sum11_w));
  fp16_add u_add12 (.clk(clk), .x16(prod12_fp16), .y16(c12_s3), .result(sum12_w));
  fp16_add u_add21 (.clk(clk), .x16(prod21_fp16), .y16(c21_s3), .result(sum21_w));
  fp16_add u_add22 (.clk(clk), .x16(prod22_fp16), .y16(c22_s3), .result(sum22_w));

  always @(posedge clk) begin
    result <= {sum22_w, sum21_w, sum12_w, sum11_w};
  end

endmodule

`default_nettype wire
