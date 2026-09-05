// ============================================================================
// tx_arbiter.v -- strict-priority selection across 8 traffic classes
//
// A class is eligible when it has a frame queued, its Qbv gate is open, and
// its Qav credit is non-negative.  Class 7 is highest.  The guard band is NOT
// applied here -- the arbiter nominates a candidate, guard_band adjudicates it
// one cycle later.  Keeping those two jobs apart is what lets the guard band
// see a stable head-of-line length instead of a combinationally moving target.
// ============================================================================
`default_nettype none

module tx_arbiter (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [7:0]   q_nonempty,
    input  wire [7:0]   gate_open,
    input  wire [7:0]   credit_ok,
    input  wire [7:0]   preemptable,
    input  wire [111:0] q_len_flat,     // 8 x 14 bits

    output reg          cand_valid,
    output reg  [2:0]   cand_class,
    output reg  [13:0]  cand_len,
    output reg          cand_preempt
);

    wire [7:0] elig = q_nonempty & gate_open & credit_ok;

    reg [2:0] sel;
    integer i;
    always @* begin
        sel = 3'd0;
        for (i = 0; i < 8; i = i + 1)
            if (elig[i]) sel = i[2:0];   // last match wins => highest index
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cand_valid   <= 1'b0;
            cand_class   <= 3'd0;
            cand_len     <= 14'd0;
            cand_preempt <= 1'b0;
        end else begin
            cand_valid   <= |elig;
            cand_class   <= sel;
            cand_len     <= q_len_flat[sel*14 +: 14];
            cand_preempt <= preemptable[sel];
        end
    end

endmodule

`default_nettype wire
