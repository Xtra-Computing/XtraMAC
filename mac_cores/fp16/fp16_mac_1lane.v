`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp16_mac_1lane : 1-lane FP16 x FP16 + FP16 -> FP16 MAC
//   Parameterized latency:
//     MUL_LAT  = 1 or 2 (fp16_mul_1lane latency)
//     MID_STAGES = 0, 1, ... (extra pipeline registers between mul and add)
//     ADD_LAT  = 2 or 3 (fp16_add latency)
//
//   Total latency = MUL_LAT + MID_STAGES + ADD_LAT  (EXACT, no hidden regs)
//     (2, 0, 2) -> 4 cycles
//     (2, 0, 3) -> 5 cycles
//     (2, 1, 3) -> 6 cycles
//     (1, 0, 2) -> 3 cycles
//
//   The C input delay line matches MUL_LAT + MID_STAGES so that
//   the product and addend arrive at the adder simultaneously.
// =============================================================
module fp16_mac_1lane #(
    parameter integer MUL_LAT    = 2,   // 1 or 2
    parameter integer MID_STAGES = 0,   // 0+
    parameter integer ADD_LAT    = 2    // 2 or 3
) (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [15:0] c16,
    output wire [15:0] result
);

  localparam integer C_DELAY = MUL_LAT + MID_STAGES;

  // ---- Multiplier ----
  wire [15:0] prod_raw;

  fp16_mul_1lane #(
    .LATENCY(MUL_LAT)
  ) u_mul (
    .clk     (clk),
    .a16     (a16),
    .b16     (b16),
    .prod16_w(prod_raw)
  );

  // ---- Optional mid-pipeline registers for product ----
  reg [15:0] prod_mid [0:MID_STAGES]; // index 0 = mul output
  integer mi;
  always @(*) prod_mid[0] = prod_raw;

  generate
    genvar gm;
    for (gm = 1; gm <= MID_STAGES; gm = gm + 1) begin : gen_mid
      always @(posedge clk) begin
        prod_mid[gm] <= prod_mid[gm-1];
      end
    end
  endgenerate

  wire [15:0] prod_delayed = prod_mid[MID_STAGES];

  // ---- C delay line (MUL_LAT + MID_STAGES cycles) ----
  reg [15:0] c_pipe [0:C_DELAY];
  always @(*) c_pipe[0] = c16;

  generate
    genvar gc;
    for (gc = 1; gc <= C_DELAY; gc = gc + 1) begin : gen_cdly
      always @(posedge clk) begin
        c_pipe[gc] <= c_pipe[gc-1];
      end
    end
  endgenerate

  wire [15:0] c_delayed = c_pipe[C_DELAY];

  // ---- Adder ----
  fp16_add #(
    .LATENCY(ADD_LAT)
  ) u_add (
    .clk   (clk),
    .x16   (prod_delayed),
    .y16   (c_delayed),
    .result(result)
  );

endmodule

`default_nettype wire
