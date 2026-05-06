`timescale 1ns/1ps
`default_nettype none

module mac_postproc_bf16 (
    input  wire        clk,
    // -------- S1 meta in --------
    input  wire signed [8:0] exp_hi_bf16_s1,
    input  wire signed [8:0] exp_lo_bf16_s1,
    input  wire        sign_hi_bf16_s1,
    input  wire        sign_lo_bf16_s1,
    input  wire        a_hi_nan_s1,
    input  wire        a_lo_nan_s1,
    input  wire        b_nan_s1,
    input  wire        a_hi_inf_s1,
    input  wire        a_lo_inf_s1,
    input  wire        b_inf_s1,
    input  wire        a_hi_zero_s1,
    input  wire        a_lo_zero_s1,
    input  wire        b_zero_s1,
    input  wire [15:0] c_lo_bf16_s1,
    input  wire [15:0] c_hi_bf16_s1,
    input  wire [44:0] product45,   // shared DSP product

    // -------- registered S2 outputs --------
    output reg  [15:0] prod_lo16_bf16,
    output reg  [15:0] prod_hi16_bf16,
    output reg  [15:0] c_lo_bf16_s2,
    output reg  [15:0] c_hi_bf16_s2
);
  localparam [15:0] QNAN16 = 16'h7FC0; // quiet-NaN pattern

  // Slice the two lanes from product45
  wire [17:0] P_lo = product45[17:0];
  wire [17:0] P_hi = product45[35:18];

  // Widen exponents to 9-bit signed for overflow clamp checks
  wire signed [8:0] exp_hi9 = exp_hi_bf16_s1;
  wire signed [8:0] exp_lo9 = exp_lo_bf16_s1;

  wire [7:0] ehi = exp_hi9[7:0];
  wire [7:0] elo = exp_lo9[7:0];

  always @(posedge clk) begin
    // Pass-through C to S2
    c_hi_bf16_s2 <= c_hi_bf16_s1;
    c_lo_bf16_s2 <= c_lo_bf16_s1;

    // HI lane
    if (a_hi_nan_s1 | b_nan_s1 | ((a_hi_inf_s1 & b_zero_s1) | (a_hi_zero_s1 & b_inf_s1))) begin
      prod_hi16_bf16 <= QNAN16;
    end else if (a_hi_inf_s1 | b_inf_s1) begin
      prod_hi16_bf16 <= {sign_hi_bf16_s1, 8'hFF, 7'd0};
    end else if (a_hi_zero_s1 | b_zero_s1) begin
      prod_hi16_bf16 <= {sign_hi_bf16_s1, 15'h0000};
    end else if (exp_hi9[8] | (exp_hi9 > 9'd254)) begin
      prod_hi16_bf16 <= {sign_hi_bf16_s1, 8'hFF, 7'b0};
    end else if (P_hi[13]) begin
      prod_hi16_bf16 <= {sign_hi_bf16_s1, ehi + 8'd1, P_hi[12:6]};
    end else begin
      prod_hi16_bf16 <= {sign_hi_bf16_s1, ehi, P_hi[11:5]};
    end

    // LO lane
    if (a_lo_nan_s1 | b_nan_s1 | ((a_lo_inf_s1 & b_zero_s1) | (a_lo_zero_s1 & b_inf_s1))) begin
      prod_lo16_bf16 <= QNAN16;
    end else if (a_lo_inf_s1 | b_inf_s1) begin
      prod_lo16_bf16 <= {sign_lo_bf16_s1, 8'hFF, 7'd0};
    end else if (a_lo_zero_s1 | b_zero_s1) begin
      prod_lo16_bf16 <= {sign_lo_bf16_s1, 15'h0000};
    end else if (exp_lo9[8] | (exp_lo9 > 9'd254)) begin
      prod_lo16_bf16 <= {sign_lo_bf16_s1, 8'hFF, 7'b0};
    end else if (P_lo[15]) begin
      prod_lo16_bf16 <= {sign_lo_bf16_s1, elo + 8'd1, P_lo[14:8]};
    end else begin
      prod_lo16_bf16 <= {sign_lo_bf16_s1, elo, P_lo[13:7]};
    end
  end
endmodule

`default_nettype wire
