// ============================================================================
// tx_engine.v -- byte serializer with 802.3br express/preemptable framing
//
// Models the wire at BYTES_PER_CLK bytes per clock (8 B x 156.25 MHz = 10 Gb/s)
// and emits SMD codes so a receiver can reassemble:
//     SMD_E  express frame, atomic
//     SMD_S  start of a preemptable frame that got cut
//     SMD_C  continuation fragment
// A cut is only issued at frag_bytes, which guard_band has already proven
// leaves >= 64 B on both sides.
//
// On completion the block reports whether the frame was truncated and how many
// bytes remain, so the queue manager can re-head the residual.
// ============================================================================
`default_nettype none

module tx_engine #(
    parameter integer BYTES_PER_CLK = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire [2:0]  start_class,
    input  wire [13:0] start_len,
    input  wire        start_preempt,     // cut this frame at frag_len
    input  wire [13:0] frag_len,
    input  wire        is_continuation,   // residual of an earlier cut

    output reg         busy,
    output reg  [2:0]  cur_class,
    output reg  [1:0]  smd,               // 0=E 1=S 2=C
    output reg         done,
    output reg  [2:0]  done_class,
    output reg  [13:0] done_bytes,
    output reg         done_truncated,
    output reg  [13:0] done_residual
);

    localparam [1:0] SMD_E = 2'd0, SMD_S = 2'd1, SMD_C = 2'd2;

    reg [13:0] rem;          // bytes still to push for this burst
    reg [13:0] burst_len;
    reg [13:0] residual;
    reg        truncating;

    wire [13:0] step = (rem > BYTES_PER_CLK[13:0]) ? BYTES_PER_CLK[13:0] : rem;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy           <= 1'b0;
            rem            <= 14'd0;
            burst_len      <= 14'd0;
            residual       <= 14'd0;
            truncating     <= 1'b0;
            cur_class      <= 3'd0;
            smd            <= SMD_E;
            done           <= 1'b0;
            done_class     <= 3'd0;
            done_bytes     <= 14'd0;
            done_truncated <= 1'b0;
            done_residual  <= 14'd0;
        end else begin
            done <= 1'b0;

            if (!busy && start) begin
                busy       <= 1'b1;
                cur_class  <= start_class;
                truncating <= start_preempt;
                burst_len  <= start_preempt ? frag_len : start_len;
                rem        <= start_preempt ? frag_len : start_len;
                residual   <= start_preempt ? (start_len - frag_len) : 14'd0;
                smd        <= is_continuation ? SMD_C :
                              (start_preempt  ? SMD_S : SMD_E);
            end else if (busy) begin
                rem <= rem - step;
                if (rem <= BYTES_PER_CLK[13:0]) begin
                    busy           <= 1'b0;
                    done           <= 1'b1;
                    done_class     <= cur_class;
                    done_bytes     <= burst_len;
                    done_truncated <= truncating;
                    done_residual  <= residual;
                end
            end
        end
    end

endmodule

`default_nettype wire
