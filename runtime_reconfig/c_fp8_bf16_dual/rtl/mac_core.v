`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp8_bf16_dual_mac : runtime-reconfigurable BF16 (2-lane) / FP8e4m3 (4-lane) MAC
//   - mode_fp8 == 0 : 2-lane BF16×BF16 + BF16 → BF16
//   - mode_fp8 == 1 : 4-lane FP8×FP8 + BF16 → BF16
//   - Backend: 4 parameterized bf16_add instances (LATENCY = ADD_LAT)
//   - Total latency = MUL_LAT + MID_STAGES + ADD_LAT
//       (2,0,2) -> 4c   (2,0,3) -> 5c   (2,1,3) -> 6c
//   - II = 1
// =============================================================
module fp8_bf16_dual_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 0,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire        mode_fp8,
    input  wire [31:0] a32,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  localparam integer DEPTH = MUL_LAT + MID_STAGES + ADD_LAT;

  // ----------------------------------------------------------------
  // Mode pipeline: track the input mode through DEPTH stages.
  //   mode_pipe[0]  : aligned with S1 (DSP input mux)
  //   mode_pipe[1]  : aligned with S2 (bf16_add input mux)
  //   mode_pipe[N-1]: aligned with output (result mux)
  // ----------------------------------------------------------------
  reg [DEPTH-1:0] mode_pipe;
  integer mp_i;
  always @(posedge clk) begin
    mode_pipe[0] <= mode_fp8;
    for (mp_i = 1; mp_i < DEPTH; mp_i = mp_i + 1)
      mode_pipe[mp_i] <= mode_pipe[mp_i-1];
  end

  // ----------------------------------------------------------------
  // S1 mappers (BF16 + FP8) — both run in parallel
  // ----------------------------------------------------------------
  wire [26:0] bf16_dsp_a_s1;
  wire [17:0] bf16_dsp_b_s1;
  wire signed [8:0] exp_hi_bf16_s1, exp_lo_bf16_s1;
  wire        sign_hi_bf16_s1, sign_lo_bf16_s1;
  wire        a_hi_nan_s1, a_lo_nan_s1, b_nan_s1;
  wire        a_hi_inf_s1, a_lo_inf_s1, b_inf_s1;
  wire        a_hi_zero_s1, a_lo_zero_s1, b_zero_s1;
  wire [15:0] c_lo_bf16_s1, c_hi_bf16_s1;

  bf16_mac_s1_prep u_bf16_s1 (
      .clk(clk), .a32(a32), .b16(b16), .c32(c64[31:0]),
      .man_a_packed(bf16_dsp_a_s1), .man_b_packed(bf16_dsp_b_s1),
      .exp_hi_s1(exp_hi_bf16_s1), .exp_lo_s1(exp_lo_bf16_s1),
      .sign_hi_s1(sign_hi_bf16_s1), .sign_lo_s1(sign_lo_bf16_s1),
      .a_hi_nan_s1(a_hi_nan_s1), .a_lo_nan_s1(a_lo_nan_s1), .b_nan_s1(b_nan_s1),
      .a_hi_inf_s1(a_hi_inf_s1), .a_lo_inf_s1(a_lo_inf_s1), .b_inf_s1(b_inf_s1),
      .a_hi_zero_s1(a_hi_zero_s1), .a_lo_zero_s1(a_lo_zero_s1), .b_zero_s1(b_zero_s1),
      .c_lo_s1(c_lo_bf16_s1), .c_hi_s1(c_hi_bf16_s1)
  );

  wire [26:0] fp8_dsp_a_s1;
  wire [17:0] fp8_dsp_b_s1;
  wire        s11_s1, s12_s1, s21_s1, s22_s1;
  wire signed [6:0] e11_s1, e12_s1, e21_s1, e22_s1;
  wire        a1_nan_fp8_s1, a2_nan_fp8_s1, b1_nan_fp8_s1, b2_nan_fp8_s1;
  wire        a1_zero_fp8_s1, a2_zero_fp8_s1, b1_zero_fp8_s1, b2_zero_fp8_s1;
  wire [15:0] c11_fp8_s1, c12_fp8_s1, c21_fp8_s1, c22_fp8_s1;

  fp8_mac_s1_prep u_fp8_s1 (
      .clk(clk), .a32(a32), .b16(b16), .c64(c64),
      .a_pack(fp8_dsp_a_s1), .b_pack(fp8_dsp_b_s1),
      .s11_s1(s11_s1), .s12_s1(s12_s1), .s21_s1(s21_s1), .s22_s1(s22_s1),
      .e11_s1(e11_s1), .e12_s1(e12_s1), .e21_s1(e21_s1), .e22_s1(e22_s1),
      .a1_nan_s1(a1_nan_fp8_s1), .a2_nan_s1(a2_nan_fp8_s1),
      .b1_nan_s1(b1_nan_fp8_s1), .b2_nan_s1(b2_nan_fp8_s1),
      .a1_zero_s1(a1_zero_fp8_s1), .a2_zero_s1(a2_zero_fp8_s1),
      .b1_zero_s1(b1_zero_fp8_s1), .b2_zero_s1(b2_zero_fp8_s1),
      .c11_s1(c11_fp8_s1), .c12_s1(c12_fp8_s1),
      .c21_s1(c21_fp8_s1), .c22_s1(c22_fp8_s1)
  );

  // DSP input mux (mode_pipe[0] aligned with S1 reg outputs)
  wire [26:0] dsp_a_s1 = mode_pipe[0] ? fp8_dsp_a_s1 : bf16_dsp_a_s1;
  wire [17:0] dsp_b_s1 = mode_pipe[0] ? fp8_dsp_b_s1 : bf16_dsp_b_s1;

  wire [44:0] product45;
  dsp_usage u_dsp (.clk(clk), .a(dsp_a_s1), .b(dsp_b_s1), .product(product45));

  // ----------------------------------------------------------------
  // S2 postproc: BF16 + FP8 paths in parallel
  // ----------------------------------------------------------------
  wire [15:0] bf16_prod_lo_s2, bf16_prod_hi_s2;
  wire [15:0] bf16_c_lo_s2, bf16_c_hi_s2;

  mac_postproc_bf16 u_bf16_pp (
      .clk(clk),
      .exp_hi_bf16_s1(exp_hi_bf16_s1), .exp_lo_bf16_s1(exp_lo_bf16_s1),
      .sign_hi_bf16_s1(sign_hi_bf16_s1), .sign_lo_bf16_s1(sign_lo_bf16_s1),
      .a_hi_nan_s1(a_hi_nan_s1), .a_lo_nan_s1(a_lo_nan_s1), .b_nan_s1(b_nan_s1),
      .a_hi_inf_s1(a_hi_inf_s1), .a_lo_inf_s1(a_lo_inf_s1), .b_inf_s1(b_inf_s1),
      .a_hi_zero_s1(a_hi_zero_s1), .a_lo_zero_s1(a_lo_zero_s1), .b_zero_s1(b_zero_s1),
      .c_lo_bf16_s1(c_lo_bf16_s1), .c_hi_bf16_s1(c_hi_bf16_s1),
      .product45(product45),
      .prod_lo16_bf16(bf16_prod_lo_s2), .prod_hi16_bf16(bf16_prod_hi_s2),
      .c_lo_bf16_s2(bf16_c_lo_s2), .c_hi_bf16_s2(bf16_c_hi_s2)
  );

  wire [15:0] fp8_prod0_s2, fp8_prod1_s2, fp8_prod2_s2, fp8_prod3_s2;
  wire [15:0] fp8_c0_s2,    fp8_c1_s2,    fp8_c2_s2,    fp8_c3_s2;

  fp8_mac_postproc u_fp8_pp (
      .clk(clk),
      .s11_s1(s11_s1), .s12_s1(s12_s1), .s21_s1(s21_s1), .s22_s1(s22_s1),
      .e11_s1(e11_s1), .e12_s1(e12_s1), .e21_s1(e21_s1), .e22_s1(e22_s1),
      .a1_nan_s1(a1_nan_fp8_s1), .a2_nan_s1(a2_nan_fp8_s1),
      .b1_nan_s1(b1_nan_fp8_s1), .b2_nan_s1(b2_nan_fp8_s1),
      .a1_zero_s1(a1_zero_fp8_s1), .a2_zero_s1(a2_zero_fp8_s1),
      .b1_zero_s1(b1_zero_fp8_s1), .b2_zero_s1(b2_zero_fp8_s1),
      .c11_s1(c11_fp8_s1), .c12_s1(c12_fp8_s1),
      .c21_s1(c21_fp8_s1), .c22_s1(c22_fp8_s1),
      .product45(product45),
      .prod_lane0_s2(fp8_prod0_s2), .prod_lane1_s2(fp8_prod1_s2),
      .prod_lane2_s2(fp8_prod2_s2), .prod_lane3_s2(fp8_prod3_s2),
      .c_lane0_s2(fp8_c0_s2), .c_lane1_s2(fp8_c1_s2),
      .c_lane2_s2(fp8_c2_s2), .c_lane3_s2(fp8_c3_s2)
  );

  // bf16_add input mux (mode_pipe[1] aligned with S2 outputs)
  wire [15:0] add_a0_s2 = mode_pipe[1] ? fp8_prod0_s2 : bf16_prod_lo_s2;
  wire [15:0] add_a1_s2 = mode_pipe[1] ? fp8_prod1_s2 : bf16_prod_hi_s2;
  wire [15:0] add_a2_s2 = mode_pipe[1] ? fp8_prod2_s2 : 16'h0000;
  wire [15:0] add_a3_s2 = mode_pipe[1] ? fp8_prod3_s2 : 16'h0000;
  wire [15:0] add_b0_s2 = mode_pipe[1] ? fp8_c0_s2    : bf16_c_lo_s2;
  wire [15:0] add_b1_s2 = mode_pipe[1] ? fp8_c1_s2    : bf16_c_hi_s2;
  wire [15:0] add_b2_s2 = mode_pipe[1] ? fp8_c2_s2    : 16'h0000;
  wire [15:0] add_b3_s2 = mode_pipe[1] ? fp8_c3_s2    : 16'h0000;

  // ----------------------------------------------------------------
  // MID_STAGES register pipeline between S2 and bf16_add
  // ----------------------------------------------------------------
  reg [15:0] add_a0_mid [0:MID_STAGES];
  reg [15:0] add_a1_mid [0:MID_STAGES];
  reg [15:0] add_a2_mid [0:MID_STAGES];
  reg [15:0] add_a3_mid [0:MID_STAGES];
  reg [15:0] add_b0_mid [0:MID_STAGES];
  reg [15:0] add_b1_mid [0:MID_STAGES];
  reg [15:0] add_b2_mid [0:MID_STAGES];
  reg [15:0] add_b3_mid [0:MID_STAGES];
  always @(*) begin
    add_a0_mid[0] = add_a0_s2; add_a1_mid[0] = add_a1_s2;
    add_a2_mid[0] = add_a2_s2; add_a3_mid[0] = add_a3_s2;
    add_b0_mid[0] = add_b0_s2; add_b1_mid[0] = add_b1_s2;
    add_b2_mid[0] = add_b2_s2; add_b3_mid[0] = add_b3_s2;
  end
  genvar gm;
  generate
    for (gm = 1; gm <= MID_STAGES; gm = gm + 1) begin : g_mid
      always @(posedge clk) begin
        add_a0_mid[gm] <= add_a0_mid[gm-1];
        add_a1_mid[gm] <= add_a1_mid[gm-1];
        add_a2_mid[gm] <= add_a2_mid[gm-1];
        add_a3_mid[gm] <= add_a3_mid[gm-1];
        add_b0_mid[gm] <= add_b0_mid[gm-1];
        add_b1_mid[gm] <= add_b1_mid[gm-1];
        add_b2_mid[gm] <= add_b2_mid[gm-1];
        add_b3_mid[gm] <= add_b3_mid[gm-1];
      end
    end
  endgenerate

  // ----------------------------------------------------------------
  // 4 × parameterized BF16 adders
  // ----------------------------------------------------------------
  wire [15:0] sum0, sum1, sum2, sum3;
  bf16_add #(.LATENCY(ADD_LAT)) u_add0 (.clk(clk), .a16(add_a0_mid[MID_STAGES]), .b16(add_b0_mid[MID_STAGES]), .c16(sum0));
  bf16_add #(.LATENCY(ADD_LAT)) u_add1 (.clk(clk), .a16(add_a1_mid[MID_STAGES]), .b16(add_b1_mid[MID_STAGES]), .c16(sum1));
  bf16_add #(.LATENCY(ADD_LAT)) u_add2 (.clk(clk), .a16(add_a2_mid[MID_STAGES]), .b16(add_b2_mid[MID_STAGES]), .c16(sum2));
  bf16_add #(.LATENCY(ADD_LAT)) u_add3 (.clk(clk), .a16(add_a3_mid[MID_STAGES]), .b16(add_b3_mid[MID_STAGES]), .c16(sum3));

  // ----------------------------------------------------------------
  // Output mux: mode_pipe[DEPTH-1] aligns with bf16_add outputs
  // ----------------------------------------------------------------
  assign result = mode_pipe[DEPTH-1] ? {sum3, sum2, sum1, sum0}
                                     : {32'd0, sum1, sum0};
endmodule
`default_nettype wire
