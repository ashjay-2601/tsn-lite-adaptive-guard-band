# TSN-Lite: Time-Aware Ethernet Egress Port with an Adaptive Guard Band

A 10 Gb/s IEEE 802.1Qbv / 802.1Qav / 802.3br egress port in Verilog-2001.
64-bit datapath at 156.25 MHz, AXI4-Lite control, two clock domains.

Built and verified entirely with open-source tools. No FPGA board.

---

## What it does

Standard 802.1Qbv blanks the port for a full `maxSDU / linkRate` before every
gate close — 1234 ns at 10 Gb/s with a 1522 B MTU, unconditionally, regardless
of what is actually queued. This design replaces that constant with a
per-frame decision based on the real head-of-line length and whether the class
is preemptable:

```
rem_eff     = remaining_ns - PIPE_LAT_NS
tx_time_ns  = ceil((len + 20) * 0.8)
fits        = tx_time_ns <= rem_eff
frag_bytes  = floor_to_8(rem_eff * 1.25) - 20
cuttable    = preempt_en & preemptable
            & frag_bytes >= 64 & (len - frag_bytes) >= 64
allow_start = fits | cuttable
```

A single CSR bit switches between static and adaptive, so both policies run in
one netlist and the comparison is exact.

## Result

Icarus Verilog 12.0 and Verilator 5.020, byte-identical:

| BE window | Cycle | Static Gb/s | Adaptive Gb/s | Gain | Jitter static | Jitter adaptive |
|---:|---:|---:|---:|---:|---:|---:|
| 3 000 ns | 12 µs | 3.440 | 4.682 | **+36.1%** | 3803 ns | 1806 ns |
| 5 000 ns | 16 µs | 4.990 | 5.875 | +17.7% | 5806 ns | 3803 ns |
| 7 000 ns | 20 µs | 5.852 | 6.599 | **+12.8%** | 1 ns | 1 ns |
| 10 000 ns | 26 µs | 6.686 | 7.258 | +8.6% | 9005 ns | 9005 ns |
| 20 000 ns | 46 µs | 7.903 | 8.225 | +4.1% | 9011 ns | 9011 ns |
| 50 000 ns | 106 µs | 8.783 | 8.930 | +1.7% | 9005 ns | 9005 ns |

Time-triggered jitter is identical between modes at every point — the
throughput is not bought with determinism. 0 assertion failures across all 12
runs.

The gain scales inversely with window length because the static guard band is
a fixed cost per gate close. That is why it matters: short-cycle schedules are
exactly where TSN is used.

## Novelty — read this before assuming any

**The idea is not novel.** Length-aware and preemption-aware Qbv guard bands
are published in the TSN literature. The asynchronous FIFO is Cummings' 2002
design essentially unchanged.

What is actually mine:

1. **A working synthesisable implementation.** The papers give equations and
   network-simulator models. This is RTL with a real serialiser, real VOQs and
   real preemption resume.
2. **Three implementation hazards the papers cannot see**, because a
   zero-latency model has no pipeline: `PIPE_LAT_NS`, 8-byte fragment
   alignment, and stale-candidate re-qualification.
3. **The measurement**, reproducible under two independent simulators.

Honest framing: *"I implemented a published TSN optimisation that has no
open-source RTL, found three hazards the papers don't discuss, then tried to
reproduce my own fixes by reverting them — and two didn't reproduce, because
an unrelated margin was masking them. My tests weren't verifying what I
thought they were."*

## Architecture

```
  rx_clk domain          |          core clk domain (156.25 MHz)
  ---------------------- | ---------------------------------------------
  AXI-Stream ingress     |
  async_fifo write side ===> read side -> frame_parser -> voq_manager
                         |                                    |
                         |   pkt_buffer (128 x 64 B cells) <---+
                         |                                    |
  AXI4-Lite -> csr_axil -> { GCL x16, CBS x8, PTP, control, stats }
                         |                                    |
  ptp_clock -> gcl_ctrl -> gate_open, remaining_ns            |
                         |                                    v
                         |   tx_arbiter -> guard_band -> tx_engine -> wire
                         |        ^                                   |
                         |   cbs_shaper x8 <-------------------------+
```

