`timescale 1ns/1ps
`default_nettype none

module fp4e3m0_bf16_mac (
    input  wire        clk,
    input  wire [7:0]  a_fp4,
    input  wire [15:0] b_bf16,
    input  wire [31:0] c_bf16,
    output wire [31:0] result
);
  `include "fp4_fp8_mac_common.vh"

  function automatic [7:0] fp4e3m0_to_fp8e4m3;
    input [3:0] lane;
    reg sign;
    reg [2:0] exp3;
    reg [3:0] exp_final;
    begin
      sign = lane[3];
      exp3 = lane[2:0];
      if (exp3 == 3'd7)
        fp4e3m0_to_fp8e4m3 = 8'h79;
      else if (exp3 == 3'd0)
        fp4e3m0_to_fp8e4m3 = {sign, 7'd0};
      else begin
        exp_final = exp3 + 4'd1;
        fp4e3m0_to_fp8e4m3 = {sign, exp_final[3:0], 3'b000};
      end
    end
  endfunction

  wire [7:0] a_lo8 = fp4e3m0_to_fp8e4m3(a_fp4[3:0]);
  wire [7:0] a_hi8 = fp4e3m0_to_fp8e4m3(a_fp4[7:4]);
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
