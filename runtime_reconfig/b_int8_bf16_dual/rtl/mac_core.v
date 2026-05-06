`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int8_bf16_mac : runtime-reconfigurable INT8 / BF16 MAC
//   - mode_int8 == 1 : 2-lane INT8 × INT8 + INT32 → INT32 (sat-add)
//   - mode_int8 == 0 : 2-lane BF16 × BF16 + BF16 → BF16
//   - INT path uses parameterized int8_add (LATENCY = ADD_LAT)
//   - BF16 path uses XtraMAC_v2 parameterized bf16_add (LATENCY = ADD_LAT)
//   - Total latency = MUL_LAT + MID_STAGES + ADD_LAT
//       (2,0,2) -> 4c   (2,0,3) -> 5c   (2,1,3) -> 6c
//   - II = 1
// =============================================================
module int8_bf16_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 0,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire        mode_int8,
    input  wire [31:0] a32,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  localparam integer DEPTH = MUL_LAT + MID_STAGES + ADD_LAT;

  // ----------------------------------------------------------------
  // Mode pipeline
  // ----------------------------------------------------------------
  reg [DEPTH-1:0] mode_pipe;
  integer mp_i;
  always @(posedge clk) begin
    mode_pipe[0] <= mode_int8;
    for (mp_i = 1; mp_i < DEPTH; mp_i = mp_i + 1)
      mode_pipe[mp_i] <= mode_pipe[mp_i-1];
  end

  // ----------------------------------------------------------------
  // S1: parallel INT8 + BF16 mappers
  // ----------------------------------------------------------------
  wire [26:0] dsp_a_s1_int8, dsp_a_s1_bf16;
  wire [17:0] dsp_b_s1_int8, dsp_b_s1_bf16;
  wire        sign_hi_int8_s1, sign_lo_int8_s1;
  wire [31:0] c_hi_int8_s1, c_lo_int8_s1;
  wire signed [8:0] exp_hi_bf16_s1, exp_lo_bf16_s1;
  wire        sign_hi_bf16_s1, sign_lo_bf16_s1;
  wire        a_hi_nan_s1, a_lo_nan_s1, b_nan_s1;
  wire        a_hi_inf_s1, a_lo_inf_s1, b_inf_s1;
  wire        a_hi_zero_s1, a_lo_zero_s1, b_zero_s1;
  wire [15:0] c_hi_bf16_s1, c_lo_bf16_s1;

  mac_mapper_int8 u_map_int8 (
    .clk(clk), .a32(a32), .b16(b16), .c64(c64),
    .dsp_a_s1(dsp_a_s1_int8), .dsp_b_s1(dsp_b_s1_int8),
    .sign_hi_int8_s1(sign_hi_int8_s1), .sign_lo_int8_s1(sign_lo_int8_s1),
    .c_hi_s1(c_hi_int8_s1), .c_lo_s1(c_lo_int8_s1)
  );

  mac_mapper_bf16 u_map_bf16 (
    .clk(clk), .a32(a32), .b16(b16), .c32(c64[31:0]),
    .dsp_a_s1(dsp_a_s1_bf16), .dsp_b_s1(dsp_b_s1_bf16),
    .exp_hi_bf16_s1(exp_hi_bf16_s1), .exp_lo_bf16_s1(exp_lo_bf16_s1),
    .sign_hi_bf16_s1(sign_hi_bf16_s1), .sign_lo_bf16_s1(sign_lo_bf16_s1),
    .a_hi_nan_s1(a_hi_nan_s1), .a_lo_nan_s1(a_lo_nan_s1), .b_nan_s1(b_nan_s1),
    .a_hi_inf_s1(a_hi_inf_s1), .a_lo_inf_s1(a_lo_inf_s1), .b_inf_s1(b_inf_s1),
    .a_hi_zero_s1(a_hi_zero_s1), .a_lo_zero_s1(a_lo_zero_s1), .b_zero_s1(b_zero_s1),
    .c_lo_s1(c_lo_bf16_s1), .c_hi_s1(c_hi_bf16_s1)
  );

  // DSP input mux (mode_pipe[0] aligns with S1)
  wire [26:0] dsp_a_s1 = mode_pipe[0] ? dsp_a_s1_int8 : dsp_a_s1_bf16;
  wire [17:0] dsp_b_s1 = mode_pipe[0] ? dsp_b_s1_int8 : dsp_b_s1_bf16;

  wire [44:0] product45;
  dsp_usage u_dsp (.clk(clk), .a(dsp_a_s1), .b(dsp_b_s1), .product(product45));

  // ----------------------------------------------------------------
  // S2: parallel postproc
  // ----------------------------------------------------------------
  wire        sign_hi_int8_s2, sign_lo_int8_s2;
  wire [31:0] c_hi_int8_s2, c_lo_int8_s2;
  wire [15:0] prod_hi16_int8_mag, prod_lo16_int8_mag;

  mac_postproc_int8 u_pp_int8 (
    .clk(clk),
    .sign_hi_int8_s1(sign_hi_int8_s1), .sign_lo_int8_s1(sign_lo_int8_s1),
    .c_hi_int8_s1(c_hi_int8_s1), .c_lo_int8_s1(c_lo_int8_s1),
    .product45(product45),
    .sign_hi_int8_s2(sign_hi_int8_s2), .sign_lo_int8_s2(sign_lo_int8_s2),
    .c_hi_int8_s2(c_hi_int8_s2), .c_lo_int8_s2(c_lo_int8_s2),
    .prod_hi16_int8_mag(prod_hi16_int8_mag), .prod_lo16_int8_mag(prod_lo16_int8_mag)
  );

  wire [15:0] prod_lo16_bf16, prod_hi16_bf16;
  wire [15:0] c_lo_bf16_s2, c_hi_bf16_s2;

  mac_postproc_bf16 u_pp_bf16 (
    .clk(clk),
    .exp_hi_bf16_s1(exp_hi_bf16_s1), .exp_lo_bf16_s1(exp_lo_bf16_s1),
    .sign_hi_bf16_s1(sign_hi_bf16_s1), .sign_lo_bf16_s1(sign_lo_bf16_s1),
    .a_hi_nan_s1(a_hi_nan_s1), .a_lo_nan_s1(a_lo_nan_s1), .b_nan_s1(b_nan_s1),
    .a_hi_inf_s1(a_hi_inf_s1), .a_lo_inf_s1(a_lo_inf_s1), .b_inf_s1(b_inf_s1),
    .a_hi_zero_s1(a_hi_zero_s1), .a_lo_zero_s1(a_lo_zero_s1), .b_zero_s1(b_zero_s1),
    .c_lo_bf16_s1(c_lo_bf16_s1), .c_hi_bf16_s1(c_hi_bf16_s1),
    .product45(product45),
    .prod_lo16_bf16(prod_lo16_bf16), .prod_hi16_bf16(prod_hi16_bf16),
    .c_lo_bf16_s2(c_lo_bf16_s2), .c_hi_bf16_s2(c_hi_bf16_s2)
  );

  // ----------------------------------------------------------------
  // MID_STAGES register pipeline between S2 and adders
  // ----------------------------------------------------------------
  // INT path: 16-bit mag, 1-bit sign, 32-bit C (per lane × 2 lanes)
  reg [15:0] int_mag_hi_mid [0:MID_STAGES];
  reg [15:0] int_mag_lo_mid [0:MID_STAGES];
  reg        int_sign_hi_mid [0:MID_STAGES];
  reg        int_sign_lo_mid [0:MID_STAGES];
  reg [31:0] int_c_hi_mid   [0:MID_STAGES];
  reg [31:0] int_c_lo_mid   [0:MID_STAGES];
  // BF16 path: two 16-bit prod + two 16-bit C
  reg [15:0] bf16_p_hi_mid  [0:MID_STAGES];
  reg [15:0] bf16_p_lo_mid  [0:MID_STAGES];
  reg [15:0] bf16_c_hi_mid  [0:MID_STAGES];
  reg [15:0] bf16_c_lo_mid  [0:MID_STAGES];

  always @(*) begin
    int_mag_hi_mid[0]  = prod_hi16_int8_mag;
    int_mag_lo_mid[0]  = prod_lo16_int8_mag;
    int_sign_hi_mid[0] = sign_hi_int8_s2;
    int_sign_lo_mid[0] = sign_lo_int8_s2;
    int_c_hi_mid[0]    = c_hi_int8_s2;
    int_c_lo_mid[0]    = c_lo_int8_s2;
    bf16_p_hi_mid[0]   = prod_hi16_bf16;
    bf16_p_lo_mid[0]   = prod_lo16_bf16;
    bf16_c_hi_mid[0]   = c_hi_bf16_s2;
    bf16_c_lo_mid[0]   = c_lo_bf16_s2;
  end
  genvar gm;
  generate
    for (gm = 1; gm <= MID_STAGES; gm = gm + 1) begin : g_mid
      always @(posedge clk) begin
        int_mag_hi_mid[gm]  <= int_mag_hi_mid[gm-1];
        int_mag_lo_mid[gm]  <= int_mag_lo_mid[gm-1];
        int_sign_hi_mid[gm] <= int_sign_hi_mid[gm-1];
        int_sign_lo_mid[gm] <= int_sign_lo_mid[gm-1];
        int_c_hi_mid[gm]    <= int_c_hi_mid[gm-1];
        int_c_lo_mid[gm]    <= int_c_lo_mid[gm-1];
        bf16_p_hi_mid[gm]   <= bf16_p_hi_mid[gm-1];
        bf16_p_lo_mid[gm]   <= bf16_p_lo_mid[gm-1];
        bf16_c_hi_mid[gm]   <= bf16_c_hi_mid[gm-1];
        bf16_c_lo_mid[gm]   <= bf16_c_lo_mid[gm-1];
      end
    end
  endgenerate

  // ----------------------------------------------------------------
  // Parameterized adders (LATENCY = ADD_LAT)
  // ----------------------------------------------------------------
  wire [31:0] int8_hi_sum, int8_lo_sum;
  int8_add #(.LATENCY(ADD_LAT)) u_int_add_hi (
    .clk(clk),
    .prod_mag16_s2(int_mag_hi_mid[MID_STAGES]),
    .prod_sign_s2 (int_sign_hi_mid[MID_STAGES]),
    .c32_s2       (int_c_hi_mid[MID_STAGES]),
    .sum32_out    (int8_hi_sum)
  );
  int8_add #(.LATENCY(ADD_LAT)) u_int_add_lo (
    .clk(clk),
    .prod_mag16_s2(int_mag_lo_mid[MID_STAGES]),
    .prod_sign_s2 (int_sign_lo_mid[MID_STAGES]),
    .c32_s2       (int_c_lo_mid[MID_STAGES]),
    .sum32_out    (int8_lo_sum)
  );

  wire [15:0] bf16_hi_sum, bf16_lo_sum;
  bf16_add #(.LATENCY(ADD_LAT)) u_bf_add_hi (
    .clk(clk), .a16(bf16_p_hi_mid[MID_STAGES]), .b16(bf16_c_hi_mid[MID_STAGES]), .c16(bf16_hi_sum)
  );
  bf16_add #(.LATENCY(ADD_LAT)) u_bf_add_lo (
    .clk(clk), .a16(bf16_p_lo_mid[MID_STAGES]), .b16(bf16_c_lo_mid[MID_STAGES]), .c16(bf16_lo_sum)
  );

  // ----------------------------------------------------------------
  // Output mux: mode_pipe[DEPTH-1] aligns with adder outputs
  // ----------------------------------------------------------------
  assign result = mode_pipe[DEPTH-1] ? {int8_hi_sum, int8_lo_sum}
                                     : {32'd0, bf16_hi_sum, bf16_lo_sum};
endmodule
`default_nettype wire
