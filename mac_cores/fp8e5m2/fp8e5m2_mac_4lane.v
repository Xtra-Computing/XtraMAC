`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// fp8e5m2_mac_4lane -- MAC shell: 4-lane multiplier + 4x FP8 E5M2 adder
//   y[i] = a[i]*b[i] + c[i]  for i in {11,12,21,22}
//
//   Parameters:
//     MUL_LAT    -- multiplier latency (default 2)
//     MID_STAGES -- extra pipeline registers between mul and add (default 0)
//     ADD_LAT    -- adder latency (default 1)
//
//   Total latency = MUL_LAT + MID_STAGES + ADD_LAT  (EXACT, no hidden regs)
//     (2, 0, 1) -> 3 cycles
//     (2, 0, 2) -> 4 cycles
//     (2, 1, 2) -> 5 cycles
//
//   Port map:
//     a16[15:0]  = {a2[15:8], a1[7:0]}   two FP8 E5M2 lanes
//     b16[15:0]  = {b2[15:8], b1[7:0]}   two FP8 E5M2 lanes
//     c32[31:0]  = {c22, c21, c12, c11}  four FP8 E5M2 addends
//     result[31:0] = {y22, y21, y12, y11} four FP8 E5M2 results
// ======================================================================
module fp8e5m2_mac_4lane #(
    parameter integer MUL_LAT    = 2,
    parameter integer MID_STAGES = 0,
    parameter integer ADD_LAT    = 1
) (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [31:0] c32,
    output wire [31:0] result
);

  // ---- 4-lane multiplier ----
  wire [31:0] mul_prod;
  wire [31:0] mul_c;

  fp8e5m2_mul_4lane #(
      .LATENCY (MUL_LAT)
  ) u_mul (
      .clk   (clk),
      .a16   (a16),
      .b16   (b16),
      .c_in  (c32),
      .prod  (mul_prod),
      .c_out (mul_c)
  );

  // ---- Optional mid-stage pipeline ----
  wire [31:0] add_a;
  wire [31:0] add_b;

  generate
    if (MID_STAGES == 0) begin : gen_no_mid
      assign add_a = mul_prod;
      assign add_b = mul_c;
    end else begin : gen_mid
      reg [31:0] mid_prod [0:MID_STAGES-1];
      reg [31:0] mid_c    [0:MID_STAGES-1];
      integer i;
      always @(posedge clk) begin
        mid_prod[0] <= mul_prod;
        mid_c[0]    <= mul_c;
        for (i = 1; i < MID_STAGES; i = i + 1) begin
          mid_prod[i] <= mid_prod[i-1];
          mid_c[i]    <= mid_c[i-1];
        end
      end
      assign add_a = mid_prod[MID_STAGES-1];
      assign add_b = mid_c[MID_STAGES-1];
    end
  endgenerate

  // ---- Per-lane adders ----
  wire [7:0] sum11, sum12, sum21, sum22;

  fp8e5m2_add #(.LATENCY(ADD_LAT)) u_add11 (
      .clk (clk),
      .a8  (add_a[ 7: 0]),
      .b8  (add_b[ 7: 0]),
      .c8  (sum11)
  );
  fp8e5m2_add #(.LATENCY(ADD_LAT)) u_add12 (
      .clk (clk),
      .a8  (add_a[15: 8]),
      .b8  (add_b[15: 8]),
      .c8  (sum12)
  );
  fp8e5m2_add #(.LATENCY(ADD_LAT)) u_add21 (
      .clk (clk),
      .a8  (add_a[23:16]),
      .b8  (add_b[23:16]),
      .c8  (sum21)
  );
  fp8e5m2_add #(.LATENCY(ADD_LAT)) u_add22 (
      .clk (clk),
      .a8  (add_a[31:24]),
      .b8  (add_b[31:24]),
      .c8  (sum22)
  );

  // ---- Final output (combinational concat; no extra register) ----
  assign result = {sum22, sum21, sum12, sum11};

endmodule

`default_nettype wire
