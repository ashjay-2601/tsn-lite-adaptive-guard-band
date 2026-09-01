// ============================================================================
// tsn_sched_top.v -- TSN-Lite egress scheduler subsystem
//
//   AXI4-Lite  ->  csr_axil  ->  { GCL, CBS config, control }
//                                        |
//   ptp_clock -> gcl_ctrl -> gate_open, remaining_ns
//                                        |
//   queue status -> tx_arbiter -> candidate -> guard_band -> tx_engine -> wire
//                                        ^
//                                   cbs_shaper x8
//
// The queue manager lives outside this block (VOQ + packet buffer).  This
// module is the unit that gets hardened to GDSII: it is pure standard-cell
// logic with no memory macros.
// ============================================================================
`default_nettype none

module tsn_sched_top #(
    parameter integer N_ENTRY     = 16,
    parameter [31:0]  PTP_INCR_Q16 = 32'd419430,   // 6.4 ns
    parameter integer BYTES_PER_CLK = 8
) (
    input  wire         clk,
    input  wire         rst_n,

    // AXI4-Lite
    input  wire [11:0]  s_awaddr,
    input  wire         s_awvalid,
    output wire         s_awready,
    input  wire [31:0]  s_wdata,
    input  wire [3:0]   s_wstrb,
    input  wire         s_wvalid,
    output wire         s_wready,
    output wire [1:0]   s_bresp,
    output wire         s_bvalid,
    input  wire         s_bready,
    input  wire [11:0]  s_araddr,
    input  wire         s_arvalid,
    output wire         s_arready,
    output wire [31:0]  s_rdata,
    output wire [1:0]   s_rresp,
    output wire         s_rvalid,
    input  wire         s_rready,

    // queue manager interface
    input  wire [7:0]   q_nonempty,
    input  wire [111:0] q_len_flat,

    output wire         tx_done,
    output wire [2:0]   tx_done_class,
    output wire [13:0]  tx_done_bytes,
    output wire         tx_done_truncated,
    output wire [13:0]  tx_done_residual,

    // observation
    output wire [47:0]  time_ns,
    output wire [7:0]   gate_open,
    output wire [31:0]  remaining_ns,
    output wire         tx_busy,
    output wire [2:0]   tx_class,
    output wire [1:0]   tx_smd
);

    // ---------------------------------------------------------------- config
    wire        cfg_enable, cfg_mode_adaptive, cfg_preempt_en, cfg_apply;
    wire [4:0]  cfg_gcl_len;
    wire [47:0] cfg_base_time;
    wire [7:0]  cfg_preempt_mask;
    wire [N_ENTRY*8-1:0]  gcl_mask_flat;
    wire [N_ENTRY*32-1:0] gcl_ival_flat;
    wire [255:0] idle_slope_flat, send_slope_flat, hi_credit_flat, lo_credit_flat;

    wire        gb_allow, gb_preempt;
    wire [13:0] gb_frag;
    wire [31:0] gb_reclaim;

    wire        cand_valid, cand_preempt;
    wire [2:0]  cand_class;
    wire [13:0] cand_len;

    wire        busy;
    wire [7:0]  credit_ok;

    // ------------------------------------------------------------------ time
    ptp_clock #(.INCR_Q16(PTP_INCR_Q16)) u_ptp (
        .clk(clk), .rst_n(rst_n),
        .set_valid(1'b0), .set_time_ns(48'd0), .rate_adj_q16(16'sd0),
        .time_ns(time_ns), .time_q16()
    );

    // ------------------------------------------------------------------- Qbv
    gcl_ctrl #(.N_ENTRY(N_ENTRY), .IDX_W(4)) u_gcl (
        .clk(clk), .rst_n(rst_n),
        .enable(cfg_enable), .time_ns(time_ns),
        .gcl_mask_flat(gcl_mask_flat), .gcl_ival_flat(gcl_ival_flat),
        .gcl_len(cfg_gcl_len), .base_time_ns(cfg_base_time),
        .cfg_apply(cfg_apply),
        .gate_open(gate_open), .remaining_ns(remaining_ns),
        .entry_idx(), .running()
    );

    // ------------------------------------------------------------------- Qav
    genvar c;
    generate
        for (c = 0; c < 8; c = c + 1) begin : G_CBS
            cbs_shaper u_cbs (
                .clk(clk), .rst_n(rst_n),
                .enable(cfg_enable),
                .idle_slope_q16($signed(idle_slope_flat[c*32 +: 32])),
                .send_slope_q16($signed(send_slope_flat[c*32 +: 32])),
                .hi_credit_q16 ($signed(hi_credit_flat [c*32 +: 32])),
                .lo_credit_q16 ($signed(lo_credit_flat [c*32 +: 32])),
                .q_nonempty(q_nonempty[c]),
                .transmitting(busy && (tx_class == c[2:0])),
                .credit_ok(credit_ok[c]),
                .credit_q16()
            );
        end
    endgenerate

    // -------------------------------------------------------------- arbitrate
    tx_arbiter u_arb (
        .clk(clk), .rst_n(rst_n),
        .q_nonempty(q_nonempty), .gate_open(gate_open),
        .credit_ok(credit_ok), .preemptable(cfg_preempt_mask),
        .q_len_flat(q_len_flat),
        .cand_valid(cand_valid), .cand_class(cand_class),
        .cand_len(cand_len), .cand_preempt(cand_preempt)
    );

    // pipeline the candidate to stay aligned with the registered guard-band verdict
    reg        cand_valid_q;
    reg [2:0]  cand_class_q;
    reg [13:0] cand_len_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cand_valid_q <= 1'b0; cand_class_q <= 3'd0;
            cand_len_q   <= 14'd0;
        end else begin
            cand_valid_q <= cand_valid; cand_class_q <= cand_class;
            cand_len_q   <= cand_len;
        end
    end

    // ------------------------------------------------------------ guard band
    guard_band u_gb (
        .clk(clk), .rst_n(rst_n),
        .mode_adaptive(cfg_mode_adaptive), .preempt_en(cfg_preempt_en),
        .hol_valid(cand_valid), .hol_len_b(cand_len),
        .hol_preemptable(cand_preempt),
        .remaining_ns(remaining_ns),
        .allow_start(gb_allow), .do_preempt(gb_preempt),
        .frag_bytes(gb_frag), .gb_reclaim_ns(gb_reclaim)
    );

    // -------------------------------------------------------- fragment tracking
    reg [7:0] frag_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) frag_pending <= 8'h00;
        else if (tx_done) begin
            if (tx_done_truncated) frag_pending[tx_done_class] <= 1'b1;
            else                   frag_pending[tx_done_class] <= 1'b0;
        end
    end

    // The guard-band verdict is two cycles old by the time it is usable.  A
    // gate close inside that shadow would otherwise launch a stale frame with
    // a stale length, so re-qualify against the live gate and credit state and
    // require the candidate to be unchanged across the pipeline.
    wire cand_stable = cand_valid && cand_valid_q &&
                       (cand_class == cand_class_q) &&
                       (cand_len   == cand_len_q);

    wire start = !busy && cand_valid_q && gb_allow && cand_stable &&
                 gate_open[cand_class_q] && credit_ok[cand_class_q];

    tx_engine #(.BYTES_PER_CLK(BYTES_PER_CLK)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .start(start), .start_class(cand_class_q), .start_len(cand_len_q),
        .start_preempt(gb_preempt), .frag_len(gb_frag),
        .is_continuation(frag_pending[cand_class_q]),
        .busy(busy), .cur_class(tx_class), .smd(tx_smd),
        .done(tx_done), .done_class(tx_done_class), .done_bytes(tx_done_bytes),
        .done_truncated(tx_done_truncated), .done_residual(tx_done_residual)
    );

    assign tx_busy = busy;

    // -------------------------------------------------------------------- CSR
    csr_axil #(.N_ENTRY(N_ENTRY)) u_csr (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid),
        .s_wready(s_wready), .s_bresp(s_bresp), .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rvalid(s_rvalid),
        .s_rready(s_rready),
        .cfg_enable(cfg_enable), .cfg_mode_adaptive(cfg_mode_adaptive),
        .cfg_preempt_en(cfg_preempt_en), .cfg_gcl_len(cfg_gcl_len),
        .cfg_base_time(cfg_base_time), .cfg_apply(cfg_apply),
        .cfg_preempt_mask(cfg_preempt_mask),
        .gcl_mask_flat(gcl_mask_flat), .gcl_ival_flat(gcl_ival_flat),
        .idle_slope_flat(idle_slope_flat), .send_slope_flat(send_slope_flat),
        .hi_credit_flat(hi_credit_flat), .lo_credit_flat(lo_credit_flat),
        .ev_tx_done(tx_done),
        .ev_tx_express(!cfg_preempt_mask[tx_done_class]),
        .ev_tx_bytes(tx_done_bytes),
        .ev_preempt(tx_done && tx_done_truncated),
        .ev_reclaim_ns(start ? gb_reclaim : 32'd0)
    );

endmodule

`default_nettype wire
