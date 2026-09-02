// ============================================================================
// reset_sync.v -- asynchronous assert, synchronous deassert
//
// A reset that deasserts asynchronously can release different flops on
// different clock edges.  In a state machine that means starting in a state
// the encoding does not define; in a FIFO it means the read and write
// pointers leaving reset at different times, which corrupts the occupancy
// calculation before a single word has moved.
//
// Assert path is combinational so the reset takes effect even with no clock
// running.  Deassert path goes through two flops in the destination domain so
// every flop in that domain leaves reset on the same edge.  One instance is
// required per clock domain -- sharing one across domains reintroduces exactly
// the reset-domain crossing it exists to prevent.
// ============================================================================
`default_nettype none

module reset_sync (
    input  wire clk,
    input  wire arst_n,      // asynchronous, active low
    output reg  srst_n       // synchronous deassert, active low
);
    reg meta;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            meta   <= 1'b0;
            srst_n <= 1'b0;
        end else begin
            meta   <= 1'b1;
            srst_n <= meta;
        end
    end
endmodule

`default_nettype wire
