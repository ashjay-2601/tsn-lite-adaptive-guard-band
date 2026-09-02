// ============================================================================
// tsn_port_top.v -- full egress port: parse -> buffer -> VOQ -> schedule
//
//   AXI-Stream in ─> frame_parser ─> voq_manager ─> pkt_buffer (storage)
//                         │               │
//                    class, len      q_nonempty, q_len
//                                         │
//                                   tsn_sched_top  ─> tx_busy/tx_done ─> wire
//
// tsn_sched_top is instantiated unmodified.  The queue model that used to
// live in the testbench is now real RTL behind the same five-signal contract
// documented in spec.md section 6.
// ============================================================================
`default_nettype none

module tsn_port_top #(
    parameter integer CELLS  = 128,
    parameter integer ADDR_W = 7,
    parameter integer DEPTH  = 8
) (
    input  wire         clk,
    input  wire         rst_n,

    // AXI4-Lite to the scheduler CSRs
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

    // ingress AXI-Stream
    input  wire [63:0]  rx_tdata,
    input  wire [7:0]   rx_tkeep,
    input  wire         rx_tvalid,
    output wire         rx_tready,
    input  wire         rx_tlast,

    // egress AXI-Stream
    output wire         tx_tvalid,
    output wire [63:0]  tx_tdata,

    // observation
    output wire [47:0]  time_ns,
    output wire [7:0]   gate_open,
    output wire [31:0]  remaining_ns,
    output wire         tx_busy,
    output wire [2:0]   tx_class,
    output wire [1:0]   tx_smd,
    output wire [7:0]   q_nonempty,
    output wire [ADDR_W:0] cells_used,
    output wire [15:0]  stat_drops,
    output wire [15:0]  stat_enq
);

    // parser -> voq
    wire [63:0] p_tdata;
    wire [7:0]  p_tkeep;
    wire        p_tvalid, p_tready, p_tlast, p_tsop;
    wire        hdr_valid, desc_valid;
    wire [2:0]  hdr_class;
    wire [13:0] desc_len;

    // voq <-> buffer
    wire               alloc_req, alloc_ok, free_req, link_en, wr_en, rd_en;
    wire [ADDR_W-1:0]  alloc_cell, free_cell, link_from, link_to;
    wire [ADDR_W-1:0]  next_q_cell, next_q_out, wr_cell, rd_cell;
    wire [2:0]         wr_word, rd_word;
    wire [63:0]        wr_data, rd_data;

    // voq -> scheduler
    wire [111:0] q_len_flat;
    wire         tx_done, tx_done_truncated;
    wire [2:0]   tx_done_class;
    wire [13:0]  tx_done_bytes, tx_done_residual;

    frame_parser u_parse (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(rx_tdata), .s_tkeep(rx_tkeep), .s_tvalid(rx_tvalid),
        .s_tready(rx_tready), .s_tlast(rx_tlast),
        .hdr_valid(hdr_valid), .hdr_class(hdr_class), .hdr_tagged(),
        .desc_valid(desc_valid), .desc_len(desc_len), .desc_class(),
        .m_tdata(p_tdata), .m_tkeep(p_tkeep), .m_tvalid(p_tvalid),
        .m_tready(p_tready), .m_tlast(p_tlast), .m_tsop(p_tsop)
    );

    voq_manager #(.CELLS(CELLS), .ADDR_W(ADDR_W), .DEPTH(DEPTH)) u_voq (
        .clk(clk), .rst_n(rst_n),
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
        .alloc_req(alloc_req), .alloc_cell(alloc_cell), .alloc_ok(alloc_ok),
        .free_req(free_req), .free_cell(free_cell),
        .link_en(link_en), .link_from(link_from), .link_to(link_to),
        .next_q_cell(next_q_cell), .next_q_out(next_q_out),
        .wr_en(wr_en), .wr_cell(wr_cell), .wr_word(wr_word), .wr_data(wr_data),
        .rd_en(rd_en), .rd_cell(rd_cell), .rd_word(rd_word), .rd_data(rd_data),
        .stat_drops(stat_drops), .stat_enq(stat_enq)
    );

    pkt_buffer #(.CELLS(CELLS), .ADDR_W(ADDR_W)) u_buf (
        .clk(clk), .rst_n(rst_n),
        .alloc_req(alloc_req), .alloc_cell(alloc_cell), .alloc_ok(alloc_ok),
        .free_req(free_req), .free_cell(free_cell),
        .link_en(link_en), .link_from(link_from), .link_to(link_to),
        .next_q_cell(next_q_cell), .next_q_out(next_q_out),
        .wr_en(wr_en), .wr_cell(wr_cell), .wr_word(wr_word), .wr_data(wr_data),
        .rd_en(rd_en), .rd_cell(rd_cell), .rd_word(rd_word), .rd_data(rd_data),
        .cells_used(cells_used)
    );

    tsn_sched_top u_sched (
        .clk(clk), .rst_n(rst_n),
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
