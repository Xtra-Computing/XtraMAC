`timescale 1ns/1ps
`default_nettype none

// INT8 postproc: captures S1 metadata and splits DSP product at S2
module mac_postproc_int8 (
    input  wire        clk,

    // From INT8 mapper (S1)
    input  wire        sign_hi_int8_s1,
    input  wire        sign_lo_int8_s1,
    input  wire [31:0] c_hi_int8_s1,
    input  wire [31:0] c_lo_int8_s1,

    // From shared DSP (S1->S2 boundary)
    input  wire [44:0] product45,

    // S2 outputs (registered here)
    output reg         sign_hi_int8_s2,
    output reg         sign_lo_int8_s2,
    output reg  [31:0] c_hi_int8_s2,
    output reg  [31:0] c_lo_int8_s2,

    // Split product magnitudes for the two INT16 adders (S2)
    output reg  [15:0] prod_hi16_int8_mag,
    output reg  [15:0] prod_lo16_int8_mag
);
  // Keep your exact behavior: take the lower 32 bits
  wire [31:0] prod32_s2_w = product45[31:0];

  always @(posedge clk) begin
    // meta to S2
    sign_hi_int8_s2 <= sign_hi_int8_s1;
    sign_lo_int8_s2 <= sign_lo_int8_s1;
    c_hi_int8_s2    <= c_hi_int8_s1;
    c_lo_int8_s2    <= c_lo_int8_s1;

    // split
    prod_hi16_int8_mag <= prod32_s2_w[31:16];
    prod_lo16_int8_mag <= prod32_s2_w[15:0];
  end
endmodule

`default_nettype wire
