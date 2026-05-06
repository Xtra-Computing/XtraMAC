`timescale 1ns/1ps
`default_nettype none

module fp8e4m3_bf16_32_mac (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);
  localparam [15:0] QNAN16 = 16'h7FC0;

  wire [7:0] a_lo8 = a16[7:0];
  wire [7:0] a_hi8 = a16[15:8];

  wire [15:0] a_lo_bf16 = lane_to_bf16(a_lo8);
  wire [15:0] a_hi_bf16 = lane_to_bf16(a_hi8);
  wire [31:0] a_bf16    = {a_hi_bf16, a_lo_bf16};

  bf16_32_mac u_mac (
    .clk   (clk),
    .a32   (a_bf16),
    .b16   (b16),
    .c64   (c64),
    .result(result)
  );

  function automatic [15:0] lane_to_bf16;
    input [7:0] fp8;
    reg        sign;
    reg [3:0]  exp_fp8;
    reg [2:0]  frac_fp8;
    reg [7:0]  exp_bf16;
    reg [6:0]  frac_bf16;
    begin
      sign     = fp8[7];
      exp_fp8  = fp8[6:3];
      frac_fp8 = fp8[2:0];
      if (exp_fp8 == 4'hF) begin
        lane_to_bf16 = QNAN16;
      end else if (exp_fp8 == 4'd0) begin
        lane_to_bf16 = {sign, 15'd0};
      end else begin
        exp_bf16  = exp_fp8 + 8'd120;
        frac_bf16 = {frac_fp8, 4'b0};
        lane_to_bf16 = {sign, exp_bf16, frac_bf16};
      end
    end
  endfunction
endmodule

`default_nettype wire
