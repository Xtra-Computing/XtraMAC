`timescale 1ns/1ps
`default_nettype none

// =============================================================
// int8_bf16_mac : Two-lane INT8 * BF16 + BF16 -> BF16
//   - Input a16 packs two int8 numbers {HI[15:8], LO[7:0]} (two's complement)
//   - Shared BF16 multiplicand b16
//   - BF16 addends c32 = {hi, lo}
//   - Output packed BF16 results {hi, lo}
//   - Int8 values are widened to BF16 inline (exact mapping)
// =============================================================
module int8_bf16_mac (
    input  wire        clk,
    input  wire [15:0] a16,
    input  wire [15:0] b16,
    input  wire [31:0] c32,
    output wire [31:0] result
);
  // Lane split
  wire [7:0] a_lo8 = a16[7:0];
  wire [7:0] a_hi8 = a16[15:8];

  // Convert int8 lanes to BF16
  wire [15:0] a_lo_bf16 = int8_to_bf16(a_lo8);
  wire [15:0] a_hi_bf16 = int8_to_bf16(a_hi8);
  wire [31:0] a_bf16    = {a_hi_bf16, a_lo_bf16};

  // Reuse BF16 MAC pipeline
  bf16_mac u_mac (
    .clk   (clk),
    .a32   (a_bf16),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

  // -----------------------------------------------------------
  // Helper: signed int8 -> BF16 (exact, FTZ for 0)
  // -----------------------------------------------------------
  function automatic [15:0] int8_to_bf16;
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
        int8_to_bf16 = {sign, 15'd0};
      end else begin
        // Locate MSB position k (0..7)
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

        exp_bf16  = k + 8'd127;              // bias shift (127)

        shift_tmp = mag << (7 - k);           // normalize mantissa
        frac_bf16 = shift_tmp[6:0];           // take bits after leading 1

        int8_to_bf16 = {sign, exp_bf16, frac_bf16};
      end
    end
  endfunction
endmodule

`default_nettype wire