| Module | Role |
|---|---|
| `ptp_clock` | 48.16 fixed-point ns time base; non-integer 6.4 ns period accumulates without drift |
| `gcl_ctrl` | Qbv gate control list, 16 entries, base-time aligned; exports `remaining_ns` |
| `cbs_shaper` | Qav credit shaper per class, no dividers (slopes pre-scaled to Q16.16/clock) |
| `guard_band` | The contribution: per-frame window-fit and cut-point decision |
| `tx_arbiter` | Strict priority over gate ∧ credit ∧ queue, with refusal feedback |
| `tx_engine` | 8 B/clk serialiser, 802.3br SMD-E/S/C framing, residual reporting |
| `frame_parser` | VLAN TPID detect, PCP → class on beat 1, length from a tkeep popcount |
| `pkt_buffer` | Shared cell pool, free-list bitmap with priority encoder, per-frame chain |
| `voq_manager` | 8 descriptor FIFOs; rewrites the head descriptor in place on a cut so the frame resumes at the exact byte |
| `async_fifo` | Gray-coded dual-clock FIFO (Cummings 2002) |
| `csr_axil` | AXI4-Lite slave; register map in `docs/spec.md` |

## Verification

| Bench | Tool | Result |
|---|---|---|
| `tb_sched.v` | Icarus + Verilator | A/B guard band, 0 failures, byte-identical across simulators |
| `tb_sweep.v` | Icarus | 12 configs, 0 failures |
| `tb_port.v` | Icarus | 16 781 B in / out, 0 cells leaked |
| `tb_cdc.v` | Icarus | two drifting clocks, 0 FIFO drops |
| `tb_cbs.v` | Icarus | Qav unit test, 25.01% achieved vs 25.00% configured |
| `tb_cbs_sys.v` | Icarus | Qav share enforced 10–80% through the CSR path |
| `tb_csr.v` | Icarus | register interface, SLVERR paths, GCL_LEN=16, PTP hooks |
| `tb_credit_gb.v` | Icarus | credit-aware admission (negative result, see below) |
| `cocotb/test_gb.py` | cocotb | 20 000 random stimuli, 0 mismatches vs reference model |
| `formal/gb_props.sv` | SymbiYosys + z3 | **6 properties proved by k-induction** |

**Formal is the strongest result.** BMC only says "no counterexample in 40
cycles"; k-induction passing means the properties hold for all reachable
states, unbounded. Four cover statements prove the interesting states are
reachable, so nothing passes vacuously. See `docs/formal_report.md`.

**Functional coverage:** 30/30 reachable bins (100%). 18 of 48 bins are
structurally unreachable and are excluded by explicit argument rather than
counted as misses.

**Code coverage:** 50.7% toggle. Not high, and stated plainly: the design is
full of wide counters and Q16.16 arithmetic whose upper bits only move at
magnitudes real traffic never reaches. Reaching 75% would need stimulus
contrived to flip bits rather than find defects.

**CDC:** every crossing enumerated in `docs/cdc_report.md`. Verified across
rx_clk 5.4–12.0 ns against a 6.4 ns core.

## A negative result

Step 19 added credit-aware admission: refuse a frame that Qav credit cannot
cover, cutting at `min(window limit, credit limit)`. Software supplies a
reciprocal so the datapath needs no divider.

It works exactly as designed and **makes things worse**:

| Metric | Off | On |
|---|---:|---:|
| Shaped-class bytes | 1 495 430 | 635 976 |
| Worst credit excursion | −1140 B | **0 B** |
| Worst service gap | **2048 ns** | 3872 ns |

Credit overshoot is eliminated, but the shaped class loses 57% of its
throughput and its worst-case gap gets *longer* — which was the entire
motivation. Qav's overshoot is deliberate; `hiCredit`/`loCredit` exist to bound
it, and refusing to start costs more than the overshoot did.

Shipped disabled by default. Kept rather than reverted because the finding is
worth more than the feature: it is direct evidence for why the standard is
written the way it is. Full write-up in `docs/credit_aware_gb.md`.

## Thirteen bugs, and which tool found each

