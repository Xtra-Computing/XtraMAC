`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int_bf16_fp32_mac : INT(2..8) x BF16 + FP32 -> FP32 (2-lane)
//   - Converts signed INT input to BF16, then calls bf16_fp32_mac_2lane
//   - INT_WIDTH: width of integer operand (2..8), default 8
//   - Two INT lanes packed in a16[2*INT_WIDTH-1:0]
// =============================================================
module int_bf16_fp32_mac #(
    parameter INT_WIDTH  = 8,
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 1,
    parameter ADD_LAT    = 2
)(
    input  wire                    clk,
    input  wire [2*INT_WIDTH-1:0]  a_int,   // packed INT {hi, lo}
    input  wire [15:0]             b16,     // shared BF16
    input  wire [63:0]             c64,     // FP32 addends {hi, lo}
    output wire [63:0]             result   // FP32 results {hi, lo}
);

  // ----------------------------------------------------------------
  // Convert each INT lane to BF16
  //   BF16 = {sign, 8-bit exp, 7-bit frac}
  //   For integer value v (signed, INT_WIDTH bits):
  //     sign = v[MSB]
  //     magnitude = |v|
  //     If magnitude == 0: BF16 = {sign, 0, 0} (zero)
  //     Else: find leading-1 position p (0-based from MSB of magnitude)
  //           exp = 127 + (INT_WIDTH-1) - p  (unbiased = bit position of leading 1)
  //           mantissa bits below leading-1, left-justified into 7-bit frac
  // ----------------------------------------------------------------

  // HI lane
  wire [INT_WIDTH-1:0] a_hi_raw = a_int[2*INT_WIDTH-1:INT_WIDTH];
  wire                 a_hi_sign = a_hi_raw[INT_WIDTH-1];
  wire [INT_WIDTH-1:0] a_hi_mag = a_hi_sign ? (~a_hi_raw + {{(INT_WIDTH-1){1'b0}}, 1'b1}) : a_hi_raw;

  // LO lane
  wire [INT_WIDTH-1:0] a_lo_raw = a_int[INT_WIDTH-1:0];
  wire                 a_lo_sign = a_lo_raw[INT_WIDTH-1];
  wire [INT_WIDTH-1:0] a_lo_mag = a_lo_sign ? (~a_lo_raw + {{(INT_WIDTH-1){1'b0}}, 1'b1}) : a_lo_raw;

  // INT to BF16 conversion function (combinational)
  // Uses a priority encoder to find the leading-1
  function [15:0] int_to_bf16;
    input             sign_in;
    input [7:0]       mag8;   // magnitude zero-extended to 8 bits
    input integer     width;  // original INT_WIDTH
    reg [7:0] e_biased;
    reg [6:0] frac;
    reg [7:0] shifted;
    integer p;
    begin
      if (mag8 == 8'd0) begin
        int_to_bf16 = {sign_in, 15'd0};
      end else begin
        // Find leading-1 position (from bit 7 down)
        p = 7;
        if      (mag8[7]) p = 7;
        else if (mag8[6]) p = 6;
        else if (mag8[5]) p = 5;
        else if (mag8[4]) p = 4;
        else if (mag8[3]) p = 3;
        else if (mag8[2]) p = 2;
        else if (mag8[1]) p = 1;
        else              p = 0;

        e_biased = 8'd127 + p[7:0]; // unbiased exponent = p
        // Shift magnitude so leading-1 is at bit 7, take bits [6:0] as frac
        shifted = mag8 << (7 - p);
        frac = shifted[6:0];
        int_to_bf16 = {sign_in, e_biased, frac};
      end
    end
  endfunction

  // Zero-extend magnitudes to 8 bits
  wire [7:0] a_hi_mag8 = {{(8-INT_WIDTH){1'b0}}, a_hi_mag};
  wire [7:0] a_lo_mag8 = {{(8-INT_WIDTH){1'b0}}, a_lo_mag};

  wire [15:0] a_hi_bf16 = int_to_bf16(a_hi_sign, a_hi_mag8, INT_WIDTH);
  wire [15:0] a_lo_bf16 = int_to_bf16(a_lo_sign, a_lo_mag8, INT_WIDTH);

  wire [31:0] a32_bf16 = {a_hi_bf16, a_lo_bf16};

  // ----------------------------------------------------------------
  // Instantiate base MAC
  // ----------------------------------------------------------------
  bf16_fp32_mac_2lane #(
    .MUL_LAT   (MUL_LAT),
    .MID_STAGES(MID_STAGES),
    .ADD_LAT   (ADD_LAT)
  ) u_mac (
    .clk   (clk),
    .a32   (a32_bf16),
    .b16   (b16),
    .c64   (c64),
    .result(result)
  );

endmodule
`default_nettype wire
