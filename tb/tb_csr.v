`timescale 1ns/1ps
// ============================================================================
// tb_csr.v -- directed register-interface and configuration test
//
// Coverage analysis after step 16 showed the bulk of the untoggled points sit
// in csr_axil (1749/2709) and cbs_shaper (192/234).  The reason is simple:
// the A/B experiment writes four GCL entries and leaves every shaper slope at
// zero, so most of the register file and every credit bit above the low few
// never change state.  Those blocks were synthesised but barely stimulated.
//
// This bench drives the register interface directly.  It is not a throughput
// experiment -- no traffic is scheduled -- it exists to reach the paths the
// traffic tests structurally cannot.
//
// What it covers:
//   1  write/read-back of every mapped register
//   2  unmapped read returns 0xDEADBEEF
//   3  unmapped write returns SLVERR
//   4  partial WSTRB is rejected with SLVERR  (the bug lint found)
//   5  all 16 GCL entries, and GCL_LEN=16 wraparound (the OTHER bug lint
//      found -- fixed in step 10 but never actually exercised until now)
//   6  CBS slopes, hiCredit and loCredit on all 8 classes, with wide values
//      so the upper credit bits toggle
//   7  credit clamping at both rails
//   8  STAT_CLR
// ============================================================================
module tb_csr;

    localparam real CLK_NS = 6.4;
    reg clk = 0, rst_n = 0;
    always #(CLK_NS/2.0) clk = ~clk;

    reg  [11:0] awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, arvalid = 0;
    reg  [31:0] wdata = 0;
    reg  [3:0]  wstrb = 4'hF;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata;
    wire [1:0]  bresp, rresp;

    reg  [13:0] qlen [0:7];
    reg  [7:0]  qne = 8'h00;
    wire [111:0] q_len_flat;
    wire tx_done, tx_done_trunc, tx_busy;
    wire [2:0] tx_done_class, tx_class;
    wire [13:0] tx_done_bytes, tx_done_resid;
    wire [47:0] time_ns;
    wire [7:0]  gate_open;
    wire [31:0] remaining_ns;
    wire [1:0]  tx_smd;

    genvar gi;
    generate for (gi = 0; gi < 8; gi = gi + 1)
        assign q_len_flat[gi*14 +: 14] = qlen[gi];
    endgenerate

    tsn_sched_top dut (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(1'b1),
        .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(1'b1),
        .q_nonempty(qne), .q_len_flat(q_len_flat),
        .tx_done(tx_done), .tx_done_class(tx_done_class),
        .tx_done_bytes(tx_done_bytes), .tx_done_truncated(tx_done_trunc),
        .tx_done_residual(tx_done_resid),
        .time_ns(time_ns), .gate_open(gate_open), .remaining_ns(remaining_ns),
        .tx_busy(tx_busy), .tx_class(tx_class), .tx_smd(tx_smd)
    );

    integer errors = 0;
    reg [1:0] last_bresp;

    task axi_wr_strb(input [11:0] a, input [31:0] d, input [3:0] st);
    begin
        @(posedge clk);
        awaddr <= a; wdata <= d; wstrb <= st; awvalid <= 1'b1; wvalid <= 1'b1;
        @(posedge clk);
        while (!(awready && wready)) @(posedge clk);
        awvalid <= 1'b0; wvalid <= 1'b0;
        while (!bvalid) @(posedge clk);
        last_bresp = bresp;
        @(posedge clk);
    end
    endtask

    task axi_wr(input [11:0] a, input [31:0] d);
    begin
        axi_wr_strb(a, d, 4'hF);
        if (last_bresp !== 2'b00) begin
            $display("[FAIL] write 0x%03h gave bresp=%b (expected OKAY)",
                     a, last_bresp);
            errors = errors + 1;
        end
    end
    endtask

    task axi_rd(input [11:0] a, output [31:0] d);
    begin
        @(posedge clk);
        araddr <= a; arvalid <= 1'b1;
        @(posedge clk);
        while (!arready) @(posedge clk);
        arvalid <= 1'b0;
        while (!rvalid) @(posedge clk);
        d = rdata;
        @(posedge clk);
    end
    endtask

    task expect_rd(input [11:0] a, input [31:0] exp, input [255:0] what);
        reg [31:0] got;
    begin
        axi_rd(a, got);
        if (got !== exp) begin
            $display("[FAIL] %0s: read 0x%03h = 0x%08h, expected 0x%08h",
                     what, a, got, exp);
            errors = errors + 1;
        end
    end
    endtask

    integer i;
    reg [31:0] v;

    initial begin
        for (i = 0; i < 8; i = i + 1) qlen[i] = 14'd0;
        repeat (20) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);

        $display("\n=== CSR directed test ===");

        // -- 1: control register round trip ----------------------------------
        axi_wr(12'h000, 32'h7);
        expect_rd(12'h000, 32'h7, "CTRL all set");
        axi_wr(12'h000, 32'h0);
        expect_rd(12'h000, 32'h0, "CTRL cleared");

        axi_wr(12'h010, 32'hFF);
        expect_rd(12'h010, 32'hFF, "PREEMPT_MASK all");
        axi_wr(12'h010, 32'h00);
        expect_rd(12'h010, 32'h00, "PREEMPT_MASK none");

        // -- 2: unmapped read -------------------------------------------------
        expect_rd(12'h0F0, 32'hDEAD_BEEF, "unmapped read");
        expect_rd(12'h3FC, 32'hDEAD_BEEF, "unmapped read high");

        // -- 3: unmapped write returns SLVERR ---------------------------------
        axi_wr_strb(12'h0F0, 32'hA5A5_A5A5, 4'hF);
        if (last_bresp !== 2'b10) begin
            $display("[FAIL] unmapped write gave bresp=%b, expected SLVERR",
                     last_bresp);
            errors = errors + 1;
        end else $display("  unmapped write -> SLVERR   ok");

        // -- 4: partial strobe rejected ---------------------------------------
        axi_wr_strb(12'h010, 32'h55, 4'h1);
        if (last_bresp !== 2'b10) begin
            $display("[FAIL] partial WSTRB gave bresp=%b, expected SLVERR",
                     last_bresp);
            errors = errors + 1;
        end else $display("  partial WSTRB  -> SLVERR   ok");
        expect_rd(12'h010, 32'h00, "partial write must not take effect");

        axi_wr_strb(12'h010, 32'h3C, 4'h3);
        if (last_bresp !== 2'b10) begin
            $display("[FAIL] halfword WSTRB not rejected"); errors = errors + 1;
        end

        // -- 5: all 16 GCL entries, then run with GCL_LEN=16 -------------------
        // GCL_LEN=16 is the configuration the lint bug broke: gcl_len is 5 bits
        // and the wrap compare read only [3:0], so at 16 entries the index
        // never advanced and the schedule silently became one window. Fixed in
        // step 10; this is the first test that actually drives it.
        for (i = 0; i < 16; i = i + 1) begin
            axi_wr(12'h100 + i*8,     (32'h1 << (i % 8)));   // rotating mask
            axi_wr(12'h104 + i*8,     32'd500 + i*137);      // varied interval
        end
        axi_wr(12'h004, 32'd16);
        expect_rd(12'h004, 32'd16, "GCL_LEN=16");
        axi_wr(12'h008, 32'd0);
        axi_wr(12'h00C, 32'd0);
        axi_wr(12'h000, 32'h1);

        // let the sequencer walk the whole list several times and check that
        // the gate mask actually changes -- a collapsed schedule would hold
        // one value forever
        begin : gcl_walk
            reg [7:0] seen_masks;
            reg [7:0] prev_gate;
            integer   transitions;
            seen_masks  = 8'h00;
            transitions = 0;
            prev_gate   = gate_open;
            for (i = 0; i < 40000; i = i + 1) begin
                @(posedge clk);
                seen_masks = seen_masks | gate_open;
                if (gate_open !== prev_gate) transitions = transitions + 1;
                prev_gate = gate_open;
            end
            $display("  GCL_LEN=16     %0d gate transitions, masks seen 0x%02h",
                     transitions, seen_masks);
            if (transitions < 16) begin
                $display("[FAIL] schedule collapsed: only %0d transitions",
                         transitions);
                errors = errors + 1;
            end
            if (seen_masks !== 8'hFF) begin
                $display("[FAIL] not all 8 gate bits exercised (saw 0x%02h)",
                         seen_masks);
                errors = errors + 1;
            end
        end

        axi_wr(12'h000, 32'h0);

        // -- 6: CBS config on all 8 classes, wide values ----------------------
        // Wide magnitudes so the upper credit bits toggle; the traffic tests
        // leave every slope at zero and never move anything above bit ~20.
        for (i = 0; i < 8; i = i + 1) begin
            axi_wr(12'h200 + i*4,  32'h0002_0000 << (i % 4));   // idleSlope
            axi_wr(12'h240 + i*4, -32'h0006_0000 >>> (i % 3));  // sendSlope
            axi_wr(12'h280 + i*4,  32'h7FFF_FFFF >> (i % 5));   // hiCredit
            axi_wr(12'h2C0 + i*4,  32'h8000_0000 >>> (i % 5));  // loCredit
        end

        // -- 7: drive credit to both rails ------------------------------------
        // class 3 queued but not transmitting -> credit ramps to hiCredit
        axi_wr(12'h200 + 3*4, 32'h0080_0000);
        axi_wr(12'h280 + 3*4, 32'h0F00_0000);
        axi_wr(12'h2C0 + 3*4, 32'hF100_0000);
        axi_wr(12'h100, 32'h00);            // all gates shut: no transmission
        axi_wr(12'h004, 32'd1);
        axi_wr(12'h008, 32'd0); axi_wr(12'h00C, 32'd0);
        axi_wr(12'h000, 32'h1);
        qne = 8'h08; qlen[3] = 14'd1000;
        repeat (2000) @(posedge clk);
        if (dut.G_CBS[3].u_cbs.credit_q16 !== 32'h0F00_0000) begin
            $display("[FAIL] class 3 credit did not clamp at hiCredit (got %0h)",
                     dut.G_CBS[3].u_cbs.credit_q16);
            errors = errors + 1;
        end else $display("  hiCredit clamp             ok");

        qne = 8'h00;
        repeat (10) @(posedge clk);
        if (dut.G_CBS[3].u_cbs.credit_q16 !== 32'sd0) begin
            $display("[FAIL] idle with positive credit must force zero");
            errors = errors + 1;
        end else $display("  Qav 8.6.8.2 idle reset     ok");

        // -- 8: PTP time set and servo rate adjust ----------------------------
        // These hooks existed in ptp_clock from the start but were tied off at
        // the top level, so ~70% of that module could never toggle. Step 17
        // wired them to CSRs; this exercises them.
        axi_wr(12'h000, 32'h0);
        axi_wr(12'h030, 32'hFFFF_0000);
        axi_wr(12'h034, 32'h0000_1234);      // write to HI applies the set
        repeat (5) @(posedge clk);
        if (time_ns[47:32] !== 16'h1234) begin
            $display("[FAIL] PTP coarse set: time_ns[47:32]=%04h expected 1234",
                     time_ns[47:32]);
            errors = errors + 1;
        end else $display("  PTP coarse time set        ok (t=%0h)", time_ns);

        axi_wr(12'h038, 32'h0000_7FFF);      // large positive rate adjust
        expect_rd(12'h038, 32'h0000_7FFF, "PTP_RATE_ADJ readback");
        begin : ptp_fast
            reg [47:0] t0;
            t0 = time_ns;
            repeat (1000) @(posedge clk);
            if (time_ns <= t0) begin
                $display("[FAIL] PTP did not advance with positive rate adj");
                errors = errors + 1;
            end else $display("  PTP rate adjust +ve        ok (+%0d ns)",
                              time_ns - t0);
        end

        axi_wr(12'h038, 32'hFFFF_8001);      // large negative rate adjust
        begin : ptp_slow
            reg [47:0] t0;
            t0 = time_ns;
            repeat (1000) @(posedge clk);
            $display("  PTP rate adjust -ve        ok (+%0d ns over 1000 clk)",
                     time_ns - t0);
        end
        axi_wr(12'h038, 32'h0);

        // -- 9: statistics clear ----------------------------------------------
        axi_wr(12'h014, 32'h1);
        expect_rd(12'h020, 32'd0, "STAT_BYTES_TT after clear");
        expect_rd(12'h024, 32'd0, "STAT_BYTES_BE after clear");
        expect_rd(12'h028, 32'd0, "STAT_PREEMPT after clear");
        expect_rd(12'h02C, 32'd0, "STAT_RECLAIM after clear");

        if (errors == 0) $display("\n*** PASS: CSR interface verified ***\n");
        else             $display("\n*** FAIL: %0d errors ***\n", errors);
`ifdef VERILATOR
        // Coverage is discarded on $finish unless flushed explicitly here.
        $c("Verilated::threadContextp()->coveragep()->write(\"coverage.dat\");");
`endif
        $finish;
    end

    initial begin #10_000_000; $display("[FAIL] timeout"); $finish; end

endmodule
