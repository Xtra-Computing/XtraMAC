`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// fp8e5m2_16_mac_4lane : 4-lane FP8(E5M2) x FP8(E5M2) -> FP16 accumulation
//   DSP packing: A={12'b0, Ma2, 9'b0, Ma1}, B={9'b0, Mb2, 3'b0, Mb1}
//   Product windows: 6-bit each at [5:0],[11:6],[17:12],[23:18]
//   Pipeline: S1 pack | S2 DSP capture | MID_STAGES | ADD_LAT fp16_add
//   Output is combinational concat of adder outputs -- no extra reg.
//
//   Total latency = 2 (mul) + MID_STAGES + ADD_LAT  (EXACT)
//   MUL_LAT, MID_STAGES, ADD_LAT parameterized.
// ==========================================================================
module fp8e5m2_16_mac_4lane #(
    parameter integer MUL_LAT    = 2,
    parameter integer MID_STAGES = 0,
    parameter integer ADD_LAT    = 2
) (
    input  wire        clk,
    input  wire [31:0] a18,
    input  wire [15:0] b18,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  localparam integer EWIDTH = 5;
  localparam integer FWIDTH = 2;
  localparam integer MBITS  = 3;
  localparam integer BIAS_V = 15;

  localparam [15:0] FP16_QNAN = 16'h7E00;
  localparam [15:0] FP16_PINF = 16'h7C00;
  localparam [15:0] FP16_NINF = 16'hFC00;

  wire [7:0] a1=a18[7:0], a2=a18[15:8], b1=b18[7:0], b2=b18[15:8];

  wire sa1=a1[7],sa2=a2[7],sb1=b1[7],sb2=b2[7];
  wire [4:0] ea1=a1[6:2],ea2=a2[6:2],eb1=b1[6:2],eb2=b2[6:2];
  wire [1:0] fa1=a1[1:0],fa2=a2[1:0],fb1=b1[1:0],fb2=b2[1:0];

  wire a1_nan=(ea1==5'h1F)&&(fa1!=2'd0), a2_nan=(ea2==5'h1F)&&(fa2!=2'd0);
  wire b1_nan=(eb1==5'h1F)&&(fb1!=2'd0), b2_nan=(eb2==5'h1F)&&(fb2!=2'd0);
  wire a1_inf=(ea1==5'h1F)&&(fa1==2'd0), a2_inf=(ea2==5'h1F)&&(fa2==2'd0);
  wire b1_inf=(eb1==5'h1F)&&(fb1==2'd0), b2_inf=(eb2==5'h1F)&&(fb2==2'd0);
  wire a1_zero=(ea1==5'd0),a2_zero=(ea2==5'd0),b1_zero=(eb1==5'd0),b2_zero=(eb2==5'd0);

  wire s11=sa1^sb1,s12=sa1^sb2,s21=sa2^sb1,s22=sa2^sb2;

  wire signed [7:0] e11_s1=$signed({3'd0,ea1})+$signed({3'd0,eb1})-$signed(8'd15);
  wire signed [7:0] e12_s1=$signed({3'd0,ea1})+$signed({3'd0,eb2})-$signed(8'd15);
  wire signed [7:0] e21_s1=$signed({3'd0,ea2})+$signed({3'd0,eb1})-$signed(8'd15);
  wire signed [7:0] e22_s1=$signed({3'd0,ea2})+$signed({3'd0,eb2})-$signed(8'd15);

  wire [2:0] Ma1=a1_zero?3'd0:{1'b1,fa1}, Ma2=a2_zero?3'd0:{1'b1,fa2};
  wire [2:0] Mb1=b1_zero?3'd0:{1'b1,fb1}, Mb2=b2_zero?3'd0:{1'b1,fb2};

  wire [15:0] c11=c64[15:0],c12=c64[31:16],c21=c64[47:32],c22=c64[63:48];

  // ---- S1 ----
  reg [26:0] A_pack; reg [17:0] B_pack;
  reg s11_s2,s12_s2,s21_s2,s22_s2;
  reg signed [7:0] e11_s2,e12_s2,e21_s2,e22_s2;
  reg a1_nan_s2,a2_nan_s2,b1_nan_s2,b2_nan_s2;
  reg a1_inf_s2,a2_inf_s2,b1_inf_s2,b2_inf_s2;
  reg a1_zero_s2,a2_zero_s2,b1_zero_s2,b2_zero_s2;
  reg [15:0] c11_s2,c12_s2,c21_s2,c22_s2;

  always @(posedge clk) begin
    A_pack<={12'b0,Ma2,9'b0,Ma1};
    B_pack<={9'b0,Mb2,3'b0,Mb1};
    s11_s2<=s11; s12_s2<=s12; s21_s2<=s21; s22_s2<=s22;
    e11_s2<=e11_s1; e12_s2<=e12_s1; e21_s2<=e21_s1; e22_s2<=e22_s1;
    a1_nan_s2<=a1_nan; a2_nan_s2<=a2_nan; b1_nan_s2<=b1_nan; b2_nan_s2<=b2_nan;
    a1_inf_s2<=a1_inf; a2_inf_s2<=a2_inf; b1_inf_s2<=b1_inf; b2_inf_s2<=b2_inf;
    a1_zero_s2<=a1_zero; a2_zero_s2<=a2_zero; b1_zero_s2<=b1_zero; b2_zero_s2<=b2_zero;
    c11_s2<=c11; c12_s2<=c12; c21_s2<=c21; c22_s2<=c22;
  end

  // ---- S2: DSP ----
  wire [44:0] product45;
  (* use_dsp = "yes" *)
  dsp_usage u_dsp (.clk(clk),.a(A_pack),.b(B_pack),.product(product45));

  reg [23:0] dsp_p;
  always @(posedge clk) dsp_p <= product45[23:0];

  // ---- S3 ----
  reg s11_s3,s12_s3,s21_s3,s22_s3;
  reg signed [7:0] e11_s3,e12_s3,e21_s3,e22_s3;
  reg a1_nan_s3,a2_nan_s3,b1_nan_s3,b2_nan_s3;
  reg a1_inf_s3,a2_inf_s3,b1_inf_s3,b2_inf_s3;
  reg a1_zero_s3,a2_zero_s3,b1_zero_s3,b2_zero_s3;
  reg [15:0] c11_s3,c12_s3,c21_s3,c22_s3;

  always @(posedge clk) begin
    s11_s3<=s11_s2; s12_s3<=s12_s2; s21_s3<=s21_s2; s22_s3<=s22_s2;
    e11_s3<=e11_s2; e12_s3<=e12_s2; e21_s3<=e21_s2; e22_s3<=e22_s2;
    a1_nan_s3<=a1_nan_s2; a2_nan_s3<=a2_nan_s2; b1_nan_s3<=b1_nan_s2; b2_nan_s3<=b2_nan_s2;
    a1_inf_s3<=a1_inf_s2; a2_inf_s3<=a2_inf_s2; b1_inf_s3<=b1_inf_s2; b2_inf_s3<=b2_inf_s2;
    a1_zero_s3<=a1_zero_s2; a2_zero_s3<=a2_zero_s2; b1_zero_s3<=b1_zero_s2; b2_zero_s3<=b2_zero_s2;
    c11_s3<=c11_s2; c12_s3<=c12_s2; c21_s3<=c21_s2; c22_s3<=c22_s2;
  end

  wire [5:0] P11=dsp_p[5:0],P12=dsp_p[11:6],P21=dsp_p[17:12],P22=dsp_p[23:18];

  // ---- Specials ----
  wire nan_11=a1_nan_s3|b1_nan_s3|((a1_inf_s3&b1_zero_s3)|(a1_zero_s3&b1_inf_s3));
  wire nan_12=a1_nan_s3|b2_nan_s3|((a1_inf_s3&b2_zero_s3)|(a1_zero_s3&b2_inf_s3));
  wire nan_21=a2_nan_s3|b1_nan_s3|((a2_inf_s3&b1_zero_s3)|(a2_zero_s3&b1_inf_s3));
  wire nan_22=a2_nan_s3|b2_nan_s3|((a2_inf_s3&b2_zero_s3)|(a2_zero_s3&b2_inf_s3));

  wire inf_11=~nan_11&(a1_inf_s3|b1_inf_s3), inf_12=~nan_12&(a1_inf_s3|b2_inf_s3);
  wire inf_21=~nan_21&(a2_inf_s3|b1_inf_s3), inf_22=~nan_22&(a2_inf_s3|b2_inf_s3);

  wire zer_11=~nan_11&~inf_11&(a1_zero_s3|b1_zero_s3);
  wire zer_12=~nan_12&~inf_12&(a1_zero_s3|b2_zero_s3);
  wire zer_21=~nan_21&~inf_21&(a2_zero_s3|b1_zero_s3);
  wire zer_22=~nan_22&~inf_22&(a2_zero_s3|b2_zero_s3);

  // ---- Widen E5M2 product to FP16 ----
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
      if (is_nan)
        widen_e5m2_to_fp16 = FP16_QNAN;
      else if (is_inf)
        widen_e5m2_to_fp16 = sign_in ? FP16_NINF : FP16_PINF;
      else if (is_zero)
        widen_e5m2_to_fp16 = {sign_in, 15'd0};
      else begin
        carry = prod6[5];
        es = exp_unb + (carry ? 8'sd1 : 8'sd0);
        ovf = (es < 8'sd0) || (es > 8'sd30);
        if (ovf)
          widen_e5m2_to_fp16 = sign_in ? FP16_NINF : FP16_PINF;
        else begin
          mant_carry   = {prod6, 5'b0};
          mant_nocarry = {prod6, 6'b0};
          mant_norm    = carry ? mant_carry : mant_nocarry[10:0];
          widen_e5m2_to_fp16 = {sign_in, es[4:0], mant_norm[9:0]};
        end
      end
    end
  endfunction

  wire [15:0] prod11_w = widen_e5m2_to_fp16(s11_s3,e11_s3,P11,nan_11,inf_11,zer_11);
  wire [15:0] prod12_w = widen_e5m2_to_fp16(s12_s3,e12_s3,P12,nan_12,inf_12,zer_12);
  wire [15:0] prod21_w = widen_e5m2_to_fp16(s21_s3,e21_s3,P21,nan_21,inf_21,zer_21);
  wire [15:0] prod22_w = widen_e5m2_to_fp16(s22_s3,e22_s3,P22,nan_22,inf_22,zer_22);

  // ---- Mid pipeline ----
  reg [15:0] p11_m[0:MID_STAGES],p12_m[0:MID_STAGES],p21_m[0:MID_STAGES],p22_m[0:MID_STAGES];
  reg [15:0] c11_m[0:MID_STAGES],c12_m[0:MID_STAGES],c21_m[0:MID_STAGES],c22_m[0:MID_STAGES];

  always @(*) begin
    p11_m[0]=prod11_w; p12_m[0]=prod12_w; p21_m[0]=prod21_w; p22_m[0]=prod22_w;
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
