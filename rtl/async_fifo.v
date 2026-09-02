// ============================================================================
// async_fifo.v -- dual-clock FIFO, Gray-coded pointers
//
// The RX side of an Ethernet port runs on a clock recovered from the incoming
// serial stream.  It is nominally the same frequency as the core clock but
// has no fixed phase relationship and a real ppm offset, so every signal
// crossing between them needs explicit treatment.  This FIFO is that boundary.
//
// Why Gray code.  The pointers are the only thing that crosses.  A binary
// pointer stepping 0111 -> 1000 changes four bits at once; sampled by the far
// clock mid-transition, individual bits land on either side of the edge and
// the receiver can observe 1111 or 0000 -- values the counter never held.
// Gray code changes exactly one bit per increment, so a mid-transition sample
// yields either the old value or the new one. Both are safe: the worst case is
// the FIFO looking momentarily emptier or fuller than it is, which is
// conservative in both directions.
//
// Why full and empty are computed in different domains.  Each flag is
// generated where its own pointer lives, comparing against the *synchronised*
// copy of the far pointer.  Full is therefore pessimistic (the write side may
// not yet have seen a read) and empty is pessimistic (the read side may not
// yet have seen a write).  Pessimism is correct: the failure mode of an
// optimistic flag is overwriting live data.  Comparing two raw pointers from
// different domains would be optimistic and is the classic way to build a FIFO
// that passes simulation and fails on silicon.
//
// The memory itself needs no synchroniser.  Data is written and held stable
// long before the read pointer is permitted to reach it -- the pointer
// handshake is what makes the data crossing safe, not any property of the RAM.
// ============================================================================
`default_nettype none

module async_fifo #(
    parameter integer DSIZE = 74,
    parameter integer ASIZE = 5          // depth = 2**ASIZE
) (
    // write domain
    input  wire              wclk,
    input  wire              wrst_n,
    input  wire              winc,
    input  wire [DSIZE-1:0]  wdata,
    output reg               wfull,

    // read domain
    input  wire              rclk,
    input  wire              rrst_n,
    input  wire              rinc,
    output wire [DSIZE-1:0]  rdata,
    output reg               rempty
);

    localparam integer DEPTH = 1 << ASIZE;

    reg [DSIZE-1:0] mem [0:DEPTH-1];

    reg  [ASIZE:0] wbin, wgray, rbin, rgray;
    wire [ASIZE:0] wbin_nxt  = wbin + (winc && !wfull);
    wire [ASIZE:0] rbin_nxt  = rbin + (rinc && !rempty);
    wire [ASIZE:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
    wire [ASIZE:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

    wire [ASIZE:0] wq_rgray;   // read pointer, synchronised into write domain
    wire [ASIZE:0] rq_wgray;   // write pointer, synchronised into read domain

    // ---- pointer crossings: Gray coded, so a multi-bit sync is legal -------
    sync_2ff #(.WIDTH_MUST_BE_GRAY_OR_1(ASIZE+1)) u_r2w (
        .dst_clk(wclk), .dst_rst_n(wrst_n), .d_src(rgray), .q_dst(wq_rgray));

    sync_2ff #(.WIDTH_MUST_BE_GRAY_OR_1(ASIZE+1)) u_w2r (
        .dst_clk(rclk), .dst_rst_n(rrst_n), .d_src(wgray), .q_dst(rq_wgray));

    // ---- write domain ------------------------------------------------------
    // wfull MUST be registered.  Driving it combinationally closes a loop:
    // wfull -> wbin_nxt -> wgray_nxt -> wfull.  Yosys reports this as a logic
    // loop; in silicon it is an unsynthesisable ring.  Registering costs one
    // cycle of pessimism on the flag, which is harmless -- the FIFO simply
    // declares itself full one write early.
    wire wfull_val = (wgray_nxt == {~wq_rgray[ASIZE:ASIZE-1],
                                     wq_rgray[ASIZE-2:0]});

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin wbin <= 0; wgray <= 0; wfull <= 1'b0; end
        else begin
            wbin  <= wbin_nxt;
            wgray <= wgray_nxt;
            wfull <= wfull_val;
        end
    end

    always @(posedge wclk) if (winc && !wfull) mem[wbin[ASIZE-1:0]] <= wdata;

    // ---- read domain -------------------------------------------------------
    // Same loop through rempty -> rbin_nxt -> rgray_nxt -> rempty; registered
    // for the same reason, and pessimistic in the safe direction (the FIFO
    // reports empty one cycle longer than strictly necessary).
    wire rempty_val = (rgray_nxt == rq_wgray);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin rbin <= 0; rgray <= 0; rempty <= 1'b1; end
        else begin
            rbin   <= rbin_nxt;
            rgray  <= rgray_nxt;
            rempty <= rempty_val;
        end
    end

    assign rdata = mem[rbin[ASIZE-1:0]];

endmodule

`default_nettype wire
