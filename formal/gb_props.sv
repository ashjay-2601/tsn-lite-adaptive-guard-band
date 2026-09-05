// ============================================================================
// gb_props.sv -- formal properties for the adaptive guard band
//
// Written as immediate assertions inside clocked blocks rather than SVA
// concurrent assertions: Yosys 0.33 does not parse `assert property (@(...))`,
// and rewriting is cheaper than depending on a newer front end.  The $past
// operator is likewise replaced with explicit one-cycle delay registers, which
// makes the timing relationship visible rather than implied.
//
// guard_band registers all of its outputs, so the verdict visible at cycle N
// belongs to the stimulus applied at cycle N-1.  Every property therefore
// compares the current outputs against a reference model computed from the
// *delayed* inputs.  Getting that alignment wrong is the usual way a formal
// run passes while proving nothing.
//
// The inputs of this module are undriven, so the solver treats them as free
// variables and explores every legal combination.  The assumes narrow that to
// legal Ethernet frames and plausible window remainders.
//
// Run:  cd formal && sby -f gb_props.sby
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
    localparam integer B_PER_NS_Q8   = 320;
    localparam integer OVERHEAD_B    = 20;
    localparam integer MIN_FRAG_B    = 64;
    localparam integer BYTES_PER_CLK = 8;
    localparam integer PIPE_LAT_NS   = 13;
    localparam integer STATIC_TXT    =
        (((1522 + OVERHEAD_B) * NS_PER_B_Q8) + 255) / 256;   // = 1235

    always @* begin
        assume (hol_len_b >= 14'd64 && hol_len_b <= 14'd1522);
        assume (remaining_ns <= 32'd1_000_000);
    end

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

    // ---- one-cycle delayed stimulus (replaces $past) ------------------------
    reg        p_mode, p_pen, p_valid, p_pre, p_rstn, past_ok;
    reg [13:0] p_len;
    reg [31:0] p_rem;

    initial past_ok = 1'b0;

    always @(posedge clk) begin
        p_mode  <= mode_adaptive;
        p_pen   <= preempt_en;
        p_valid <= hol_valid;
        p_pre   <= hol_preemptable;
        p_len   <= hol_len_b;
        p_rem   <= remaining_ns;
        p_rstn  <= rst_n;
        past_ok <= 1'b1;
    end

    // ---- reference model over the delayed stimulus --------------------------
    wire [31:0] rem_eff = (p_rem > PIPE_LAT_NS) ? (p_rem - PIPE_LAT_NS) : 32'd0;

    wire [23:0] txt_q8  = (p_len + OVERHEAD_B[13:0]) * NS_PER_B_Q8[9:0];
    wire [31:0] tx_time = {16'd0, txt_q8[23:8]} + {31'd0, |txt_q8[7:0]};

    wire [33:0] fb_q8   = rem_eff[23:0] * B_PER_NS_Q8[9:0];
    wire [13:0] fb_raw  = fb_q8[21:8];
    wire [13:0] fb_hdr  = (fb_raw > OVERHEAD_B[13:0]) ?
                          (fb_raw - OVERHEAD_B[13:0]) : 14'd0;
    wire [13:0] fb_net  = fb_hdr & ~(BYTES_PER_CLK[13:0] - 14'd1);

    wire [23:0] wire_q8 = fb_net * NS_PER_B_Q8[9:0];
    wire [31:0] frag_ns = {16'd0, wire_q8[23:8]} + {31'd0, |wire_q8[7:0]};

    wire live = past_ok && rst_n && p_rstn;

    always @(posedge clk) begin
        if (live) begin

            // -- P1: a permitted whole-frame transmission always fits --------
            if (allow_start && !do_preempt && p_mode)
                assert (tx_time <= rem_eff);

            // -- P2: both sides of a cut are legal ---------------------------
            if (do_preempt) begin
                assert (frag_bytes >= MIN_FRAG_B[13:0]);
                assert (p_len > frag_bytes);
                assert ((p_len - frag_bytes) >= MIN_FRAG_B[13:0]);
            end

            // -- P3: a cut is aligned to the serialiser and fits -------------
            if (do_preempt) begin
                assert ((frag_bytes & (BYTES_PER_CLK[13:0] - 14'd1)) == 14'd0);
                assert (frag_ns <= rem_eff);
            end

            // -- P4: adaptive is a strict superset of static -----------------
            if (p_mode && p_valid && (rem_eff >= STATIC_TXT[31:0]))
                assert (allow_start);

            // -- P5: static mode never fragments -----------------------------
            if (!p_mode)
                assert (!do_preempt);

            // -- P6: nothing permitted when there is no frame ----------------
            if (!p_valid)
                assert (!allow_start && !do_preempt);

            // -- covers: prove the interesting states are reachable ----------
            cover (do_preempt);
            cover (allow_start && !do_preempt && p_mode);
            cover (!allow_start && p_valid && p_mode);
            cover (do_preempt && (fb_hdr != fb_net));
        end
    end

endmodule

`default_nettype wire
