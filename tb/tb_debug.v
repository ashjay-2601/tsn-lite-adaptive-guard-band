`timescale 1ns/1ps
// Short trace TB: 3 schedule cycles, prints every gate change and every burst.
module tb_debug;
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

    reg run_active=0; integer seed=1;
    reg [47:0] next_tt;
    always @(posedge clk) begin
        if(!rst_n) qne<=0;
        else if(run_active) begin
            if(time_ns>=next_tt) begin
                qlen[7]<=500; qne[7]<=1; next_tt<=next_tt+10000;
            end
            if(qlen[0]==0) begin qlen[0]<=1400; qne[0]<=1; end
            if(tx_done) begin
                if(tx_done_trunc) qlen[tx_done_class]<=tx_done_resid;
                else begin qlen[tx_done_class]<=0; qne[tx_done_class]<=0; end
            end
        end
    end

    // trace
    reg [7:0] gate_d; reg busy_d;
    reg [47:0] start_t;
    always @(posedge clk) if(rst_n) begin
        gate_d <= gate_open; busy_d <= tx_busy;
        if(gate_open!=gate_d)
            $display("  t=%6d  GATE -> %02h   (rem=%0d)",time_ns,gate_open,remaining_ns);
        if(tx_busy && !busy_d) begin
            start_t <= time_ns;
            $display("t=%6d  START cls=%0d len=%0d rem=%0d gb_allow=%b preempt=%b frag=%0d",
                     time_ns, dut.cand_class_q, dut.cand_len_q, remaining_ns,
                     dut.gb_allow, dut.gb_preempt, dut.gb_frag);
        end
        if(tx_done)
            $display("t=%6d  DONE  cls=%0d bytes=%0d trunc=%b resid=%0d  (dur=%0d ns, gate=%02h)",
                     time_ns, tx_done_class, tx_done_bytes, tx_done_trunc,
                     tx_done_resid, time_ns-start_t, gate_open);
    end

    integer i;
    initial begin
        for(i=0;i<8;i=i+1) qlen[i]=0;
        next_tt=200;
        repeat(20) @(posedge clk); rst_n=1; repeat(5) @(posedge clk);
        axi_wr(12'h004,32'd4);
        axi_wr(12'h100,32'h80); axi_wr(12'h104,32'd3000);
        axi_wr(12'h108,32'h7F); axi_wr(12'h10C,32'd7000);
        axi_wr(12'h110,32'h80); axi_wr(12'h114,32'd3000);
        axi_wr(12'h118,32'h7F); axi_wr(12'h11C,32'd7000);
        axi_wr(12'h010,32'h7F);
        axi_wr(12'h008,32'd0); axi_wr(12'h00C,32'd0);
        axi_wr(12'h000,32'h7);   // enable + adaptive + preempt
        run_active=1;
        repeat(9400) @(posedge clk);   // ~60 us = 3 cycles
        $finish;
    end
endmodule
