`timescale 1ns/1ps
`default_nettype none

module int8_bf16_32_mac (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [63:0] c64,
    output wire [63:0] result
);
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
    input [7:0] x;
    reg        sign;
    reg [7:0]  mag;
    reg [7:0]  exp_bf16;
    reg [6:0]  frac_bf16;
    reg [7:0]  shift_tmp;
    integer    k;
    begin
      sign = x[7];
      mag  = sign ? (~x + 8'd1) : x;
      if (mag == 8'd0) begin
        lane_to_bf16 = {sign, 15'd0};
      end else begin
        casex (mag)
          8'b1xxxxxxx: k = 7;
          8'b01xxxxxx: k = 6;
          8'b001xxxxx: k = 5;
          8'b0001xxxx: k = 4;
          8'b00001xxx: k = 3;
          8'b000001xx: k = 2;
          8'b0000001x: k = 1;
          default:      k = 0;
        endcase
        exp_bf16  = k + 8'd127;
        shift_tmp = mag << (7 - k);
        frac_bf16 = shift_tmp[6:0];
        lane_to_bf16 = {sign, exp_bf16, frac_bf16};
      end
    end
  endfunction
endmodule

`default_nettype wire
