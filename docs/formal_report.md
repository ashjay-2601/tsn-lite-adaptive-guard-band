# Formal verification report — adaptive guard band

Tool: SymbiYosys 0.68 with Yosys 0.33, solver z3 4.8.12.
Run: `cd formal && sby -f gb_props.sby`

## Result

| Task | Mode | Depth | Result |
|---|---|---|---|
| `gb_props_bmc` | bounded model check | 40 | **PASS** |
| `gb_props_cover` | reachability | 40 | **PASS** — all 4 covers reached at step 2 |
| `gb_props_prove` | k-induction | 20 | **PASS** (basecase and induction) |

`prove` is the result that matters. BMC only says "no counterexample within 40
cycles"; k-induction passing means the properties hold for **all** reachable
states, unbounded. That is a proof, not a search.

## Properties

| # | Claim |
|---|---|
| P1 | A permitted whole-frame transmission always fits the window: `allow_start && !do_preempt && adaptive` implies `tx_time <= rem_eff`. The core determinism claim — adaptive mode must never leak into a protected window. |
| P2 | Both sides of a cut are legal: `frag_bytes >= 64` **and** `len - frag_bytes >= 64`. Missing the tail half is the classic 802.3br bug. |
| P3 | A cut is aligned to the serialiser width and the fragment fits: `frag_bytes % 8 == 0` and `frag_ns <= rem_eff`. An unaligned cut is rounded *up* on the wire and overruns. |
| P4 | Adaptive is a strict superset of static: anything the conservative policy permits, the adaptive policy also permits. Proves the optimisation never loses ground. |
| P5 | Static mode never fragments. The A/B comparison is only fair if the baseline is a true baseline. |
| P6 | Nothing is permitted when no frame is present. |

## Why the covers matter

Assertions of the form `if (do_preempt) assert(...)` pass trivially if
`do_preempt` is never reachable. A BMC-only run would report PASS while
proving nothing. The `cover` task discharges that:

```
Reached cover statement at gb_props.sv:127 in step 2   -- do_preempt
Reached cover statement at gb_props.sv:130 in step 2   -- whole frame permitted
Reached cover statement at gb_props.sv:131 in step 2   -- frame blocked
Reached cover statement at gb_props.sv:132 in step 2   -- alignment mask fires
```

The fourth cover is the interesting one. It requires `fb_hdr != fb_net` — a
cut point that the alignment mask actually changes. Its reachability is
independent confirmation of the cocotb finding that the mask is load-bearing,
and it closes the item that was left open in the bug log after the Verilog
testbench could not reach it.

## Notes on the encoding

Yosys 0.33 does not parse SVA concurrent assertions
(`assert property (@(posedge clk) ...)`), so the properties are written as
immediate assertions inside clocked blocks, and `$past` is replaced with
explicit one-cycle delay registers.

That rewrite is not merely cosmetic. `guard_band` registers all of its
outputs, so the verdict visible at cycle N belongs to the stimulus applied at
cycle N-1. Every property compares the current outputs against a reference
model computed from the *delayed* inputs. Getting that alignment wrong is the
usual way a formal run passes while proving nothing — the same class of
mistake as the circular coverage measurement recorded in the bug log.

The module's inputs are undriven, so the solver treats them as free variables.
Two assumes narrow the space to legal Ethernet frames (64..1522 B) and
plausible window remainders (<= 1 ms).

## Limitation

Only `guard_band` is formally verified. The scheduler, VOQ manager and CDC
FIFO are covered by simulation and directed tests, not by proof. Proving the
FIFO would need its own property set (no overflow, no underflow, pointer
Gray-code invariant) and is the obvious next target.
