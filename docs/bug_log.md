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

## 2. Unaccounted pipeline latency in the window fit    [found by simulation]
remaining_ns is sampled two clocks before the serialiser moves, making every
decision 12.8 ns optimistic. Fixed with PIPE_LAT_NS = 13.

Isolating this experimentally gave an unexpected result. Reverting
PIPE_LAT_NS to 0 alone does NOT fail the testbench. A six-way parameter sweep
showed why: OVERHEAD_B = 20 budgets 20 bytes of preamble and IPG into every
transmission-time estimate, but tx_engine serialises only frame bytes and
never transmits preamble or IPG. That reserves 16 ns of slack per decision,
which exceeds the 12.8 ns of pipeline latency and masks it entirely.

With OVERHEAD_B forced to 0, PIPE_LAT_NS = 0 fails and PIPE_LAT_NS = 13
passes -- so the compensation is real and correct, but redundant given the
overhead budget. Two independent safety mechanisms cover the same hazard and
the testbench cannot distinguish them. That redundancy is a coverage gap, not
a virtue: a future change that trims OVERHEAD_B to reclaim bandwidth would
silently remove the margin without any test failing.

## 3. Fragment not aligned to the serialiser width      [not reachable by test]
The datapath moves 8 B/clk, so a cut at an unaligned byte count is rounded up
on the wire past the boundary. frag_bytes is floored to a BYTES_PER_CLK
multiple. Reverting this produces no failures under the current traffic
profile even with all other margins removed -- the hazard is real in
principle but this stimulus does not reach it. Flagged as an open coverage
gap requiring a directed test with cut points deliberately placed off an
8-byte boundary.

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

## Coverage gaps found by this exercise
Attempting to reproduce each fix by reverting it revealed that only bug 1 is
independently observable. Bugs 2 and 3 are masked by conservative margins
elsewhere in the design. The randomised testbench passes with either
mechanism removed, which means it is not actually verifying them. Closing
this needs directed tests that null out competing margins and place cut
points at deliberately hostile offsets.
