// ============================================================================
// guard_band.v -- Preemption-Aware Adaptive Guard Band          *** NOVELTY ***
//
// Standard 802.1Qbv closes a gate a full maxSDU transmission time before the
// window boundary, unconditionally.  On a 10G link with a 1522 B MTU that is
//     (1522 + 20) * 0.8 ns  =  1234 ns
// of dead air per gate close, per cycle, regardless of what is actually at the
// head of the queue.  With a 20 us cycle and two protected windows that is
// ~12 % of link capacity thrown away.
//
// This block replaces the constant with a per-frame decision:
//
//   rem_eff    = remaining_ns - PIPE_LAT_NS      // decision is made early
//   tx_time_ns = ceil((len + 20) * ns_per_byte)
//   fits       = tx_time_ns <= rem_eff
//   frag_bytes = floor_align(rem_eff * bytes_per_ns) - overhead
//   cuttable   = preempt_en & preemptable
//              & frag_bytes         >= 64       // head fragment legal
//              & (len - frag_bytes) >= 64       // *and the tail is legal too*
//   allow_start = fits | cuttable
//
// Three details that are easy to get wrong and are the substance of the block:
//
//  1. PIPE_LAT_NS.  The verdict is registered here, the arbiter registers its
//     candidate, and tx_engine registers its start.  The wire therefore moves
//     PIPE_LAT_NS after remaining_ns was sampled.  Without this subtraction
//     every burst overruns the window by two clocks.
//
//  2. Fragment alignment.  The serialiser moves BYTES_PER_CLK bytes per clock,
//     so a cut at an unaligned byte count is rounded *up* on the wire and
//     overruns.  frag_bytes is floored to a BYTES_PER_CLK multiple.
//
//  3. The tail check.  Cutting so that only 40 B remain produces an illegal
//     continuation fragment.  Both sides of the cut must be >= MIN_FRAG_B.
//
// Arithmetic: ns_per_byte at 10 Gb/s = 0.8, held as NS_PER_B_Q8 = 205
// (0.80078) so tx_time rounds up; the inverse B_PER_NS_Q8 = 320 (1.25) with a
// floor so frag_bytes rounds down.  Every rounding error is in the safe
// direction.  No dividers; one 14x10 and one 24x10 multiply.
//
// mode_adaptive=0 restores textbook behaviour so both policies can be A/B
// compared in one netlist with a single CSR bit.
// ============================================================================
`default_nettype none

module guard_band #(
    parameter integer NS_PER_B_Q8   = 205,   // ceil(0.8  * 256) @ 10 Gb/s
    parameter integer B_PER_NS_Q8   = 320,   //      1.25 * 256  @ 10 Gb/s
    parameter integer OVERHEAD_B    = 20,    // 8 preamble/SFD + 12 IPG
    parameter integer MIN_FRAG_B    = 64,    // 802.3br minimum fragment
    parameter integer MAX_SDU_B     = 1522,  // static guard band basis
    parameter integer BYTES_PER_CLK = 8,     // serialiser width
    parameter integer PIPE_LAT_NS   = 13     // ceil(2 clocks @ 6.4 ns)
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         mode_adaptive,       // 0 = static GB, 1 = adaptive
    input  wire         preempt_en,

    input  wire         hol_valid,
    input  wire [13:0]  hol_len_b,
    input  wire         hol_preemptable,

    input  wire [31:0]  remaining_ns,

    output reg          allow_start,
    output reg          do_preempt,
    output reg  [13:0]  frag_bytes,
    output reg  [31:0]  gb_reclaim_ns
);

    // ---- effective window, after pipeline latency --------------------------
    wire [31:0] rem_eff = (remaining_ns > PIPE_LAT_NS[31:0]) ?
                          (remaining_ns - PIPE_LAT_NS[31:0]) : 32'd0;

    // ---- transmission time of the head-of-line frame -----------------------
    wire [13:0] len_tot = hol_len_b + OVERHEAD_B[13:0];
    wire [23:0] txt_q8  = len_tot * NS_PER_B_Q8[9:0];
    wire [31:0] tx_time = {16'd0, txt_q8[23:8]} + {31'd0, |txt_q8[7:0]};  // ceil

    // ---- static reference guard band ---------------------------------------
    localparam integer STATIC_TXT =
        (((MAX_SDU_B + OVERHEAD_B) * NS_PER_B_Q8) + 255) / 256;

    // ---- where the cut lands ------------------------------------------------
    wire [33:0] fb_q8  = rem_eff[23:0] * B_PER_NS_Q8[9:0];
    wire [13:0] fb_raw = fb_q8[21:8];                            // floor to byte
    wire [13:0] fb_hdr = (fb_raw > OVERHEAD_B[13:0]) ?
                         (fb_raw - OVERHEAD_B[13:0]) : 14'd0;
    // floor to the serialiser granularity, else the cut rounds up on the wire
    wire [13:0] fb_net = fb_hdr & ~(BYTES_PER_CLK[13:0] - 14'd1);

    wire head_ok = (fb_net >= MIN_FRAG_B[13:0]);
    wire tail_ok = (hol_len_b > fb_net) &&
                   ((hol_len_b - fb_net) >= MIN_FRAG_B[13:0]);

    wire fits     = (tx_time <= rem_eff);
    wire cuttable = preempt_en && hol_preemptable && head_ok && tail_ok;

    wire allow_adp = hol_valid && (fits || cuttable);
    wire allow_sta = hol_valid && (rem_eff >= STATIC_TXT[31:0]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            allow_start   <= 1'b0;
            do_preempt    <= 1'b0;
            frag_bytes    <= 14'd0;
            gb_reclaim_ns <= 32'd0;
        end else begin
            allow_start   <= mode_adaptive ? allow_adp : allow_sta;
            do_preempt    <= mode_adaptive && allow_adp && !fits && cuttable;
            frag_bytes    <= fb_net;
            // instrumentation: window time the static policy would have blanked
            gb_reclaim_ns <= (mode_adaptive && allow_adp && !allow_sta) ?
                             rem_eff : 32'd0;
        end
    end

endmodule

`default_nettype wire
