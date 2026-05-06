`timescale 1ns/1ps

module dsp_usage(
    input wire clk,
    input wire [26:0] a,
    input wire [17:0] b,
    output wire [44:0] product
    );
    wire [47:0] out;
    DSP48E2 #(
        .USE_MULT   ("MULTIPLY"),
        .USE_SIMD   ("ONE48"),
        .A_INPUT    ("DIRECT"),
        .B_INPUT    ("DIRECT"),
        .AREG       (0),  .ACASCREG (0),
        .BREG       (0),  .BCASCREG (0),
        .MREG       (0),
        .PREG       (0),
        .OPMODEREG      (0),
        .ALUMODEREG     (0),
        .INMODEREG      (0),
        .CARRYINREG     (0),
        .CARRYINSELREG  (0)
    ) u_mul (
        .CLK         (clk),
        .A           (a),
        .B           (b),
        .C           (48'd0),
        .D           (27'd0),

        .INMODE      (5'b00000),
        .ALUMODE     (4'b0000),
        .OPMODE      (9'b000_000_101),
        .CARRYIN     (1'b0),
        .CARRYINSEL  (3'b000),

        .CEA1(1'b0), .CEA2(1'b0), .CEB1(1'b0), .CEB2(1'b0),
        .CEM (1'b0), .CEP (1'b0), .CEC (1'b0), .CED (1'b0),

        .P (out)
    );

    assign product = out[44:0];
endmodule
