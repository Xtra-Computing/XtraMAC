`ifndef INT4_FP8_COMMON_VH
`define INT4_FP8_COMMON_VH

// Macro expands to a Verilog-2001 function that converts a signed INT4 lane
// into {is_zero, sign, exp_unbiased[3:0], mant_frac[2:0]}.
`define DECL_INT4_DECODE_FP8_FIELDS \
  function [8:0] int4_decode_fp8_fields; \
    input [3:0] val4; \
    reg  signed [4:0] sval; \
    reg         sign; \
    reg  signed [4:0] abs5; \
    reg  [3:0] mag; \
    reg  [3:0] exp_unb; \
    reg  [3:0] mant4; \
    begin \
      sval = $signed({val4[3], val4}); \
      sign = sval[4]; \
      abs5 = sign ? -sval : sval; \
      mag  = abs5[3:0]; \
      if (mag == 4'd0) begin \
        int4_decode_fp8_fields = 9'd0; \
        int4_decode_fp8_fields[8] = 1'b1; \
      end else begin \
        casez (mag) \
          4'b1???: begin \
            exp_unb = 4'd3; \
            mant4   = {1'b1, mag[2:0]}; \
          end \
          4'b01??: begin \
            exp_unb = 4'd2; \
            mant4   = {1'b1, mag[1:0], 1'b0}; \
          end \
          4'b001?: begin \
            exp_unb = 4'd1; \
            mant4   = {1'b1, mag[0], 2'b00}; \
          end \
          default: begin \
            exp_unb = 4'd0; \
            mant4   = 4'b1000; \
          end \
        endcase \
        int4_decode_fp8_fields = {1'b0, sign, exp_unb, mant4[2:0]}; \
      end \
    end \
  endfunction

`endif // INT4_FP8_COMMON_VH
