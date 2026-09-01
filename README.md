# TSN-Lite: Preemption-Aware Adaptive Guard Band for IEEE 802.1Qbv

A time-aware Ethernet egress scheduler in Verilog-2001, targeting a 64-bit
datapath at 156.25 MHz (10 Gb/s). Implements 802.1Qbv gate control, 802.1Qav
credit-based shaping and 802.3br frame preemption, with an AXI4-Lite register
interface.

The contribution is the guard-band policy. Standard Qbv blanks the port for a
full `maxSDU / linkRate` before every gate close, unconditionally. This design
replaces that constant with a per-frame decision based on the actual
head-of-line frame length and whether its traffic class is preemptable.

**Result: +13.1% best-effort goodput at a 20 µs schedule cycle, rising to
+35.5% at 12 µs, with time-triggered latency jitter bit-identical to the
baseline.**

---

## Results

Same netlist, both runs, switched by one CSR bit (`CTRL[1]`). 10 Gb/s link,
1522 B MTU, 100 schedule cycles per point. TT class 7 = 500 B every 10 µs,
BE class 0 = saturating, uniform 64–1522 B.

| BE window | Cycle | Static (Gb/s) | Adaptive (Gb/s) | Gain | Jitter static | Jitter adaptive | Fragments |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 3 000 ns | 12 µs | 3.580 | 4.851 | **+35.5%** | 4212 ns | 2216 ns | 178 |
| 5 000 ns | 16 µs | 5.158 | 6.106 | **+18.4%** | 6216 ns | 4212 ns | 178 |
| 7 000 ns | 20 µs | 6.063 | 6.854 | **+13.1%** | 411 ns | 411 ns | 174 |
| 10 000 ns | 26 µs | 6.944 | 7.545 | +8.7% | 9415 ns | 9415 ns | 181 |
| 15 000 ns | 36 µs | 7.745 | 8.188 | +5.7% | 8416 ns | 8416 ns | 174 |
| 20 000 ns | 46 µs | 8.189 | 8.552 | +4.4% | 9420 ns | 9420 ns | 186 |
| 30 000 ns | 66 µs | 8.709 | 8.947 | +2.7% | 9415 ns | 9415 ns | 180 |
| 50 000 ns | 106 µs | 9.145 | 9.290 | +1.6% | 9415 ns | 9415 ns | 180 |

The gain scales inversely with window length, which is the expected physics:
the static guard band is a fixed cost per gate close, so it dominates at fine
schedule granularity. TT jitter is never degraded, and at the two shortest
cycles it *improves*, because fewer BE frames are left stranded across a
boundary.

Assertion failures across all 16 runs: **0**.

## Implementation

Yosys 0.33, generic technology mapping, `check -assert` clean:

| | |
|---|---|
| Cells | 17 197 |
| Flip-flops | 2 478 |
| Inferred latches | 0 |
| Yosys `check` problems | 0 |

## Architecture

```
  AXI4-Lite ──> csr_axil ──> { GCL x16, CBS config x8, control, statistics }
                                     │
  ptp_clock ──> gcl_ctrl ──> gate_open[7:0], remaining_ns
                                     │
  queue status ──> tx_arbiter ──> candidate ──> guard_band ──> tx_engine ──> wire
                                     ▲
                                cbs_shaper x8
```

| Module | Role |
|---|---|
| `ptp_clock.v` | 48.16 fixed-point ns time base; non-integer 6.4 ns period accumulates without drift |
| `gcl_ctrl.v` | Qbv gate control list, 16 entries, base-time aligned; exports `remaining_ns` |
| `cbs_shaper.v` | Qav credit-based shaper, one per class, no dividers (slopes pre-scaled to Q16.16 per-clock) |
| `guard_band.v` | **The contribution.** Per-frame window-fit and cut-point decision |
| `tx_arbiter.v` | Strict priority over classes gated by gate ∧ credit ∧ queue |
| `tx_engine.v` | 8 B/clk serialiser with 802.3br SMD-E/S/C framing and residual reporting |
| `csr_axil.v` | AXI4-Lite slave, register map in `docs/spec.md` |

### The decision

```
rem_eff     = remaining_ns - PIPE_LAT_NS
tx_time_ns  = ceil((len + 20) * 0.8)
fits        = tx_time_ns <= rem_eff
frag_bytes  = floor_to_8(rem_eff * 1.25) - 20
cuttable    = preempt_en & preemptable
            & frag_bytes         >= 64
            & (len - frag_bytes) >= 64
allow_start = fits | cuttable
```

Three details carry the design, and all three were found by simulation or
synthesis rather than by inspection:

1. **`PIPE_LAT_NS`.** The verdict is registered in `guard_band`, the candidate
   is registered in `tx_arbiter`, and the start is registered in `tx_engine`.
   The wire therefore moves two clocks after `remaining_ns` was sampled.
   Without this subtraction every burst overruns its window.
2. **Fragment alignment.** The serialiser moves 8 B/clk, so an unaligned cut is
   rounded *up* on the wire. `frag_bytes` is floored to an 8-byte multiple.
3. **The tail check.** Cutting so that only 40 B remain produces an illegal
   continuation fragment. Both sides of the cut must be ≥ 64 B.

All fixed-point rounding is deliberately asymmetric — `tx_time` rounds up
(`0.8 → 205/256`), `frag_bytes` rounds down (`1.25 → 320/256`) — so every
arithmetic error is in the safe direction. No dividers anywhere.

### Pipeline hazard

The guard-band verdict is two cycles stale by the time it is usable. A gate
close inside that shadow originally launched a frame with a *stale length* on a
*closed gate*. `tsn_sched_top` re-qualifies the start against the live gate and
credit state and requires the candidate to be unchanged across the pipeline:

```verilog
wire cand_stable = cand_valid && cand_valid_q &&
                   (cand_class == cand_class_q) && (cand_len == cand_len_q);
wire start = !busy && cand_valid_q && gb_allow && cand_stable &&
             gate_open[cand_class_q] && credit_ok[cand_class_q];
```

## Verification

- **Directed** — `tb_debug.v` traces every gate transition and burst over three
  schedule cycles.
- **Randomised** — `tb_sched.v` runs the full A/B with random BE lengths and a
  scoreboard; checks CSR statistics against independently maintained testbench
  counters (they match exactly).
- **Inline assertions** — no transmission while its gate is closed; no fragment
  or residual below 64 B; no TT frame overrun.
- **Formal** — `formal/gb_props.sv`, six properties under SymbiYosys BMC.
  P1 (permitted frames always fit), P2 (both sides of a cut are legal),
  P3 (cuts are serialiser-aligned), P4 (adaptive is a strict superset of
  static), P5 (static mode never fragments), plus a cover proving cuts are
  reachable.

## Reproducing

```bash
make sim      # A/B experiment, prints the comparison table
make sweep    # window-size sweep -> results/sweep.csv
make debug    # cycle-by-cycle burst trace
make synth    # Yosys, cell/FF counts, check -assert
make lint     # verilator -Wall
make formal   # SymbiYosys BMC
make wave     # VCD + GTKWave
```

Only `iverilog` is needed for `sim`/`sweep`/`debug`.

## Status

Done: scheduler subsystem, AXI4-Lite CSRs, A/B methodology, sweep, generic
synthesis, formal property set.

Not done yet: VOQ manager and shared packet buffer (the queue model currently
lives in the testbench), frame parser and VLAN/PCP decode, 4×4 crossbar, RX
reassembly, CDC between the recovered RX clock and the core domain, and the
OpenLane push to GDSII.
