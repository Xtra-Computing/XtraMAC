`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// fp8e4m3_mac_4lane -- MAC shell: 4-lane multiplier + 4x FP8 adders
//   FP8(E4M3) x FP8(E4M3) + FP8 -> FP8 (4 independent lanes)
//
//   Pipeline:
//     fp8e4m3_mul_4lane  (MUL_LAT cycles: S1 pack + DSP + S2 decode)
//     MID_STAGES optional mid-pipeline registers (both product and C)
//     4x fp8e4m3_add     (ADD_LAT cycles per adder)
//
//   Total latency = MUL_LAT + MID_STAGES + ADD_LAT  (EXACT, no hidden regs)
//     (2, 0, 1) -> 3 cycles
//     (2, 0, 2) -> 4 cycles
//     (2, 1, 2) -> 5 cycles
//
//   Port map mirrors fp8e4m3_mac from User_spec:
//     a_fp8[15:0] = {a2[15:8], a1[7:0]} -- two FP8 A-lanes
//     b_fp8[15:0] = {b2[15:8], b1[7:0]} -- two FP8 B-lanes
//     c_fp8[31:0] = {c22, c21, c12, c11} -- four FP8 addends
//     result[31:0] = {y22, y21, y12, y11} -- four FP8 results
// ======================================================================
module fp8e4m3_mac_4lane #(
    parameter integer MUL_LAT    = 2,  // multiplier latency (fixed at 2)
    parameter integer MID_STAGES = 0,  // mid-pipeline registers (for both product and C)
    parameter integer ADD_LAT    = 1   // adder latency (1 or 2)
) (
    input  wire        clk,
    input  wire [15:0] a_fp8,   // {a2, a1} two FP8(E4M3) A-lanes
    input  wire [15:0] b_fp8,   // {b2, b1} two FP8(E4M3) B-lanes
    input  wire [31:0] c_fp8,   // {c22, c21, c12, c11} four FP8 addends
    output wire [31:0] result   // {y22, y21, y12, y11}
);

  // ---- 4-lane multiplier ----
  wire [7:0] prod11, prod12, prod21, prod22;
  wire       sign11, sign12, sign21, sign22;

  fp8e4m3_mul_4lane #(
    .LATENCY (MUL_LAT)
  ) u_mul (
    .clk    (clk),
    .a_fp8  (a_fp8),
    .b_fp8  (b_fp8),
    .prod11 (prod11),
    .prod12 (prod12),
    .prod21 (prod21),
    .prod22 (prod22),
    .sign11 (sign11),
    .sign12 (sign12),
    .sign21 (sign21),
    .sign22 (sign22)
  );

  // ---- C-input delay to match multiplier latency (MUL_LAT cycles) ----
  reg [31:0] c_aligned_mul;
  reg [31:0] c_mul_pipe [0:MUL_LAT-1];
  integer j;
  always @(posedge clk) begin
    c_mul_pipe[0] <= c_fp8;
    for (j = 1; j < MUL_LAT; j = j + 1)
      c_mul_pipe[j] <= c_mul_pipe[j-1];
  end
  wire [31:0] c_after_mul = c_mul_pipe[MUL_LAT-1];
  wire [31:0] prod_packed = {prod22, prod21, prod12, prod11};

  // ---- Mid-stage pipeline: both product and C delayed by MID_STAGES ----
  wire [31:0] add_a;  // product input to adders
  wire [31:0] add_b;  // C input to adders

  generate
    if (MID_STAGES == 0) begin : gen_no_mid
      assign add_a = prod_packed;
      assign add_b = c_after_mul;
    end else begin : gen_mid
      reg [31:0] mid_prod [0:MID_STAGES-1];
      reg [31:0] mid_c    [0:MID_STAGES-1];
      integer i;
      always @(posedge clk) begin
        mid_prod[0] <= prod_packed;
        mid_c[0]    <= c_after_mul;
        for (i = 1; i < MID_STAGES; i = i + 1) begin
          mid_prod[i] <= mid_prod[i-1];
          mid_c[i]    <= mid_c[i-1];
        end
      end
      assign add_a = mid_prod[MID_STAGES-1];
      assign add_b = mid_c[MID_STAGES-1];
    end
  endgenerate

  // ---- 4x FP8 adders (product + C) ----
  wire [7:0] sum11, sum12, sum21, sum22;

  fp8e4m3_add #(.LATENCY(ADD_LAT)) u_add11 (
    .clk (clk), .a8 (add_a[ 7: 0]), .b8 (add_b[ 7: 0]), .c8 (sum11)
  );
  fp8e4m3_add #(.LATENCY(ADD_LAT)) u_add12 (
    .clk (clk), .a8 (add_a[15: 8]), .b8 (add_b[15: 8]), .c8 (sum12)
  );
  fp8e4m3_add #(.LATENCY(ADD_LAT)) u_add21 (
    .clk (clk), .a8 (add_a[23:16]), .b8 (add_b[23:16]), .c8 (sum21)
  );
  fp8e4m3_add #(.LATENCY(ADD_LAT)) u_add22 (
    .clk (clk), .a8 (add_a[31:24]), .b8 (add_b[31:24]), .c8 (sum22)
  );

  // ---- Final output ----
  assign result = {sum22, sum21, sum12, sum11};

endmodule

`default_nettype wire
