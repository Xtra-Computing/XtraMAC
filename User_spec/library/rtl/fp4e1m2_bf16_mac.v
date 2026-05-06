`timescale 1ns/1ps
`default_nettype none

module fp4e1m2_bf16_mac (
    input  wire        clk,
    input  wire [7:0]  a_fp4,
    input  wire [15:0] b_bf16,
    input  wire [31:0] c_bf16,
    output wire [31:0] result
);
  `include "fp4_fp8_mac_common.vh"

  function automatic [7:0] fp4e1m2_to_fp8e4m3;
    input [3:0] lane;
    reg sign;
    reg [1:0] frac2;
    begin
      sign = lane[3];
      if (lane[2] == 1'b1)
        fp4e1m2_to_fp8e4m3 = 8'h79;
      else begin
        frac2 = lane[1:0];
        if (frac2 == 2'b00)
          fp4e1m2_to_fp8e4m3 = {sign, 7'd0};
        else
          fp4e1m2_to_fp8e4m3 = {sign, 4'd6, frac2, 1'b0};
      end
    end
  endfunction

  wire [7:0] a_lo8 = fp4e1m2_to_fp8e4m3(a_fp4[3:0]);
  wire [7:0] a_hi8 = fp4e1m2_to_fp8e4m3(a_fp4[7:4]);
  wire [15:0] a_fp8 = {a_hi8, a_lo8};

  fp8e4m3_bf16_mac u_mac (
      .clk   (clk),
      .a16   (a_fp8),
      .b16   (b_bf16),
      .c32   (c_bf16),
      .result(result)
  );
endmodule

`default_nettype wire
