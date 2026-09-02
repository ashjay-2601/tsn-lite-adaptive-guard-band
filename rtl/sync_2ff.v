// ============================================================================
// sync_2ff.v -- two flop synchroniser
//
// The primitive every other crossing is built from.  Two flops in the
// destination domain give the first flop a full clock to resolve if it goes
// metastable; the MTBF improves roughly exponentially per added stage.
//
// WIDTH > 1 is ONLY safe when the bus is Gray coded or otherwise guaranteed
// to change one bit at a time.  Synchronising an arbitrary multi-bit value
// bit-by-bit lets different bits land on different sides of the sampling
// edge, producing a value that never existed in the source domain.  That is
// the single most common CDC bug in real designs, so the parameter is named
// to make the requirement impossible to miss.
// ============================================================================
`default_nettype none

module sync_2ff #(
    parameter integer WIDTH_MUST_BE_GRAY_OR_1 = 1
) (
    input  wire                                  dst_clk,
    input  wire                                  dst_rst_n,
    input  wire [WIDTH_MUST_BE_GRAY_OR_1-1:0]    d_src,
    output reg  [WIDTH_MUST_BE_GRAY_OR_1-1:0]    q_dst
);
    reg [WIDTH_MUST_BE_GRAY_OR_1-1:0] meta;

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            meta  <= {WIDTH_MUST_BE_GRAY_OR_1{1'b0}};
            q_dst <= {WIDTH_MUST_BE_GRAY_OR_1{1'b0}};
        end else begin
            meta  <= d_src;
            q_dst <= meta;
        end
    end
endmodule

`default_nettype wire
