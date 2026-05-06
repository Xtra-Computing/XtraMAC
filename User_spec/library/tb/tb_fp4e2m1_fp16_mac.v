`timescale 1ns/1ps
`default_nettype none

`include "../sources_1/new/fp16_mac_util.vh"

////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_fp4e2m1_fp16_mac
//   - Exercises fp4e2m1_fp16_mac over a mix of finite and special cases
//   - Golden model uses fp16_mul/fp16_add helpers from fp16_mac_util.vh
////////////////////////////////////////////////////////////////////////////////
module tb_fp4e2m1_fp16_mac;
  localparam integer LAT        = 4;
  localparam integer N          = 40;
  localparam integer DUMMY_CLKS = 6;

  reg         clk;
  reg  [7:0]  a_fp4;
  reg  [15:0] b_fp16;
  reg  [31:0] c_fp16;
  wire [31:0] result;

  fp4e2m1_fp16_mac dut (
      .clk    (clk),
      .a_fp4  (a_fp4),
      .b_fp16 (b_fp16),
      .c_fp16 (c_fp16),
      .result (result)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  localparam [15:0] FP16_PINF = 16'h7C00;
  localparam [15:0] FP16_NINF = 16'hFC00;
  localparam [15:0] FP16_PZER = 16'h0000;
  localparam [15:0] FP16_NZER = 16'h8000;

  //-------------------------------
  // Helper: FP4(E2M1) -> FP16 bits
  //-------------------------------
  function automatic [15:0] fp4e2m1_to_fp16;
    input [3:0] lane;
    reg sign;
    reg [1:0] exp2;
    reg frac1;
    reg [4:0] exp16;
    reg [9:0] frac16;
    begin
      sign  = lane[3];
      exp2  = lane[2:1];
      frac1 = lane[0];

      if (exp2 == 2'b11) begin
        fp4e2m1_to_fp16 = (frac1 == 1'b0) ? {sign, 5'h1F, 10'd0} : FP16_QNAN;
      end else if (exp2 == 2'b00) begin
        if (frac1 == 1'b0) begin
          fp4e2m1_to_fp16 = {sign, 15'd0};
        end else begin
          exp16  = 5'd14;               // exponent = -1
          frac16 = 10'd0;
          fp4e2m1_to_fp16 = {sign, exp16, frac16};
        end
      end else begin
        exp16  = 5'd14 + {3'd0, exp2};  // exponent = exp2-1
        frac16 = frac1 ? 10'b1000_0000_00 : 10'd0;
        fp4e2m1_to_fp16 = {sign, exp16, frac16};
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

  function automatic [15:0] lane_mac_fp16_expect;
    input [3:0]  a_lane;
    input [15:0] b_lane;
    input [15:0] c_lane;
    reg   [15:0] a_fp16_lane;
    reg   [15:0] prod_lane;
    begin
      a_fp16_lane = fp4e2m1_to_fp16(a_lane);
      prod_lane   = fp16_mul(a_fp16_lane, b_lane);
      lane_mac_fp16_expect = fp16_add(prod_lane, c_lane);
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
    fp4_values[0] = 4'b0000;  // +0
    fp4_values[1] = 4'b0001;  // denorm
    fp4_values[2] = 4'b0010;  // 0.5
    fp4_values[3] = 4'b0101;  // 1.5
    fp4_values[4] = 4'b0110;  // 2.0
    fp4_values[5] = 4'b1010;  // -0.5
    fp4_values[6] = 4'b1100;  // -1.0
    fp4_values[7] = 4'b1111;  // qNaN

    b_choices[0] = FP16_PZER;
    b_choices[1] = 16'h3C00;        // +1.0
    b_choices[2] = 16'hBC00;        // -1.0
    b_choices[3] = 16'h3555;        // +0.333
    b_choices[4] = 16'hC800;        // -256
    b_choices[5] = FP16_PINF;
    b_choices[6] = FP16_QNAN;

    c_choices[0] = FP16_PZER;
    c_choices[1] = FP16_NZER;
    c_choices[2] = 16'h3800;        // +0.5
    c_choices[3] = 16'hB800;        // -0.5
    c_choices[4] = 16'h3C00;        // +1.0
    c_choices[5] = 16'hBC00;        // -1.0
    c_choices[6] = FP16_PINF;
    c_choices[7] = FP16_QNAN;

    for (idx = 0; idx < N; idx = idx + 1) begin
      sel_a0 = idx % 8;
      sel_a1 = (idx + 3) % 8;
      sel_b  = idx % 7;
      sel_c  = idx % 8;

      avec[idx] = {fp4_values[sel_a1], fp4_values[sel_a0]};
      bvec[idx] = b_choices[sel_b];
      cvec[idx] = pack2_16(c_choices[(sel_c + 2) % 8], c_choices[sel_c]);
    end

    // Directed corner cases
    avec[0] = {4'b1110, 4'b0001};           // -Inf * denorm
    bvec[0] = FP16_PINF;
    cvec[0] = pack2_16(FP16_PINF, FP16_PZER);

    avec[1] = {4'b0111, 4'b1111};           // +Inf upper, NaN lower
    bvec[1] = 16'h3555;
    cvec[1] = pack2_16(FP16_NZER, FP16_QNAN);

    avec[2] = {4'b0100, 4'b0100};           // normal lanes
    bvec[2] = 16'hBC00;
    cvec[2] = pack2_16(16'h3C00, 16'hBC00);

    // Expected results
    for (idx = 0; idx < N; idx = idx + 1) begin
      yexp[idx] = {
          lane_mac_fp16_expect(avec[idx][7:4], bvec[idx], cvec[idx][31:16]),
          lane_mac_fp16_expect(avec[idx][3:0], bvec[idx], cvec[idx][15:0])
      };
    end
  end

  integer errors;
  integer i;
  integer idx_chk;

  initial begin
    errors = 0;
    a_fp4  = 8'h00;
    b_fp16 = FP16_PZER;
    c_fp16 = 32'h0000_0000;

    $display("\n--- FP4(E2M1) x FP16 MAC (LAT=%0d, Vectors=%0d) ---", LAT, N);
    $display("Priming pipeline with %0d dummy clocks...", DUMMY_CLKS);
    repeat (DUMMY_CLKS) @(posedge clk);

    for (i = 0; i < N + LAT; i = i + 1) begin
      if (i < N) begin
        a_fp4 <= avec[i];
        b_fp16 <= bvec[i];
        c_fp16 <= cvec[i];
      end else begin
        a_fp4 <= 8'h00;
        b_fp16 <= FP16_PZER;
        c_fp16 <= 32'h0000_0000;
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
