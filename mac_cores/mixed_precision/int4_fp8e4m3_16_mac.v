`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// int4_fp8e4m3_16_mac : 4-lane INT4 x FP8(E4M3) -> FP16 accumulation
//   Two INT4 lanes x two FP8(E4M3) lanes, products widened to FP16.
//   Pipeline: S1 pack | S2 DSP capture | MID_STAGES | ADD_LAT fp16_add
//   Output is combinational concat of adder outputs -- no extra reg.
//
//   Total latency = 2 (mul) + MID_STAGES + ADD_LAT  (EXACT)
//   MUL_LAT, MID_STAGES, ADD_LAT parameterized.
// ==========================================================================
module int4_fp8e4m3_16_mac #(
    parameter integer MUL_LAT    = 2,
    parameter integer MID_STAGES = 0,
    parameter integer ADD_LAT    = 2
) (
    input  wire        clk,
    input  wire [7:0]  a_int4,    // {a2[7:4], a1[3:0]} INT4 lanes
    input  wire [15:0] b_fp8,     // {b2[15:8], b1[7:0]} FP8(E4M3)
    input  wire [63:0] c_fp16,    // {c22,c21,c12,c11} FP16 lanes
    output wire [63:0] result     // {y22,y21,y12,y11}
);
  `include "int4_fp8_common.vh"
  `DECL_INT4_DECODE_FP8_FIELDS

  localparam integer EWIDTH = 4;
  localparam integer FWIDTH = 3;
  localparam integer MBITS  = 1 + FWIDTH;
  localparam integer BIAS   = 7;

  localparam [15:0] FP16_QNAN       = 16'h7E00;
  localparam [15:0] FP16_MAXFIN_POS = 16'h5B80;
  localparam [15:0] FP16_MAXFIN_NEG = 16'hDB80;

  // ---- INT4 decode ----
  wire [8:0] a1_core = int4_decode_fp8_fields(a_int4[3:0]);
  wire [8:0] a2_core = int4_decode_fp8_fields(a_int4[7:4]);

  wire a1_zero = a1_core[8], a2_zero = a2_core[8];
  wire sa1 = a1_core[7], sa2 = a2_core[7];
  wire [3:0] ea1_unb = a1_core[6:3], ea2_unb = a2_core[6:3];
  wire [2:0] fa1_core = a1_core[2:0], fa2_core = a2_core[2:0];

  wire [4:0] ea1_bias = {1'b0, ea1_unb} + 5'd7;
  wire [4:0] ea2_bias = {1'b0, ea2_unb} + 5'd7;
  wire [EWIDTH-1:0] ea1 = a1_zero ? 4'd0 : ea1_bias[3:0];
  wire [EWIDTH-1:0] ea2 = a2_zero ? 4'd0 : ea2_bias[3:0];

  wire [MBITS-1:0] Ma1 = a1_zero ? 4'd0 : {1'b1, fa1_core};
  wire [MBITS-1:0] Ma2 = a2_zero ? 4'd0 : {1'b1, fa2_core};

  // ---- FP8 B lanes ----
  wire [7:0] b1 = b_fp8[7:0], b2 = b_fp8[15:8];
  wire sb1=b1[7], sb2=b2[7];
  wire [EWIDTH-1:0] eb1=b1[6:3], eb2=b2[6:3];
  wire [FWIDTH-1:0] fb1=b1[2:0], fb2=b2[2:0];
  wire b1_nan=(eb1==4'hF), b2_nan=(eb2==4'hF);
  wire b1_zero=(eb1==4'd0), b2_zero=(eb2==4'd0);

  wire s11=sa1^sb1, s12=sa1^sb2, s21=sa2^sb1, s22=sa2^sb2;

  wire signed [6:0] e11_s1=$signed({3'd0,ea1})+$signed({3'd0,eb1})-$signed(7'd7);
  wire signed [6:0] e12_s1=$signed({3'd0,ea1})+$signed({3'd0,eb2})-$signed(7'd7);
  wire signed [6:0] e21_s1=$signed({3'd0,ea2})+$signed({3'd0,eb1})-$signed(7'd7);
  wire signed [6:0] e22_s1=$signed({3'd0,ea2})+$signed({3'd0,eb2})-$signed(7'd7);

  wire [15:0] c11=c_fp16[15:0],c12=c_fp16[31:16],c21=c_fp16[47:32],c22=c_fp16[63:48];

  // ---- S1 ----
  reg [26:0] A_pack; reg [17:0] B_pack;
  reg s11_s2,s12_s2,s21_s2,s22_s2;
  reg signed [6:0] e11_s2,e12_s2,e21_s2,e22_s2;
  reg a1_zero_s2,a2_zero_s2,b1_zero_s2,b2_zero_s2,b1_nan_s2,b2_nan_s2;
  reg [15:0] c11_s2,c12_s2,c21_s2,c22_s2;

  always @(posedge clk) begin
    A_pack <= {7'b0, Ma2, 12'b0, Ma1};
    B_pack <= {6'b0, (b2_zero?4'd0:{1'b1,fb2}), 4'b0, (b1_zero?4'd0:{1'b1,fb1})};
    s11_s2<=s11; s12_s2<=s12; s21_s2<=s21; s22_s2<=s22;
    e11_s2<=e11_s1; e12_s2<=e12_s1; e21_s2<=e21_s1; e22_s2<=e22_s1;
    a1_zero_s2<=a1_zero; a2_zero_s2<=a2_zero;
    b1_zero_s2<=b1_zero; b2_zero_s2<=b2_zero;
    b1_nan_s2<=b1_nan; b2_nan_s2<=b2_nan;
    c11_s2<=c11; c12_s2<=c12; c21_s2<=c21; c22_s2<=c22;
  end

  // ---- DSP ----
  wire [44:0] product45;
  (* use_dsp = "yes" *)
  dsp_usage u_dsp (.clk(clk),.a(A_pack),.b(B_pack),.product(product45));

  reg [31:0] dsp_p;
  always @(posedge clk) dsp_p <= product45[31:0];

  // ---- S3 ----
  reg s11_s3,s12_s3,s21_s3,s22_s3;
  reg signed [6:0] e11_s3,e12_s3,e21_s3,e22_s3;
  reg a1_zero_s3,a2_zero_s3,b1_zero_s3,b2_zero_s3,b1_nan_s3,b2_nan_s3;
  reg [15:0] c11_s3,c12_s3,c21_s3,c22_s3;

  always @(posedge clk) begin
    s11_s3<=s11_s2; s12_s3<=s12_s2; s21_s3<=s21_s2; s22_s3<=s22_s2;
    e11_s3<=e11_s2; e12_s3<=e12_s2; e21_s3<=e21_s2; e22_s3<=e22_s2;
    a1_zero_s3<=a1_zero_s2; a2_zero_s3<=a2_zero_s2;
    b1_zero_s3<=b1_zero_s2; b2_zero_s3<=b2_zero_s2;
    b1_nan_s3<=b1_nan_s2; b2_nan_s3<=b2_nan_s2;
    c11_s3<=c11_s2; c12_s3<=c12_s2; c21_s3<=c21_s2; c22_s3<=c22_s2;
  end

  wire [7:0] P11=dsp_p[7:0],P12=dsp_p[15:8],P21=dsp_p[23:16],P22=dsp_p[31:24];

  wire nan_11=b1_nan_s3, nan_12=b2_nan_s3, nan_21=b1_nan_s3, nan_22=b2_nan_s3;
  wire zer_11=~nan_11&(a1_zero_s3|b1_zero_s3);
  wire zer_12=~nan_12&(a1_zero_s3|b2_zero_s3);
  wire zer_21=~nan_21&(a2_zero_s3|b1_zero_s3);
  wire zer_22=~nan_22&(a2_zero_s3|b2_zero_s3);

  // ---- Widen to FP16 ----
  function automatic [15:0] lane_fp16_from_e4;
    input        sign_in;
    input signed [6:0] exp_unb_in;
    input [7:0]  prod_q8;
    input        is_zero;
    input        is_nan;
    reg signed [6:0] exp_adj;
    reg [11:0] mant_shift;
    reg [11:0] mant_norm_full;
    reg [10:0] mant_norm;
    reg [4:0]  exp16;
    begin
      if (is_nan)
        lane_fp16_from_e4 = FP16_QNAN;
      else if (is_zero)
        lane_fp16_from_e4 = {sign_in, 15'd0};
      else begin
        exp_adj = exp_unb_in + (prod_q8[7] ? 7'sd1 : 7'sd0);
        if ((exp_adj < 7'sd0) || (exp_adj > 7'sd14))
          lane_fp16_from_e4 = sign_in ? FP16_MAXFIN_NEG : FP16_MAXFIN_POS;
        else begin
          exp16          = exp_adj[4:0] + 5'd8;
          mant_shift     = {prod_q8, 4'b0000};
          mant_norm_full = prod_q8[7] ? (mant_shift >> 1) : mant_shift;
          mant_norm      = mant_norm_full[10:0];
          lane_fp16_from_e4 = {sign_in, exp16, mant_norm[9:0]};
        end
      end
    end
  endfunction

  wire [15:0] prod11_fp16 = lane_fp16_from_e4(s11_s3, e11_s3, P11, zer_11, nan_11);
  wire [15:0] prod12_fp16 = lane_fp16_from_e4(s12_s3, e12_s3, P12, zer_12, nan_12);
  wire [15:0] prod21_fp16 = lane_fp16_from_e4(s21_s3, e21_s3, P21, zer_21, nan_21);
  wire [15:0] prod22_fp16 = lane_fp16_from_e4(s22_s3, e22_s3, P22, zer_22, nan_22);

  // ---- Mid pipeline ----
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
