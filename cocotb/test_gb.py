"""
Constrained-random verification of the adaptive guard band, with a functional
coverage model.

The Verilog testbenches drive the whole scheduler and measure aggregate
throughput.  This targets the decision function itself: for a random frame
length, preemptability and window remainder, does guard_band make the call an
independent reference model would make?

The coverage model is the point.  It crosses three axes that together describe
every situation the block can be in:

    length bucket   x   window pressure   x   outcome

"window pressure" is remaining_ns expressed relative to what the frame needs,
which is the axis that actually matters -- a 1500 B frame with 200 ns left and
a 64 B frame with 200 ns left are completely different cases that a raw
remaining_ns bin would merge.

It also bins the cut point modulo the serialiser width, which closes an item
left open in the bug log: fragment alignment could not be shown to matter
under the Verilog stimulus, and this reports directly whether unaligned cut
points are even being generated.
"""

import random
from collections import defaultdict

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.types import LogicArray

NS_PER_B_Q8 = 205
B_PER_NS_Q8 = 320
OVERHEAD_B = 20
MIN_FRAG_B = 64
BYTES_PER_CLK = 8
MAX_SDU_B = 1522
PIPE_LAT_NS = 13
STATIC_TXT = ((MAX_SDU_B + OVERHEAD_B) * NS_PER_B_Q8 + 255) // 256


def model(mode_adaptive, preempt_en, valid, length, preemptable, remaining):
    """Independent reference implementation of the guard band decision."""
    rem_eff = remaining - PIPE_LAT_NS if remaining > PIPE_LAT_NS else 0

    txt_q8 = (length + OVERHEAD_B) * NS_PER_B_Q8
    tx_time = (txt_q8 >> 8) + (1 if txt_q8 & 0xFF else 0)

    fb_raw = (rem_eff * B_PER_NS_Q8) >> 8
    fb_hdr = fb_raw - OVERHEAD_B if fb_raw > OVERHEAD_B else 0
    fb_net = fb_hdr & ~(BYTES_PER_CLK - 1)
    # fb_hdr is the pre-alignment cut point; the difference is what the
    # alignment mask actually removes

    head_ok = fb_net >= MIN_FRAG_B
    tail_ok = length > fb_net and (length - fb_net) >= MIN_FRAG_B
    fits = tx_time <= rem_eff
    cuttable = preempt_en and preemptable and head_ok and tail_ok

    allow_adp = valid and (fits or cuttable)
    allow_sta = valid and (rem_eff >= STATIC_TXT)

    allow = allow_adp if mode_adaptive else allow_sta
    cut = bool(mode_adaptive and allow_adp and not fits and cuttable)
    return allow, cut, fb_net, fits, fb_hdr


def len_bucket(n):
    if n <= 128:
        return "tiny"
    if n <= 512:
        return "small"
    if n <= 1024:
        return "mid"
    return "jumbo"


def pressure_bucket(remaining, length):
    """Window remainder relative to what this frame actually needs."""
    need = ((length + OVERHEAD_B) * NS_PER_B_Q8 + 255) // 256
    if need == 0:
        return "n/a"
    r = remaining / need
    if r < 0.25:
        return "<25%"
    if r < 0.75:
        return "25-75%"
    if r < 1.0:
        return "75-100%"
    return ">=100%"


