# Clock domain crossing report

## Domains

| Domain | Clock | Nominal | Contents |
|---|---|---|---|
| RX | `rx_clk` | 156.25 MHz, recovered from the serial stream | AXI-Stream ingress, `async_fifo` write side, drop counter |
| Core | `core_clk` | 156.25 MHz, local oscillator | `async_fifo` read side, parser, VOQ, buffer, scheduler, CSRs |

The two are nominally the same frequency but have no phase relationship and a
real ppm offset, so they are treated as fully asynchronous.

## Crossings

| # | Signal | From | To | Type | Protection |
|---|---|---|---|---|---|
| 1 | `wgray[5:0]` | RX | Core | multi-bit, Gray coded | `sync_2ff` |
| 2 | `rgray[5:0]` | Core | RX | multi-bit, Gray coded | `sync_2ff` |
| 3 | `{tlast,tkeep,tdata}` 74 b | RX | Core | data | FIFO memory, no synchroniser needed |
| 4 | `arst_n` | async | RX | reset | `reset_sync` (async assert, sync deassert) |
| 5 | `arst_n` | async | Core | reset | `reset_sync` (async assert, sync deassert) |

**No unprotected crossing exists.** Every path between domains is one of the
five above.

### Why crossing 3 needs no synchroniser
Data is written into the FIFO memory in the RX domain and is stable long
before the read pointer is permitted to reach it. The pointer handshake
(crossings 1 and 2) is what makes the data safe; the RAM has no special
property. Attempting to synchronise 74 bits of arbitrary data directly would
be the bug this structure exists to avoid.

### Why the pointers are Gray coded
A binary pointer stepping `0111 -> 1000` changes four bits at once. Sampled by
the far clock mid-transition, individual bits can land on either side of the
edge and the receiver may observe `1111` or `0000` -- values the counter never
held. Gray code changes exactly one bit per increment, so a mid-transition
sample yields either the old value or the new one, and both are safe.

`sync_2ff`'s width parameter is deliberately named
`WIDTH_MUST_BE_GRAY_OR_1` so a future user cannot pass an arbitrary bus
without noticing the requirement.

### Why full and empty are generated in different domains
Each flag is computed where its own pointer lives, against the *synchronised*
copy of the far pointer. Full is therefore pessimistic (the write side may not
yet have seen a read) and empty is pessimistic (the read side may not yet have
seen a write). Pessimism is the correct direction: the failure mode of an
optimistic flag is overwriting live data. Comparing two raw pointers from
different domains would be optimistic, and is the standard way to build a FIFO
that passes simulation and fails in silicon.

### Registered flags (bug found by synthesis)
`wfull` and `rempty` were originally continuous assignments. That closes a
combinational loop: `wfull -> wbin_nxt -> wgray_nxt -> wfull`, and the same
through `rempty`. Simulation ran without complaint; Yosys reported
`found logic loop in module async_fifo` and `check -assert` failed with 2
problems. Both flags are now registered. The cost is one cycle of extra
pessimism on each flag, which is harmless.

### Reset domain crossing
One `reset_sync` instance per domain, both fed from the same asynchronous
`arst_n`. Assert is combinational so reset takes effect with no clock running;
deassert passes through two flops in the destination domain so every flop
there leaves reset on the same edge. Sharing a single synchroniser across both
domains would reintroduce the reset-domain crossing it exists to remove.

## Verification

`tb/tb_cdc.v` runs the full ingress-to-egress loopback with the two clocks
free-running at different periods, checking every byte against a per-class
reference model.

Verified range of `rx_clk` period against a 6.4 ns core clock:

| rx_clk period | Result |
|---|---|
| 5.4 ns | PASS |
| 5.5 ns | PASS |
| 6.0 ns | PASS |
| 6.35 ns | PASS |
| 6.4 ns | PASS |
| 6.45 ns | PASS |
| 7.0 ns | PASS |
| 8.0 ns | PASS |
| 12.0 ns | PASS |

A real recovered Ethernet clock sits within +/-100 ppm of nominal, i.e.
6.3994 to 6.4006 ns. The 6.35 / 6.45 ns cases are roughly 8000x that margin,
and every phase alignment is swept many times over an 820 us run.

## Known limit

Below about 5.3 ns the test fails: sustained ingress outruns what the core
domain can drain, and the testbench's ready-handshake model does not implement
a drop-on-full path. This is outside the physical operating range -- it would
require the recovered clock to be 20% faster than the core, which is not a
clock-recovery offset but a different design. It is recorded here as a
documented limit rather than left as an unexplained boundary.

`stat_fifo_drops` counts beats that would have been lost had the RX side been
unable to back-pressure, which is the real situation on a wire. It reads 0 for
every passing case above.

## Not yet done

No automated CDC checker has been run. Yosys has no CDC pass, and the
open-source options were not available in this environment. The table above is
derived by inspection of the RTL, and every crossing listed is traceable to a
named module instance. A commercial flow would run Spyglass CDC or Questa CDC
here and the report would be tool-generated.
