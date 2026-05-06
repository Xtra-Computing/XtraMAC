`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp16_fp32_mac_2lane : 2-lane FP16 x FP16 + FP32 -> FP32
//   - Uses 2x fp16_fp32_mul_1lane (one per lane; FP16 mantissa too wide to DSP-pack)
//   - Uses fp32_add for two independent FP32 additions
//   - Total latency = MUL_LAT + MID_STAGES + ADD_LAT  (EXACT, no hidden regs)
//       (2, 0, 2) -> 4 cycles
//       (2, 0, 3) -> 5 cycles
//       (2, 1, 3) -> 6 cycles
//   - II = 1
// =============================================================
module fp16_fp32_mac_2lane #(
    parameter MUL_LAT    = 2,  // multiplier latency (1 or 2)
    parameter MID_STAGES = 0,  // pipeline regs between mul and add
    parameter ADD_LAT    = 2   // fp32_add latency (2 or 3)
)(
    input  wire        clk,
    input  wire [31:0] a32,     // FP16 lanes {HI[31:16], LO[15:0]}
    input  wire [15:0] b16,     // shared FP16 multiplier
    input  wire [63:0] c64,     // FP32 addends {HI[63:32], LO[31:0]}
    output wire [63:0] result   // FP32 results {HI, LO}
);

  // ----------------------------------------------------------------
  // Multipliers: 2x (FP16 x FP16 -> FP32)
  // ----------------------------------------------------------------
  wire [31:0] mul_hi32, mul_lo32;

  fp16_fp32_mul_1lane #(.MUL_LAT(MUL_LAT)) u_mul_hi (
    .clk(clk), .a16(a32[31:16]), .b16(b16), .prod32(mul_hi32)
  );
  fp16_fp32_mul_1lane #(.MUL_LAT(MUL_LAT)) u_mul_lo (
    .clk(clk), .a16(a32[15:0]),  .b16(b16), .prod32(mul_lo32)
  );

  // ----------------------------------------------------------------
  // Delay C to align with multiplier output
  // ----------------------------------------------------------------
  localparam C_DELAY = MUL_LAT;

  reg [63:0] c_pipe [0:C_DELAY-1];
  integer i;

  always @(posedge clk) begin
    c_pipe[0] <= c64;
    for (i = 1; i < C_DELAY; i = i + 1)
      c_pipe[i] <= c_pipe[i-1];
  end

  wire [31:0] c_hi_aligned = c_pipe[C_DELAY-1][63:32];
  wire [31:0] c_lo_aligned = c_pipe[C_DELAY-1][31:0];

  // ----------------------------------------------------------------
  // Mid-pipeline stages
  // ----------------------------------------------------------------
  wire [31:0] add_a_hi, add_a_lo, add_b_hi, add_b_lo;

  generate
    if (MID_STAGES == 0) begin : gen_no_mid
      assign add_a_hi = mul_hi32;
      assign add_a_lo = mul_lo32;
      assign add_b_hi = c_hi_aligned;
      assign add_b_lo = c_lo_aligned;
    end else begin : gen_mid
      reg [31:0] mid_mul_hi [0:MID_STAGES-1];
      reg [31:0] mid_mul_lo [0:MID_STAGES-1];
      reg [31:0] mid_c_hi   [0:MID_STAGES-1];
      reg [31:0] mid_c_lo   [0:MID_STAGES-1];
      integer m;

      always @(posedge clk) begin
        mid_mul_hi[0] <= mul_hi32;
        mid_mul_lo[0] <= mul_lo32;
        mid_c_hi[0]   <= c_hi_aligned;
        mid_c_lo[0]   <= c_lo_aligned;
        for (m = 1; m < MID_STAGES; m = m + 1) begin
          mid_mul_hi[m] <= mid_mul_hi[m-1];
          mid_mul_lo[m] <= mid_mul_lo[m-1];
          mid_c_hi[m]   <= mid_c_hi[m-1];
          mid_c_lo[m]   <= mid_c_lo[m-1];
        end
      end

      assign add_a_hi = mid_mul_hi[MID_STAGES-1];
      assign add_a_lo = mid_mul_lo[MID_STAGES-1];
      assign add_b_hi = mid_c_hi[MID_STAGES-1];
      assign add_b_lo = mid_c_lo[MID_STAGES-1];
    end
  endgenerate

  // ----------------------------------------------------------------
  // FP32 adders (per lane)
  // ----------------------------------------------------------------
  wire [31:0] sum_hi32, sum_lo32;

  fp32_add #(
    .LATENCY              (ADD_LAT),
    .SATURATE_ON_MAX      (1'b0),
    .INF_CANCELLATION_TO_NAN(1'b0)
  ) u_add_hi (
    .clk(clk), .x32(add_a_hi), .y32(add_b_hi), .result(sum_hi32)
  );

  fp32_add #(
    .LATENCY              (ADD_LAT),
    .SATURATE_ON_MAX      (1'b0),
    .INF_CANCELLATION_TO_NAN(1'b0)
  ) u_add_lo (
    .clk(clk), .x32(add_a_lo), .y32(add_b_lo), .result(sum_lo32)
  );

  assign result = {sum_hi32, sum_lo32};

endmodule
`default_nettype wire
