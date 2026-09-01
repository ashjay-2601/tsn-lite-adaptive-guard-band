# Bug log

Three implementation hazards found during bring-up, each reproducible by
reverting a single line. Reproduction steps in section 11 of the build notes.

## 1. Pipeline shadow on the start decision
tx_arbiter registers its candidate, guard_band registers its verdict, and
tx_engine registers its start -- three clocks between sampling the gate and
driving the wire. A gate closing inside that shadow launched a frame onto a
closed gate with a stale length (observed: an 1128 B frame transmitting as
1400 B). Fixed by re-qualifying start against the live gate and credit state
plus a candidate-stability compare. Reverting the fix: ~39 000 assertion
failures.

## 2. Unaccounted pipeline latency in the window fit
remaining_ns is sampled two clocks before the serialiser moves, making every
decision 12.8 ns optimistic and every burst a slight overrun. Fixed with
PIPE_LAT_NS = 13. Reverting: gate-closed failures clustered at window
boundaries.

## 3. Fragment not aligned to the serialiser width
The datapath moves 8 B/clk, so a cut at an unaligned byte count is rounded up
on the wire past the boundary. Fixed by flooring frag_bytes to a
BYTES_PER_CLK multiple. Reverting: failures only on non-multiple-of-8 cuts.

## 4. Async reset containing a synchronous clear (found by synthesis)
csr_axil used `if (!rst_n || stat_clr)` inside an always @(posedge clk or
negedge rst_n) block. Icarus simulated it correctly; Yosys rejected it as
"multiple edge sensitive events". A sim/synth mismatch invisible to
simulation.

## 5. GCL_LEN=16 collapses the schedule (found by lint)
gcl_len is 5 bits; the wrap comparison read only [3:0]. At the documented
maximum of 16 entries the index never advances and the schedule silently
becomes a single window. The testbench uses 4 entries, so simulation could
not reach it. Found by Verilator UNUSEDSIGNAL on gcl_len[4].

## 6. AXI4-Lite byte strobes ignored (found by lint)
s_wstrb was declared and never read, so a partial-width write would update all
32 bits of a register. Now rejected with SLVERR; documented as 32-bit access
only.
