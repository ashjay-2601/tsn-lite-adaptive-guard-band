// ============================================================================
// voq_manager.v -- virtual output queues, one descriptor FIFO per class
//
// Write side: as a frame streams in, cells are allocated on demand and chained
// through pkt_buffer's next_ptr.  At tlast a descriptor is pushed onto the
// FIFO for that frame's traffic class.  The class arrives from the parser on
// beat 1, before the frame ends, so the queue is chosen while the body is
// still streaming.
//
// Read side: the scheduler drives tx_busy/tx_class; this block streams 8 B per
// busy cycle out of the chain, freeing each cell as it is left behind.
//
// The interesting part is preemption.  On a truncated transmission the frame
// is *not* popped -- the head descriptor is rewritten in place with the
// residual length and the exact resume cursor (cell, word, and the pending-
// advance flag).  When the gate reopens the chain continues from that byte.
// That is what makes 802.3br work at the queue level: a cut frame is a frame
// with a moved cursor, not a new frame and not a dropped one.
//
// Allocator control is combinational, not registered.  A registered alloc_req
// would let two requests one cycle apart both observe the same first_free bit
// and hand out the same cell twice.  Allocations here are always >= 8 cycles
// apart so the hazard is unreachable in practice, but relying on that is the
// kind of assumption that breaks when someone widens the datapath.
//
// Backpressure: if no cell is free at start-of-frame the whole frame is
// discarded and counted.  Dropping at SOP rather than mid-frame keeps the
// linked list consistent -- a partial chain would leak cells forever.
// ============================================================================
`default_nettype none

module voq_manager #(
    parameter integer CELLS  = 128,
    parameter integer ADDR_W = 7,
    parameter integer DEPTH  = 8,
    parameter integer DPTR_W = 3
) (
    input  wire                clk,
    input  wire                rst_n,

    input  wire                s_tvalid,
    input  wire [63:0]         s_tdata,
    input  wire                s_tlast,
    input  wire                s_tsop,
    output wire                s_tready,
    input  wire                hdr_valid,
    input  wire [2:0]          hdr_class,
    input  wire                desc_valid,
    input  wire [13:0]         desc_len,

    output wire [7:0]          q_nonempty,
    output wire [111:0]        q_len_flat,

    input  wire                tx_busy,
    input  wire [2:0]          tx_class,
    input  wire                tx_done,
    input  wire [2:0]          tx_done_class,
    input  wire                tx_done_truncated,
    input  wire [13:0]         tx_done_residual,

    output reg                 m_tvalid,
    output wire [63:0]         m_tdata,

    output wire                alloc_req,
    input  wire [ADDR_W-1:0]   alloc_cell,
    input  wire                alloc_ok,
    output wire                free_req,
    output wire [ADDR_W-1:0]   free_cell,
    output wire                link_en,
    output wire [ADDR_W-1:0]   link_from,
    output wire [ADDR_W-1:0]   link_to,
    output wire [ADDR_W-1:0]   next_q_cell,
    input  wire [ADDR_W-1:0]   next_q_out,
    output reg                 wr_en,
    output reg  [ADDR_W-1:0]   wr_cell,
    output reg  [2:0]          wr_word,
    output reg  [63:0]         wr_data,
    output reg                 rd_en,
    output reg  [ADDR_W-1:0]   rd_cell,
    output reg  [2:0]          rd_word,
    input  wire [63:0]         rd_data,

    output reg  [15:0]         stat_drops,
    output reg  [15:0]         stat_enq
);

    assign m_tdata  = rd_data;
    assign s_tready = 1'b1;

    // ---------------------------------------------------------- descriptors
    reg [ADDR_W-1:0] d_cell [0:8*DEPTH-1];
    reg [2:0]        d_word [0:8*DEPTH-1];
    reg              d_pend [0:8*DEPTH-1];
    reg [13:0]       d_rem  [0:8*DEPTH-1];

    reg [DPTR_W-1:0] hd_ptr [0:7];
    reg [DPTR_W-1:0] tl_ptr [0:7];
    reg [DPTR_W:0]   d_cnt  [0:7];

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : G_Q
            assign q_nonempty[g]          = (d_cnt[g] != 0);
            // force zero when empty: a stale non-zero length reaching the
            // scheduler's pipeline shadow would start a phantom transmission
            assign q_len_flat[g*14 +: 14] = (d_cnt[g] != 0) ?
                                    d_rem[g*DEPTH + hd_ptr[g]] : 14'd0;
        end
    endgenerate

    // ---------------------------------------------------------- write side
    reg              wr_active, wr_drop;
    reg [ADDR_W-1:0] wr_head;
    reg [ADDR_W-1:0] cur_cell;
    reg [2:0]        cur_word;
    reg [2:0]        wr_class;

    wire wr_beat = s_tvalid && s_tready;
    wire at_sop  = wr_beat && s_tsop;
    wire at_wrap = wr_beat && wr_active && !s_tsop && !wr_drop &&
                   (cur_word == 3'd7) && !s_tlast;

    // ---------------------------------------------------------- read side
    // The cursor must be live on the FIRST tx_busy cycle, not the cycle after.
    // tx_engine asserts busy for exactly ceil(len/8) clocks, so a one-cycle
    // arming delay drops the final word of every frame.  On the first busy
    // cycle the descriptor is read combinationally; after that the registered
    // cursor takes over.
    reg [ADDR_W-1:0] rc_cell;
    reg [2:0]        rc_word;
    reg              rc_pend;
    reg              rd_armed;

    wire rd_start = tx_busy && !rd_armed;

    wire [ADDR_W-1:0] sel_cell = rd_start ?
                        d_cell[tx_class*DEPTH + hd_ptr[tx_class]] : rc_cell;
    wire [2:0]        sel_word = rd_start ?
                        d_word[tx_class*DEPTH + hd_ptr[tx_class]] : rc_word;
    wire              sel_pend = rd_start ?
                        d_pend[tx_class*DEPTH + hd_ptr[tx_class]] : rc_pend;

    assign next_q_cell = sel_cell;

    wire [ADDR_W-1:0] eff_cell = sel_pend ? next_q_out : sel_cell;
    wire [2:0]        eff_word = sel_pend ? 3'd0       : sel_word;
    // Gate reads on the queue actually holding something.  tx_busy can be
    // asserted for a phantom burst in the scheduler's pipeline shadow; letting
    // that drive the cursor walks a freed chain and corrupts the free list.
    wire              rd_beat  = tx_busy && q_nonempty[tx_class];

    // ------------------------------------------------- combinational control
    assign alloc_req = (at_sop && alloc_ok) || at_wrap;
    assign link_en   = at_wrap;
    assign link_from = cur_cell;
    assign link_to   = alloc_cell;

    // tx_done lands on the SAME edge as the final read beat, so rc_* has not
    // yet absorbed that beat.  The resume point and the cell to free must be
    // computed from the post-beat position, or the frame restarts one word
    // early and replays 8 bytes.
    wire [ADDR_W-1:0] nxt_cell = rd_beat ? eff_cell        : rc_cell;
    wire [2:0]        nxt_word = rd_beat ? (eff_word+3'd1) : rc_word;
    wire              nxt_pend = rd_beat ? (eff_word == 3'd7) : rc_pend;

    // A cell is freed exactly once: when the read cursor leaves it, or -- for
    // the cell holding the final byte -- at clean completion.  On a truncated
    // burst nothing is freed, because the frame resumes inside that cell.
    wire free_on_leave = rd_beat && sel_pend;
    wire free_on_done  = tx_done && !tx_done_truncated && !free_on_leave &&
                         (d_cnt[tx_done_class] != 0);
    assign free_req  = free_on_leave || free_on_done;
    assign free_cell = free_on_leave ? sel_cell : nxt_cell;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_en <= 1'b0; rd_en <= 1'b0; m_tvalid <= 1'b0;
            wr_active <= 1'b0; wr_drop <= 1'b0;
            wr_head <= 0; wr_cell <= 0; wr_word <= 3'd0; wr_data <= 64'd0;
            cur_cell <= 0; cur_word <= 3'd0; wr_class <= 3'd0;
            rd_cell <= 0; rd_word <= 3'd0;
            rc_cell <= 0; rc_word <= 3'd0; rc_pend <= 1'b0; rd_armed <= 1'b0;
            stat_drops <= 16'd0; stat_enq <= 16'd0;
            for (i = 0; i < 8; i = i + 1) begin
                hd_ptr[i] <= 0; tl_ptr[i] <= 0; d_cnt[i] <= 0;
            end
            for (i = 0; i < 8*DEPTH; i = i + 1) begin
                d_cell[i] <= 0; d_word[i] <= 3'd0;
                d_pend[i] <= 1'b0; d_rem[i] <= 14'd0;
            end
        end else begin
            wr_en    <= 1'b0;
            rd_en    <= 1'b0;
            m_tvalid <= rd_en;

            // ===================== WRITE =====================
            if (at_sop) begin
                if (alloc_ok) begin
                    wr_active <= 1'b1;
                    wr_drop   <= 1'b0;
                    wr_head   <= alloc_cell;
                    wr_en     <= 1'b1;
                    wr_cell   <= alloc_cell;      // this beat writes word 0
                    wr_word   <= 3'd0;
                    wr_data   <= s_tdata;
                    cur_cell  <= alloc_cell;      // next beat position
                    cur_word  <= 3'd1;
                end else begin
                    wr_active  <= 1'b1;
                    wr_drop    <= 1'b1;
                    stat_drops <= stat_drops + 16'd1;
                end
            end else if (wr_beat && wr_active && !wr_drop) begin
                wr_en   <= 1'b1;
                wr_cell <= cur_cell;
                wr_word <= cur_word;
                wr_data <= s_tdata;
                if (cur_word == 3'd7) begin
                    if (!s_tlast) begin
                        cur_cell <= alloc_cell;   // chained by link_en above
                        cur_word <= 3'd0;
                    end
                end else begin
                    cur_word <= cur_word + 3'd1;
                end
            end

            if (hdr_valid) wr_class <= hdr_class;

            if (wr_beat && s_tlast) begin
                wr_active <= 1'b0;
                cur_word  <= 3'd0;
            end

            // ---- enqueue descriptor at end of frame ----
            if (desc_valid) begin
                if (!wr_drop && (d_cnt[wr_class] < DEPTH[DPTR_W:0])) begin
                    d_cell[wr_class*DEPTH + tl_ptr[wr_class]] <= wr_head;
                    d_word[wr_class*DEPTH + tl_ptr[wr_class]] <= 3'd0;
                    d_pend[wr_class*DEPTH + tl_ptr[wr_class]] <= 1'b0;
                    d_rem [wr_class*DEPTH + tl_ptr[wr_class]] <= desc_len;
                    tl_ptr[wr_class] <= tl_ptr[wr_class] + 1'b1;
                    d_cnt [wr_class] <= d_cnt[wr_class] + 1'b1;
                    stat_enq <= stat_enq + 16'd1;
                end else if (!wr_drop) begin
                    stat_drops <= stat_drops + 16'd1;
                end
                wr_drop <= 1'b0;
            end

            // ===================== READ =====================
            if (rd_beat) begin
                rd_armed <= 1'b1;
                rd_en    <= 1'b1;
                rd_cell  <= eff_cell;
                rd_word  <= eff_word;
                rc_cell  <= eff_cell;
                rc_word  <= eff_word + 3'd1;
                rc_pend  <= (eff_word == 3'd7);
            end

            // =================== COMPLETION ==================
            // A tx_done for a class with no descriptors is a phantom from the
            // scheduler's pipeline shadow.  Acting on it corrupts the queue:
            // the truncation path would write a resume cursor into a slot that
            // holds no frame, and that slot is later read as if it did.
            if (tx_done && (d_cnt[tx_done_class] != 0)) begin
                rd_armed <= 1'b0;
                if (!tx_done_truncated) rc_pend <= 1'b0;
                if (tx_done_truncated) begin
                    d_cell[tx_done_class*DEPTH + hd_ptr[tx_done_class]] <= nxt_cell;
                    d_word[tx_done_class*DEPTH + hd_ptr[tx_done_class]] <= nxt_word;
                    d_pend[tx_done_class*DEPTH + hd_ptr[tx_done_class]] <= nxt_pend;
                    d_rem [tx_done_class*DEPTH + hd_ptr[tx_done_class]] <=
                                                            tx_done_residual;
                end else if (d_cnt[tx_done_class] != 0) begin
                    hd_ptr[tx_done_class] <= hd_ptr[tx_done_class] + 1'b1;
                    d_cnt [tx_done_class] <= d_cnt[tx_done_class] - 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
