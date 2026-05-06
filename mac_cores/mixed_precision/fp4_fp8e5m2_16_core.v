`timescale 1ns/1ps
`default_nettype none

// ==========================================================================
// fp4_fp8e5m2_16_core : Parameterized FP4 x FP8(E5M2) -> FP16 accumulation
//   Converts FP4 lanes to FP8(E5M2), then delegates to fp8e5m2_16_mac_4lane.
//   FP4_MODE: 0=E3M0, 1=E2M1, 2=E1M2
// ==========================================================================
module fp4_fp8e5m2_16_core #(
    parameter integer FP4_MODE   = 0,
    parameter integer MUL_LAT    = 2,
    parameter integer MID_STAGES = 0,
    parameter integer ADD_LAT    = 2
) (
    input  wire        clk,
    input  wire [7:0]  a_fp4,
    input  wire [15:0] b_fp8,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  `include "fp4_fp8_mac_common.vh"

  localparam [7:0] QNAN8 = 8'h7D;

  function [7:0] fp4_to_fp8_e5m2;
    input [3:0] lane;
    reg sign;
    reg [2:0] exp3;
    reg [1:0] exp2;
    reg       frac1;
    reg [1:0] frac2;
    reg [4:0] exp_final;
    begin
      sign = lane[3];
      case (FP4_MODE)
        `FP4_MODE_E3M0: begin
          exp3 = lane[2:0];
          if (exp3 == 3'd7)
            fp4_to_fp8_e5m2 = {sign, 5'h1F, 2'b00};
          else if (exp3 == 3'd0)
            fp4_to_fp8_e5m2 = {sign, 5'd0, 2'b00};
          else begin
            exp_final = exp3 + 5'd12;
            fp4_to_fp8_e5m2 = {sign, exp_final[4:0], 2'b00};
          end
        end
        `FP4_MODE_E2M1: begin
          exp2  = lane[2:1];
          frac1 = lane[0];
          if (exp2 == 2'b11)
            fp4_to_fp8_e5m2 = (frac1 == 1'b0) ? {sign, 5'h1F, 2'b00} : QNAN8;
          else if (exp2 == 2'b00)
            fp4_to_fp8_e5m2 = (frac1 == 1'b0) ? {sign, 5'd0, 2'b00}
                                               : {sign, 5'd14, 2'b00};
          else begin
            exp_final = 5'd15 + exp2 - 5'd1;
            fp4_to_fp8_e5m2 = {sign, exp_final[4:0], {frac1, 1'b0}};
          end
        end
        default: begin // E1M2
          frac2 = lane[1:0];
          if ((lane[2] == 1'b0) && (frac2 == 2'b00))
            fp4_to_fp8_e5m2 = {sign, 5'd0, 2'b00};
          else
            fp4_to_fp8_e5m2 = {sign, 5'd15, frac2};
        end
      endcase
    end
  endfunction

  wire [7:0] a1_fp8 = fp4_to_fp8_e5m2(a_fp4[3:0]);
  wire [7:0] a2_fp8 = fp4_to_fp8_e5m2(a_fp4[7:4]);
  wire [31:0] a_bus = {16'd0, a2_fp8, a1_fp8};

  fp8e5m2_16_mac_4lane #(
    .MUL_LAT   (MUL_LAT),
    .MID_STAGES(MID_STAGES),
    .ADD_LAT   (ADD_LAT)
  ) u_mac (
    .clk   (clk),
    .a18   (a_bus),
    .b18   (b_fp8),
    .c64   (c64),
    .result(result)
  );

endmodule

`default_nettype wire
