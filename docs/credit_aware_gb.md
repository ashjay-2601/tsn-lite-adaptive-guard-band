# Credit-aware guard band — design note and negative result

## The idea

The adaptive guard band asks one question: *does this frame fit before the
gate shuts?* For an 802.1Qav shaped class that is incomplete. Credit drains at
sendSlope while transmitting, and `tsn_sched_top` gates only the START on
`credit_ok`; once `tx_engine` is busy the frame runs to completion. That is
correct Qav behaviour — Qav is a shaper, not a policer, and frames are atomic.

The consequence is **credit overshoot**. A class that starts a 1522 B frame
with credit at +1 finishes deeply negative and is locked out until idleSlope
climbs back. Worst-case lockout is set by the largest frame, not the
configured share.

So: add a second admission question. *Does this frame fit before CREDIT runs
out?*

```
clocks_to_stall = credit / |sendSlope|
bytes_to_stall  = clocks_to_stall * BYTES_PER_CLK
```

A divider on this path is unacceptable, so software supplies the reciprocal at
configuration time — the same treatment the slopes themselves already get:

```
inv_send_q8    = 2048 / |sendSlope_bytes_per_clk|      (Q8.8, CSR 0x300+4c)
bytes_to_stall = (credit_b * inv_send_q8) >> 8
```

One 16x16 multiply. The cut point becomes `min(window limit, credit limit)`.
`inv_send_q8 = 0` marks a class unshaped and bypasses the check entirely.

## Result: it does what it says, and it is not worth it

Class 6 shaped to 25%, mixed 64–1522 B frames, class 0 unshaped filler,
gates always open, 400 000 clocks.

| Metric | Credit-aware off | Credit-aware on |
|---|---:|---:|
| Class 6 bytes | 1 495 430 | 635 976 |
| Class 0 bytes | 1 634 576 | 2 448 456 |
| Worst credit excursion | **−1140 B** | **0 B** |
| Worst class-6 service gap | **2048 ns** | **3872 ns** |
| Fragments generated | 1 | 1036 |

The mechanism works exactly as designed: credit never goes negative. But the
shaped class loses 57% of its throughput, generates a thousand fragments, and
**its worst-case service gap gets worse, not better** — which was the whole
motivation.

## Why it fails

Qav's overshoot is deliberate. `hiCredit` and `loCredit` exist precisely to
bound it, and the standard's authors accepted atomic frames as the price of
not fragmenting everything. Refusing to start costs more than the overshoot
did, because a refused frame yields the wire to a lower-priority class and
then has to wait for a fresh admission opportunity — which is a *longer* gap
than simply going negative and recovering.

## Two bugs the attempt exposed

**Fragment explosion.** The first version had no minimum-progress rule.
idleSlope tops credit up every clock, so the class was never actually blocked
and shredded every frame into 64 B pieces: **10 878 fragments and zero bytes
for best effort.** Fixed with `MIN_CRED_FRAG = 256`.

**No arbiter fallback.** `tx_arbiter` nominates a single candidate by strict
priority. When the guard band refused it, nothing transmitted at all — the
port went idle rather than offering the next class down. This was latent
before: the window-driven guard band refuses rarely and always resolves at the
next gate transition, so it never showed. Fixed with a per-class `inhibit`
mask fed back into the arbiter.

That second one is the more valuable find. It is a real architectural gap in
the scheduler, exposed only because a new feature started refusing candidates
often enough to matter.

## Status

Shipped, **disabled by default** (`inv_send_q8 = 0` at reset). The A/B
headline is unchanged at 12.76%, and every existing bench passes. The inhibit
feedback is gated on credit-shaped classes because inhibiting on window-driven
refusals cost 12.76% → 12.06% for no benefit.

Kept rather than reverted because the negative result is worth more than the
feature would have been: it is direct evidence for why Qav is specified the
way it is.
