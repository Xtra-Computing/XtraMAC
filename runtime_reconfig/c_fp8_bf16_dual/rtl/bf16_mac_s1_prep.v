`timescale 1ns/1ps
`default_nettype none
module bf16_mac_s1_prep (
    input  wire        clk,
    input  wire [31:0] a32,     // BF16 lanes {hi[31:16], lo[15:0]}
    input  wire [15:0] b16,     // shared BF16
    input  wire [31:0] c32,     // BF16 addends {hi, lo}

    // outputs consumed by S2 in top
    output reg  [26:0] man_a_packed,
    output reg  [17:0] man_b_packed,

    output reg  signed [8:0] exp_hi_s1,
    output reg  signed [8:0] exp_lo_s1,
    output reg               sign_hi_s1,
    output reg               sign_lo_s1,

    output reg a_hi_nan_s1,
    output reg a_lo_nan_s1,
    output reg b_nan_s1,
    output reg a_hi_inf_s1,
    output reg a_lo_inf_s1,
    output reg b_inf_s1,
    output reg a_hi_zero_s1,
    output reg a_lo_zero_s1,
    output reg b_zero_s1,

    output reg [15:0] c_lo_s1,
    output reg [15:0] c_hi_s1
);
  localparam [7:0]  BF16_BIAS = 8'd127;

  // Power-up clean (optional, FPGA-friendly)
  initial begin
    man_a_packed = 27'd0;
    man_b_packed = 18'd0;

    exp_hi_s1=9'sd0; exp_lo_s1=9'sd0;
    sign_hi_s1=1'b0; sign_lo_s1=1'b0;

    a_hi_nan_s1=1'b0; a_lo_nan_s1=1'b0; b_nan_s1=1'b0;
    a_hi_inf_s1=1'b0; a_lo_inf_s1=1'b0; b_inf_s1=1'b0;
    a_hi_zero_s1=1'b0; a_lo_zero_s1=1'b0; b_zero_s1=1'b0;

    c_lo_s1=16'h0000; c_hi_s1=16'h0000;
  end

  // --------------------------
  // S1: BF16×BF16 prenorm + align C
  // --------------------------
  always @(posedge clk) begin
    // signs (per lane) = XOR
    sign_hi_s1 <= a32[31] ^ b16[15];
    sign_lo_s1 <= a32[15] ^ b16[15];

    // exponents (finite path); signed to catch negatives (underflow) & big positives
    exp_hi_s1 <= {1'b0, a32[30:23]} + {1'b0, b16[14:7]} - {1'b0, BF16_BIAS};
    exp_lo_s1 <= {1'b0, a32[14:7]}  + {1'b0, b16[14:7]} - {1'b0, BF16_BIAS};

    // classify A(hi/lo)
    a_hi_nan_s1  <= (a32[30:23]==8'hFF) && (a32[22:16]!=7'd0);
    a_hi_inf_s1  <= (a32[30:23]==8'hFF) && (a32[22:16]==7'd0);
    a_hi_zero_s1 <= (a32[30:23]==8'd0); // FTZ

    a_lo_nan_s1  <= (a32[14:7]==8'hFF) && (a32[6:0]!=7'd0);
    a_lo_inf_s1  <= (a32[14:7]==8'hFF) && (a32[6:0]==7'd0);
    a_lo_zero_s1 <= (a32[14:7]==8'd0); // FTZ

    // classify shared B
    b_nan_s1     <= (b16[14:7]==8'hFF) && (b16[6:0]!=7'd0);
    b_inf_s1     <= (b16[14:7]==8'hFF) && (b16[6:0]==7'd0);
    b_zero_s1    <= (b16[14:7]==8'd0); // FTZ

    // pack mantissas with hidden-1 (finite path only; specials will bypass)
    man_a_packed <= {3'b0, 1'b1, a32[22:16], 8'd0, 1'b1, a32[6:0]};
    man_b_packed <= {10'b0, 1'b1, b16[6:0]};

    // align C to S2 pipeline boundary (carried to top S2 regs)
    c_lo_s1 <= c32[15:0];
    c_hi_s1 <= c32[31:16];
  end
endmodule
`default_nettype wire
