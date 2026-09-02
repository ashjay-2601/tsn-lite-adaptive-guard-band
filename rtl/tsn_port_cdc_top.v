// ============================================================================
// tsn_port_cdc_top.v -- two clock domains
//
//   rx_clk domain          |          core clk domain
//   ---------------------- | ---------------------------------------------
//   AXI-Stream ingress     |
//   async_fifo write side ===> async_fifo read side
//                          |    -> frame_parser -> voq_manager -> scheduler
//
// rx_clk is recovered from the incoming serial stream.  It is nominally the
// same frequency as the core clock but has no phase relationship and a real
// ppm offset, so the two are asynchronous and every crossing is explicit.
//
// Only ONE thing crosses: the FIFO's Gray-coded pointers.  The stream payload
// rides in the FIFO memory, which needs no synchroniser because the pointer
// handshake guarantees data is stable long before the far side may read it.
// Parsing happens after the crossing, in the core domain, so no parser state
// crosses at all -- moving the parser to the RX side would add descriptor and
// class crossings for no benefit.
//
// Each domain gets its own reset_sync instance off the same asynchronous
// reset. Sharing one would reintroduce the reset-domain crossing the
// synchroniser exists to remove.
//
// Backpressure: fifo_full drives rx_tready, so the far end stalls rather than
// the FIFO overflowing.  A dropped-on-full counter is exposed because in a
// real port the RX side cannot be back-pressured -- the wire keeps arriving --
// and the honest failure mode is a counted drop, not a silent corruption.
// ============================================================================
`default_nettype none

module tsn_port_cdc_top #(
    parameter integer CELLS  = 128,
    parameter integer ADDR_W = 7,
    parameter integer DEPTH  = 8,
    parameter integer FIFO_A = 5
) (
    input  wire         core_clk,
    input  wire         rx_clk,
    input  wire         arst_n,          // asynchronous, both domains

    // AXI4-Lite (core domain)
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

    // ingress, rx_clk domain
    input  wire [63:0]  rx_tdata,
    input  wire [7:0]   rx_tkeep,
    input  wire         rx_tvalid,
    output wire         rx_tready,
    input  wire         rx_tlast,

    // egress, core domain
    output wire         tx_tvalid,
    output wire [63:0]  tx_tdata,
    output wire [7:0]   tx_tkeep,
    output wire         tx_tlast,

    // observation, core domain
    output wire [47:0]  time_ns,
    output wire [7:0]   gate_open,
    output wire [31:0]  remaining_ns,
    output wire         tx_busy,
    output wire [2:0]   tx_class,
    output wire [1:0]   tx_smd,
    output wire [7:0]   q_nonempty,
    output wire [ADDR_W:0] cells_used,
    output wire [15:0]  stat_drops,
    output wire [15:0]  stat_enq,
    output reg  [15:0]  stat_fifo_drops
);

    // ---- per-domain reset synchronisers ------------------------------------
    wire core_rst_n, rx_rst_n;

    reset_sync u_rst_core (.clk(core_clk), .arst_n(arst_n), .srst_n(core_rst_n));
    reset_sync u_rst_rx   (.clk(rx_clk),   .arst_n(arst_n), .srst_n(rx_rst_n));

    // ---- the crossing -------------------------------------------------------
    // payload: {tlast, tkeep[7:0], tdata[63:0]} = 74 bits
    localparam integer DW = 74;

    wire [DW-1:0] fifo_wdata = {rx_tlast, rx_tkeep, rx_tdata};
    wire          fifo_full, fifo_empty;
    wire [DW-1:0] fifo_rdata;

    wire fifo_wr = rx_tvalid && !fifo_full;
    assign rx_tready = !fifo_full;

    async_fifo #(.DSIZE(DW), .ASIZE(FIFO_A)) u_cdc (
        .wclk(rx_clk),    .wrst_n(rx_rst_n),
        .winc(fifo_wr),   .wdata(fifo_wdata), .wfull(fifo_full),
        .rclk(core_clk),  .rrst_n(core_rst_n),
        .rinc(1'b1),      .rdata(fifo_rdata), .rempty(fifo_empty)
    );

    // count what the wire would have lost if it could not be back-pressured
    always @(posedge rx_clk or negedge rx_rst_n) begin
        if (!rx_rst_n)                      stat_fifo_drops <= 16'd0;
        else if (rx_tvalid && fifo_full)    stat_fifo_drops <= stat_fifo_drops
                                                             + 16'd1;
    end

    // ---- core domain --------------------------------------------------------
    wire        c_tvalid = !fifo_empty;
    wire [63:0] c_tdata  = fifo_rdata[63:0];
    wire [7:0]  c_tkeep  = fifo_rdata[71:64];
    wire        c_tlast  = fifo_rdata[72];

    wire [63:0] p_tdata;
    wire [7:0]  p_tkeep;
    wire        p_tvalid, p_tready, p_tlast, p_tsop;
    wire        hdr_valid, desc_valid;
    wire [2:0]  hdr_class;
    wire [13:0] desc_len;

    wire               alloc_req, alloc_ok, free_req, link_en, wr_en, rd_en;
    wire [ADDR_W-1:0]  alloc_cell, free_cell, link_from, link_to;
    wire [ADDR_W-1:0]  next_q_cell, next_q_out, wr_cell, rd_cell;
    wire [2:0]         wr_word, rd_word;
    wire [63:0]        wr_data, rd_data;

    wire [111:0] q_len_flat;
    wire         tx_done, tx_done_truncated;
    wire [2:0]   tx_done_class;
    wire [13:0]  tx_done_bytes, tx_done_residual;

    frame_parser u_parse (
        .clk(core_clk), .rst_n(core_rst_n),
        .s_tdata(c_tdata), .s_tkeep(c_tkeep), .s_tvalid(c_tvalid),
        .s_tready(), .s_tlast(c_tlast),
        .hdr_valid(hdr_valid), .hdr_class(hdr_class), .hdr_tagged(),
        .desc_valid(desc_valid), .desc_len(desc_len), .desc_class(),
        .m_tdata(p_tdata), .m_tkeep(p_tkeep), .m_tvalid(p_tvalid),
        .m_tready(p_tready), .m_tlast(p_tlast), .m_tsop(p_tsop)
    );

    voq_manager #(.CELLS(CELLS), .ADDR_W(ADDR_W), .DEPTH(DEPTH)) u_voq (
        .clk(core_clk), .rst_n(core_rst_n),
        .s_tvalid(p_tvalid), .s_tdata(p_tdata), .s_tlast(p_tlast),
        .s_tsop(p_tsop), .s_tready(p_tready),
        .hdr_valid(hdr_valid), .hdr_class(hdr_class),
        .desc_valid(desc_valid), .desc_len(desc_len),
        .q_nonempty(q_nonempty), .q_len_flat(q_len_flat),
        .tx_busy(tx_busy), .tx_class(tx_class),
        .tx_done(tx_done), .tx_done_class(tx_done_class),
        .tx_done_truncated(tx_done_truncated),
        .tx_done_residual(tx_done_residual),
        .m_tvalid(tx_tvalid), .m_tdata(tx_tdata),
        .m_tkeep(tx_tkeep), .m_tlast(tx_tlast),
        .alloc_req(alloc_req), .alloc_cell(alloc_cell), .alloc_ok(alloc_ok),
        .free_req(free_req), .free_cell(free_cell),
        .link_en(link_en), .link_from(link_from), .link_to(link_to),
        .next_q_cell(next_q_cell), .next_q_out(next_q_out),
        .wr_en(wr_en), .wr_cell(wr_cell), .wr_word(wr_word), .wr_data(wr_data),
        .rd_en(rd_en), .rd_cell(rd_cell), .rd_word(rd_word), .rd_data(rd_data),
        .stat_drops(stat_drops), .stat_enq(stat_enq)
    );

    pkt_buffer #(.CELLS(CELLS), .ADDR_W(ADDR_W)) u_buf (
        .clk(core_clk), .rst_n(core_rst_n),
        .alloc_req(alloc_req), .alloc_cell(alloc_cell), .alloc_ok(alloc_ok),
        .free_req(free_req), .free_cell(free_cell),
        .link_en(link_en), .link_from(link_from), .link_to(link_to),
        .next_q_cell(next_q_cell), .next_q_out(next_q_out),
        .wr_en(wr_en), .wr_cell(wr_cell), .wr_word(wr_word), .wr_data(wr_data),
        .rd_en(rd_en), .rd_cell(rd_cell), .rd_word(rd_word), .rd_data(rd_data),
        .cells_used(cells_used)
    );

    tsn_sched_top u_sched (
        .clk(core_clk), .rst_n(core_rst_n),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid),
        .s_wready(s_wready), .s_bresp(s_bresp), .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rvalid(s_rvalid),
        .s_rready(s_rready),
        .q_nonempty(q_nonempty), .q_len_flat(q_len_flat),
        .tx_done(tx_done), .tx_done_class(tx_done_class),
        .tx_done_bytes(tx_done_bytes),
        .tx_done_truncated(tx_done_truncated),
        .tx_done_residual(tx_done_residual),
        .time_ns(time_ns), .gate_open(gate_open),
        .remaining_ns(remaining_ns), .tx_busy(tx_busy),
        .tx_class(tx_class), .tx_smd(tx_smd)
    );

endmodule

`default_nettype wire
