`timescale 1ns/1ps
`default_nettype none

// =============================================================
// fp8_mac_s1_prep
//   Stage-1 preparation for FP8e4m3 × FP8e4m3 products sharing a DSP
//   Packs mantissas, registers per-lane signs/exponents/classification,
//   and forwards BF16 addend tiles.
// =============================================================
module fp8_mac_s1_prep (
    input  wire        clk,
    input  wire [31:0] a32,    // lower two bytes carry FP8 lanes a1/a2
    input  wire [15:0] b16,    // two FP8 lanes b1/b2
    input  wire [63:0] c64,    // four BF16 addends {c22,c21,c12,c11}

    output reg [26:0] a_pack,
    output reg [17:0] b_pack,

    output reg        s11_s1,
    output reg        s12_s1,
    output reg        s21_s1,
    output reg        s22_s1,

    output reg signed [6:0] e11_s1,
    output reg signed [6:0] e12_s1,
    output reg signed [6:0] e21_s1,
    output reg signed [6:0] e22_s1,

    output reg a1_nan_s1,
    output reg a2_nan_s1,
    output reg b1_nan_s1,
    output reg b2_nan_s1,
    output reg a1_zero_s1,
    output reg a2_zero_s1,
    output reg b1_zero_s1,
    output reg b2_zero_s1,

    output reg [15:0] c11_s1,
    output reg [15:0] c12_s1,
    output reg [15:0] c21_s1,
    output reg [15:0] c22_s1
);
  wire [7:0] a1 = a32[7:0];
  wire [7:0] a2 = a32[15:8];
  wire [7:0] b1 = b16[7:0];
  wire [7:0] b2 = b16[15:8];

  wire sa1 = a1[7];
  wire sa2 = a2[7];
  wire sb1 = b1[7];
  wire sb2 = b2[7];

  wire [3:0] ea1 = a1[6:3];
  wire [3:0] ea2 = a2[6:3];
  wire [3:0] eb1 = b1[6:3];
  wire [3:0] eb2 = b2[6:3];

  wire [2:0] fa1 = a1[2:0];
  wire [2:0] fa2 = a2[2:0];
  wire [2:0] fb1 = b1[2:0];
  wire [2:0] fb2 = b2[2:0];

  wire a1_nan_w  = (ea1 == 4'hF);
  wire a2_nan_w  = (ea2 == 4'hF);
  wire b1_nan_w  = (eb1 == 4'hF);
  wire b2_nan_w  = (eb2 == 4'hF);

  wire a1_zero_w = (ea1 == 4'd0);
  wire a2_zero_w = (ea2 == 4'd0);
  wire b1_zero_w = (eb1 == 4'd0);
  wire b2_zero_w = (eb2 == 4'd0);

  wire [3:0] Ma1 = a1_zero_w ? 4'd0 : {1'b1, fa1};
  wire [3:0] Ma2 = a2_zero_w ? 4'd0 : {1'b1, fa2};
  wire [3:0] Mb1 = b1_zero_w ? 4'd0 : {1'b1, fb1};
  wire [3:0] Mb2 = b2_zero_w ? 4'd0 : {1'b1, fb2};

  wire signed [6:0] e11_w = $signed({1'b0, ea1}) + $signed({1'b0, eb1}) - 7'sd7;
  wire signed [6:0] e12_w = $signed({1'b0, ea1}) + $signed({1'b0, eb2}) - 7'sd7;
  wire signed [6:0] e21_w = $signed({1'b0, ea2}) + $signed({1'b0, eb1}) - 7'sd7;
  wire signed [6:0] e22_w = $signed({1'b0, ea2}) + $signed({1'b0, eb2}) - 7'sd7;

  always @(posedge clk) begin
    a_pack <= {7'b0, Ma2, 12'b0, Ma1};
    b_pack <= {6'b0, Mb2, 4'b0, Mb1};

    s11_s1 <= sa1 ^ sb1;
    s12_s1 <= sa1 ^ sb2;
    s21_s1 <= sa2 ^ sb1;
    s22_s1 <= sa2 ^ sb2;

    e11_s1 <= e11_w;
    e12_s1 <= e12_w;
    e21_s1 <= e21_w;
    e22_s1 <= e22_w;

    a1_nan_s1  <= a1_nan_w;
    a2_nan_s1  <= a2_nan_w;
    b1_nan_s1  <= b1_nan_w;
    b2_nan_s1  <= b2_nan_w;
    a1_zero_s1 <= a1_zero_w;
    a2_zero_s1 <= a2_zero_w;
    b1_zero_s1 <= b1_zero_w;
    b2_zero_s1 <= b2_zero_w;

    c11_s1 <= c64[15:0];
    c12_s1 <= c64[31:16];
    c21_s1 <= c64[47:32];
    c22_s1 <= c64[63:48];
  end
endmodule

`default_nettype wire
