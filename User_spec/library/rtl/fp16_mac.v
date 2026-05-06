`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp16_mac  (Top) — 3-module refactor, same 4-cycle latency
//   - Submodules:
//       * fp16_mul   : 2-stage FP16 multiplier + classify/pack
//       * fp16_add   : 2-stage FP16 adder/normalizer/packer (with special-cases)
//   - Behavior identical to the single-module optimized version
//   - FTZ/DAZ, NaN/Inf rules, RN-even preserved
// =============================================================
module fp16_mac (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [15:0] c16,
    output wire [15:0] result
);
  // Product from multiplier (already packed FP16 with correct special cases)
  wire [15:0] prod16_w;

  // 2-cycle delay line for C to align with multiplier latency (M1+M2)
  reg [15:0] c16_d1, c16_d2;
  always @(posedge clk) begin
    c16_d1 <= c16;
    c16_d2 <= c16_d1;
  end

  fp16_mul u_mul (
    .clk(clk),
    .a16(a16),
    .b16(b16),
    .prod16_w(prod16_w)
  );

  // Feed delayed C into the adder so x16 and y16 are time-aligned
  fp16_add u_add (
    .clk(clk),
    .x16(prod16_w),
    .y16(c16_d2),
    .result(result)
  );
endmodule

`default_nettype wire
