`timescale 1ns/1ps
`default_nettype none
// =============================================================
// bf16_fp4_dual_mac : runtime-reconfigurable BF16 / FP4(E2M1) MAC
//   - mode_fp4 == 0 : pass BF16 lanes directly from a_data
//   - mode_fp4 == 1 : reinterpret FP4 nibbles as BF16 by zero-padding
//   - Backend: parameterized bf16_mac_2lane (XtraMAC_v2)
//   - Total latency = MUL_LAT + MID_STAGES + ADD_LAT
//       (2,0,2) -> 4c   (2,0,3) -> 5c   (2,1,3) -> 6c
//   - II = 1
// =============================================================
module bf16_fp4_dual_mac #(
    parameter MUL_LAT    = 2,
    parameter MID_STAGES = 0,
    parameter ADD_LAT    = 2
)(
    input  wire        clk,
    input  wire        mode_fp4,
    input  wire [31:0] a_data,   // BF16 lanes when mode=0; FP4 packed [7:0] when mode=1
    input  wire [15:0] b_bf16,
    input  wire [31:0] c_bf16,
    output wire [31:0] result
);
  // FP4(E2M1) lane → BF16 by sign + exp_pad + mantissa MSB padding
  function automatic [15:0] fp4_lane_to_bf16;
    input [3:0] lane;
    begin
      fp4_lane_to_bf16 = {
        lane[3],            // sign
        {lane[2:1], 6'b0},  // exp(2b) → BF16 exp(8b) MSB-aligned
        lane[0],            // frac MSB
        6'b0
      };
    end
  endfunction

  wire [15:0] fp4_lo = fp4_lane_to_bf16(a_data[3:0]);
  wire [15:0] fp4_hi = fp4_lane_to_bf16(a_data[7:4]);
  wire [31:0] a_data_fp4 = {fp4_hi, fp4_lo};
  wire [31:0] a_mux = mode_fp4 ? a_data_fp4 : a_data;

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