The point is the spread, not the count.

**Simulation (3):** pipeline shadow on the start decision (~39 000 failures on
revert); unaccounted pipeline latency; fragment misalignment.

**Synthesis (2):** a synchronous clear inside an async-reset block — Icarus
simulated it fine, Yosys rejected it as "multiple edge sensitive events"; a
combinational loop through `wfull`/`rempty` in the async FIFO.

**Lint (2):** `gcl_len[4]` unread, so GCL_LEN=16 silently collapsed the
schedule to one window; `s_wstrb` ignored, so partial AXI writes corrupted
whole registers.

**Integration (4):** phantom start on a queue that just emptied (`d_cnt`
underflowed 0→15); start racing completion, orphaning a 101-byte residual and
deadlocking the port; no arbiter fallback when the guard band refuses;
credit-aware cuts without a progress rule shredding frames into 10 878
fragments.

**Cross-simulation (1):** Verilator and Icarus disagreed on the headline
number. Root cause was not a race — `$random(seed)` is not portable, so the
two tools generated *different stimulus from the same seed*. Replaced with an
explicit LFSR.

**Coverage analysis (1):** `ptp_clock`'s IEEE 1588 set and servo inputs were
tied off at the top level, capping that module at 29% toggle coverage. A
missing feature, found by asking why a number would not move.

**Two entries correct my own earlier conclusions.** `PIPE_LAT_NS` and
`OVERHEAD_B` turned out redundant — either alone suffices, so the testbench
was verifying neither. And my first alignment measurement was circular: I
binned the DUT's post-mask output to decide whether the mask mattered.
Measured properly, it fires on 90.4% of cuts.

Full detail in `docs/bug_log.md`.

## Reproducing

```bash
make sim      # A/B experiment
make sweep    # window-size sweep
make lint     # verilator -Wall with documented waivers
make synth    # Yosys, 0 latches, 0 check problems
cd formal && sby -f gb_props.sby      # BMC + cover + k-induction
cd cocotb && make                      # random + functional coverage
```

Tools: Icarus 12.0, Verilator 5.020, Yosys 0.33, cocotb 2.1, SymbiYosys 0.68
with z3.

## Physical implementation

LibreLane 3.1 / OpenROAD on Sky130A (open 130 nm academic node, not a
production process). Scheduler subsystem only — pure standard cell, no macros.

| Attempt | Clock | DRC | LVS | Antenna | Setup timing |
|---|---|---|---|---|---|
| 1 | 6.4 ns / 156 MHz | pass | pass | pass | fails all 9 corners |
| 2 | 12.0 ns / 83 MHz | ✅ | ✅ | ✅ | fast corner **+0.53 ns**; slow corner **−18.2 ns** |

26 992 standard cells placed and routed. Both runs completed all 80 stages and
produced a DRC-, LVS- and antenna-clean GDS. Only timing signoff failed.

The 6.4 ns target came from the 10 Gb/s line rate, not from what the process
can deliver — a 64-bit datapath at 156 MHz is a sub-28 nm target. Slow-corner
WNS of −18.2 ns at a 12 ns period puts the real critical path near 30 ns,
roughly 33 MHz on 130 nm. No further relaxation was attempted: closing at
33 MHz would be arithmetically true and engineering-meaningless.

Issues visible in the reports and not papered over:

- `clk` drives 2668 terminals. This is a flat block with ~2500 flops on one
  clock; CTS is straining and a real implementation would partition it.
- Hold violations appear on the 32-bit statistics counters in `csr_axil`,
  which self-loop through their own increment logic. Those counters are not
  performance-critical and should be pipelined or clock-gated.

## Known gaps

- `pkt_buffer` synthesises to ~65 600 flops because Yosys flattens the 8 KB
  array. It must become an SRAM macro before any area number means anything.
  Only the scheduler is hardened.
- No automated CDC checker was run; Yosys has no CDC pass. The report is
  derived by inspection, with every crossing traceable to a named instance.
- Only `guard_band` is formally verified. The FIFO is the obvious next target.
- The CDC test fails below rx_clk ≈ 5.3 ns — outside the physical range for a
  recovered clock, documented rather than hidden.
