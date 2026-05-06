`timescale 1ns/1ps
`default_nettype none

// Part (1): Mapping for BF16 lanes into a single DSP (S1 stage)
module mac_mapper_bf16_orig4c (
    input  wire        clk,
    input  wire [31:0] a32,     // BF16 lanes {hi[31:16], lo[15:0]}
    input  wire [15:0] b16,     // shared BF16
    input  wire [31:0] c32,     // BF16 addends {hi, lo}

    output reg  [26:0] dsp_a_s1,         // packed |mant_a| for two lanes
    output reg  [17:0] dsp_b_s1,         // packed |mant_b|
    output reg signed [8:0] exp_hi_bf16_s1,   // raw BF16 exponent for HI lane
    output reg signed [8:0] exp_lo_bf16_s1,   // raw BF16 exponent for LO lane
    output reg         sign_hi_bf16_s1,  // signs for two lanes
    output reg         sign_lo_bf16_s1,

    // specials/classification
    output reg a_hi_nan_s1,
    output reg a_lo_nan_s1,
    output reg b_nan_s1,
    output reg a_hi_inf_s1,
    output reg a_lo_inf_s1,
    output reg b_inf_s1,
    output reg a_hi_zero_s1,
    output reg a_lo_zero_s1,
    output reg b_zero_s1,

    // pass-through addends for S2
    output reg [15:0] c_lo_s1,
    output reg [15:0] c_hi_s1
);
  localparam [7:0] BF16_BIAS = 8'd127;

  // Unpack A/B fields
  wire       a_hi_sign = a32[31];
  wire [7:0] a_hi_exp  = a32[30:23];
  wire [6:0] a_hi_frac = a32[22:16];

  wire       a_lo_sign = a32[15];
  wire [7:0] a_lo_exp  = a32[14:7];
  wire [6:0] a_lo_frac = a32[6:0];

  wire       b_sign    = b16[15];
  wire [7:0] b_exp     = b16[14:7];
  wire [6:0] b_frac    = b16[6:0];

  always @(posedge clk) begin
    // signs (S1)
    sign_hi_bf16_s1 <= a_hi_sign ^ b_sign;
    sign_lo_bf16_s1 <= a_lo_sign ^ b_sign;

    // raw exponents (S1) — keep 8-bit raw BF16; postproc will widen if needed
    exp_hi_bf16_s1 <= {1'b0, a_hi_exp} + {1'b0, b_exp} - {1'b0, BF16_BIAS};
    exp_lo_bf16_s1 <= {1'b0, a_lo_exp} + {1'b0, b_exp} - {1'b0, BF16_BIAS};

    // classify A(hi/lo)
    a_hi_nan_s1  <= (a_hi_exp==8'hFF) && (a_hi_frac!=7'd0);
    a_hi_inf_s1  <= (a_hi_exp==8'hFF) && (a_hi_frac==7'd0);
    a_hi_zero_s1 <= (a_hi_exp==8'd0); // FTZ
    a_lo_nan_s1  <= (a_lo_exp==8'hFF) && (a_lo_frac!=7'd0);
    a_lo_inf_s1  <= (a_lo_exp==8'hFF) && (a_lo_frac==7'd0);
    a_lo_zero_s1 <= (a_lo_exp==8'd0); // FTZ

    // classify B
    b_nan_s1     <= (b_exp==8'hFF) && (b_frac!=7'd0);
    b_inf_s1     <= (b_exp==8'hFF) && (b_frac==7'd0);
    b_zero_s1    <= (b_exp==8'd0); // FTZ

    // mantissa packs (hidden-1 assumed for finite path; postproc handles specials)
    dsp_a_s1 <= {3'b000, 1'b1, a_hi_frac, 8'd0, 1'b1, a_lo_frac};
    dsp_b_s1 <= {10'b0, 1'b1, b_frac};

    // C to S2
    c_lo_s1 <= c32[15:0];
    c_hi_s1 <= c32[31:16];
  end
endmodule

`default_nettype wire
