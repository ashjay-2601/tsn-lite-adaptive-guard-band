`timescale 1ns/1ps
// Sweep harness: +bewin=<ns> +mode=<0|1>  -> one CSV line on stdout.
// TT window is fixed at 3000 ns; the BE window is swept to show how the
// guard-band overhead scales with schedule granularity.
module tb_sweep;
    localparam real CLK_NS = 6.4;
    reg clk=0, rst_n=0; always #(CLK_NS/2.0) clk=~clk;

    reg [11:0] awaddr=0, araddr=0; reg awvalid=0,wvalid=0,arvalid=0;
    reg [31:0] wdata=0; wire awready,wready,bvalid,arready,rvalid;
    wire [31:0] rdata; wire [1:0] bresp,rresp;

    reg [13:0] qlen[0:7]; reg [7:0] qne; wire [111:0] q_len_flat;
    wire tx_done,tx_done_trunc,tx_busy; wire [2:0] tx_done_class,tx_class;
    wire [13:0] tx_done_bytes,tx_done_resid; wire [47:0] time_ns;
    wire [7:0] gate_open; wire [31:0] remaining_ns; wire [1:0] tx_smd;

    genvar gi; generate for(gi=0;gi<8;gi=gi+1)
        assign q_len_flat[gi*14+:14]=qlen[gi]; endgenerate

    tsn_sched_top dut(.clk(clk),.rst_n(rst_n),
      .s_awaddr(awaddr),.s_awvalid(awvalid),.s_awready(awready),.s_wdata(wdata),
      .s_wstrb(4'hF),.s_wvalid(wvalid),.s_wready(wready),.s_bresp(bresp),
      .s_bvalid(bvalid),.s_bready(1'b1),.s_araddr(araddr),.s_arvalid(arvalid),
      .s_arready(arready),.s_rdata(rdata),.s_rresp(rresp),.s_rvalid(rvalid),
      .s_rready(1'b1),.q_nonempty(qne),.q_len_flat(q_len_flat),
      .tx_done(tx_done),.tx_done_class(tx_done_class),
      .tx_done_bytes(tx_done_bytes),.tx_done_truncated(tx_done_trunc),
      .tx_done_residual(tx_done_resid),.time_ns(time_ns),.gate_open(gate_open),
      .remaining_ns(remaining_ns),.tx_busy(tx_busy),.tx_class(tx_class),
      .tx_smd(tx_smd));

    task axi_wr(input [11:0] a, input [31:0] d); begin
        @(posedge clk); awaddr<=a; wdata<=d; awvalid<=1; wvalid<=1;
        @(posedge clk); while(!(awready&&wready)) @(posedge clk);
        awvalid<=0; wvalid<=0; while(!bvalid) @(posedge clk); @(posedge clk);
    end endtask

    integer bewin, mode, seed, errors;
    integer be_bytes, tt_count, lat_min, lat_max, preempts;
    integer cycle_ns, nsim;
    reg run_active=0, tt_inflight=0;
    reg [47:0] next_tt, tt_enq;

    always @(posedge clk) begin
        if(!rst_n) qne<=0;
        else if(run_active) begin
            if(time_ns>=next_tt) begin
                qlen[7]<=500; qne[7]<=1; tt_enq<=time_ns; tt_inflight<=1;
                next_tt<=next_tt+10000;
            end
            if(qlen[0]==0) begin
                qlen[0]<=14'd64+($unsigned($random(seed))%1459); qne[0]<=1;
            end
            if(tx_done) begin
                if(tx_done_trunc) begin
                    qlen[tx_done_class]<=tx_done_resid;
                    preempts=preempts+1;
                    if(tx_done_resid<64 || tx_done_bytes<64) errors=errors+1;
                end else begin
                    qlen[tx_done_class]<=0; qne[tx_done_class]<=0;
                    if(tx_done_class==7) begin
                        tt_inflight<=0; tt_count=tt_count+1;
                        if((time_ns-tt_enq)>lat_max) lat_max=time_ns-tt_enq;
                        if((time_ns-tt_enq)<lat_min) lat_min=time_ns-tt_enq;
                    end
                end
                if(tx_done_class!=7) be_bytes=be_bytes+tx_done_bytes;
            end
        end
    end

    always @(posedge clk) if(rst_n && tx_busy && !gate_open[tx_class])
        errors = errors + 1;

    integer i;
    initial begin
        if(!$value$plusargs("bewin=%d", bewin)) bewin = 7000;
        if(!$value$plusargs("mode=%d",  mode))  mode  = 0;
        cycle_ns = 2*(3000 + bewin);
        nsim = (100*cycle_ns)/6.4;
        for(i=0;i<8;i=i+1) qlen[i]=0;
        next_tt=200; seed=32'h1234_5678; errors=0;
        be_bytes=0; tt_count=0; lat_min=1000000; lat_max=0; preempts=0;
        repeat(20) @(posedge clk); rst_n=1; repeat(5) @(posedge clk);
        axi_wr(12'h004,32'd4);
        axi_wr(12'h100,32'h80); axi_wr(12'h104,32'd3000);
        axi_wr(12'h108,32'h7F); axi_wr(12'h10C,bewin);
        axi_wr(12'h110,32'h80); axi_wr(12'h114,32'd3000);
        axi_wr(12'h118,32'h7F); axi_wr(12'h11C,bewin);
        axi_wr(12'h010,32'h7F);
        axi_wr(12'h008,32'd0); axi_wr(12'h00C,32'd0);
        axi_wr(12'h000, {29'd0, 1'b1, mode[0], 1'b1});
        run_active=1;
        repeat(nsim) @(posedge clk);
        run_active=0; repeat(20) @(posedge clk);
        // csv: bewin,mode,be_bytes,goodput_gbps,tt_lat_max,jitter,preempts,errors
        $display("CSV,%0d,%0d,%0d,%0.4f,%0d,%0d,%0d,%0d",
                 bewin, mode, be_bytes,
                 be_bytes*8.0/(100.0*cycle_ns),
                 lat_max, lat_max-lat_min, preempts, errors);
        $finish;
    end
    initial begin #60_000_000; $display("CSV,TIMEOUT"); $finish; end
endmodule
