// ============================================================================
// cbs_shaper.v -- IEEE 802.1Qav Credit Based Shaper (one traffic class)
//
// credit accumulates at idleSlope while the class has traffic queued but is
// not transmitting, and drains at sendSlope while transmitting.  Transmission
// is permitted only when credit >= 0.  Credit is forced to zero when the class
// is idle and credit is positive (Qav 8.6.8.2).
//
// Slopes are supplied already scaled to credit-units-per-clock in Q16.16, so
// this block contains no dividers.
//   idle_slope_q16 = (idleSlope_bps / clk_hz) * 65536
// ============================================================================
`default_nettype none

module cbs_shaper (
    input  wire                clk,
    input  wire                rst_n,

    input  wire                enable,
    input  wire signed [31:0]  idle_slope_q16,   // positive
    input  wire signed [31:0]  send_slope_q16,   // negative
    input  wire signed [31:0]  hi_credit_q16,
    input  wire signed [31:0]  lo_credit_q16,

    input  wire                q_nonempty,
    input  wire                transmitting,     // this class owns the wire

    output wire                credit_ok,        // credit >= 0
    output reg  signed [31:0]  credit_q16
);

    wire signed [31:0] nxt_raw = transmitting ? (credit_q16 + send_slope_q16)
                               : (q_nonempty  ? (credit_q16 + idle_slope_q16)
                                              : 32'sd0);

    wire signed [31:0] nxt_clamped =
        (nxt_raw > hi_credit_q16) ? hi_credit_q16 :
        (nxt_raw < lo_credit_q16) ? lo_credit_q16 : nxt_raw;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       credit_q16 <= 32'sd0;
        else if (!enable) credit_q16 <= 32'sd0;
        else              credit_q16 <= nxt_clamped;
    end

    assign credit_ok = !credit_q16[31];   // sign bit clear => >= 0

endmodule

`default_nettype wire
