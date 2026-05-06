`timescale 1ns/1ps
`default_nettype none

module bf16_fp4_dual_mac_tb;
  localparam integer PIPE_LAT    = 4;
  localparam integer BF16_TESTS  = 4;
  localparam integer FP4_TESTS   = 4;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg        mode_fp4;
  reg [31:0] a_data;
  reg [15:0] b_bf16;
  reg [31:0] c_bf16;
  reg        input_valid;

  wire [31:0] dut_result;
  wire [31:0] ref_bf16_result;
  wire [31:0] ref_fp4_result;

  bf16_fp4_dual_mac dut (
    .clk     (clk),
    .mode_fp4(mode_fp4),
    .a_data  (a_data),
    .b_bf16  (b_bf16),
    .c_bf16  (c_bf16),
    .result  (dut_result)
  );

  bf16_mac ref_bf16 (
    .clk   (clk),
    .a32   (a_data),
    .b16   (b_bf16),
    .c32   (c_bf16),
    .result(ref_bf16_result)
  );

  function automatic [15:0] fp4_lane_to_bf16;
    input [3:0] lane;
    begin
      fp4_lane_to_bf16 = { lane[3], {lane[2:1], 6'b0}, lane[0], 6'b0 };
    end
  endfunction

  wire [31:0] a_fp4_as_bf16 = {
      fp4_lane_to_bf16(a_data[7:4]),
      fp4_lane_to_bf16(a_data[3:0])
  };

  bf16_mac ref_fp4 (
    .clk   (clk),
    .a32   (a_fp4_as_bf16),
    .b16   (b_bf16),
    .c32   (c_bf16),
    .result(ref_fp4_result)
  );

  reg [PIPE_LAT-1:0] valid_pipe;
  reg [PIPE_LAT-1:0] mode_pipe;
  integer cycle;
  integer errors;
  integer checks;

  reg [31:0] bf16_a_vec [0:BF16_TESTS-1];
  reg [15:0] bf16_b_vec [0:BF16_TESTS-1];
  reg [31:0] bf16_c_vec [0:BF16_TESTS-1];

  reg [7:0]  fp4_a_vec  [0:FP4_TESTS-1];
  reg [15:0] fp4_b_vec  [0:FP4_TESTS-1];
  reg [31:0] fp4_c_vec  [0:FP4_TESTS-1];

  localparam [3:0] FP4_POS1   = 4'b0010; // +1.0
  localparam [3:0] FP4_POS1P5 = 4'b0011; // +1.5
  localparam [3:0] FP4_POS2   = 4'b0100; // +2.0
  localparam [3:0] FP4_NEG1   = 4'b1010; // -1.0
  localparam [3:0] FP4_SUB    = 4'b0001; // +subnormal
  localparam [3:0] FP4_INF    = 4'b0110; // +INF
  localparam [3:0] FP4_NAN    = 4'b0111; // qNaN

  function automatic [7:0] pack_fp4_pair;
    input [3:0] hi;
    input [3:0] lo;
    begin
      pack_fp4_pair = {hi, lo};
    end
  endfunction

  integer idx;

  initial begin
    mode_fp4    = 1'b0;
    a_data      = 32'd0;
    b_bf16      = 16'd0;
    c_bf16      = 32'd0;
    input_valid = 1'b0;
    valid_pipe  = {PIPE_LAT{1'b0}};
    mode_pipe   = {PIPE_LAT{1'b0}};
    cycle       = 0;
    errors      = 0;
    checks      = 0;

    // BF16 vectors
    bf16_a_vec[0] = {16'h3F80, 16'h3F80}; // 1.0 * 1.0 + 0
    bf16_b_vec[0] = 16'h3F80;
    bf16_c_vec[0] = 32'h0000_0000;

    bf16_a_vec[1] = {16'h4000, 16'h0000}; // 2.0 * 0.5 + c
    bf16_b_vec[1] = 16'h3F00;
    bf16_c_vec[1] = {16'h3F80, 16'h3F80};

    bf16_a_vec[2] = {16'h7F80, 16'h3F80}; // Inf * anything + c
    bf16_b_vec[2] = 16'h3F80;
    bf16_c_vec[2] = {16'h4000, 16'h0000};

    bf16_a_vec[3] = {16'h7FC0, 16'h0000}; // NaN path + zero lane
    bf16_b_vec[3] = 16'h3F80;
    bf16_c_vec[3] = {16'h3F80, 16'h3F80};

    // FP4 vectors
    fp4_a_vec[0] = pack_fp4_pair(FP4_POS1, FP4_POS1);
    fp4_b_vec[0] = 16'h3F80;
    fp4_c_vec[0] = 32'h0000_0000;

    fp4_a_vec[1] = pack_fp4_pair(FP4_POS1P5, FP4_NEG1);
    fp4_b_vec[1] = 16'h3F80;
    fp4_c_vec[1] = {16'h3F80, 16'h3F80};

    fp4_a_vec[2] = pack_fp4_pair(FP4_POS2, FP4_SUB);
    fp4_b_vec[2] = 16'h4000; // 2.0
    fp4_c_vec[2] = {16'h3F00, 16'h0000};

    fp4_a_vec[3] = pack_fp4_pair(FP4_INF, FP4_NAN);
    fp4_b_vec[3] = 16'h3F80;
    fp4_c_vec[3] = {16'h3F80, 16'h3F80};

    repeat (3) @(posedge clk);

    // BF16 stimulus
    for (idx = 0; idx < BF16_TESTS; idx = idx + 1) begin
      @(negedge clk);
      mode_fp4    = 1'b0;
      a_data      = bf16_a_vec[idx];
      b_bf16      = bf16_b_vec[idx];
      c_bf16      = bf16_c_vec[idx];
      input_valid = 1'b1;
    end

    // bubble to flush BF16 stream
    @(negedge clk);
    input_valid = 1'b0;
    mode_fp4    = 1'b0;
    a_data      = 32'd0;
    b_bf16      = 16'd0;
    c_bf16      = 32'd0;
    repeat (PIPE_LAT+2) @(posedge clk);

    // FP4 stimulus
    for (idx = 0; idx < FP4_TESTS; idx = idx + 1) begin
      @(negedge clk);
      mode_fp4    = 1'b1;
      a_data      = {24'd0, fp4_a_vec[idx]};
      b_bf16      = fp4_b_vec[idx];
      c_bf16      = fp4_c_vec[idx];
      input_valid = 1'b1;
    end

    // bubble to flush FP4 stream
    @(negedge clk);
    input_valid = 1'b0;
    mode_fp4    = 1'b0;
    a_data      = 32'd0;
    b_bf16      = 16'd0;
    c_bf16      = 32'd0;
    repeat (PIPE_LAT+4) @(posedge clk);

    if (errors == 0) begin
      $display("bf16_fp4_dual_mac_tb PASSED (%0d checks).", checks);
    end else begin
      $display("bf16_fp4_dual_mac_tb FAILED with %0d errors (%0d checks).", errors, checks);
    end
    $finish;
  end

  always @(posedge clk) begin
    cycle      <= cycle + 1;
    valid_pipe <= {valid_pipe[PIPE_LAT-2:0], input_valid};
    mode_pipe  <= {mode_pipe[PIPE_LAT-2:0], mode_fp4};

    if (valid_pipe[PIPE_LAT-1]) begin
      checks <= checks + 1;
      if (mode_pipe[PIPE_LAT-1] == 1'b0) begin
        if (dut_result !== ref_bf16_result) begin
          errors <= errors + 1;
          $display("[BF16] mismatch @cycle %0d exp=%h got=%h", cycle, ref_bf16_result, dut_result);
        end
      end else begin
        if (dut_result !== ref_fp4_result) begin
          errors <= errors + 1;
          $display("[FP4 ] mismatch @cycle %0d exp=%h got=%h", cycle, ref_fp4_result, dut_result);
        end
      end
    end
  end
endmodule

// ---------------------------------------------------------------------------
// Simple behavioral DSP48E2 stub for simulation (models pure A*B multiply)
// ---------------------------------------------------------------------------
module DSP48E2 #(
    parameter USE_MULT      = "MULTIPLY",
    parameter USE_SIMD      = "ONE48",
    parameter A_INPUT       = "DIRECT",
    parameter B_INPUT       = "DIRECT",
    parameter AREG          = 0,
    parameter ACASCREG      = 0,
    parameter BREG          = 0,
    parameter BCASCREG      = 0,
    parameter MREG          = 0,
    parameter PREG          = 0,
    parameter OPMODEREG     = 0,
    parameter ALUMODEREG    = 0,
    parameter INMODEREG     = 0,
    parameter CARRYINREG    = 0,
    parameter CARRYINSELREG = 0
) (
    input  wire        CLK,
    input  wire [26:0] A,
    input  wire [17:0] B,
    input  wire [47:0] C,
    input  wire [26:0] D,
    input  wire [4:0]  INMODE,
    input  wire [3:0]  ALUMODE,
    input  wire [8:0]  OPMODE,
    input  wire        CARRYIN,
    input  wire [2:0]  CARRYINSEL,
    input  wire        CEA1,
    input  wire        CEA2,
    input  wire        CEB1,
    input  wire        CEB2,
    input  wire        CEM,
    input  wire        CEP,
    input  wire        CEC,
    input  wire        CED,
    output reg  [47:0] P
);
  wire [44:0] mult = A * B;

  always @(*) begin
    P = {3'b000, mult};
  end
endmodule

`default_nettype wire
