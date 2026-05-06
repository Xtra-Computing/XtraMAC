# int8_int8_int32 Synthesis Results (U55C, 450 MHz target)

Target clock: 2.222 ns (450 MHz)  
Part: xcu55c-fsvh2892-2L-e  
Lane group: 2lane

| Variant | Latency | LUT | FF | DSP | Route WNS (ns) | Fmax (MHz) |
|---------|---------|-----|-----|-----|----------------|------------|
| 4c | 4 | 93 | 252 | 1 | +0.305 | 521.6 |
| 5c | 5 | 93 | 252 | 1 | +0.305 | 521.6 |
| 6c | 6 | 113 | 350 | 1 | +0.374 | 541.1 |

## Notes
- The int32 accumulator core has a built-in `+1` output register that is not controllable via the `ADD_LAT` parameter, so the reported latency reflects the wrapper configuration plus this extra stage.
