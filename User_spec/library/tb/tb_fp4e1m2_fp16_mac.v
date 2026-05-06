`timescale 1ns/1ps
`default_nettype none

module tb_fp4e1m2_fp16_mac;
  localparam integer LAT        = 4;
  localparam integer VEC_COUNT  = 64;
  localparam integer DUMMY_CLKS = 6;

  reg         clk;
  reg  [7:0]  a_fp4;
  reg  [15:0] b_fp16;
  reg  [31:0] c_fp16;
  wire [31:0] dut_result;
  wire [31:0] ref_result;

  fp4e1m2_fp16_mac dut (
      .clk   (clk),
      .a_fp4 (a_fp4),
      .b_fp16(b_fp16),
      .c_fp16(c_fp16),
      .result(dut_result)
  );

  fp8e4m3_fp16_mac ref (
      .clk   (clk),
      .a16   (fp4e1m2_to_fp8e4m3_packed(a_fp4)),
      .b16   (b_fp16),
      .c32   (c_fp16),
      .result(ref_result)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  integer cycle = 0;
  always @(posedge clk) begin
    cycle <= cycle + 1;
    if (cycle > DUMMY_CLKS + LAT) begin
      if (dut_result !== ref_result) begin
        $fatal(1, "Mismatch at cycle %0d: dut=%h ref=%h", cycle, dut_result, ref_result);
      end
    end
  end

  integer i;
  initial begin
    a_fp4  = 8'h00;
    b_fp16 = 16'h0000;
    c_fp16 = 32'h0000_0000;

    repeat (DUMMY_CLKS) @(posedge clk);

    for (i = 0; i < VEC_COUNT; i = i + 1) begin
      a_fp4  <= $random;
      b_fp16 <= $random;
      c_fp16 <= {$random, $random};
      @(posedge clk);
    end

    repeat (LAT + 4) @(posedge clk);
    $display("tb_fp4e1m2_fp16_mac completed without mismatches.");
    $finish;
  end

  function automatic [7:0] fp4e1m2_to_fp8e4m3_lane;
    input [3:0] lane;
    reg sign;
    reg [1:0] frac2;
    begin
      sign = lane[3];
      if (lane[2] == 1'b1)
        fp4e1m2_to_fp8e4m3_lane = 8'h79;
      else begin
        frac2 = lane[1:0];
        if (frac2 == 2'b00)
          fp4e1m2_to_fp8e4m3_lane = {sign, 7'd0};
        else
          fp4e1m2_to_fp8e4m3_lane = {sign, 4'd6, frac2, 1'b0};
      end
    end
  endfunction

  function automatic [15:0] fp4e1m2_to_fp8e4m3_packed;
    input [7:0] lanes;
    begin
      fp4e1m2_to_fp8e4m3_packed = {
          fp4e1m2_to_fp8e4m3_lane(lanes[7:4]),
          fp4e1m2_to_fp8e4m3_lane(lanes[3:0])
      };
    end
  endfunction
endmodule

`default_nettype wire
