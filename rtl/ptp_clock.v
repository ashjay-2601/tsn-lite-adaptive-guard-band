// ============================================================================
// ptp_clock.v -- IEEE 1588 style free-running time base
//
// Time is kept as 48.16 fixed point nanoseconds so that a non-integer clock
// period (6.4 ns @ 156.25 MHz) accumulates without drift.
//
//   INCR_Q16 = round(period_ns * 65536).  6.4 ns -> 419430
//
// rate_adj is a signed per-cycle addend used by a servo loop to slew the
// local clock toward a grandmaster.  Not exercised in this project, but the
// hook is present so the block is reusable.
// ============================================================================
`default_nettype none

module ptp_clock #(
    parameter [31:0] INCR_Q16 = 32'd419430   // 6.4 ns in Q16.16
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        set_valid,
    input  wire [47:0] set_time_ns,

    input  wire signed [15:0] rate_adj_q16,

    output wire [47:0] time_ns,      // integer nanoseconds
    output reg  [63:0] time_q16      // full 48.16 fixed point
);

    wire [63:0] incr_ext = {32'd0, INCR_Q16} +
                           {{48{rate_adj_q16[15]}}, rate_adj_q16};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          time_q16 <= 64'd0;
        else if (set_valid)  time_q16 <= {set_time_ns, 16'd0};
        else                 time_q16 <= time_q16 + incr_ext;
    end

    assign time_ns = time_q16[63:16];

endmodule

`default_nettype wire
