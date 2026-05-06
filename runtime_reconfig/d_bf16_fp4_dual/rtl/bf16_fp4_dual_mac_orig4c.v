`timescale 1ns/1ps
`default_nettype none

// =============================================================
// bf16_fp4_dual_mac_orig4c
//   Shared bf16_mac_orig4c backend with a mode-select front-end:
//     mode_fp4 == 0 : pass BF16 lanes directly from a_data
//     mode_fp4 == 1 : reinterpret FP4(E2M1) nibbles as BF16 by zero-padding
//   Latency and II follow bf16_mac_orig4c (4 cycles, II=1).
// =============================================================
module bf16_fp4_dual_mac_orig4c (
    input  wire        clk,
    input  wire        mode_fp4,
    input  wire [31:0] a_data,   // BF16 lanes when mode=0, FP4 packed when mode=1
    input  wire [15:0] b_bf16,
    input  wire [31:0] c_bf16,
    output wire [31:0] result
);
  // Map a 4-bit FP4 lane {sign, exp[1:0], frac} into BF16 by padding zeros.
  function automatic [15:0] fp4_lane_to_bf16;
    input [3:0] lane;
    begin
      fp4_lane_to_bf16 = {
        lane[3],           // sign
        {lane[2:1], 6'b0}, // exponent bits in MSBs, pad to 8 bits
        lane[0],           // mantissa MSB
        6'b0               // remaining mantissa bits cleared
      };
    end
  endfunction

  wire [15:0] fp4_lo = fp4_lane_to_bf16(a_data[3:0]);
  wire [15:0] fp4_hi = fp4_lane_to_bf16(a_data[7:4]);
  wire [31:0] a_data_fp4 = {fp4_hi, fp4_lo};

  wire [31:0] a_mux = mode_fp4 ? a_data_fp4 : a_data;

  bf16_mac_orig4c u_mac (
    .clk   (clk),
    .a32   (a_mux),
    .b16   (b_bf16),
    .c32   (c_bf16),
    .result(result)
  );
endmodule

`default_nettype wire