@cocotb.test()
async def gb_random(dut):
    cocotb.start_soon(Clock(dut.clk, 6400, unit="ps").start())

    dut.rst_n.value = 0
    dut.mode_adaptive.value = 0
    dut.preempt_en.value = 0
    dut.hol_valid.value = 0
    dut.hol_len_b.value = 0
    dut.hol_preemptable.value = 0
    dut.remaining_ns.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    random.seed(20260902)

    cov = defaultdict(int)
    cut_align = defaultdict(int)
    mismatches = 0
    N = 20000

    prev = None
    for _ in range(N):
        mode = random.randint(0, 1)
        pen = random.randint(0, 1)
        valid = 1 if random.random() < 0.95 else 0
        length = random.choice(
            [random.randint(64, 128), random.randint(64, 1522),
             random.randint(1400, 1522), random.choice([64, 65, 127, 128, 1522])]
        )
        pre = random.randint(0, 1)
        remaining = random.choice(
            [random.randint(0, 200), random.randint(0, 2000),
             random.randint(0, 20000), random.choice([0, 1, 13, 14, 1234, 1235])]
        )

        dut.mode_adaptive.value = mode
        dut.preempt_en.value = pen
        dut.hol_valid.value = valid
        dut.hol_len_b.value = length
        dut.hol_preemptable.value = pre
        dut.remaining_ns.value = remaining

        await RisingEdge(dut.clk)

        # outputs are registered: check the stimulus applied one cycle ago
        if prev is not None:
            exp_allow, exp_cut, exp_frag, exp_fits, exp_hdr = model(*prev)
            got_allow = int(dut.allow_start.value)
            got_cut = int(dut.do_preempt.value)
            got_frag = int(dut.frag_bytes.value)

            if got_allow != int(exp_allow) or got_cut != int(exp_cut):
                mismatches += 1
                if mismatches <= 5:
                    dut._log.error(
                        f"mismatch stim={prev} "
                        f"allow {got_allow}!={int(exp_allow)} "
                        f"cut {got_cut}!={int(exp_cut)}"
                    )
            if exp_cut and got_frag != exp_frag:
                mismatches += 1

            # ---- coverage ----
            _, _, plen, ppre, prem = prev[1], prev[0], prev[3], prev[4], prev[5]
            outcome = "cut" if exp_cut else ("whole" if exp_allow else "blocked")
            cov[(len_bucket(plen), pressure_bucket(prem, plen), outcome)] += 1
            if exp_cut:
                # measure the PRE-alignment cut point: this is what tells us
                # whether the alignment mask is doing any work at all
                cut_align[exp_hdr % BYTES_PER_CLK] += 1

        prev = (mode, pen, valid, length, pre, remaining)

    # ------------------------------------------------------------------ report
    buckets = ["tiny", "small", "mid", "jumbo"]
    pressures = ["<25%", "25-75%", "75-100%", ">=100%"]
    outcomes = ["whole", "cut", "blocked"]

    def reachable(b, p, o):
        # "whole" requires the frame to fit, which requires >=100% pressure
        if o == "whole" and p != ">=100%":
            return False
        # a frame that fits is sent whole, never cut
        if o == "cut" and p == ">=100%":
            return False
        # a cut needs >=64 B on both sides, so the frame must be >=128 B;
        # only one length in the "tiny" bucket qualifies, and only at a
        # narrow window remainder
        if o == "cut" and b == "tiny" and p in ("<25%", "75-100%"):
            return False
        return True

    total = len(buckets) * len(pressures) * len(outcomes)
    reach = [(b, p, o) for b in buckets for p in pressures for o in outcomes
             if reachable(b, p, o)]
    hit = sum(1 for k in reach if cov[k] > 0)

    dut._log.info("")
    dut._log.info("functional coverage: length x window-pressure x outcome")
    dut._log.info(f"{'length':>7} {'pressure':>9} " +
                  " ".join(f"{o:>8}" for o in outcomes))
    for b in buckets:
        for p in pressures:
            cells = []
            for o in outcomes:
                if not reachable(b, p, o):
                    cells.append(f"{'--':>8}")
                else:
                    cells.append(f"{cov[(b, p, o)]:>8}")
            dut._log.info(f"{b:>7} {p:>9} " + " ".join(cells))

    dut._log.info("")
    dut._log.info(f"total bins           : {total}")
    dut._log.info(f"structurally unreachable: {total - len(reach)} "
                  f"(marked --; excluded from the score)")
    dut._log.info(f"reachable bins hit   : {hit}/{len(reach)} "
                  f"({100.0*hit/len(reach):.1f}%)")
    if hit < len(reach):
        miss = [k for k in reach if cov[k] == 0]
        dut._log.info(f"unhit reachable bins : {miss}")

    dut._log.info("")
    dut._log.info(f"pre-alignment cut point mod {BYTES_PER_CLK}: {dict(cut_align)}")
    unaligned = sum(v for k, v in cut_align.items() if k != 0)
    total_cuts = sum(cut_align.values())
    if total_cuts:
        dut._log.info(
            f"  {unaligned}/{total_cuts} cuts ({100.0*unaligned/total_cuts:.1f}%) "
            f"land off an 8B boundary and are floored by the alignment mask")
        if unaligned == 0:
            dut._log.info("  -> mask never fires under this stimulus")
        else:
            dut._log.info("  -> the alignment mask is load-bearing: without it "
                          "these cuts would round UP past the window boundary")

    assert mismatches == 0, f"{mismatches} mismatches against reference model"
    assert hit >= len(reach) * 0.9, f"only {hit}/{len(reach)} reachable bins hit"
