`timescale 1ns/1ps
// ============================================================================
// tb_cbs_sys.v -- Qav bandwidth split through the real CSR path
//
// tb_cbs.v proves the shaper block in isolation.  This proves the whole path:
// software writes idleSlope/sendSlope/hiCredit/loCredit over AXI4-Lite, and
// the scheduler enforces the configured share against a competing class.
//
// Setup: gates always open, so Qbv is out of the way and only Qav is under
// test.  Class 6 is CBS-limited to +share; class 0 is unshaped best effort.
// Strict priority puts class 6 first, so without a working shaper it would
// take 100% of the link and starve class 0 completely.  The measured split is
// therefore a direct test of whether the credit loop is doing anything.
//
// Run with +share=<percent>.
// ============================================================================
module tb_cbs_sys;

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
        .time_ns(time_ns), .gate_open(gate_open),
        .remaining_ns(remaining_ns), .tx_busy(tx_busy),
        .tx_class(tx_class), .tx_smd(tx_smd)
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

    integer bytes6 = 0, bytes0 = 0, i, share, errors = 0;
    integer idle_q16, send_q16;
    real    got6, expect6;
    reg     run = 0;

    // Both classes are held permanently backlogged: qlen and qne never drop.
    // An earlier version cleared the queue on tx_done and refilled it the next
    // cycle; that one-cycle gap let the lower-priority class in and produced a
    // fixed 50/50 split no matter how the shaper was configured -- the
    // testbench artifact completely masked the thing under test.
    always @(posedge clk) begin
        if (!rst_n) begin
            qne <= 8'h00;
        end else if (run) begin
            qlen[6] <= 14'd1000; qne[6] <= 1'b1;
            qlen[0] <= 14'd1000; qne[0] <= 1'b1;
            if (tx_done) begin
                if (tx_done_class == 3'd6) bytes6 = bytes6 + tx_done_bytes;
                if (tx_done_class == 3'd0) bytes0 = bytes0 + tx_done_bytes;
            end
        end
    end

    initial begin
        if (!$value$plusargs("share=%d", share)) share = 30;

        // Q16.16 bytes per clock.  8 B/clk at line rate.
        idle_q16 =  (share * 8 * 65536) / 100;
        send_q16 = -(((100 - share) * 8 * 65536) / 100);

        for (i = 0; i < 8; i = i + 1) qlen[i] = 0;
        repeat (20) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);

        axi_wr(12'h004, 32'd1);
        axi_wr(12'h100, 32'hFF); axi_wr(12'h104, 32'd1000000);  // gates open
        axi_wr(12'h010, 32'h00);                                // no preemption

        // class 6 shaper
        axi_wr(12'h218, idle_q16);        // 0x200 + 4*6
        axi_wr(12'h258, send_q16);        // 0x240 + 4*6
        axi_wr(12'h298, 32'd99745792);    // hiCredit  = +1522 B
        axi_wr(12'h2D8, -32'sd99745792);  // loCredit  = -1522 B

        axi_wr(12'h008, 32'd0); axi_wr(12'h00C, 32'd0);
        axi_wr(12'h000, 32'h1);

        run = 1;
        repeat (300000) @(posedge clk);
        run = 0;

        got6    = 100.0 * bytes6 / (bytes6 + bytes0);
        expect6 = share;

        $display("\n=== Qav bandwidth split, class 6 shaped to %0d%% ===", share);
        $display("class 6 (shaped)     : %0d bytes  %0.2f %%", bytes6, got6);
        $display("class 0 (best effort): %0d bytes  %0.2f %%",
                 bytes0, 100.0 - got6);

        // Strict priority means an unshaped class 6 would take 100%.
        if (got6 > 99.0) begin
            $display("[FAIL] shaper had no effect - class 6 starved class 0");
            errors = errors + 1;
        end
        if (got6 < expect6 - 4.0 || got6 > expect6 + 4.0) begin
            $display("[FAIL] share %0.2f%% outside %0.1f +/- 4%%", got6, expect6);
            errors = errors + 1;
        end

        if (errors == 0) $display("*** PASS: Qav share enforced ***\n");
        else             $display("*** FAIL: %0d errors ***\n", errors);
        $finish;
    end

    initial begin #30_000_000; $display("[FAIL] timeout"); $finish; end

endmodule
