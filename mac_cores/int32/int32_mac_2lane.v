`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int32_mac_2lane : INT8 x INT8 + INT32 -> INT32 (2-lane, DSP-packed)
//   - Multiplier: 2-lane DSP-packed INT8 x INT8 via int8_mul_2lane
//   - Accumulation: signed 32-bit integer add per lane
//   - Total latency = MUL_LAT + MID_STAGES + 1 (output reg)
//   - II = 1
//
// Parameters:
//   MUL_LAT    : multiplier latency (1 or 2, default 2)
//   MID_STAGES : extra pipeline registers between mul output and add
//                (0 = combinational add right after mul, default 0)
// =============================================================
module int32_mac_2lane #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 0
)(
    input  wire        clk,
    input  wire [15:0] a16,    // packed INT8 {hi[15:8], lo[7:0]}
    input  wire  [7:0] b8,     // shared INT8
    input  wire [63:0] c64,    // INT32 addends {hi[63:32], lo[31:0]}
    output wire [63:0] result  // INT32 results {hi, lo}
);

  // ----------------------------------------------------------------
  // Multiplier: 2-lane INT8 x INT8
  // ----------------------------------------------------------------
  wire [31:0] prod_hi_w, prod_lo_w;

  int8_mul_2lane #(
    .MUL_LAT(MUL_LAT)
  ) u_mul (
    .clk    (clk),
    .a16    (a16),
    .b8     (b8),
    .prod_hi(prod_hi_w),
    .prod_lo(prod_lo_w)
  );

  // ----------------------------------------------------------------
  // Delay C to align with multiplier output
  //   C must arrive at the adder at the same cycle as the product.
  //   Multiplier latency = MUL_LAT cycles from input regs.
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
  // Optional mid-pipeline stages between mul and add
  // ----------------------------------------------------------------
  generate
    if (MID_STAGES == 0) begin : gen_no_mid
      wire [31:0] mul_hi_mid = prod_hi_w;
      wire [31:0] mul_lo_mid = prod_lo_w;
      wire [31:0] c_hi_mid   = c_hi_aligned;
      wire [31:0] c_lo_mid   = c_lo_aligned;

      // Signed 32-bit add + output register
      reg [31:0] result_hi, result_lo;
      always @(posedge clk) begin
        result_hi <= $signed(mul_hi_mid) + $signed(c_hi_mid);
        result_lo <= $signed(mul_lo_mid) + $signed(c_lo_mid);
      end
      assign result = {result_hi, result_lo};

    end else begin : gen_mid
      // MID_STAGES pipeline registers
      reg [31:0] mid_mul_hi [0:MID_STAGES-1];
      reg [31:0] mid_mul_lo [0:MID_STAGES-1];
      reg [31:0] mid_c_hi   [0:MID_STAGES-1];
      reg [31:0] mid_c_lo   [0:MID_STAGES-1];
      integer m;

      always @(posedge clk) begin
        mid_mul_hi[0] <= prod_hi_w;
        mid_mul_lo[0] <= prod_lo_w;
        mid_c_hi[0]   <= c_hi_aligned;
        mid_c_lo[0]   <= c_lo_aligned;
        for (m = 1; m < MID_STAGES; m = m + 1) begin
          mid_mul_hi[m] <= mid_mul_hi[m-1];
          mid_mul_lo[m] <= mid_mul_lo[m-1];
          mid_c_hi[m]   <= mid_c_hi[m-1];
          mid_c_lo[m]   <= mid_c_lo[m-1];
        end
      end

      // Signed 32-bit add + output register
      reg [31:0] result_hi, result_lo;
      always @(posedge clk) begin
        result_hi <= $signed(mid_mul_hi[MID_STAGES-1]) + $signed(mid_c_hi[MID_STAGES-1]);
        result_lo <= $signed(mid_mul_lo[MID_STAGES-1]) + $signed(mid_c_lo[MID_STAGES-1]);
      end
      assign result = {result_hi, result_lo};
    end
  endgenerate

endmodule
`default_nettype wire
