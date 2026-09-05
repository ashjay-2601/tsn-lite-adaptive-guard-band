`timescale 1ns/1ps
// ============================================================================
// tb_credit_gb.v -- credit-aware guard band: does it bound credit overshoot?
//
// The claim under test, stated precisely.
//
// tsn_sched_top gates a transmission START on credit_ok (credit >= 0), but
// once tx_engine is busy the frame runs to completion regardless.  That is
// correct 802.1Qav behaviour -- Qav is a shaper, not a policer, and frames are
// atomic.  The consequence is credit OVERSHOOT: a class that starts a 1522 B
// frame with credit sitting at +1 ends the frame deeply negative, and is then
// locked out for however long idleSlope takes to climb back.  The worst-case
// lockout is set by the largest frame, not by the configured share.
//
// For a shaped class carrying periodic traffic that lockout is the thing that
// breaks a deadline: the class is not over its long-run share, it is simply
// unavailable at the moment its next frame arrives.
//
// The credit-aware guard band refuses to start a frame that credit cannot
// cover, and (when the class is preemptable) cuts it at the credit limit
// instead.  The prediction is a smaller worst-case negative excursion and a
// shorter worst-case service gap, at some cost in shaped-class throughput.
//
// Run with +credaware=0 or 1.
// ============================================================================
module tb_credit_gb;

    localparam real CLK_NS = 6.4;
    reg clk = 0, rst_n = 0;
    always #(CLK_NS/2.0) clk = ~clk;

    reg  [11:0] awaddr = 0; reg awvalid = 0, wvalid = 0;
    reg  [31:0] wdata = 0;
    wire awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata; wire [1:0] bresp, rresp;

    reg  [13:0] qlen [0:7];
    reg  [7:0]  qne;
    wire [111:0] q_len_flat;
    wire tx_done, tx_done_trunc, tx_busy;
    wire [2:0] tx_done_class, tx_class;
    wire [13:0] tx_done_bytes, tx_done_resid;
    wire [47:0] time_ns; wire [7:0] gate_open;
    wire [31:0] remaining_ns; wire [1:0] tx_smd;

    genvar gi;
    generate for (gi = 0; gi < 8; gi = gi + 1)
        assign q_len_flat[gi*14 +: 14] = qlen[gi];
    endgenerate

    tsn_sched_top dut (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(4'hF), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(1'b1),
        .s_araddr(12'd0), .s_arvalid(1'b0), .s_arready(arready),
        .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(1'b1),
        .q_nonempty(qne), .q_len_flat(q_len_flat),
        .tx_done(tx_done), .tx_done_class(tx_done_class),
        .tx_done_bytes(tx_done_bytes), .tx_done_truncated(tx_done_trunc),
        .tx_done_residual(tx_done_resid),
        .time_ns(time_ns), .gate_open(gate_open), .remaining_ns(remaining_ns),
        .tx_busy(tx_busy), .tx_class(tx_class), .tx_smd(tx_smd)
    );

    task axi_wr(input [11:0] a, input [31:0] d);
    begin
        @(posedge clk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
        @(posedge clk); while (!(awready && wready)) @(posedge clk);
        awvalid <= 0; wvalid <= 0;
        while (!bvalid) @(posedge clk);
        @(posedge clk);
    end
    endtask

    // 25% share: idleSlope +2.0 B/clk, sendSlope -6.0 B/clk (Q16.16)
    localparam signed [31:0] IDLE_25 =  32'sd131072;
    localparam signed [31:0] SEND_25 = -32'sd393216;
    localparam signed [31:0] HI_CR   =  32'sd99745792;  // +1522 B: must cover a max frame
    localparam signed [31:0] LO_CR   = -32'sd131072000;  // -2000 B, room to dip
    // 2048 / 6.0 = 341  (Q8.8 reciprocal of |sendSlope| in bytes per clock)
    localparam [15:0] INV_SEND_25 = 16'd341;

    integer credaware, i, seed_i;
    integer bytes6, bytes0, cuts6;
    integer min_credit, gap_max, last6;
    reg [31:0] lfsr;
    reg run = 0;
    integer cred_b;

    function [31:0] lfsr_next(input [31:0] v);
        lfsr_next = {v[0], v[31:1]} ^ (32'h04C11DB7 & {32{v[0]}});
    endfunction

    // class 6 shaped and backlogged with mixed sizes; class 0 unshaped filler
    always @(posedge clk) begin
        if (!rst_n) qne <= 8'h00;
        else if (run) begin
            if (qlen[6] == 0) begin
                lfsr    <= lfsr_next(lfsr);
                qlen[6] <= 14'd64 + (lfsr[23:8] % 1459);
                qne[6]  <= 1'b1;
            end
            qlen[0] <= 14'd1000; qne[0] <= 1'b1;
            if (tx_done) begin
                if (tx_done_class == 3'd6) begin
                    bytes6 = bytes6 + tx_done_bytes;
                    if (tx_done_trunc) begin
                        qlen[6] <= tx_done_resid;
                        cuts6 = cuts6 + 1;
                    end else begin
                        qlen[6] <= 14'd0; qne[6] <= 1'b0;
                    end
                    if ((time_ns - last6) > gap_max) gap_max = time_ns - last6;
                    last6 = time_ns;
                end
                if (tx_done_class == 3'd0) bytes0 = bytes0 + tx_done_bytes;
            end
        end
    end

    // track the worst negative credit excursion, in whole bytes
    always @(posedge clk) if (run) begin
        cred_b = $signed(dut.G_CBS[6].u_cbs.credit_q16) / 65536;
        if (cred_b < min_credit) min_credit = cred_b;
    end

    initial begin
        if (!$value$plusargs("credaware=%d", credaware)) credaware = 0;

        for (i = 0; i < 8; i = i + 1) qlen[i] = 0;
        bytes6 = 0; bytes0 = 0; cuts6 = 0;
        min_credit = 0; gap_max = 0; last6 = 0;
        lfsr = 32'h1234_5678;

        repeat (20) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);

        axi_wr(12'h004, 32'd1);
        axi_wr(12'h100, 32'hFF); axi_wr(12'h104, 32'd1000000);  // gates open
        axi_wr(12'h010, 32'h7F);                                // 0..6 preemptable

        axi_wr(12'h218, IDLE_25);          // class 6 idleSlope
        axi_wr(12'h258, SEND_25);          // class 6 sendSlope
        axi_wr(12'h298, HI_CR);
        axi_wr(12'h2D8, LO_CR);

        // 0x300 + 4*6 : the reciprocal.  0 disables the credit check, which is
        // exactly the baseline this experiment compares against.
        axi_wr(12'h318, credaware ? {16'd0, INV_SEND_25} : 32'd0);

        axi_wr(12'h008, 32'd0); axi_wr(12'h00C, 32'd0);
        axi_wr(12'h000, 32'h7);            // enable + adaptive + preempt

        run = 1;
        repeat (400000) @(posedge clk);
        run = 0;

        $display("CSV,%0d,%0d,%0d,%0d,%0d,%0d",
                 credaware, bytes6, bytes0, min_credit, gap_max, cuts6);
        $finish;
    end

    initial begin #40_000_000; $display("CSV,TIMEOUT"); $finish; end

endmodule
