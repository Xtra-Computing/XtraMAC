`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp8e4m3_bf16_mac : Two-lane FP8(E4M3) * BF16 + BF16 -> BF16
//   - Input a16 holds two FP8 lanes {HI[15:8], LO[7:0]}
//   - Shared BF16 multiplier input b16
//   - BF16 addends packed in c32 {HI[31:16], LO[15:0]}
//   - Result is two BF16 lanes packed as {HI, LO}
//   - FP8 handling:
//       * FTZ (exp==0 => zero, preserve sign for +/-0)
//       * exp==4'hF treated as NaN (no Inf in E4M3) → mapped to BF16 qNaN
//       * Normalized values are mapped exactly onto BF16 domain
//   - Re-uses the existing bf16_mac pipeline after widening FP8 to BF16
// =============================================================
module fp8e4m3_bf16_mac (
    input  wire        clk,
    input  wire [15:0] a16,    // {a_hi[15:8], a_lo[7:0]} FP8 E4M3 lanes
    input  wire [15:0] b16,    // shared BF16 multiplicand
    input  wire [31:0] c32,    // BF16 addends {hi, lo}
    output wire [31:0] result  // BF16 results {hi, lo}
);
  localparam [15:0] QNAN16 = 16'h7FC0;

  // Split FP8 lanes
  wire [7:0] a_lo8 = a16[7:0];
  wire [7:0] a_hi8 = a16[15:8];

  // ---- Lane conversion: FP8(E4M3) -> BF16 (combinational) ----
  // Low lane
  wire        s_lo_fp8   = a_lo8[7];
  wire [3:0]  e_lo_fp8   = a_lo8[6:3];
  wire [2:0]  f_lo_fp8   = a_lo8[2:0];
  wire        lo_nan     = (e_lo_fp8 == 4'hF);
  wire        lo_zero    = (e_lo_fp8 == 4'd0);
  wire [7:0]  e_lo_bf16  = {4'd0, e_lo_fp8} + 8'd120;
  wire [6:0]  f_lo_bf16  = {f_lo_fp8, 4'b0000};
  wire [15:0] a_lo_bf16  = lo_nan                 ? QNAN16 :
                           lo_zero                ? {s_lo_fp8, 15'd0} :
                                                   {s_lo_fp8, e_lo_bf16, f_lo_bf16};

  // High lane
  wire        s_hi_fp8   = a_hi8[7];
  wire [3:0]  e_hi_fp8   = a_hi8[6:3];
  wire [2:0]  f_hi_fp8   = a_hi8[2:0];
  wire        hi_nan     = (e_hi_fp8 == 4'hF);
  wire        hi_zero    = (e_hi_fp8 == 4'd0);
  wire [7:0]  e_hi_bf16  = {4'd0, e_hi_fp8} + 8'd120;
  wire [6:0]  f_hi_bf16  = {f_hi_fp8, 4'b0000};
  wire [15:0] a_hi_bf16  = hi_nan                 ? QNAN16 :
                           hi_zero                ? {s_hi_fp8, 15'd0} :
                                                   {s_hi_fp8, e_hi_bf16, f_hi_bf16};

  wire [31:0] a_bf16 = {a_hi_bf16, a_lo_bf16};

  // Delegate the heavy lifting to the proven BF16 MAC
  bf16_mac u_mac (
    .clk   (clk),
    .a32   (a_bf16),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );
endmodule

`default_nettype wire
