// ============================================================================
// gb_props.sv -- formal properties for the adaptive guard band
//
// Bind-style wrapper for SymbiYosys bounded model checking.  Run with:
//     sby -f formal/gb_props.sby
//
// These are the four claims the design has to survive.  P1 and P2 are the ones
// that actually matter: they are the safety argument for why replacing a
// worst-case constant with a per-frame computation does not break determinism.
// ============================================================================
`default_nettype none

module gb_props (
    input wire        clk,
    input wire        rst_n,
    input wire        mode_adaptive,
    input wire        preempt_en,
    input wire        hol_valid,
    input wire [13:0] hol_len_b,
    input wire        hol_preemptable,
    input wire [31:0] remaining_ns
);

    localparam integer NS_PER_B_Q8   = 205;
    localparam integer OVERHEAD_B    = 20;
    localparam integer MIN_FRAG_B    = 64;
    localparam integer BYTES_PER_CLK = 8;
    localparam integer PIPE_LAT_NS   = 13;

    wire        allow_start, do_preempt;
    wire [13:0] frag_bytes;
    wire [31:0] gb_reclaim_ns;

    guard_band dut (
        .clk(clk), .rst_n(rst_n),
        .mode_adaptive(mode_adaptive), .preempt_en(preempt_en),
        .hol_valid(hol_valid), .hol_len_b(hol_len_b),
        .hol_preemptable(hol_preemptable), .remaining_ns(remaining_ns),
        .allow_start(allow_start), .do_preempt(do_preempt),
        .frag_bytes(frag_bytes), .gb_reclaim_ns(gb_reclaim_ns)
    );

    // constrain the input space to legal Ethernet frames
    always @* begin
        assume (hol_len_b >= 64 && hol_len_b <= 1522);
        assume (remaining_ns <= 32'd1_000_000);
    end

    // reference model, computed independently of the DUT's internals
    wire [31:0] rem_eff_ref = (remaining_ns > PIPE_LAT_NS) ?
                              (remaining_ns - PIPE_LAT_NS) : 32'd0;
    wire [31:0] txt_ref     = (($past(hol_len_b) + OVERHEAD_B) * NS_PER_B_Q8
                               + 255) / 256;
    // bytes the serialiser will actually push for a burst of N bytes
    function automatic [31:0] wire_ns (input [13:0] n);
        wire_ns = (((n + BYTES_PER_CLK - 1) / BYTES_PER_CLK) * BYTES_PER_CLK)
                  * NS_PER_B_Q8 / 256;
    endfunction

    // ---------------------------------------------------------------------
    // P1  A permitted whole-frame transmission always fits in the window.
    //     This is the core determinism claim: adaptive mode must never leak
    //     into a protected window.
    // ---------------------------------------------------------------------
    p1_fits: assert property (@(posedge clk) disable iff (!rst_n)
        (allow_start && !do_preempt && $past(mode_adaptive))
        |-> (txt_ref <= $past(rem_eff_ref)));

    // ---------------------------------------------------------------------
    // P2  Every fragment is legal on both sides of the cut.  Missing the
    //     tail half of this check is the classic 802.3br bug.
    // ---------------------------------------------------------------------
    p2_head_legal: assert property (@(posedge clk) disable iff (!rst_n)
        do_preempt |-> (frag_bytes >= MIN_FRAG_B));

    p2_tail_legal: assert property (@(posedge clk) disable iff (!rst_n)
        do_preempt |-> (($past(hol_len_b) - frag_bytes) >= MIN_FRAG_B));

    // ---------------------------------------------------------------------
    // P3  A fragment is aligned to the serialiser width, so the cut is not
    //     rounded up onto the wire past the window boundary.
    // ---------------------------------------------------------------------
    p3_aligned: assert property (@(posedge clk) disable iff (!rst_n)
        do_preempt |-> ((frag_bytes % BYTES_PER_CLK) == 0));

    p3_frag_fits: assert property (@(posedge clk) disable iff (!rst_n)
        do_preempt |-> (wire_ns(frag_bytes) <= $past(rem_eff_ref)));

    // ---------------------------------------------------------------------
    // P4  Adaptive mode is a strict superset of static mode: anything the
    //     conservative policy would have permitted, the adaptive policy also
    //     permits.  Proves the optimisation never *loses* throughput.
    // ---------------------------------------------------------------------
    p4_superset: assert property (@(posedge clk) disable iff (!rst_n)
        ($past(mode_adaptive) && $past(hol_valid) &&
         ($past(rem_eff_ref) >= 1234))
        |-> allow_start);

    // ---------------------------------------------------------------------
    // P5  Static mode is unchanged by the preemption logic -- the A/B
    //     comparison is only fair if the baseline is a true baseline.
    // ---------------------------------------------------------------------
    p5_static_clean: assert property (@(posedge clk) disable iff (!rst_n)
        !$past(mode_adaptive) |-> !do_preempt);

    // cover: prove a cut is actually reachable, not vacuously absent
    c1_cut_happens: cover property (@(posedge clk) disable iff (!rst_n)
        do_preempt);

endmodule

`default_nettype wire
