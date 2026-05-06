`timescale 1ns/1ps
`default_nettype none
// =============================================================
// bf16_mac_2lane : 2-lane BF16 MAC shell
//   result = a * b + c  (per lane)
//
//   Parameters:
//     MUL_LAT    : multiply latency (1=LUT, 2=DSP)  [default 2]
//     MID_STAGES : extra pipeline registers between mul and add [default 0]
//     ADD_LAT    : adder latency (2 or 3)            [default 2]
//
//   Total latency = MUL_LAT + MID_STAGES + ADD_LAT  (EXACT, no hidden regs)
//     (2, 0, 2) -> 4 cycles
//     (2, 0, 3) -> 5 cycles
//     (2, 1, 3) -> 6 cycles
//     (1, 0, 2) -> 3 cycles
//
//   Interface:
//     a32[31:0] = {a_hi[31:16], a_lo[15:0]}  two BF16 multiplicands
//     b16[15:0] = shared BF16 multiplier
//     c32[31:0] = {c_hi[31:16], c_lo[15:0]}  two BF16 addends
//     result[31:0] = {res_hi[31:16], res_lo[15:0]} two BF16 results
// =============================================================
module bf16_mac_2lane #(
    parameter MUL_LAT    = 2,  // 1 or 2
    parameter MID_STAGES = 0,  // 0, 1, ...
    parameter ADD_LAT    = 2   // 2 or 3
)(
    input  wire        clk,
    input  wire [31:0] a32,
    input  wire [15:0] b16,
    input  wire [31:0] c32,
    output wire [31:0] result
);

  // ---- Delay C to align with mul output ----
  // C must be delayed by MUL_LAT + MID_STAGES cycles to arrive at the adder
  // at the same time as the product.
  localparam C_DELAY = MUL_LAT + MID_STAGES;

  reg [15:0] c_lo_dly [0:C_DELAY-1];
  reg [15:0] c_hi_dly [0:C_DELAY-1];

  integer i;
  always @(posedge clk) begin
    c_lo_dly[0] <= c32[15:0];
    c_hi_dly[0] <= c32[31:16];
    for (i = 1; i < C_DELAY; i = i + 1) begin
      c_lo_dly[i] <= c_lo_dly[i-1];
      c_hi_dly[i] <= c_hi_dly[i-1];
    end
  end

  wire [15:0] c_lo_aligned = c_lo_dly[C_DELAY-1];
  wire [15:0] c_hi_aligned = c_hi_dly[C_DELAY-1];

  // ---- 2-lane BF16 multiply ----
  wire [31:0] prod32;

  bf16_mul_2lane #(
    .LATENCY(MUL_LAT)
  ) u_mul (
    .clk (clk),
    .a32 (a32),
    .b16 (b16),
    .p32 (prod32)
  );

  // ---- Optional mid-pipeline registers ----
  wire [15:0] prod_hi_mid, prod_lo_mid;

  generate
  if (MID_STAGES == 0) begin : gen_mid0
    assign prod_hi_mid = prod32[31:16];
    assign prod_lo_mid = prod32[15:0];
  end else begin : gen_mid_pipe
    reg [15:0] mid_hi [0:MID_STAGES-1];
    reg [15:0] mid_lo [0:MID_STAGES-1];
    integer j;
    always @(posedge clk) begin
      mid_hi[0] <= prod32[31:16];
      mid_lo[0] <= prod32[15:0];
      for (j = 1; j < MID_STAGES; j = j + 1) begin
        mid_hi[j] <= mid_hi[j-1];
        mid_lo[j] <= mid_lo[j-1];
      end
    end
    assign prod_hi_mid = mid_hi[MID_STAGES-1];
    assign prod_lo_mid = mid_lo[MID_STAGES-1];
  end
  endgenerate

  // ---- 2x BF16 adders ----
  wire [15:0] sum_lo, sum_hi;

  bf16_add #(
    .LATENCY(ADD_LAT)
  ) u_add_lo (
    .clk (clk),
    .a16 (prod_lo_mid),
    .b16 (c_lo_aligned),
    .c16 (sum_lo)
  );

  bf16_add #(
    .LATENCY(ADD_LAT)
  ) u_add_hi (
    .clk (clk),
    .a16 (prod_hi_mid),
    .b16 (c_hi_aligned),
    .c16 (sum_hi)
  );

  // ---- Output (combinational concat; no extra register) ----
  assign result = {sum_hi, sum_lo};

endmodule

`default_nettype wire
