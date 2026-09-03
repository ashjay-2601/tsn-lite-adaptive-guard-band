
## 7. Phantom start on a queue that just emptied      [found by integration]
tsn_sched_top re-qualified `start` against the live gate and credit state but
not against live q_nonempty. When a queue emptied, the three-cycle
arbiter/guard-band/engine shadow allowed one further start with a stale
length. The resulting phantom tx_done decremented d_cnt from 0 to 15, making
the queue appear permanently occupied and corrupting the cell free list.
Structurally unreachable by the original testbench, whose queue model was
always backlogged and never emptied.

## 8. Start racing completion -- orphaned residual     [found by integration]
A start could be issued on the same clock edge as the tx_done of the previous
frame. The queue manager arms its read cursor from d_cell[hd_ptr] on that
edge, while hd_ptr is being incremented by the pop -- so the burst read the
wrong descriptor and the occupancy counts desynchronised. Symptom: a 101-byte
residual was orphaned and the port deadlocked for the remaining 760 us of the
run, leaking one cell.

Fixed by adding !tx_done to the start condition, enforcing one idle cycle
between bursts. Cost: BE goodput fell from 6.063 to 5.840 Gb/s at a 20 us
cycle (-3.7%), and the headline adaptive-vs-static gain from 13.05% to 12.99%.
Accepting a bounded ~0.6%-per-frame throughput loss to remove an unbounded
deadlock is the right trade, but it is a real cost and the README numbers were
restated rather than left at their pre-fix values.

## 9. Datapath bugs during VOQ bring-up               [found by integration]
- Read cursor armed one cycle after tx_busy, dropping the final word of every
  frame (tx_engine asserts busy for exactly ceil(len/8) clocks).
- Allocator handed out a cell it had already allocated, producing a cell
  linked to itself. Fixed by making allocator control combinational.
- rc_pend persisted across transmissions, walking a freed chain.
- The 802.3br resume cursor was written back one word stale, because tx_done
  shares a clock edge with the final read beat.

## CORRECTION to item 3 (fragment alignment)                [found by cocotb]
Item 3 recorded that the 8-byte fragment alignment could not be shown to
matter, and flagged it as an open coverage gap. That conclusion was wrong.

The cocotb reference model bins the cut point BEFORE the alignment mask is
applied. Over 20,000 random stimuli it reports:

    pre-alignment cut point mod 8: {0:34, 1:52, 2:41, 3:53, 4:46, 5:28, 6:50, 7:52}
    322/356 cuts (90.4%) land off an 8-byte boundary

So the mask fires on 90% of all cuts and is firmly load-bearing. The reason
removing it did not fail the Verilog testbench is the same reason PIPE_LAT_NS
did not: OVERHEAD_B reserves 16 ns per decision that the serialiser never
spends, and that slack absorbs the overrun.

The earlier measurement was circular -- it binned frag_bytes, which is the
DUT's own output AFTER masking, so of course every value was aligned. Binning
the DUT's output to decide whether the DUT's logic matters proves nothing.
The reference model has to compute the pre-masked value independently.

## 10. Two simulators disagree on the same RTL       [found by cross-simulation]
Running tb_sched.v under Verilator 5.020 reports a 13.51% adaptive-vs-static
goodput gain; Icarus Verilog 12.0 reports 12.99% on identical sources. The
assertion count is 0 in both, so no gate is violated either way.

A numeric difference between simulators on the same RTL points at a race in
the testbench -- most likely the blocking assignments used for statistics
counters inside always @(posedge clk) blocks, which have no defined ordering
against the non-blocking updates they observe. The RTL itself uses
non-blocking assignments throughout.

Not yet root-caused. Recorded here rather than quietly reporting whichever
number looks better; the README quotes the Icarus figure and names the
simulator and version.
