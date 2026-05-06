`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int8_mul_2lane : 2-lane INT8 x INT8 DSP-packed multiply
//   - Packs two signed INT8 x INT8 multiplications into one
//     27x18 DSP block using magnitude + sign-correction.
//   - A[26:0] = {3'b0, |a_hi|[7:0], 8'b0, |a_lo|[7:0]}
//   - B[17:0] = {10'b0, |b|[7:0]}
//   - Product windows: P_hi[31:16], P_lo[15:0]
//   - Latency: MUL_LAT cycles (1 or 2)
//     MUL_LAT=1 : S1 input regs -> combinational DSP
//     MUL_LAT=2 : S1 input regs -> DSP -> S2 product capture
// =============================================================
module int8_mul_2lane #(
    parameter MUL_LAT = 2  // 1 or 2
)(
    input  wire        clk,
    input  wire [15:0] a16,    // packed INT8 {hi[15:8], lo[7:0]}
    input  wire  [7:0] b8,     // shared INT8 operand
    output wire [31:0] prod_hi, // signed 32-bit product for hi lane
    output wire [31:0] prod_lo  // signed 32-bit product for lo lane
);

  // ----------------------------------------------------------------
  // Extract sign and magnitude (two's-complement INT8)
  // ----------------------------------------------------------------
  wire        a_hi_sign = a16[15];
  wire        a_lo_sign = a16[7];
  wire        b_sign    = b8[7];

  // Magnitude: if negative, negate; else keep
  wire [7:0] a_hi_mag = a_hi_sign ? (~a16[15:8] + 8'd1) : a16[15:8];
  wire [7:0] a_lo_mag = a_lo_sign ? (~a16[7:0]  + 8'd1) : a16[7:0];
  wire [7:0] b_mag    = b_sign    ? (~b8         + 8'd1) : b8;

  // Product signs (XOR)
  wire p_hi_neg = a_hi_sign ^ b_sign;
  wire p_lo_neg = a_lo_sign ^ b_sign;

  // ----------------------------------------------------------------
  // S1 registers: pack for DSP
  // ----------------------------------------------------------------
  reg [26:0] dsp_a_s1;
  reg [17:0] dsp_b_s1;
  reg        p_hi_neg_s1, p_lo_neg_s1;

  always @(posedge clk) begin
    dsp_a_s1    <= {3'b000, a_hi_mag, 8'b0000_0000, a_lo_mag};
    dsp_b_s1    <= {10'b0, b_mag};
    p_hi_neg_s1 <= p_hi_neg;
    p_lo_neg_s1 <= p_lo_neg;
  end

  // ----------------------------------------------------------------
  // DSP: combinational 27x18 unsigned multiply
  // ----------------------------------------------------------------
  wire [44:0] product45;

  (* use_dsp = "yes" *)
  dsp_usage u_dsp (
    .clk    (clk),
    .a      (dsp_a_s1),
    .b      (dsp_b_s1),
    .product(product45)
  );

  // ----------------------------------------------------------------
  // Extract lane products from DSP output
  //   P_hi = product45[31:16]  (magnitude of a_hi * b)
  //   P_lo = product45[15:0]   (magnitude of a_lo * b)
  // ----------------------------------------------------------------

  generate
    if (MUL_LAT == 1) begin : gen_lat1
      // No extra register; output directly from DSP + sign correction
      wire [15:0] mag_hi = product45[31:16];
      wire [15:0] mag_lo = product45[15:0];

      // Sign-extend magnitude to 32 bits, negate if needed
      wire [31:0] sext_hi = {16'd0, mag_hi};
      wire [31:0] sext_lo = {16'd0, mag_lo};

      assign prod_hi = p_hi_neg_s1 ? (~sext_hi + 32'd1) : sext_hi;
      assign prod_lo = p_lo_neg_s1 ? (~sext_lo + 32'd1) : sext_lo;
    end else begin : gen_lat2
      // S2 register: capture product + signs
      reg [15:0] mag_hi_s2, mag_lo_s2;
      reg        p_hi_neg_s2, p_lo_neg_s2;

      always @(posedge clk) begin
        mag_hi_s2   <= product45[31:16];
        mag_lo_s2   <= product45[15:0];
        p_hi_neg_s2 <= p_hi_neg_s1;
        p_lo_neg_s2 <= p_lo_neg_s1;
      end

      wire [31:0] sext_hi = {16'd0, mag_hi_s2};
      wire [31:0] sext_lo = {16'd0, mag_lo_s2};

      assign prod_hi = p_hi_neg_s2 ? (~sext_hi + 32'd1) : sext_hi;
      assign prod_lo = p_lo_neg_s2 ? (~sext_lo + 32'd1) : sext_lo;
    end
  endgenerate

endmodule
`default_nettype wire
