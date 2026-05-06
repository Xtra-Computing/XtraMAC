`timescale 1ns/1ps
`default_nettype none

// Part (1): Mapping for INT8 lanes into a single DSP (S1 stage)
module mac_mapper_int8_orig4c (
    input  wire        clk,
    input  wire [31:0] a32,   // a_hi8=a32[31:24], a_lo8=a32[15:8]
    input  wire [15:0] b16,   // b8=b16[15:8]
    input  wire [63:0] c64,   // {c_hi32, c_lo32}

    output reg  [26:0] dsp_a_s1,        // {2'b00,1'b0,|a_hi|,8'd0,|a_lo|}
    output reg  [17:0] dsp_b_s1,        // {6'b0,4'b0,|b|}
    output reg         sign_hi_int8_s1, // sign bits for two INT8 products (S1)
    output reg         sign_lo_int8_s1,
    output reg  [31:0] c_hi_s1,         // pass-through addends
    output reg  [31:0] c_lo_s1
);

  wire [7:0] a_hi8_w = a32[31:24];
  wire [7:0] a_lo8_w = a32[15:8];
  wire [7:0] b8_w    = b16[15:8];

  function [7:0] abs8;
    input [7:0] x;
    begin
      abs8 = x[7] ? (~x + 8'd1) : x; // |−128|=128 (unsigned magnitude)
    end
  endfunction

  wire [7:0] a_hi_abs_w = abs8(a_hi8_w);
  wire [7:0] a_lo_abs_w = abs8(a_lo8_w);
  wire [7:0] b_abs_w    = abs8(b8_w);

  wire [31:0] c_lo_w = c64[31:0];
  wire [31:0] c_hi_w = c64[63:32];

  always @(posedge clk) begin
    // signs (S1)
    sign_hi_int8_s1 <= a_hi8_w[7] ^ b8_w[7];
    sign_lo_int8_s1 <= a_lo8_w[7] ^ b8_w[7];

    // DSP inputs (S1)
    dsp_a_s1 <= {2'b00, 1'b0, a_hi_abs_w, 8'd0, a_lo_abs_w};
    dsp_b_s1 <= {6'b0, 4'b0, b_abs_w};

    // pass-through addends (S1 -> S2 boundary inside postproc)
    c_hi_s1  <= c_hi_w;
    c_lo_s1  <= c_lo_w;
  end
endmodule

`default_nettype wire
