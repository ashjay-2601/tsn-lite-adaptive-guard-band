`timescale 1ns/1ps
// ============================================================================
// tb_cdc.v -- ingress-to-egress loopback for the datapath
//
// Injects real VLAN-tagged frames, checks:
//   1. the parser routes each frame to the PCP-derived class
//   2. every byte comes back out in order, byte-identical
//   3. the cell pool returns to empty (no leak, no double free)
//   4. preempted frames resume from the correct byte
// ============================================================================
module tb_cdc;

    // Core at 156.25 MHz, RX recovered clock deliberately offset.  Equal
    // frequencies would keep a fixed phase and never exercise the crossing;
    // 6.35 vs 6.4 ns is ~7800 ppm, far worse than any real link, so every
    // possible phase alignment is swept many times during the run.
    localparam real CLK_NS    = 6.4;
    localparam real RX_CLK_NS = 6.35;
    reg clk = 0, rx_clk = 0, rst_n = 0;
    always #(CLK_NS/2.0)    clk    = ~clk;
    always #(RX_CLK_NS/2.0) rx_clk = ~rx_clk;

    reg  [11:0] awaddr = 0; reg awvalid = 0, wvalid = 0;
    reg  [31:0] wdata = 0;
    wire awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata; wire [1:0] bresp, rresp;

    reg  [63:0] rx_tdata = 0;
    reg  [7:0]  rx_tkeep = 0;
    reg         rx_tvalid = 0, rx_tlast = 0;
    wire        rx_tready;

    wire        tx_tvalid, tx_tlast; wire [63:0] tx_tdata; wire [7:0] tx_tkeep;
    wire [47:0] time_ns; wire [7:0] gate_open, q_nonempty;
    wire [31:0] remaining_ns; wire tx_busy; wire [2:0] tx_class;
    wire [1:0]  tx_smd; wire [7:0] cells_used;
    wire [15:0] stat_drops, stat_enq, fifo_drops;

    tsn_port_cdc_top dut (
        .core_clk(clk), .rx_clk(rx_clk), .arst_n(rst_n),
        .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(4'hF), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(1'b1),
        .s_araddr(12'd0), .s_arvalid(1'b0), .s_arready(arready),
        .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(1'b1),
        .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tvalid(rx_tvalid),
        .rx_tready(rx_tready), .rx_tlast(rx_tlast),
        .tx_tvalid(tx_tvalid), .tx_tdata(tx_tdata),
        .tx_tkeep(tx_tkeep), .tx_tlast(tx_tlast),
        .stat_fifo_drops(fifo_drops),
        .time_ns(time_ns), .gate_open(gate_open),
        .remaining_ns(remaining_ns), .tx_busy(tx_busy), .tx_class(tx_class),
        .tx_smd(tx_smd), .q_nonempty(q_nonempty), .cells_used(cells_used),
        .stat_drops(stat_drops), .stat_enq(stat_enq)
    );

    integer errors = 0;

    task axi_wr(input [11:0] a, input [31:0] d);
    begin
        @(posedge clk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
        @(posedge clk); while (!(awready && wready)) @(posedge clk);
        awvalid <= 0; wvalid <= 0;
        while (!bvalid) @(posedge clk);
        @(posedge clk);
    end
    endtask

    // ---- reference model: per-class byte queues ----
    // The scheduler drains by strict priority, so egress order is NOT
    // injection order.  Scoreboarding against a single flat queue would
    // report false mismatches the moment two classes are backlogged at once.
    reg [7:0] ref_q  [0:8*16384-1];
    integer   ref_wr [0:7];
    integer   ref_rd [0:7];
    integer   tot_wr = 0, tot_rd = 0;
    // Per-class frame-length FIFO.  The egress bus carries no tkeep, so the
    // final word of a frame is padded; without frame boundaries the scoreboard
    // would score those pad bytes against the next frame and report a false
    // offset.  Real silicon carries tlast+tkeep here -- see known gaps.
    integer flen_q [0:8*64-1];
    integer flen_wr [0:7];
    integer flen_rd [0:7];
    integer frame_left [0:7];

    // ---- inject one VLAN-tagged frame of `len` bytes with priority `pcp` ---
    task send_frame(input integer len, input [2:0] pcp);
        integer b, w, nb;
        reg [7:0] byt;
        reg [63:0] beat;
        reg [7:0]  keep;
    begin
        b = 0;
        while (b < len) begin
            beat = 64'd0; keep = 8'd0;
            nb = (len - b > 8) ? 8 : (len - b);
            for (w = 0; w < nb; w = w + 1) begin
                case (b + w)
                    12: byt = 8'h81;                 // TPID hi
                    13: byt = 8'h00;                 // TPID lo
                    14: byt = {pcp, 5'd1};           // TCI hi: PCP | DEI | VID
                    15: byt = 8'h64;                 // TCI lo
                    default: byt = (b + w) & 8'hFF;  // walking pattern
                endcase
                beat[8*w +: 8] = byt;
                keep[w] = 1'b1;
                ref_q[pcp*16384 + ref_wr[pcp]] = byt;
                ref_wr[pcp] = ref_wr[pcp] + 1;
                tot_wr = tot_wr + 1;
            end
            @(posedge rx_clk);
            rx_tdata  <= beat;
            rx_tkeep  <= keep;
            rx_tvalid <= 1'b1;
            rx_tlast  <= ((b + nb) >= len);
            b = b + nb;
            @(posedge rx_clk);
            while (!rx_tready) @(posedge rx_clk);
            rx_tvalid <= 1'b0; rx_tlast <= 1'b0;
        end
        flen_q[pcp*64 + flen_wr[pcp]] = len;
        flen_wr[pcp] = flen_wr[pcp] + 1;
    end
    endtask

    // ---- scoreboard: compare egress bytes against the reference ----
    // tx_class must be delayed to line up with the data: rd_en is registered
    // in the VOQ, pkt_buffer's read is registered, so the bytes appear two
    // clocks after the cycle whose tx_class selected them.
    reg [2:0] cls_d1, cls_d2;
    always @(posedge clk) begin cls_d1 <= tx_class; cls_d2 <= cls_d1; end

    integer i;
    reg [7:0] got;
    reg [2:0] c;
    always @(posedge clk) if (rst_n && tx_tvalid) begin
        c = cls_d2;
        // tkeep now comes from the DUT, so the scoreboard no longer needs an
        // external frame-length model to know which lanes are real.
        for (i = 0; i < 8; i = i + 1) begin
            if (tx_tkeep[i] && ref_rd[c] < ref_wr[c]) begin
                got = tx_tdata[8*i +: 8];
                if (got !== ref_q[c*16384 + ref_rd[c]]) begin
                    if (errors < 10)
                        $display("[FAIL] class %0d byte %0d: got %02h expected %02h",
                                 c, ref_rd[c], got, ref_q[c*16384 + ref_rd[c]]);
                    errors = errors + 1;
                end
                ref_rd[c] = ref_rd[c] + 1;
                tot_rd = tot_rd + 1;
            end
        end
    end

    integer cls;
    initial begin
        for (cls = 0; cls < 8; cls = cls + 1) begin
            ref_wr[cls] = 0; ref_rd[cls] = 0;
            flen_wr[cls] = 0; flen_rd[cls] = 0; frame_left[cls] = 0;
        end
        repeat (20) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);

        // single always-open window so the scheduler drains continuously
        axi_wr(12'h004, 32'd1);
        axi_wr(12'h100, 32'hFF); axi_wr(12'h104, 32'd1000000);
        axi_wr(12'h010, 32'h00);            // nothing preemptable yet
        axi_wr(12'h008, 32'd0); axi_wr(12'h00C, 32'd0);
        axi_wr(12'h000, 32'h1);             // enable

        $display("\n=== CDC loopback: rx_clk %0.2f ns / core %0.2f ns ===", RX_CLK_NS, CLK_NS);

        // one frame per class, mixed lengths incl. cell-boundary cases
        send_frame(64,   3'd0);
        send_frame(128,  3'd1);   // exactly two cells
        send_frame(65,   3'd2);   // one byte into a second cell
        send_frame(500,  3'd7);
        send_frame(1518, 3'd4);   // max, spans 24 cells
        send_frame(64,   3'd7);

        repeat (4000) @(posedge clk);
        $display("phase 1 (no preemption) done, errors=%0d", errors);

        // ---- phase 2: tight Qbv schedule + preemption, forces mid-cell cuts
        axi_wr(12'h000, 32'h0);              // disable while reprogramming
        axi_wr(12'h004, 32'd2);
        axi_wr(12'h100, 32'h80); axi_wr(12'h104, 32'd2000);   // class 7 only
        axi_wr(12'h108, 32'h7F); axi_wr(12'h10C, 32'd3000);   // the rest
        axi_wr(12'h010, 32'h7F);             // classes 0..6 preemptable
        axi_wr(12'h008, 32'd0); axi_wr(12'h00C, 32'd0);
        axi_wr(12'h000, 32'h7);              // enable + adaptive + preempt

        for (cls = 0; cls < 12; cls = cls + 1)
            send_frame(1000 + cls*37, (cls % 3));

        repeat (120000) @(posedge clk);
        $display("phase 2 (preemption) done, errors=%0d", errors);

        $display("frames enqueued : %0d", stat_enq);
        $display("frames dropped  : %0d", stat_drops);
        $display("bytes injected  : %0d", tot_wr);
        $display("bytes received  : %0d", tot_rd);
        $display("cells still used: %0d", cells_used);
        $display("fifo drops      : %0d", fifo_drops);
        if (fifo_drops !== 0) begin
            $display("[FAIL] CDC FIFO overflowed"); errors=errors+1; end

        if (stat_enq !== 18)  begin $display("[FAIL] expected 18 enqueues, got %0d", stat_enq); errors=errors+1; end
        if (stat_drops !== 0) begin $display("[FAIL] unexpected drops");    errors=errors+1; end
        if (tot_rd !== tot_wr)begin $display("[FAIL] byte count mismatch"); errors=errors+1; end
        if (cells_used !== 0) begin $display("[FAIL] cell leak: %0d cells still allocated", cells_used); errors=errors+1; end

        if (errors == 0) $display("\n*** PASS: CDC datapath clean ***\n");
        else             $display("\n*** FAIL: %0d errors ***\n", errors);
        $finish;
    end

    initial begin #50_000_000; $display("[FAIL] timeout"); $finish; end

endmodule
