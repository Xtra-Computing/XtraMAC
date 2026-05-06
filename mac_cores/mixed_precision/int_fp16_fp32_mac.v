`timescale 1ns/1ps
`default_nettype none
// =============================================================
// int_fp16_fp32_mac : INT(2..8) x FP16 + FP32 -> FP32 (2-lane)
//   - Decodes each INT lane to a 7-bit normalized mantissa
//     (with leading 1 at bit 6) + 4-bit exponent
//   - DSP-packs two lanes into one 27x18 DSP48E2:
//       A[26:0] = {2'b0, mant_hi7, 11'b0, mant_lo7}
//       B[17:0] = {7'b0, man_b_eff(11)}
//     Per-lane product occupies 18 bits.
//   - Each lane composes an FP32 product, then goes through fp32_add
//     with a corresponding FP32 addend from c64.
//   - Total latency = MUL_LAT + MID_STAGES + ADD_LAT
//       (2,0,2) -> 4, (2,0,3) -> 5, (2,1,3) -> 6
//   - II = 1
// =============================================================
module int_fp16_fp32_mac #(
    parameter INT_WIDTH  = 8,   // 2..8
    parameter MUL_LAT    = 2,   // 1 or 2
    parameter MID_STAGES = 0,
    parameter ADD_LAT    = 2    // 2 or 3
)(
    input  wire                    clk,
    input  wire [2*INT_WIDTH-1:0]  a_int,   // packed INT {hi, lo}
    input  wire [15:0]             b16,     // shared FP16 operand
    input  wire [63:0]             c64,     // FP32 addends {hi, lo}
    output wire [63:0]             result   // FP32 results {hi, lo}
);
  localparam [31:0] QNAN32 = 32'h7FC0_0000;

  // ----------------------------------------------------------------
  // INT -> normalized 7-bit mantissa decode (reused from int_fp16_mac_2lane)
  //   Returns {sign, zero, exp_u[3:0], mant7[6:0]}
  // ----------------------------------------------------------------
  function automatic [12:0] int_decode;
    input [7:0] x;
    reg        sign;
    reg [7:0]  mag;
    reg        zero;
    reg [3:0]  exp_u;
    reg [6:0]  mant7;
    integer    k;
    reg [13:0] numer, quotient, remainder;
    reg        round_up;
    reg [7:0]  mant_ext;
    begin
      sign = x[7];
      mag  = sign ? (~x + 8'd1) : x;
      zero = (mag == 8'd0);
      exp_u = 4'd0;
      mant7 = 7'd0;

      if (!zero) begin
        casex (mag)
          8'b1???????: k = 7;
          8'b01??????: k = 6;
          8'b001?????: k = 5;
          8'b0001????: k = 4;
          8'b00001???: k = 3;
          8'b000001??: k = 2;
          8'b0000001?: k = 1;
          default:     k = 0;
        endcase
        exp_u = k[3:0];

        numer = {mag, 6'd0};
        if (k == 0) begin
          quotient  = numer;
          remainder = 14'd0;
        end else begin
          quotient  = numer >> k;
          remainder = numer & ((14'd1 << k) - 14'd1);
        end
        if (quotient > 14'd127)
          quotient = 14'd127;

        if (k == 0)
          round_up = 1'b0;
        else
          round_up = (remainder > (14'd1 << (k-1))) ||
                     ((remainder == (14'd1 << (k-1))) && quotient[0]);

        mant_ext = {1'b0, quotient[6:0]} + {7'd0, round_up};
        if (mant_ext[7]) begin
          mant_ext = {1'b0, mant_ext[7:1]};
          if (exp_u != 4'd7)
            exp_u = exp_u + 4'd1;
        end
        if (~mant_ext[6])
          mant_ext[6] = 1'b1;
        mant7 = mant_ext[6:0];
      end

      int_decode = {sign, zero, exp_u, mant7};
    end
  endfunction

  // Sign-extend narrow int to 8 bits
  wire [7:0] a_lo_ext = {{(8-INT_WIDTH){a_int[INT_WIDTH-1]}},   a_int[INT_WIDTH-1:0]};
  wire [7:0] a_hi_ext = {{(8-INT_WIDTH){a_int[2*INT_WIDTH-1]}}, a_int[2*INT_WIDTH-1:INT_WIDTH]};

  wire [12:0] lo_dec = int_decode(a_lo_ext);
  wire [12:0] hi_dec = int_decode(a_hi_ext);

  wire        a_lo_sign = lo_dec[12];
  wire        a_lo_zero = lo_dec[11];
  wire [3:0]  a_lo_exp  = lo_dec[10:7];
  wire [6:0]  mant_lo7  = lo_dec[6:0];

  wire        a_hi_sign = hi_dec[12];
  wire        a_hi_zero = hi_dec[11];
  wire [3:0]  a_hi_exp  = hi_dec[10:7];
  wire [6:0]  mant_hi7  = hi_dec[6:0];

  // ----------------------------------------------------------------
  // FP16 B classification
  // ----------------------------------------------------------------
  wire        b_sign   = b16[15];
  wire [4:0]  b_exp    = b16[14:10];
  wire [9:0]  b_frac   = b16[9:0];
  wire        b_is_nan = (b_exp == 5'h1F) && (b_frac != 10'd0);
  wire        b_is_inf = (b_exp == 5'h1F) && (b_frac == 10'd0);
  wire        b_is_zero= (b_exp == 5'd0);
  wire [10:0] man_b_eff = b_is_zero ? 11'd0 : {1'b1, b_frac};
  wire signed [11:0] b_unbias = $signed({1'b0, b_exp}) - 12'sd15;

  // Per-lane unbiased exponent (INT has exp_u range 0..7, no INT bias)
  wire signed [11:0] exp_lo_unbias = (a_lo_zero || b_is_zero) ? 12'sd0
                                   : ($signed({8'd0, a_lo_exp}) + b_unbias);
  wire signed [11:0] exp_hi_unbias = (a_hi_zero || b_is_zero) ? 12'sd0
                                   : ($signed({8'd0, a_hi_exp}) + b_unbias);

  // ----------------------------------------------------------------
  // FP32 lane compose function (22-bit mantissa product)
  //   Input mul22 = {18-bit INT x FP16 mantissa product, 4'b0} (paper
  //   convention). Always fits in FP32 normal range for INT*FP16.
  // ----------------------------------------------------------------
  function automatic [31:0] lane_fp32_mul_result;
    input [21:0]        mul22;
    input signed [11:0] exp_unbiased_in;
    input               sign;
    input               a_is_zero;
    input               b_is_zero_in;
    input               b_is_nan_in;
    input               b_is_inf_in;
    reg                 leading2;
    reg [21:0]          norm22;
    reg signed  [11:0]  exp_biased;
    begin
      if (b_is_nan_in || (b_is_inf_in && a_is_zero)) begin
        lane_fp32_mul_result = QNAN32;
      end else if (b_is_inf_in) begin
        lane_fp32_mul_result = {sign, 8'hFF, 23'd0};
      end else if (a_is_zero || b_is_zero_in) begin
        lane_fp32_mul_result = {sign, 31'd0};
      end else begin
        leading2   = mul22[21];
        norm22     = leading2 ? (mul22 >> 1) : mul22;
        exp_biased = exp_unbiased_in + (leading2 ? 12'sd128 : 12'sd127);
        lane_fp32_mul_result = {sign, exp_biased[7:0], norm22[19:0], 3'd0};
      end
    end
  endfunction

  // ----------------------------------------------------------------
  // DSP-packed 2-lane multiply
  //   MUL_LAT = 1 : S1 registers + combinational DSP + inline compose
  //   MUL_LAT = 2 : S1 registers + DSP + S2 capture + compose
  // ----------------------------------------------------------------
  generate
  if (MUL_LAT == 1) begin : gen_mul1
    reg [26:0] man_a_packed_s1;
    reg [17:0] man_b_packed_s1;
    reg signed [11:0] exp_lo_s1, exp_hi_s1;
    reg        sign_lo_s1, sign_hi_s1;
    reg        a_lo_zero_s1, a_hi_zero_s1;
    reg        b_zero_s1, b_nan_s1, b_inf_s1;
    reg [31:0] c_lo_s1, c_hi_s1;

    always @(posedge clk) begin
      man_a_packed_s1 <= {2'b00, mant_hi7, 11'd0, mant_lo7};
      man_b_packed_s1 <= {7'd0, man_b_eff};
      exp_lo_s1       <= exp_lo_unbias;
      exp_hi_s1       <= exp_hi_unbias;
      sign_lo_s1      <= a_lo_sign ^ b_sign;
      sign_hi_s1      <= a_hi_sign ^ b_sign;
      a_lo_zero_s1    <= a_lo_zero;
      a_hi_zero_s1    <= a_hi_zero;
      b_zero_s1       <= b_is_zero;
      b_nan_s1        <= b_is_nan;
      b_inf_s1        <= b_is_inf;
      c_lo_s1         <= c64[31:0];
      c_hi_s1         <= c64[63:32];
    end

    wire [44:0] product45;
    dsp_usage u_dsp (.clk(clk), .a(man_a_packed_s1), .b(man_b_packed_s1), .product(product45));

    wire [21:0] prod_lo22 = {product45[17:0], 4'd0};
    wire [21:0] prod_hi22 = {product45[35:18], 4'd0};

    wire [31:0] prod_lo32 = lane_fp32_mul_result(
        prod_lo22, exp_lo_s1, sign_lo_s1, a_lo_zero_s1, b_zero_s1, b_nan_s1, b_inf_s1);
    wire [31:0] prod_hi32 = lane_fp32_mul_result(
        prod_hi22, exp_hi_s1, sign_hi_s1, a_hi_zero_s1, b_zero_s1, b_nan_s1, b_inf_s1);

    // Mid-stage pipeline
    reg [31:0] plo_mid [0:MID_STAGES];
    reg [31:0] phi_mid [0:MID_STAGES];
    reg [31:0] clo_mid [0:MID_STAGES];
    reg [31:0] chi_mid [0:MID_STAGES];
    always @(*) begin
      plo_mid[0] = prod_lo32; phi_mid[0] = prod_hi32;
      clo_mid[0] = c_lo_s1;   chi_mid[0] = c_hi_s1;
    end
    genvar gm;
    for (gm = 1; gm <= MID_STAGES; gm = gm + 1) begin : gen_mid
      always @(posedge clk) begin
        plo_mid[gm] <= plo_mid[gm-1]; phi_mid[gm] <= phi_mid[gm-1];
        clo_mid[gm] <= clo_mid[gm-1]; chi_mid[gm] <= chi_mid[gm-1];
      end
    end

    wire [31:0] sum_lo32, sum_hi32;
    fp32_add #(.LATENCY(ADD_LAT), .SATURATE_ON_MAX(1'b0), .INF_CANCELLATION_TO_NAN(1'b0))
      u_add_lo (.clk(clk), .x32(plo_mid[MID_STAGES]), .y32(clo_mid[MID_STAGES]), .result(sum_lo32));
    fp32_add #(.LATENCY(ADD_LAT), .SATURATE_ON_MAX(1'b0), .INF_CANCELLATION_TO_NAN(1'b0))
      u_add_hi (.clk(clk), .x32(phi_mid[MID_STAGES]), .y32(chi_mid[MID_STAGES]), .result(sum_hi32));

    assign result = {sum_hi32, sum_lo32};

  end else begin : gen_mul2
    reg [26:0] man_a_packed_s1;
    reg [17:0] man_b_packed_s1;
    reg signed [11:0] exp_lo_s1, exp_hi_s1;
    reg        sign_lo_s1, sign_hi_s1;
    reg        a_lo_zero_s1, a_hi_zero_s1;
    reg        b_zero_s1, b_nan_s1, b_inf_s1;
    reg [31:0] c_lo_s1, c_hi_s1;

    always @(posedge clk) begin
      man_a_packed_s1 <= {2'b00, mant_hi7, 11'd0, mant_lo7};
      man_b_packed_s1 <= {7'd0, man_b_eff};
      exp_lo_s1       <= exp_lo_unbias;
      exp_hi_s1       <= exp_hi_unbias;
      sign_lo_s1      <= a_lo_sign ^ b_sign;
      sign_hi_s1      <= a_hi_sign ^ b_sign;
      a_lo_zero_s1    <= a_lo_zero;
      a_hi_zero_s1    <= a_hi_zero;
      b_zero_s1       <= b_is_zero;
      b_nan_s1        <= b_is_nan;
      b_inf_s1        <= b_is_inf;
      c_lo_s1         <= c64[31:0];
      c_hi_s1         <= c64[63:32];
    end

    wire [44:0] product45;
    dsp_usage u_dsp (.clk(clk), .a(man_a_packed_s1), .b(man_b_packed_s1), .product(product45));

    reg [44:0] prod_s2;
    reg signed [11:0] exp_lo_s2, exp_hi_s2;
    reg        sign_lo_s2, sign_hi_s2;
    reg        a_lo_zero_s2, a_hi_zero_s2;
    reg        b_zero_s2, b_nan_s2, b_inf_s2;
    reg [31:0] c_lo_s2, c_hi_s2;

    always @(posedge clk) begin
      prod_s2      <= product45;
      exp_lo_s2    <= exp_lo_s1;     exp_hi_s2    <= exp_hi_s1;
      sign_lo_s2   <= sign_lo_s1;    sign_hi_s2   <= sign_hi_s1;
      a_lo_zero_s2 <= a_lo_zero_s1;  a_hi_zero_s2 <= a_hi_zero_s1;
      b_zero_s2    <= b_zero_s1;     b_nan_s2     <= b_nan_s1;    b_inf_s2 <= b_inf_s1;
      c_lo_s2      <= c_lo_s1;       c_hi_s2      <= c_hi_s1;
    end

    wire [21:0] prod_lo22 = {prod_s2[17:0], 4'd0};
    wire [21:0] prod_hi22 = {prod_s2[35:18], 4'd0};

    wire [31:0] prod_lo32 = lane_fp32_mul_result(
        prod_lo22, exp_lo_s2, sign_lo_s2, a_lo_zero_s2, b_zero_s2, b_nan_s2, b_inf_s2);
    wire [31:0] prod_hi32 = lane_fp32_mul_result(
        prod_hi22, exp_hi_s2, sign_hi_s2, a_hi_zero_s2, b_zero_s2, b_nan_s2, b_inf_s2);

    reg [31:0] plo_mid [0:MID_STAGES];
    reg [31:0] phi_mid [0:MID_STAGES];
    reg [31:0] clo_mid [0:MID_STAGES];
    reg [31:0] chi_mid [0:MID_STAGES];
    always @(*) begin
      plo_mid[0] = prod_lo32; phi_mid[0] = prod_hi32;
      clo_mid[0] = c_lo_s2;   chi_mid[0] = c_hi_s2;
    end
    genvar gm;
    for (gm = 1; gm <= MID_STAGES; gm = gm + 1) begin : gen_mid
      always @(posedge clk) begin
        plo_mid[gm] <= plo_mid[gm-1]; phi_mid[gm] <= phi_mid[gm-1];
        clo_mid[gm] <= clo_mid[gm-1]; chi_mid[gm] <= chi_mid[gm-1];
      end
    end

    wire [31:0] sum_lo32, sum_hi32;
    fp32_add #(.LATENCY(ADD_LAT), .SATURATE_ON_MAX(1'b0), .INF_CANCELLATION_TO_NAN(1'b0))
      u_add_lo (.clk(clk), .x32(plo_mid[MID_STAGES]), .y32(clo_mid[MID_STAGES]), .result(sum_lo32));
    fp32_add #(.LATENCY(ADD_LAT), .SATURATE_ON_MAX(1'b0), .INF_CANCELLATION_TO_NAN(1'b0))
      u_add_hi (.clk(clk), .x32(phi_mid[MID_STAGES]), .y32(chi_mid[MID_STAGES]), .result(sum_hi32));

    assign result = {sum_hi32, sum_lo32};
  end
  endgenerate

endmodule
`default_nettype wire
