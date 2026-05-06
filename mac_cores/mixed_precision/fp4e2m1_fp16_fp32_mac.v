`timescale 1ns/1ps
`default_nettype none
// =============================================================
// fp4e2m1_fp16_fp32_mac : FP4(E2M1) x FP16 + FP32 -> FP32 (2-lane)
//   Converts each FP4(E2M1) lane to FP8(E4M3), then delegates to
//   fp8e4m3_fp16_fp32_mac.
// =============================================================
module fp4e2m1_fp16_fp32_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 0,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire  [7:0] a8,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  function automatic [7:0] fp4e2m1_to_fp8e4m3;
    input [3:0] lane;
    reg sign;
    reg [1:0] exp2;
    reg       frac1;
    reg [3:0] exp_final;
    reg [2:0] frac_final;
    begin
      sign  = lane[3];
      exp2  = lane[2:1];
      frac1 = lane[0];
      if (exp2 == 2'b11)
        fp4e2m1_to_fp8e4m3 = 8'h79;               // NaN
      else if (exp2 == 2'b00)
        fp4e2m1_to_fp8e4m3 = {sign, 7'd0};        // zero / subnormal -> FTZ
      else begin
        exp_final  = {2'b00, exp2} + 4'd4;
        frac_final = {frac1, 2'b00};
        fp4e2m1_to_fp8e4m3 = {sign, exp_final[3:0], frac_final};
      end
    end
  endfunction

  wire [7:0] a_lo8 = fp4e2m1_to_fp8e4m3(a8[3:0]);
  wire [7:0] a_hi8 = fp4e2m1_to_fp8e4m3(a8[7:4]);
  wire [15:0] a_fp8 = {a_hi8, a_lo8};

  fp8e4m3_fp16_fp32_mac #(
    .MUL_LAT   (MUL_LAT),
    .MID_STAGES(MID_STAGES),
    .ADD_LAT   (ADD_LAT)
  ) u_mac (
    .clk   (clk),
    .a16   (a_fp8),
    .b16   (b16),
    .c64   (c64),
    .result(result)
  );

endmodule
`default_nettype wire
