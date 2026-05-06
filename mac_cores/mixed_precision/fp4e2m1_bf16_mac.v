`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp4e2m1_bf16_mac : 2-lane FP4(E2M1) x BF16 + BF16 -> BF16
//   - Input a_fp4[7:0] holds two 4-bit lanes {HI[7:4], LO[3:0]}
//   - FP4(E2M1): 1 sign + 2 exp + 1 mantissa bit
//       * exp==3 & frac==1 => NaN
//       * exp==3 & frac==0 => Infinity
//       * exp==0 & frac==0 => signed zero
//       * exp==0 & frac==1 => subnormal (value = +/-0.5)
//       * else             => (-1)^s * 2^(exp-1) * (1.frac)
//   - Conversion: FP4 -> BF16 inline, then bf16_mac_2lane.
// =============================================================
module fp4e2m1_bf16_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 0,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire [7:0]  a_fp4,    // {hi[7:4], lo[3:0]} FP4 E2M1
    input  wire [15:0] b16,      // shared BF16
    input  wire [31:0] c32,      // BF16 addends {hi, lo}
    output wire [31:0] result    // BF16 results {hi, lo}
);

  localparam [15:0] QNAN16 = 16'h7FC0;

  // ---- FP4(E2M1) -> BF16 conversion ----
  // E2M1 bias = 1. BF16 bias = 127.
  //   subnormal (exp=0,frac=1): value = 0.5 => BF16 exp=126, frac=0
  //   normal: exp_bf16 = exp_fp4 - 1 + 127 = exp_fp4 + 126
  function automatic [15:0] fp4e2m1_to_bf16;
    input [3:0] lane;
    reg        sign;
    reg [1:0]  exp2;
    reg        frac1;
    reg [7:0]  exp_bf16;
    begin
      sign  = lane[3];
      exp2  = lane[2:1];
      frac1 = lane[0];

      if ((exp2 == 2'b11) && (frac1 == 1'b1)) begin
        fp4e2m1_to_bf16 = QNAN16;                          // NaN
      end else if ((exp2 == 2'b11) && (frac1 == 1'b0)) begin
        fp4e2m1_to_bf16 = sign ? 16'hFF80 : 16'h7F80;     // +/-Inf
      end else if ((exp2 == 2'b00) && (frac1 == 1'b0)) begin
        fp4e2m1_to_bf16 = {sign, 15'd0};                   // signed zero
      end else if ((exp2 == 2'b00) && (frac1 == 1'b1)) begin
        // subnormal: 0.5 -> BF16 {sign, 8'd126, 7'b0000000}
        fp4e2m1_to_bf16 = {sign, 8'd126, 7'b0000000};
      end else begin
        exp_bf16 = {6'd0, exp2} + 8'd126;                  // exp-1+127
        fp4e2m1_to_bf16 = {sign, exp_bf16, frac1, 6'b000000};
      end
    end
  endfunction

  wire [3:0] a_lo4 = a_fp4[3:0];
  wire [3:0] a_hi4 = a_fp4[7:4];

  wire [15:0] a_lo_bf16 = fp4e2m1_to_bf16(a_lo4);
  wire [15:0] a_hi_bf16 = fp4e2m1_to_bf16(a_hi4);
  wire [31:0] a_bf16    = {a_hi_bf16, a_lo_bf16};

  bf16_mac_2lane #(
    .MUL_LAT   (MUL_LAT),
    .MID_STAGES(MID_STAGES),
    .ADD_LAT   (ADD_LAT)
  ) u_mac (
    .clk   (clk),
    .a32   (a_bf16),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

endmodule

`default_nettype wire
