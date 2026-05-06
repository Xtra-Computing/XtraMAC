`timescale 1ns/1ps
`default_nettype none

////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_fp4e2m1_bf16_mac
//   - Generates BF16 reference results via single-precision math + RN-even
////////////////////////////////////////////////////////////////////////////////
module tb_fp4e2m1_bf16_mac;
  localparam integer LAT        = 4;
  localparam integer N          = 40;
  localparam integer DUMMY_CLKS = 6;

  reg         clk;
  reg  [7:0]  a_fp4;
  reg  [15:0] b_bf16;
  reg  [31:0] c_bf16;
  wire [31:0] result;

  fp4e2m1_bf16_mac dut (
      .clk    (clk),
      .a_fp4  (a_fp4),
      .b_bf16 (b_bf16),
      .c_bf16 (c_bf16),
      .result (result)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  localparam [15:0] BF16_QNAN = 16'h7FC0;
  localparam [15:0] BF16_PINF = 16'h7F80;
  localparam [15:0] BF16_NINF = 16'hFF80;
  localparam [15:0] BF16_PZER = 16'h0000;
  localparam [15:0] BF16_NZER = 16'h8000;

  //------------------------------------------
  // FP4(E2M1) -> BF16 helper (matches RTL)
  //------------------------------------------
  function automatic [15:0] fp4e2m1_to_bf16;
    input [3:0] lane;
    reg sign;
    reg [1:0] exp2;
    reg frac1;
    reg [7:0] exp_bf;
    reg [6:0] frac_bf;
    begin
      sign  = lane[3];
      exp2  = lane[2:1];
      frac1 = lane[0];
      if ((exp2 == 2'b11) && (frac1 == 1'b1)) begin
        fp4e2m1_to_bf16 = BF16_QNAN;
      end else if ((exp2 == 2'b11) && (frac1 == 1'b0)) begin
        fp4e2m1_to_bf16 = {sign, 8'hFF, 7'd0};
      end else if ((exp2 == 2'b00) && (frac1 == 1'b0)) begin
        fp4e2m1_to_bf16 = {sign, 15'd0};
      end else if (exp2 == 2'b00) begin
        exp_bf  = 8'd126;              // exponent = -1
        frac_bf = 7'd0;
        fp4e2m1_to_bf16 = {sign, exp_bf, frac_bf};
      end else begin
        exp_bf  = 8'd126 + {6'd0, exp2};
        frac_bf = frac1 ? 7'b1000_000 : 7'd0;
        fp4e2m1_to_bf16 = {sign, exp_bf, frac_bf};
      end
    end
  endfunction

  function automatic [31:0] pack2_16;
    input [15:0] hi;
    input [15:0] lo;
    begin
      pack2_16 = {hi, lo};
    end
  endfunction

  //------------------------------------------
  // BF16 helpers via single-precision carrier
  //------------------------------------------
  function automatic [31:0] bf16_to_f32_bits;
    input [15:0] bf16;
    begin
      bf16_to_f32_bits = {bf16, 16'd0};
    end
  endfunction

  function automatic [15:0] round_f32_to_bf16;
    input [31:0] fbits;
    reg [15:0] upper;
    reg guard, round_bit, sticky;
    reg round_up;
    reg [16:0] rounded_ext;
    begin
      if ((fbits[30:23] == 8'hFF) && (fbits[22:0] != 0)) begin
        round_f32_to_bf16 = BF16_QNAN;
      end else begin
        upper    = fbits[31:16];
        guard    = fbits[15];
        round_bit= fbits[14];
        sticky   = |fbits[13:0];
        round_up = guard & (round_bit | sticky | upper[0]);
        rounded_ext = {1'b0, upper} + (round_up ? 17'h1 : 17'h0);
        if (rounded_ext[16])
          round_f32_to_bf16 = {fbits[31], 8'hFF, 7'd0};
        else
          round_f32_to_bf16 = rounded_ext[15:0];
      end
    end
  endfunction

  function automatic [15:0] bf16_mul_model;
    input [15:0] a;
    input [15:0] b;
    shortreal ra, rb, rprod;
    begin
      ra     = $bitstoshortreal(bf16_to_f32_bits(a));
      rb     = $bitstoshortreal(bf16_to_f32_bits(b));
      rprod  = ra * rb;
      bf16_mul_model = round_f32_to_bf16($shortrealtobits(rprod));
    end
  endfunction

  function automatic [15:0] bf16_add_model;
    input [15:0] a;
    input [15:0] b;
    shortreal ra, rb, rsum;
    begin
      ra    = $bitstoshortreal(bf16_to_f32_bits(a));
      rb    = $bitstoshortreal(bf16_to_f32_bits(b));
      rsum  = ra + rb;
      bf16_add_model = round_f32_to_bf16($shortrealtobits(rsum));
    end
  endfunction

  function automatic [15:0] lane_mac_bf16_expect;
    input [3:0]  a_lane;
    input [15:0] b_lane;
    input [15:0] c_lane;
    reg   [15:0] a_bf16_lane;
    reg   [15:0] prod_lane;
    begin
      a_bf16_lane = fp4e2m1_to_bf16(a_lane);
      prod_lane   = bf16_mul_model(a_bf16_lane, b_lane);
      lane_mac_bf16_expect = bf16_add_model(prod_lane, c_lane);
    end
  endfunction

  reg [7:0]  avec [0:N-1];
  reg [15:0] bvec [0:N-1];
  reg [31:0] cvec [0:N-1];
  reg [31:0] yexp [0:N-1];

  reg [3:0]  fp4_values [0:7];
  reg [15:0] b_choices  [0:6];
  reg [15:0] c_choices  [0:7];

  integer idx;
  integer sel_a0;
  integer sel_a1;
  integer sel_b;
  integer sel_c;

  initial begin
    fp4_values[0] = 4'b0000;
    fp4_values[1] = 4'b0001;
    fp4_values[2] = 4'b0010;
    fp4_values[3] = 4'b0101;
    fp4_values[4] = 4'b0110;
    fp4_values[5] = 4'b1010;
    fp4_values[6] = 4'b1100;
    fp4_values[7] = 4'b1111;

    b_choices[0] = BF16_PZER;
    b_choices[1] = 16'h3F80;   // +1.0
    b_choices[2] = 16'hBF80;   // -1.0
    b_choices[3] = 16'h4000;   // +2.0
    b_choices[4] = 16'hC000;   // -2.0
    b_choices[5] = BF16_PINF;
    b_choices[6] = BF16_QNAN;

    c_choices[0] = BF16_PZER;
    c_choices[1] = BF16_NZER;
    c_choices[2] = 16'h3F00;   // +0.5
    c_choices[3] = 16'hBF00;   // -0.5
    c_choices[4] = 16'h3FC0;   // +1.5
    c_choices[5] = 16'hBFC0;   // -1.5
    c_choices[6] = BF16_PINF;
    c_choices[7] = BF16_QNAN;

    for (idx = 0; idx < N; idx = idx + 1) begin
      sel_a0 = idx % 8;
      sel_a1 = (idx + 5) % 8;
      sel_b  = idx % 7;
      sel_c  = (idx + 2) % 8;

      avec[idx] = {fp4_values[sel_a1], fp4_values[sel_a0]};
      bvec[idx] = b_choices[sel_b];
      cvec[idx] = pack2_16(c_choices[(sel_c + 3) % 8], c_choices[sel_c]);
    end

    // Directed overrides for specials
    avec[0] = {4'b1110, 4'b0001};
    bvec[0] = BF16_PINF;
    cvec[0] = pack2_16(BF16_PINF, BF16_PZER);

    avec[1] = {4'b0111, 4'b1111};
    bvec[1] = 16'h3F80;
    cvec[1] = pack2_16(BF16_NZER, BF16_QNAN);

    avec[2] = {4'b0100, 4'b0010};
    bvec[2] = 16'hBF80;
    cvec[2] = pack2_16(16'h3F00, 16'hBF00);

    for (idx = 0; idx < N; idx = idx + 1) begin
      yexp[idx] = {
          lane_mac_bf16_expect(avec[idx][7:4], bvec[idx], cvec[idx][31:16]),
          lane_mac_bf16_expect(avec[idx][3:0], bvec[idx], cvec[idx][15:0])
      };
    end
  end

  integer errors;
  integer i;
  integer idx_chk;

  initial begin
    errors = 0;
    a_fp4  = 8'h00;
    b_bf16 = BF16_PZER;
    c_bf16 = 32'h0000_0000;

    $display("\n--- FP4(E2M1) x BF16 MAC (LAT=%0d, Vectors=%0d) ---", LAT, N);
    $display("Priming pipeline with %0d dummy clocks...", DUMMY_CLKS);
    repeat (DUMMY_CLKS) @(posedge clk);

    for (i = 0; i < N + LAT; i = i + 1) begin
      if (i < N) begin
        a_fp4  <= avec[i];
        b_bf16 <= bvec[i];
        c_bf16 <= cvec[i];
      end else begin
        a_fp4  <= 8'h00;
        b_bf16 <= BF16_PZER;
        c_bf16 <= 32'h0000_0000;
      end

      @(posedge clk);

      if (i >= LAT) begin
        idx_chk = i - LAT;
        if (result !== yexp[idx_chk]) begin
          errors = errors + 1;
          $display("Mismatch idx %0d: got %h expected %h (a=%02h b=%04h c=%08h)",
                   idx_chk, result, yexp[idx_chk], avec[idx_chk], bvec[idx_chk], cvec[idx_chk]);
        end
      end
    end

    if (errors == 0)
      $display("PASS: %0d stimulus vectors matched expectations.", N);
    else
      $display("FAIL: %0d mismatches observed over %0d vectors.", errors, N);

    $finish;
  end

endmodule

`default_nettype wire
