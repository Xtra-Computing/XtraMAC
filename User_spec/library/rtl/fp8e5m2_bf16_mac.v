`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp8e5m2_bf16_mac : Two-lane FP8(E5M2) * BF16 + BF16 -> BF16
//   - Input a16 holds two FP8(E5M2) lanes {HI[15:8], LO[7:0]}
//   - Shared multiplicand b16 (BF16)
//   - BF16 addends packed in c32 {HI[31:16], LO[15:0]}
//   - Result packed as two BF16 lanes {HI, LO}
//   - FP8 handling:
//       * FTZ (exp==0 => signed zero)
//       * exp==11111 & frac!=0 → qNaN
//       * exp==11111 & frac==0 → +/-Infinity
//   - Each lane is translated to BF16 inline and fed into bf16_mac
// =============================================================
module fp8e5m2_bf16_mac (
    input  wire        clk,
    input  wire [15:0] a16,    // {a_hi[15:8], a_lo[7:0]} FP8 E5M2 lanes
    input  wire [15:0] b16,    // shared BF16 multiplicand
    input  wire [31:0] c32,    // BF16 addends {hi, lo}
    output wire [31:0] result  // BF16 results {hi, lo}
);
  localparam [15:0] QNAN16 = 16'h7FC0;
  localparam [7:0]  PINF8  = 8'h7C;
  localparam [7:0]  NINF8  = 8'hFC;

  // Split FP8 lanes
  wire [7:0] a_lo8 = a16[7:0];
  wire [7:0] a_hi8 = a16[15:8];

  // ---- Lane conversion: FP8(E5M2) -> BF16 (combinational) ----
  function automatic [15:0] lane_to_bf16;
    input [7:0] fp8;
    reg        sign;
    reg [4:0]  exp_fp8;
    reg [1:0]  frac_fp8;
    reg [7:0]  exp_bf16;
    reg [6:0]  frac_bf16;
    begin
      sign     = fp8[7];
      exp_fp8  = fp8[6:2];
      frac_fp8 = fp8[1:0];

      if ((exp_fp8 == 5'h1F) && (frac_fp8 != 2'd0)) begin
        lane_to_bf16 = QNAN16;
      end else if ((exp_fp8 == 5'h1F) && (frac_fp8 == 2'd0)) begin
        lane_to_bf16 = sign ? 16'hFF80 : 16'h7F80; // +/-Inf
      end else if (exp_fp8 == 5'd0) begin
        lane_to_bf16 = {sign, 15'd0};              // signed zero (FTZ)
      end else begin
        exp_bf16  = {3'd0, exp_fp8} + 8'd112;      // bias shift (127-15)
        frac_bf16 = {frac_fp8, 5'b0};              // scale 2-bit frac to 7 bits
        lane_to_bf16 = {sign, exp_bf16, frac_bf16};
      end
    end
  endfunction

  wire [15:0] a_lo_bf16 = lane_to_bf16(a_lo8);
  wire [15:0] a_hi_bf16 = lane_to_bf16(a_hi8);
  wire [31:0] a_bf16    = {a_hi_bf16, a_lo_bf16};

  // Reuse the bf16_mac pipeline
  bf16_mac u_mac (
    .clk   (clk),
    .a32   (a_bf16),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );
endmodule

`default_nettype wire
