`timescale 1ns/1ps
`default_nettype none

module fp4_fp8e4m3_16_core #(
    parameter integer FP4_MODE = 0  // 0:E3M0, 1:E2M1, 2:E1M2
) (
    input  wire        clk,
    input  wire [7:0]  a_fp4,
    input  wire [15:0] b_fp8,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  `include "fp4_fp8_mac_common.vh"

  // Conversion helpers mirror the behavioural models used by the test benches.
  function [7:0] fp4_to_fp8_e4m3;
    input [3:0] lane;
    reg sign;
    reg [2:0] exp3;
    reg [1:0] exp2;
    reg       frac1;
    reg [1:0] frac2;
    reg [3:0] exp_final;
    reg [2:0] frac_final;
    begin
      sign = lane[3];
      case (FP4_MODE)
        `FP4_MODE_E3M0: begin
          exp3 = lane[2:0];
          if (exp3 == 3'd7)
            fp4_to_fp8_e4m3 = 8'h79;                // qNaN exemplar (no sign dependency)
          else if (exp3 == 3'd0)
            fp4_to_fp8_e4m3 = {sign, 7'd0};         // zero
          else begin
            exp_final = exp3 + 4'd1;
            fp4_to_fp8_e4m3 = {sign, exp_final[3:0], 3'b000};
          end
        end
        `FP4_MODE_E2M1: begin
          exp2  = lane[2:1];
          frac1 = lane[0];
          if (exp2 == 2'b11)
            fp4_to_fp8_e4m3 = 8'h79;
          else if (exp2 == 2'b00)
            fp4_to_fp8_e4m3 = {sign, 7'd0};
          else begin
            exp_final  = {2'b00, exp2} + 4'd4;
            frac_final = {frac1, 2'b00};
            fp4_to_fp8_e4m3 = {sign, exp_final[3:0], frac_final};
          end
        end
        default: begin // E1M2
          // exp_bit=1 encodes NaN; exp=0 with frac=0 => zero; otherwise exponent=6
          if (lane[2] == 1'b1)
            fp4_to_fp8_e4m3 = 8'h79;
          else begin
            frac2 = lane[1:0];
            if (frac2 == 2'b00)
              fp4_to_fp8_e4m3 = {sign, 7'd0};
            else
              fp4_to_fp8_e4m3 = {sign, 4'd6, frac2, 1'b0};
          end
        end
      endcase
    end
  endfunction

  wire [7:0] a1_fp8 = fp4_to_fp8_e4m3(a_fp4[3:0]);
  wire [7:0] a2_fp8 = fp4_to_fp8_e4m3(a_fp4[7:4]);
  wire [31:0] a_bus = {16'd0, a2_fp8, a1_fp8};

  fp8e4m3_16_mac u_mac (
      .clk   (clk),
      .a18   (a_bus),
      .b18   (b_fp8),
      .c64   (c64),
      .result(result)
  );

endmodule

`default_nettype wire
