// ============================================================================
// tb_sched.v -- directed testbench + A/B guard-band experiment
//
// Traffic profile
//   class 7 (express)     : 500 B time-triggered frame every 10 us
//   class 0 (preemptable) : saturating best-effort, 64..1522 B uniform
//
// Schedule (20 us cycle, two protected windows)
//   e0 mask 0x80  3000 ns      e1 mask 0x7F  7000 ns
//   e2 mask 0x80  3000 ns      e3 mask 0x7F  7000 ns
//
// The same netlist is run twice, flipping CTRL[1], and the two runs are
// compared on BE goodput and TT latency jitter.
// ============================================================================
`timescale 1ns/1ps

module tb_sched;

    localparam real   CLK_NS   = 6.4;
    localparam integer N_CYCLE = 100;          // 20 us schedule cycles per run

    reg clk = 1'b0, rst_n = 1'b0;
    always #(CLK_NS/2.0) clk = ~clk;

    // ---- AXI4-Lite ----
    reg  [11:0] awaddr, araddr;
    reg         awvalid, wvalid, arvalid, bready, rready;
    reg  [31:0] wdata;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata;
    wire [1:0]  bresp, rresp;

    // ---- queue model <-> DUT ----
    reg  [13:0] qlen [0:7];
    reg  [7:0]  qne;
    wire [111:0] q_len_flat;

    wire        tx_done, tx_done_trunc, tx_busy;
    wire [2:0]  tx_done_class, tx_class;
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
        .s_wdata(wdata), .s_wstrb(4'hF), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready),
        .q_nonempty(qne), .q_len_flat(q_len_flat),
        .tx_done(tx_done), .tx_done_class(tx_done_class),
        .tx_done_bytes(tx_done_bytes), .tx_done_truncated(tx_done_trunc),
        .tx_done_residual(tx_done_resid),
        .time_ns(time_ns), .gate_open(gate_open), .remaining_ns(remaining_ns),
        .tx_busy(tx_busy), .tx_class(tx_class), .tx_smd(tx_smd)
    );

    // ---------------------------------------------------------------- AXI task
    task axi_wr(input [11:0] a, input [31:0] d);
    begin
        @(posedge clk);
        awaddr <= a; wdata <= d; awvalid <= 1'b1; wvalid <= 1'b1;
        @(posedge clk);
        while (!(awready && wready)) @(posedge clk);
        awvalid <= 1'b0; wvalid <= 1'b0;
        while (!bvalid) @(posedge clk);
        if (bresp !== 2'b00) begin
            $display("[FAIL] AXI write to 0x%03h returned bresp=%b", a, bresp);
            errors = errors + 1;
        end
        @(posedge clk);
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

    // ------------------------------------------------------------ queue model
    integer seed;
    reg [47:0] next_tt, tt_enq_time;
    reg        tt_inflight;

    integer be_bytes, tt_bytes, preempts, tt_count;
    integer tt_lat_min, tt_lat_max, tt_lat_sum;
    integer errors;
    reg     run_active;

    localparam integer TT_LEN     = 500;
    localparam integer TT_PERIOD  = 10000;   // ns

    always @(posedge clk) begin
        if (!rst_n) begin
            qne <= 8'h00; tt_inflight <= 1'b0;
        end else if (run_active) begin
            // ---- time-triggered arrival ----
            if (time_ns >= next_tt) begin
                qlen[7]     <= TT_LEN[13:0];
                qne[7]      <= 1'b1;
                tt_enq_time <= time_ns;
                tt_inflight <= 1'b1;
                next_tt     <= next_tt + TT_PERIOD;
                if (tt_inflight) begin
                    $display("[FAIL] t=%0t TT frame overrun: previous not sent",
                             $time);
                    errors = errors + 1;
                end
            end
            // ---- best-effort is always backlogged ----
            if (qlen[0] == 14'd0) begin
                qlen[0] <= 14'd64 + ($unsigned($random(seed)) % 1459);
                qne[0]  <= 1'b1;
            end
            // ---- completion handling ----
            if (tx_done) begin
                if (tx_done_trunc) begin
                    qlen[tx_done_class] <= tx_done_resid;
                    preempts = preempts + 1;
                    if (tx_done_resid < 64) begin
                        $display("[FAIL] t=%0t illegal residual %0d B",
                                 $time, tx_done_resid);
                        errors = errors + 1;
                    end
                    if (tx_done_bytes < 64) begin
                        $display("[FAIL] t=%0t illegal fragment %0d B",
                                 $time, tx_done_bytes);
                        errors = errors + 1;
                    end
                end else begin
                    qlen[tx_done_class] <= 14'd0;
                    qne[tx_done_class]  <= 1'b0;
                    if (tx_done_class == 3'd7) begin
                        tt_inflight <= 1'b0;
                        tt_count    = tt_count + 1;
                        tt_lat_sum  = tt_lat_sum + (time_ns - tt_enq_time);
                        if ((time_ns - tt_enq_time) > tt_lat_max)
                            tt_lat_max = time_ns - tt_enq_time;
                        if ((time_ns - tt_enq_time) < tt_lat_min)
                            tt_lat_min = time_ns - tt_enq_time;
                    end
                end
                if (tx_done_class == 3'd7) tt_bytes = tt_bytes + tx_done_bytes;
                else                       be_bytes = be_bytes + tx_done_bytes;
            end
        end
    end

    // ---------------------------------------------------------- gate assertion
    // A transmission must never be in flight on a class whose gate is shut.
    always @(posedge clk) if (rst_n && tx_busy && !gate_open[tx_class]) begin
        $display("[FAIL] t=%0t class %0d transmitting with gate closed",
                 $time, tx_class);
        errors = errors + 1;
    end

    // ------------------------------------------------------------ experiment
    integer  be_sta, be_adp, pre_sta, pre_adp;
    integer  lmax_sta, lmax_adp, lmin_sta, lmin_adp;
    integer  lavg_sta, lavg_adp;
    real     util_sta, util_adp, gain;
    reg [31:0] rd;

    task program_schedule;
    begin
        axi_wr(12'h004, 32'd4);            // GCL_LEN
        axi_wr(12'h100, 32'h80); axi_wr(12'h104, 32'd3000);
        axi_wr(12'h108, 32'h7F); axi_wr(12'h10C, 32'd7000);
        axi_wr(12'h110, 32'h80); axi_wr(12'h114, 32'd3000);
        axi_wr(12'h118, 32'h7F); axi_wr(12'h11C, 32'd7000);
        axi_wr(12'h010, 32'h7F);           // classes 0..6 preemptable
        axi_wr(12'h008, 32'd0);            // base time lo
        axi_wr(12'h00C, 32'd0);            // base time hi + APPLY
    end
    endtask

    task reset_counters;
    begin
        be_bytes = 0; tt_bytes = 0; preempts = 0; tt_count = 0;
        tt_lat_min = 1000000; tt_lat_max = 0; tt_lat_sum = 0;
    end
    endtask

    task run_mode(input adaptive);
    begin
        rst_n = 1'b0; run_active = 1'b0;
        qlen[0]=0; qlen[1]=0; qlen[2]=0; qlen[3]=0;
        qlen[4]=0; qlen[5]=0; qlen[6]=0; qlen[7]=0;
        next_tt = 200; tt_inflight = 1'b0; seed = 32'h1234_5678;
        reset_counters;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);
        program_schedule;
        axi_wr(12'h000, {29'd0, 1'b1, adaptive, 1'b1});  // preempt_en, mode, en
        run_active = 1'b1;
        repeat ((N_CYCLE*20000)/6.4) @(posedge clk);
        run_active = 1'b0;
        repeat (50) @(posedge clk);
    end
    endtask

    initial begin
        awvalid=0; wvalid=0; arvalid=0; bready=1; rready=1;
        awaddr=0; araddr=0; wdata=0; errors=0; run_active=0;
        if ($test$plusargs("dump")) begin
            $dumpfile("results/tb_sched.vcd");
            $dumpvars(0, tb_sched);
        end

        $display("\n=== TSN-Lite scheduler : guard band A/B ===");
        $display("schedule 20 us cycle, 2 x 3000 ns protected windows");
        $display("TT class 7: %0d B every %0d ns, BE class 0: saturating\n",
                 TT_LEN, TT_PERIOD);

        // ---------------- run 1: static guard band ----------------
        run_mode(1'b0);
        be_sta = be_bytes; pre_sta = preempts;
        lmax_sta = tt_lat_max; lmin_sta = tt_lat_min;
        lavg_sta = (tt_count > 0) ? tt_lat_sum / tt_count : 0;
        axi_rd(12'h024, rd);
        $display("[static]   BE bytes=%0d  csr=%0d  TT frames=%0d  preempts=%0d",
                 be_sta, rd, tt_count, pre_sta);

        // ---------------- run 2: adaptive guard band ----------------
        run_mode(1'b1);
        be_adp = be_bytes; pre_adp = preempts;
        lmax_adp = tt_lat_max; lmin_adp = tt_lat_min;
        lavg_adp = (tt_count > 0) ? tt_lat_sum / tt_count : 0;
        axi_rd(12'h02C, rd);
        $display("[adaptive] BE bytes=%0d  reclaimed=%0d ns  TT frames=%0d  preempts=%0d",
                 be_adp, rd, tt_count, pre_adp);

        // ---------------- report ----------------
        util_sta = (be_sta + tt_bytes) * 8.0 / (N_CYCLE * 20000.0);   // Gb/s
        util_adp = (be_adp + tt_bytes) * 8.0 / (N_CYCLE * 20000.0);
        gain     = (be_sta > 0) ? (100.0 * (be_adp - be_sta) / be_sta) : 0.0;

        $display("\n+-------------------------+------------+------------+");
        $display("| metric                  |   static   |  adaptive  |");
        $display("+-------------------------+------------+------------+");
        $display("| BE bytes sent           | %10d | %10d |", be_sta, be_adp);
        $display("| BE goodput      (Gb/s)  | %10.3f | %10.3f |",
                 be_sta*8.0/(N_CYCLE*20000.0), be_adp*8.0/(N_CYCLE*20000.0));
        $display("| link utilisation  (%%)   | %10.2f | %10.2f |",
                 util_sta*10.0, util_adp*10.0);
        $display("| TT latency min    (ns)  | %10d | %10d |", lmin_sta, lmin_adp);
        $display("| TT latency max    (ns)  | %10d | %10d |", lmax_sta, lmax_adp);
        $display("| TT jitter  max-min(ns)  | %10d | %10d |",
                 lmax_sta-lmin_sta, lmax_adp-lmin_adp);
        $display("| fragments generated     | %10d | %10d |", pre_sta, pre_adp);
        $display("+-------------------------+------------+------------+");
        $display("\nBE goodput gain: %0.2f %%", gain);

        if (errors == 0) $display("\n*** PASS: 0 assertion failures ***\n");
        else             $display("\n*** FAIL: %0d assertion failures ***\n", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("[FAIL] global timeout");
        $finish;
    end

endmodule
