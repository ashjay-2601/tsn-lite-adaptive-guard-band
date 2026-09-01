# TSN-Lite Egress Scheduler — Specification

## 1. Targets
| Parameter | Value |
|---|---|
| Line rate | 10 Gb/s |
| Core clock | 156.25 MHz (6.4 ns) |
| Datapath | 64 bit (8 B/clk) |
| MTU | 1522 B (802.1Q tagged) |
| Traffic classes | 8 (PCP 0..7) |
| GCL entries | 16 |
| Min fragment | 64 B (802.3br) |

## 2. Register map (AXI4-Lite, 12-bit byte address)
| Addr | Name | Access | Description |
|---|---|---|---|
| 0x000 | CTRL | RW | [0] enable, [1] mode_adaptive, [2] preempt_en |
| 0x004 | GCL_LEN | RW | valid GCL entries, 1..16 |
| 0x008 | BASE_LO | RW | admin base time ns[31:0] |
| 0x00C | BASE_HI | RW | ns[47:32]; write pulses APPLY |
| 0x010 | PREEMPT_MASK | RW | [7:0] preemptable classes |
| 0x014 | STAT_CLR | W | write 1 to clear statistics |
| 0x020 | STAT_BYTES_TT | RO | express bytes transmitted |
| 0x024 | STAT_BYTES_BE | RO | preemptable bytes transmitted |
| 0x028 | STAT_PREEMPT | RO | fragmentation events |
| 0x02C | STAT_RECLAIM | RO | ns of guard band reclaimed vs static |
| 0x100+8i | GCL[i].MASK | RW | [7:0] gate mask |
| 0x104+8i | GCL[i].IVAL | RW | interval in ns |
| 0x200+4c | CBS[c].IDLE_SLOPE | RW | Q16.16 credit/clock, positive |
| 0x240+4c | CBS[c].SEND_SLOPE | RW | Q16.16 credit/clock, negative |
| 0x280+4c | CBS[c].HI_CREDIT | RW | Q16.16 clamp |
| 0x2C0+4c | CBS[c].LO_CREDIT | RW | Q16.16 clamp |

Unmapped writes return SLVERR. Unmapped reads return 0xDEADBEEF.

All registers are 32-bit access only. Writes with WSTRB != 4'hF are
rejected with SLVERR and have no effect.

## 3. Programming sequence
1. Write GCL_LEN, then each GCL[i].MASK / GCL[i].IVAL.
2. Write PREEMPT_MASK.
3. Write CBS slopes and clamps per class.
4. Write BASE_LO, then BASE_HI (the BASE_HI write applies the schedule and
   restarts the sequencer at entry 0).
5. Write CTRL with enable=1.

## 4. Eligibility
A class may start a transmission when all of:
- queue non-empty
- Qbv gate open for that class
- Qav credit >= 0
- guard band permits the head-of-line frame
- the engine is idle

Strict priority selects among eligible classes, highest PCP first.

## 5. Guard band
See README. `mode_adaptive=0` reproduces textbook Qbv exactly and is the
comparison baseline.

## 6. Interfaces
Queue manager (external, to be built):
- in:  `q_nonempty[7:0]`, `q_len_flat[111:0]` (8 x 14b head-of-line lengths)
- out: `tx_done`, `tx_done_class[2:0]`, `tx_done_bytes[13:0]`,
       `tx_done_truncated`, `tx_done_residual[13:0]`

On `tx_done_truncated`, the queue manager must re-head the residual at
`tx_done_residual` bytes for that class. On a clean done it pops the frame.

## 7. Known limitations
- Single egress port; the 4x4 crossbar is not yet built.
- Queue occupancy is modelled in the testbench, not by real VOQs.
- Single clock domain; RX recovered-clock CDC not yet implemented.
- CBS slopes must be pre-scaled by software; no hardware divider.
