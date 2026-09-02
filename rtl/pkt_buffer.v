// ============================================================================
// pkt_buffer.v -- shared cell buffer, free list, and per-frame linked list
//
// Storage is CELLS cells of CELL_B bytes.  A frame occupies a chain of cells
// linked by next_ptr, so a 1522 B frame and a 64 B frame both cost only what
// they use -- this is why real switches use a shared dynamic buffer rather
// than static per-queue partitions.  Head-of-line blocking is handled by the
// VOQs above, not here.
//
// Allocation is a priority encoder over a free bitmap: one cell per request,
// lowest index first.  A bitmap plus encoder is O(CELLS) in area but single
// cycle, which is what a line-rate allocator needs -- a free *list* in RAM
// would cost a read before every allocation.
//
// This block is pure storage and bookkeeping.  Chain traversal lives in
// voq_manager, which owns the read cursor and therefore the preemption
// resume point.
// ============================================================================
`default_nettype none

module pkt_buffer #(
    parameter integer CELLS  = 128,
    parameter integer ADDR_W = 7,       // log2(CELLS)
    parameter integer WORDS  = 8        // 64-bit words per cell => 64 B cells
) (
    input  wire                clk,
    input  wire                rst_n,

    // allocation
    input  wire                alloc_req,
    output wire [ADDR_W-1:0]   alloc_cell,
    output wire                alloc_ok,      // a free cell exists

    // free
    input  wire                free_req,
    input  wire [ADDR_W-1:0]   free_cell,

    // linked list
    input  wire                link_en,
    input  wire [ADDR_W-1:0]   link_from,
    input  wire [ADDR_W-1:0]   link_to,
    input  wire [ADDR_W-1:0]   next_q_cell,
    output wire [ADDR_W-1:0]   next_q_out,

    // data write
    input  wire                wr_en,
    input  wire [ADDR_W-1:0]   wr_cell,
    input  wire [2:0]          wr_word,
    input  wire [63:0]         wr_data,

    // data read (registered, 1 cycle latency)
    input  wire                rd_en,
    input  wire [ADDR_W-1:0]   rd_cell,
    input  wire [2:0]          rd_word,
    output reg  [63:0]         rd_data,

    output wire [ADDR_W:0]     cells_used
);

    reg [63:0]        mem      [0:CELLS*WORDS-1];
    reg [ADDR_W-1:0]  next_ptr [0:CELLS-1];
    reg [CELLS-1:0]   free_vec;

    // ---- priority encoder over the free bitmap ----------------------------
    reg [ADDR_W-1:0] first_free;
    reg              any_free;
    integer i;
    always @* begin
        first_free = {ADDR_W{1'b0}};
        any_free   = 1'b0;
        for (i = CELLS-1; i >= 0; i = i - 1)
            if (free_vec[i]) begin
                first_free = i[ADDR_W-1:0];
                any_free   = 1'b1;
            end
    end

    assign alloc_cell = first_free;
    assign alloc_ok   = any_free;

    // ---- occupancy counter, for backpressure and stats --------------------
    reg [ADDR_W:0] used;
    assign cells_used = used;

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            free_vec <= {CELLS{1'b1}};
            used     <= {(ADDR_W+1){1'b0}};
            for (k = 0; k < CELLS; k = k + 1) next_ptr[k] <= {ADDR_W{1'b0}};
        end else begin
            if (alloc_req && any_free) free_vec[first_free] <= 1'b0;
            if (free_req)              free_vec[free_cell]  <= 1'b1;

            case ({alloc_req && any_free, free_req})
                2'b10: used <= used + 1'b1;
                2'b01: used <= used - 1'b1;
                default: ;
            endcase

            if (link_en) next_ptr[link_from] <= link_to;
        end
    end

    assign next_q_out = next_ptr[next_q_cell];

    // ---- data ports --------------------------------------------------------
    always @(posedge clk) begin
        if (wr_en) mem[{wr_cell, wr_word}] <= wr_data;
        if (rd_en) rd_data <= mem[{rd_cell, rd_word}];
    end

endmodule

`default_nettype wire
