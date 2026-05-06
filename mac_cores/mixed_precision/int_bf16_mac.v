`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int_bf16_mac : 2-lane INT(WIDTH) x BF16 + BF16 -> BF16
//   - Parameterized integer width (2..8, default 8).
//   - Input a_int packs two signed integers:
//       {hi[2*WIDTH-1:WIDTH], lo[WIDTH-1:0]}  (two's complement)
//   - Shared BF16 multiplicand b16.
//   - BF16 addends c32 = {hi, lo}.
//   - Output: two BF16 results packed {hi, lo}.
//   - Each INT lane is converted to BF16 inline (exact for widths <= 8)
//     then delegated to bf16_mac_2lane.
//
//   MAC pipeline params forwarded from bf16_mac_2lane defaults.
// =============================================================
module int_bf16_mac #(
    parameter WIDTH      = 8,   // integer operand width (2..8)
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 0,
    parameter ADD_LAT    = 2
)(
    input  wire                    clk,
    input  wire [2*WIDTH-1:0]      a_int,   // {hi, lo} signed integers
    input  wire [15:0]             b16,     // shared BF16
    input  wire [31:0]             c32,     // BF16 addends {hi, lo}
    output wire [31:0]             result   // BF16 results {hi, lo}
);

  // ---------------------------------------------------------------
  // INT -> BF16 conversion (exact for up to 8-bit signed integers)
  // ---------------------------------------------------------------
  function automatic [15:0] int_to_bf16;
    input [WIDTH-1:0] x;
    reg        sign;
    reg [7:0]  mag;
    reg [7:0]  exp_bf16;
    reg [6:0]  frac_bf16;
    reg [7:0]  shift_tmp;
    integer    k;
    begin
      sign = x[WIDTH-1];
      mag  = sign ? (~{8'd0, x} + 8'd1) : {8'd0, x};
      mag  = mag[7:0]; // keep lower 8 bits (sufficient for WIDTH <= 8)

      if (mag == 8'd0) begin
        int_to_bf16 = {sign, 15'd0};
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

        exp_bf16  = k[7:0] + 8'd127;
        shift_tmp = mag << (7 - k);
        frac_bf16 = shift_tmp[6:0];
        int_to_bf16 = {sign, exp_bf16, frac_bf16};
      end
    end
  endfunction

  // Lane split
  wire [WIDTH-1:0] a_lo = a_int[WIDTH-1:0];
  wire [WIDTH-1:0] a_hi = a_int[2*WIDTH-1:WIDTH];

  wire [15:0] a_lo_bf16 = int_to_bf16(a_lo);
  wire [15:0] a_hi_bf16 = int_to_bf16(a_hi);
  wire [31:0] a_bf16    = {a_hi_bf16, a_lo_bf16};

  bf16_mac_2lane #(
    .MUL_LAT   (MUL_LAT),
    .MID_STAGES(MID_STAGES),
    .ADD_LAT   (ADD_LAT)
  ) u_mac (
    .clk   (clk),
    .a32   (a_bf16),
    .b16   (b16),
    .c32   (c32),
    .result(result)
  );

endmodule

`default_nettype wire
