`timescale 1ns/1ps
`default_nettype none

module int8_add (
    input  wire        clk,
    input  wire [15:0] prod_mag16_s2, // unsigned magnitude from DSP split
    input  wire        prod_sign_s2,  // sign from mapper (S2)
    input  wire [31:0] c32_s2,        // 32-bit addend (S2)
    output wire [31:0] sum32_out      // saturating INT32 add
);
  // S3 regs
  reg [15:0] prod_mag_s3;
  reg [31:0] c32_s3;
  reg        prod_sign_s3;

  always @(posedge clk) begin
    prod_mag_s3  <= prod_mag16_s2;
    prod_sign_s3 <= prod_sign_s2;
    c32_s3       <= c32_s2;
  end

  // convert magnitude + sign to two's complement; add; saturate
  wire [31:0] prod_mag_ext = {16'd0, prod_mag_s3};
  wire [31:0] prod_tc      = prod_sign_s3 ? (~prod_mag_ext + 32'd1) : prod_mag_ext;
  wire [31:0] sum32_i      = c32_s3 + prod_tc;
  wire        ovf          = (c32_s3[31] == prod_tc[31]) && (sum32_i[31] != c32_s3[31]);
  assign sum32_out = ovf ? (c32_s3[31] ? 32'h8000_0000 : 32'h7FFF_FFFF) : sum32_i;
endmodule

`default_nettype wire
