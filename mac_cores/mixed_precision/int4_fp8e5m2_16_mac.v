`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// int4_fp8e5m2_16_mac : 4-lane INT4 x FP8(E5M2) -> FP16 accumulation
//   DSP packing mirrors fp8e5m2_16_mac: A={12'b0,Ma2,9'b0,Ma1}, B={9'b0,Mb2,3'b0,Mb1}
//   Product windows: 6-bit each
//   Pipeline: S1 pack | S2 DSP capture | MID_STAGES | ADD_LAT fp16_add
//   Output is combinational concat of adder outputs -- no extra reg.
//
//   Total latency = 2 (mul) + MID_STAGES + ADD_LAT  (EXACT)
//   MUL_LAT, MID_STAGES, ADD_LAT parameterized.
// ==========================================================================
module int4_fp8e5m2_16_mac #(
    parameter integer MUL_LAT    = 2,
    parameter integer MID_STAGES = 0,
    parameter integer ADD_LAT    = 2
) (
    input  wire        clk,
    input  wire [7:0]  a_int4,
    input  wire [15:0] b_fp8,
    input  wire [63:0] c_fp16,
    output wire [63:0] result
);
  `include "int4_fp8_common.vh"
  `DECL_INT4_DECODE_FP8_FIELDS

  localparam integer EWIDTH = 5;
  localparam integer FWIDTH = 2;
  localparam integer MBITS  = 3;
  localparam integer BIAS_V = 15;

  localparam [15:0] FP16_QNAN = 16'h7E00;
  localparam [15:0] FP16_PINF = 16'h7C00;
  localparam [15:0] FP16_NINF = 16'hFC00;

  // INT4 -> 3-bit mantissa helper
  function [2:0] int4_mant3;
    input [3:0] exp_unb;
    input [2:0] frac_core;
    reg [3:0] mant4, abs_val, tmp_shift;
    begin
      mant4 = {1'b1, frac_core};
      case (exp_unb)
        4'd3: int4_mant3 = mant4[3:1];
        4'd2: begin abs_val = mant4 >> 1; int4_mant3 = abs_val[2:0]; end
        4'd1: begin abs_val = mant4 >> 2; tmp_shift = abs_val << 1; int4_mant3 = tmp_shift[2:0]; end
        default: begin abs_val = mant4 >> 3; tmp_shift = abs_val << 2; int4_mant3 = tmp_shift[2:0]; end
      endcase
    end
  endfunction

  wire [8:0] a1_core = int4_decode_fp8_fields(a_int4[3:0]);
  wire [8:0] a2_core = int4_decode_fp8_fields(a_int4[7:4]);

  wire a1_zero=a1_core[8], a2_zero=a2_core[8];
  wire sa1=a1_core[7], sa2=a2_core[7];
  wire [3:0] ea1_unb=a1_core[6:3], ea2_unb=a2_core[6:3];
  wire [2:0] fa1_core=a1_core[2:0], fa2_core=a2_core[2:0];

  wire [5:0] ea1_bias={2'b00,ea1_unb}+6'd15, ea2_bias={2'b00,ea2_unb}+6'd15;
  wire [EWIDTH-1:0] ea1=a1_zero?5'd0:ea1_bias[4:0], ea2=a2_zero?5'd0:ea2_bias[4:0];

  wire [2:0] mant3_a1=int4_mant3(ea1_unb,fa1_core), mant3_a2=int4_mant3(ea2_unb,fa2_core);
  wire [MBITS-1:0] Ma1=a1_zero?3'd0:{1'b1,mant3_a1[1:0]}, Ma2=a2_zero?3'd0:{1'b1,mant3_a2[1:0]};

  // FP8 B lanes
  wire [7:0] b1=b_fp8[7:0], b2=b_fp8[15:8];
  wire sb1=b1[7],sb2=b2[7];
  wire [EWIDTH-1:0] eb1=b1[6:2],eb2=b2[6:2];
  wire [FWIDTH-1:0] fb1=b1[1:0],fb2=b2[1:0];

  wire b1_nan=(eb1==5'h1F)&&(fb1!=2'd0), b2_nan=(eb2==5'h1F)&&(fb2!=2'd0);
  wire b1_inf=(eb1==5'h1F)&&(fb1==2'd0), b2_inf=(eb2==5'h1F)&&(fb2==2'd0);
  wire b1_zero=(eb1==5'd0), b2_zero=(eb2==5'd0);

  wire s11=sa1^sb1,s12=sa1^sb2,s21=sa2^sb1,s22=sa2^sb2;

  wire signed [7:0] e11_s1=$signed({3'd0,ea1})+$signed({3'd0,eb1})-$signed(8'd15);
  wire signed [7:0] e12_s1=$signed({3'd0,ea1})+$signed({3'd0,eb2})-$signed(8'd15);
  wire signed [7:0] e21_s1=$signed({3'd0,ea2})+$signed({3'd0,eb1})-$signed(8'd15);
  wire signed [7:0] e22_s1=$signed({3'd0,ea2})+$signed({3'd0,eb2})-$signed(8'd15);

  wire [15:0] c11=c_fp16[15:0],c12=c_fp16[31:16],c21=c_fp16[47:32],c22=c_fp16[63:48];

  // S1
  reg [26:0] A_pack; reg [17:0] B_pack;
  reg s11_s2,s12_s2,s21_s2,s22_s2;
  reg signed [7:0] e11_s2,e12_s2,e21_s2,e22_s2;
  reg a1_zero_s2,a2_zero_s2,b1_zero_s2,b2_zero_s2;
  reg b1_nan_s2,b2_nan_s2,b1_inf_s2,b2_inf_s2;
  reg [15:0] c11_s2,c12_s2,c21_s2,c22_s2;

  always @(posedge clk) begin
    A_pack<={12'b0,Ma2,9'b0,Ma1};
    B_pack<={9'b0,(b2_zero?3'd0:{1'b1,fb2}),3'b0,(b1_zero?3'd0:{1'b1,fb1})};
    s11_s2<=s11; s12_s2<=s12; s21_s2<=s21; s22_s2<=s22;
    e11_s2<=e11_s1; e12_s2<=e12_s1; e21_s2<=e21_s1; e22_s2<=e22_s1;
    a1_zero_s2<=a1_zero; a2_zero_s2<=a2_zero;
    b1_zero_s2<=b1_zero; b2_zero_s2<=b2_zero;
    b1_nan_s2<=b1_nan; b2_nan_s2<=b2_nan;
    b1_inf_s2<=b1_inf; b2_inf_s2<=b2_inf;
    c11_s2<=c11; c12_s2<=c12; c21_s2<=c21; c22_s2<=c22;
  end

  wire [44:0] product45;
  (* use_dsp = "yes" *)
  dsp_usage u_dsp (.clk(clk),.a(A_pack),.b(B_pack),.product(product45));

  reg [23:0] dsp_p;
  always @(posedge clk) dsp_p <= product45[23:0];

  // S3
  reg s11_s3,s12_s3,s21_s3,s22_s3;
  reg signed [7:0] e11_s3,e12_s3,e21_s3,e22_s3;
  reg a1_zero_s3,a2_zero_s3,b1_zero_s3,b2_zero_s3;
  reg b1_nan_s3,b2_nan_s3,b1_inf_s3,b2_inf_s3;
  reg [15:0] c11_s3,c12_s3,c21_s3,c22_s3;

  always @(posedge clk) begin
    s11_s3<=s11_s2; s12_s3<=s12_s2; s21_s3<=s21_s2; s22_s3<=s22_s2;
    e11_s3<=e11_s2; e12_s3<=e12_s2; e21_s3<=e21_s2; e22_s3<=e22_s2;
    a1_zero_s3<=a1_zero_s2; a2_zero_s3<=a2_zero_s2;
    b1_zero_s3<=b1_zero_s2; b2_zero_s3<=b2_zero_s2;
    b1_nan_s3<=b1_nan_s2; b2_nan_s3<=b2_nan_s2;
    b1_inf_s3<=b1_inf_s2; b2_inf_s3<=b2_inf_s2;
    c11_s3<=c11_s2; c12_s3<=c12_s2; c21_s3<=c21_s2; c22_s3<=c22_s2;
  end

  wire [5:0] P11=dsp_p[5:0],P12=dsp_p[11:6],P21=dsp_p[17:12],P22=dsp_p[23:18];

  wire nan_11=b1_nan_s3|(b1_inf_s3&a1_zero_s3);
  wire nan_12=b2_nan_s3|(b2_inf_s3&a1_zero_s3);
  wire nan_21=b1_nan_s3|(b1_inf_s3&a2_zero_s3);
  wire nan_22=b2_nan_s3|(b2_inf_s3&a2_zero_s3);

  wire inf_11=~nan_11&b1_inf_s3, inf_12=~nan_12&b2_inf_s3;
  wire inf_21=~nan_21&b1_inf_s3, inf_22=~nan_22&b2_inf_s3;

  wire zer_11=~nan_11&~inf_11&(a1_zero_s3|b1_zero_s3);
  wire zer_12=~nan_12&~inf_12&(a1_zero_s3|b2_zero_s3);
  wire zer_21=~nan_21&~inf_21&(a2_zero_s3|b1_zero_s3);
  wire zer_22=~nan_22&~inf_22&(a2_zero_s3|b2_zero_s3);

  // Widen product to FP16 (same as fp8e5m2_16_mac)
  function automatic [15:0] widen_e5m2_to_fp16;
    input sign_in;
    input signed [7:0] exp_unb;
    input [5:0] prod6;
    input is_nan, is_inf, is_zero;
    reg carry;
    reg signed [7:0] es;
    reg ovf;
    reg [10:0] mant_carry, mant_norm;
    reg [11:0] mant_nocarry;
    begin
      if (is_nan)      widen_e5m2_to_fp16 = FP16_QNAN;
      else if (is_inf) widen_e5m2_to_fp16 = sign_in ? FP16_NINF : FP16_PINF;
      else if (is_zero)widen_e5m2_to_fp16 = {sign_in, 15'd0};
      else begin
        carry = prod6[5];
        es = exp_unb + (carry ? 8'sd1 : 8'sd0);
        ovf = (es < 8'sd0) || (es > 8'sd30);
        if (ovf) widen_e5m2_to_fp16 = sign_in ? FP16_NINF : FP16_PINF;
        else begin
          mant_carry   = {prod6, 5'b0};
          mant_nocarry = {prod6, 6'b0};
          mant_norm    = carry ? mant_carry : mant_nocarry[10:0];
          widen_e5m2_to_fp16 = {sign_in, es[4:0], mant_norm[9:0]};
        end
      end
    end
  endfunction

  // Build intermediate FP8 then widen (matching ref int4_fp8e5m2_16_mac)
  wire c11_carry=P11[5]; wire [1:0] c11_frac2=c11_carry?P11[4:3]:P11[3:2];
  wire signed [7:0] c11_es=e11_s3+(c11_carry?8'sd1:8'sd0);
  wire c11_ovf=(c11_es<8'sd0)||(c11_es>8'sd30);

  wire c12_carry=P12[5]; wire [1:0] c12_frac2=c12_carry?P12[4:3]:P12[3:2];
  wire signed [7:0] c12_es=e12_s3+(c12_carry?8'sd1:8'sd0);
  wire c12_ovf=(c12_es<8'sd0)||(c12_es>8'sd30);

  wire c21_carry=P21[5]; wire [1:0] c21_frac2=c21_carry?P21[4:3]:P21[3:2];
  wire signed [7:0] c21_es=e21_s3+(c21_carry?8'sd1:8'sd0);
  wire c21_ovf=(c21_es<8'sd0)||(c21_es>8'sd30);

  wire c22_carry=P22[5]; wire [1:0] c22_frac2=c22_carry?P22[4:3]:P22[3:2];
  wire signed [7:0] c22_es=e22_s3+(c22_carry?8'sd1:8'sd0);
  wire c22_ovf=(c22_es<8'sd0)||(c22_es>8'sd30);

  localparam [7:0] QNAN8_E5 = 8'h7D;

  wire [7:0] prod11_fin = c11_ovf ? {s11_s3,5'h1F,2'b00} : {s11_s3,c11_es[4:0],c11_frac2};
  wire [7:0] prod12_fin = c12_ovf ? {s12_s3,5'h1F,2'b00} : {s12_s3,c12_es[4:0],c12_frac2};
  wire [7:0] prod21_fin = c21_ovf ? {s21_s3,5'h1F,2'b00} : {s21_s3,c21_es[4:0],c21_frac2};
  wire [7:0] prod22_fin = c22_ovf ? {s22_s3,5'h1F,2'b00} : {s22_s3,c22_es[4:0],c22_frac2};

  wire [7:0] prod11_fp8 = nan_11?QNAN8_E5 : inf_11?{s11_s3,5'h1F,2'b00} : zer_11?{s11_s3,5'd0,2'd0} : prod11_fin;
  wire [7:0] prod12_fp8 = nan_12?QNAN8_E5 : inf_12?{s12_s3,5'h1F,2'b00} : zer_12?{s12_s3,5'd0,2'd0} : prod12_fin;
  wire [7:0] prod21_fp8 = nan_21?QNAN8_E5 : inf_21?{s21_s3,5'h1F,2'b00} : zer_21?{s21_s3,5'd0,2'd0} : prod21_fin;
  wire [7:0] prod22_fp8 = nan_22?QNAN8_E5 : inf_22?{s22_s3,5'h1F,2'b00} : zer_22?{s22_s3,5'd0,2'd0} : prod22_fin;

  function automatic [15:0] fp8e5_to_fp16;
    input [7:0] val8;
    reg sign; reg [4:0] exp8; reg [1:0] frac2;
    begin
      sign=val8[7]; exp8=val8[6:2]; frac2=val8[1:0];
      if (exp8==5'h1F)
        fp8e5_to_fp16 = (frac2==2'b00) ? (sign?FP16_NINF:FP16_PINF) : FP16_QNAN;
      else if (exp8==5'd0)
        fp8e5_to_fp16 = {sign, 15'd0};
      else
        fp8e5_to_fp16 = {sign, exp8, {frac2, 8'b0}};
    end
  endfunction

  wire [15:0] prod11_fp16=fp8e5_to_fp16(prod11_fp8);
  wire [15:0] prod12_fp16=fp8e5_to_fp16(prod12_fp8);
  wire [15:0] prod21_fp16=fp8e5_to_fp16(prod21_fp8);
  wire [15:0] prod22_fp16=fp8e5_to_fp16(prod22_fp8);

  // Mid pipeline
  reg [15:0] p11_m[0:MID_STAGES],p12_m[0:MID_STAGES],p21_m[0:MID_STAGES],p22_m[0:MID_STAGES];
  reg [15:0] c11_m[0:MID_STAGES],c12_m[0:MID_STAGES],c21_m[0:MID_STAGES],c22_m[0:MID_STAGES];

  always @(*) begin
    p11_m[0]=prod11_fp16; p12_m[0]=prod12_fp16; p21_m[0]=prod21_fp16; p22_m[0]=prod22_fp16;
    c11_m[0]=c11_s3; c12_m[0]=c12_s3; c21_m[0]=c21_s3; c22_m[0]=c22_s3;
  end

  generate genvar gm;
    for (gm=1;gm<=MID_STAGES;gm=gm+1) begin:gen_mid
      always @(posedge clk) begin
        p11_m[gm]<=p11_m[gm-1]; p12_m[gm]<=p12_m[gm-1]; p21_m[gm]<=p21_m[gm-1]; p22_m[gm]<=p22_m[gm-1];
        c11_m[gm]<=c11_m[gm-1]; c12_m[gm]<=c12_m[gm-1]; c21_m[gm]<=c21_m[gm-1]; c22_m[gm]<=c22_m[gm-1];
      end
    end
  endgenerate

  wire [15:0] sum11_w,sum12_w,sum21_w,sum22_w;

  fp16_add #(.LATENCY(ADD_LAT)) u_add11 (.clk(clk),.x16(p11_m[MID_STAGES]),.y16(c11_m[MID_STAGES]),.result(sum11_w));
  fp16_add #(.LATENCY(ADD_LAT)) u_add12 (.clk(clk),.x16(p12_m[MID_STAGES]),.y16(c12_m[MID_STAGES]),.result(sum12_w));
  fp16_add #(.LATENCY(ADD_LAT)) u_add21 (.clk(clk),.x16(p21_m[MID_STAGES]),.y16(c21_m[MID_STAGES]),.result(sum21_w));
  fp16_add #(.LATENCY(ADD_LAT)) u_add22 (.clk(clk),.x16(p22_m[MID_STAGES]),.y16(c22_m[MID_STAGES]),.result(sum22_w));

  assign result = {sum22_w, sum21_w, sum12_w, sum11_w};

endmodule

`default_nettype wire
