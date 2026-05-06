`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp4e2m1_bf16_mac
//   Reinterprets FP4 (E2M1) lane pairs as BF16 operands by zero-padding
//   the exponent/mantissa fields, then reuses bf16_mac for the math.
//   - Keeps original interface/latency (4-cycle, II=1 via bf16_mac)
//   - mode conversions are purely combinational in front of bf16_mac
// =============================================================
module fp4e2m1_bf16_mac (
    input  wire        clk,
    input  wire [7:0]  a_fp4,    // {hi[7:4], lo[3:0]} FP4 (E2M1) lanes
    input  wire [15:0] b_bf16,   // shared BF16 multiplicand
    input  wire [31:0] c_bf16,   // BF16 addends {hi, lo}
    output wire [31:0] result
);
  // Convert each FP4 lane into a BF16 lane by padding zeros after the
  // exponent (2→8 bits) and mantissa (1→7 bits). Sign bit maps 1:1.
  function automatic [15:0] fp4_to_bf16;
    input [3:0] lane;
    begin
      fp4_to_bf16 = { lane[3],            // sign
                      {lane[2:1], 6'b0},  // exponent padded to 8 bits
                      lane[0],            // mantissa MSB
                      6'b0               // remaining mantissa bits cleared
                    };
    end
  endfunction

  wire [15:0] a_lo_bf16 = fp4_to_bf16(a_fp4[3:0]);
  wire [15:0] a_hi_bf16 = fp4_to_bf16(a_fp4[7:4]);
  wire [31:0] a32_bf16  = {a_hi_bf16, a_lo_bf16};

  bf16_mac u_bf16_mac (
    .clk   (clk),
    .a32   (a32_bf16),
    .b16   (b_bf16),
    .c32   (c_bf16),
    .result(result)
  );
endmodule

`default_nettype wire
