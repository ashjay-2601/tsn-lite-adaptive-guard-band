
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
