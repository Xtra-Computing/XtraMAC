`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp16_fp32_mac_1lane : FP16 x FP16 + FP32 -> FP32
//   - Uses fp16_fp32_mul_1lane for the multiplier
//   - Uses fp32_add for the FP32 addition
//   - Total latency = MUL_LAT + MID_STAGES + ADD_LAT  (EXACT, no hidden regs)
//       (2, 0, 2) -> 4 cycles
//       (2, 1, 2) -> 5 cycles
//       (2, 1, 3) -> 6 cycles
//   - II = 1
// =============================================================
module fp16_fp32_mac_1lane #(
    parameter MUL_LAT    = 2,  // multiplier latency (1 or 2)
    parameter MID_STAGES = 0,  // pipeline regs between mul and add
    parameter ADD_LAT    = 2   // fp32_add latency (2 or 3)
)(
    input  wire        clk,
    input  wire [15:0] a16,     // FP16 input A
    input  wire [15:0] b16,     // FP16 input B
    input  wire [31:0] c32,     // FP32 addend
    output wire [31:0] result   // FP32 result
);

  // ----------------------------------------------------------------
  // Multiplier: FP16 x FP16 -> FP32
  // ----------------------------------------------------------------
  wire [31:0] mul32;

  fp16_fp32_mul_1lane #(
    .MUL_LAT(MUL_LAT)
  ) u_mul (
    .clk   (clk),
    .a16   (a16),
    .b16   (b16),
    .prod32(mul32)
  );

  // ----------------------------------------------------------------
  // Delay C to align with multiplier output
  // ----------------------------------------------------------------
  localparam C_DELAY = MUL_LAT;

  reg [31:0] c_pipe [0:C_DELAY-1];
  integer i;

  always @(posedge clk) begin
    c_pipe[0] <= c32;
    for (i = 1; i < C_DELAY; i = i + 1)
      c_pipe[i] <= c_pipe[i-1];
  end

  wire [31:0] c_aligned = c_pipe[C_DELAY-1];

  // ----------------------------------------------------------------
  // Mid-pipeline stages
  // ----------------------------------------------------------------
  wire [31:0] add_a, add_b;

  generate
    if (MID_STAGES == 0) begin : gen_no_mid
      assign add_a = mul32;
      assign add_b = c_aligned;
    end else begin : gen_mid
      reg [31:0] mid_mul [0:MID_STAGES-1];
      reg [31:0] mid_c   [0:MID_STAGES-1];
      integer m;

      always @(posedge clk) begin
        mid_mul[0] <= mul32;
        mid_c[0]   <= c_aligned;
        for (m = 1; m < MID_STAGES; m = m + 1) begin
          mid_mul[m] <= mid_mul[m-1];
          mid_c[m]   <= mid_c[m-1];
        end
      end

      assign add_a = mid_mul[MID_STAGES-1];
      assign add_b = mid_c[MID_STAGES-1];
    end
  endgenerate

  // ----------------------------------------------------------------
  // FP32 adder
  // ----------------------------------------------------------------
  fp32_add #(
    .LATENCY              (ADD_LAT),
    .SATURATE_ON_MAX      (1'b1),
    .INF_CANCELLATION_TO_NAN(1'b1)
  ) u_add (
    .clk   (clk),
    .x32   (add_a),
    .y32   (add_b),
    .result(result)
  );

endmodule
`default_nettype wire
