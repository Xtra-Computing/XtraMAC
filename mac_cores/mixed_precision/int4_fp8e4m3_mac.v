`timescale 1ns/1ps
`default_nettype none

// ======================================================================
// int4_fp8e4m3_mac -- INT4 x FP8(E4M3) + FP8 -> FP8 (4-lane)
//   Two signed INT(INT_WIDTH)-bit lanes (two's complement) x two FP8 B-lanes
//   => 4 products via DSP, then 4x FP8 adds with C.
//
//   INT4 conversion: two's complement -> sign + magnitude,
//   then normalize to {exp_unbiased, 1.frac} representation,
//   bias (+7) to produce an FP8(E4M3)-compatible encoding,
//   and feed into the shared mac_4lane core.
//
//   Uses int4_decode_fp8_fields from int4_fp8_common.vh
//   Params: INT_WIDTH (default 4), MUL_LAT, MID_STAGES, ADD_LAT
// ======================================================================
module int4_fp8e4m3_mac #(
    parameter integer INT_WIDTH  = 4,
    parameter integer MUL_LAT    = 2,
    parameter integer MID_STAGES = 1,
    parameter integer ADD_LAT    = 1
) (
    input  wire                       clk,
    input  wire [2*INT_WIDTH-1:0]     a_int,    // {a2[INT_WIDTH-1:0], a1[INT_WIDTH-1:0]} signed INT lanes
    input  wire [15:0]                b_fp8,    // {b2[15:8], b1[7:0]} FP8(E4M3)
    input  wire [31:0]                c_fp8,    // {c22, c21, c12, c11} FP8(E4M3)
    output wire [31:0]                result    // {y22, y21, y12, y11}
);

  // ---- INT decode helper (mirrors int4_fp8_common.vh) ----
  // Converts a signed INT(INT_WIDTH) lane (two's complement) into
  // {is_zero, sign, exp_unbiased[3:0], frac[2:0]} = 9 bits.
  // Sign-extension to 5 bits is done via $signed assignment.
  function [8:0] int_decode_fp8_fields;
    input [INT_WIDTH-1:0] val;
    reg signed [4:0] sval;
    reg        sign;
    reg signed [4:0] abs5;
    reg [3:0]  mag;
    reg [3:0]  exp_unb;
    reg [3:0]  mant4;
    begin
      // Sign-extend to 5 bits via $signed (works for any INT_WIDTH <= 4)
      sval = $signed(val);
      sign = sval[4];
      abs5 = sign ? -sval : sval;
      mag  = abs5[3:0];
      if (mag == 4'd0) begin
        int_decode_fp8_fields = 9'd0;
        int_decode_fp8_fields[8] = 1'b1;
      end else begin
        casez (mag)
          4'b1???: begin
            exp_unb = 4'd3;
            mant4   = {1'b1, mag[2:0]};
          end
          4'b01??: begin
            exp_unb = 4'd2;
            mant4   = {1'b1, mag[1:0], 1'b0};
          end
          4'b001?: begin
            exp_unb = 4'd1;
            mant4   = {1'b1, mag[0], 2'b00};
          end
          default: begin
            exp_unb = 4'd0;
            mant4   = 4'b1000;
          end
        endcase
        int_decode_fp8_fields = {1'b0, sign, exp_unb, mant4[2:0]};
      end
    end
  endfunction

  // ---- Decode INT lanes ----
  wire [8:0] a1_core = int_decode_fp8_fields(a_int[INT_WIDTH-1:0]);
  wire [8:0] a2_core = int_decode_fp8_fields(a_int[2*INT_WIDTH-1:INT_WIDTH]);

  wire       a1_zero = a1_core[8];
  wire       a2_zero = a2_core[8];
  wire       sa1     = a1_core[7];
  wire       sa2     = a2_core[7];
  wire [3:0] ea1_unb = a1_core[6:3];
  wire [3:0] ea2_unb = a2_core[6:3];
  wire [2:0] fa1     = a1_core[2:0];
  wire [2:0] fa2     = a2_core[2:0];

  // Bias the exponent to FP8 E4M3 domain (bias=7)
  wire [4:0] ea1_bias = {1'b0, ea1_unb} + 5'd7;
  wire [4:0] ea2_bias = {1'b0, ea2_unb} + 5'd7;
  wire [3:0] ea1 = a1_zero ? 4'd0 : ea1_bias[3:0];
  wire [3:0] ea2 = a2_zero ? 4'd0 : ea2_bias[3:0];

  // Pack as FP8: {sign, exp[3:0], frac[2:0]}
  wire [7:0] a1_fp8 = a1_zero ? 8'd0 : {sa1, ea1, fa1};
  wire [7:0] a2_fp8 = a2_zero ? 8'd0 : {sa2, ea2, fa2};

  // ---- Instantiate mac_4lane ----
  fp8e4m3_mac_4lane #(
    .MUL_LAT    (MUL_LAT),
    .MID_STAGES (MID_STAGES),
    .ADD_LAT    (ADD_LAT)
  ) u_mac (
    .clk    (clk),
    .a_fp8  ({a2_fp8, a1_fp8}),
    .b_fp8  (b_fp8),
    .c_fp8  (c_fp8),
    .result (result)
  );

endmodule

`default_nettype wire
