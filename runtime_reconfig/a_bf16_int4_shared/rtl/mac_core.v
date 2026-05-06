`timescale 1ns/1ps
`default_nettype none
// =============================================================
// bf16_int4_shared_mac : runtime-reconfigurable BF16 / INT4 MAC
//   - mode_int4 == 0 : pass BF16 lanes directly from a_data
//   - mode_int4 == 1 : convert INT4 nibbles to BF16 (sign-ext + normalize)
//   - Backend: parameterized bf16_mac_2lane (XtraMAC_v2)
//   - Total latency = MUL_LAT + MID_STAGES + ADD_LAT
//       (2,0,2) -> 4c   (2,0,3) -> 5c   (2,1,3) -> 6c
//   - II = 1
// =============================================================
module bf16_int4_shared_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 0,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire        mode_int4,
    input  wire [31:0] a_data,   // BF16 lanes when mode=0; INT4 packed [7:0] when mode=1
    input  wire [15:0] b_bf16,
    input  wire [31:0] c_bf16,
    output wire [31:0] result
);
  // Combinational INT4 (signed, two's complement) → BF16 (exact, FTZ for 0).
  function automatic [15:0] int4_to_bf16;
    input [3:0] x;
    reg [7:0]  val8, mag, shift_tmp;
    reg        sign;
    reg [7:0]  exp_bf16;
    reg [6:0]  frac_bf16;
    integer    k;
    begin
      val8 = {{4{x[3]}}, x};
      sign = val8[7];
      mag  = sign ? (~val8 + 8'd1) : val8;
      if (mag == 8'd0) begin
        int4_to_bf16 = {sign, 15'd0};
      end else begin
        casex (mag)
          8'b1xxxxxxx: k = 7;
          8'b01xxxxxx: k = 6;
          8'b001xxxxx: k = 5;
          8'b0001xxxx: k = 4;
          8'b00001xxx: k = 3;
          8'b000001xx: k = 2;
          8'b0000001x: k = 1;
          default:     k = 0;
        endcase
        exp_bf16  = k + 8'd127;
        shift_tmp = mag << (7 - k);
        frac_bf16 = shift_tmp[6:0];
        int4_to_bf16 = {sign, exp_bf16, frac_bf16};
      end
    end
  endfunction

  wire [15:0] int4_lo_bf16 = int4_to_bf16(a_data[3:0]);
  wire [15:0] int4_hi_bf16 = int4_to_bf16(a_data[7:4]);
  wire [31:0] a_data_int4  = {int4_hi_bf16, int4_lo_bf16};
  wire [31:0] a_mux        = mode_int4 ? a_data_int4 : a_data;

  bf16_mac_2lane #(
    .MUL_LAT   (MUL_LAT),
    .MID_STAGES(MID_STAGES),
    .ADD_LAT   (ADD_LAT)
  ) u_mac (
    .clk   (clk),
    .a32   (a_mux),
    .b16   (b_bf16),
    .c32   (c_bf16),
    .result(result)
  );
endmodule
`default_nettype wire
