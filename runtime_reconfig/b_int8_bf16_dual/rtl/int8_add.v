`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int8_add : Parameterized INT32 saturating adder
//   - Input is sign+magnitude (16-bit unsigned) from DSP split, plus 32-bit C
//   - LATENCY parameter:
//       LATENCY = 1 : input register + comb output wire (1 reg)
//       LATENCY = 2 : input register + comb + output register (2 regs)
//       LATENCY = 3 : 3-stage pipeline (input | sum | sat-pack)
// =============================================================
module int8_add #(
    parameter LATENCY = 2
)(
    input  wire        clk,
    input  wire [15:0] prod_mag16_s2,
    input  wire        prod_sign_s2,
    input  wire [31:0] c32_s2,
    output wire [31:0] sum32_out
);
  reg [15:0] prod_mag_r;
  reg        prod_sign_r;
  reg [31:0] c32_r;
  always @(posedge clk) begin
    prod_mag_r  <= prod_mag16_s2;
    prod_sign_r <= prod_sign_s2;
    c32_r       <= c32_s2;
  end

  wire [31:0] prod_mag_ext = {16'd0, prod_mag_r};
  wire [31:0] prod_tc      = prod_sign_r ? (~prod_mag_ext + 32'd1) : prod_mag_ext;
  wire [31:0] sum32_raw    = c32_r + prod_tc;
  wire        ovf          = (c32_r[31] == prod_tc[31]) && (sum32_raw[31] != c32_r[31]);
  wire [31:0] sat32        = ovf ? (c32_r[31] ? 32'h8000_0000 : 32'h7FFF_FFFF) : sum32_raw;

  generate
    if (LATENCY <= 1) begin : gen_lat1
      assign sum32_out = sat32;
    end else if (LATENCY == 2) begin : gen_lat2
      reg [31:0] sat32_r;
      always @(posedge clk) sat32_r <= sat32;
      assign sum32_out = sat32_r;
    end else begin : gen_lat3
      reg [31:0] sum_r, prod_tc_r, c32_rr;
      always @(posedge clk) begin
        sum_r     <= sum32_raw;
        prod_tc_r <= prod_tc;
        c32_rr    <= c32_r;
      end
      wire ovf2 = (c32_rr[31] == prod_tc_r[31]) && (sum_r[31] != c32_rr[31]);
      wire [31:0] sat2 = ovf2 ? (c32_rr[31] ? 32'h8000_0000 : 32'h7FFF_FFFF) : sum_r;
      reg [31:0] sat_r;
      always @(posedge clk) sat_r <= sat2;
      assign sum32_out = sat_r;
    end
  endgenerate
endmodule
`default_nettype wire
