// ============================================================================
// csr_axil.v -- AXI4-Lite slave: control, GCL storage, shaper config, stats
//
// Register map (byte addresses, all 32-bit):
//   0x000 CTRL          [0] enable  [1] mode_adaptive  [2] preempt_en
//   0x004 GCL_LEN       number of valid GCL entries (1..16)
//   0x008 BASE_LO       admin base time, ns[31:0]
//   0x00C BASE_HI       admin base time, ns[47:32]; write also pulses APPLY
//   0x010 PREEMPT_MASK  [7:0] classes that are preemptable (802.1Qbu)
//   0x014 STAT_CLR      write 1 to clear statistics
//   0x020 STAT_BYTES_TT bytes transmitted by express classes
//   0x024 STAT_BYTES_BE bytes transmitted by preemptable classes
//   0x028 STAT_PREEMPT  fragmentation events
//   0x02C STAT_RECLAIM  ns of guard band reclaimed vs static policy
//   0x100 + 8*i  GCL[i].gate_mask  [7:0]
//   0x104 + 8*i  GCL[i].interval_ns
//   0x200 + 4*c  CBS[c].idle_slope_q16
//   0x240 + 4*c  CBS[c].send_slope_q16
//   0x280 + 4*c  CBS[c].hi_credit_q16
//   0x2C0 + 4*c  CBS[c].lo_credit_q16
// ============================================================================
`default_nettype none

module csr_axil #(
    parameter integer N_ENTRY = 16
) (
    input  wire         clk,
    input  wire         rst_n,

    // ---- AXI4-Lite ----
    input  wire [11:0]  s_awaddr,
    input  wire         s_awvalid,
    output wire         s_awready,
    input  wire [31:0]  s_wdata,
    input  wire [3:0]   s_wstrb,
    input  wire         s_wvalid,
    output wire         s_wready,
    output reg  [1:0]   s_bresp,
    output reg          s_bvalid,
    input  wire         s_bready,
    input  wire [11:0]  s_araddr,
    input  wire         s_arvalid,
    output wire         s_arready,
    output reg  [31:0]  s_rdata,
    output reg  [1:0]   s_rresp,
    output reg          s_rvalid,
    input  wire         s_rready,

    // ---- config out ----
    output reg          cfg_enable,
    output reg          cfg_mode_adaptive,
    output reg          cfg_preempt_en,
    output reg  [4:0]   cfg_gcl_len,
    output reg  [47:0]  cfg_base_time,
    output reg          cfg_apply,
    output reg  [7:0]   cfg_preempt_mask,
    output wire [N_ENTRY*8-1:0]  gcl_mask_flat,
    output wire [N_ENTRY*32-1:0] gcl_ival_flat,
    output wire [255:0] idle_slope_flat,
    output wire [255:0] send_slope_flat,
    output wire [255:0] hi_credit_flat,
    output wire [255:0] lo_credit_flat,

    // ---- stats in ----
    input  wire         ev_tx_done,
    input  wire         ev_tx_express,
    input  wire [13:0]  ev_tx_bytes,
    input  wire         ev_preempt,
    input  wire [31:0]  ev_reclaim_ns
);

    reg [7:0]  gcl_mask [0:N_ENTRY-1];
    reg [31:0] gcl_ival [0:N_ENTRY-1];
    reg [31:0] idle_slope [0:7];
    reg [31:0] send_slope [0:7];
    reg [31:0] hi_credit  [0:7];
    reg [31:0] lo_credit  [0:7];

    reg [31:0] stat_bytes_tt, stat_bytes_be, stat_preempt, stat_reclaim;
    reg        stat_clr;

    genvar g;
    generate
        for (g = 0; g < N_ENTRY; g = g + 1) begin : G_GCL
            assign gcl_mask_flat[g*8  +: 8]  = gcl_mask[g];
            assign gcl_ival_flat[g*32 +: 32] = gcl_ival[g];
        end
        for (g = 0; g < 8; g = g + 1) begin : G_CBS
            assign idle_slope_flat[g*32 +: 32] = idle_slope[g];
            assign send_slope_flat[g*32 +: 32] = send_slope[g];
            assign hi_credit_flat [g*32 +: 32] = hi_credit[g];
            assign lo_credit_flat [g*32 +: 32] = lo_credit[g];
        end
    endgenerate

    // ------------------------------------------------------------------ write
    wire wr_fire = s_awvalid && s_wvalid && (!s_bvalid || s_bready);
    assign s_awready = wr_fire;
    assign s_wready  = wr_fire;

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_enable <= 1'b0; cfg_mode_adaptive <= 1'b0; cfg_preempt_en <= 1'b0;
            cfg_gcl_len <= 5'd1; cfg_base_time <= 48'd0; cfg_apply <= 1'b0;
            cfg_preempt_mask <= 8'h00;
            s_bvalid <= 1'b0; s_bresp <= 2'b00; stat_clr <= 1'b0;
            for (k = 0; k < N_ENTRY; k = k + 1) begin
                gcl_mask[k] <= 8'hFF; gcl_ival[k] <= 32'd1000;
            end
            for (k = 0; k < 8; k = k + 1) begin
                idle_slope[k] <= 32'd0; send_slope[k] <= 32'd0;
                hi_credit[k]  <= 32'h7FFF_FFFF; lo_credit[k] <= 32'h8000_0000;
            end
        end else begin
            cfg_apply <= 1'b0;
            stat_clr  <= 1'b0;
            if (s_bvalid && s_bready) s_bvalid <= 1'b0;

            if (wr_fire) begin
                s_bvalid <= 1'b1;
                // 32-bit access only.  Partial-strobe writes would need a
                // read-modify-write per register; rejecting them is cheaper
                // and makes the software contract explicit.
                s_bresp  <= (s_wstrb == 4'hF) ? 2'b00 : 2'b10;
                if (s_wstrb != 4'hF) begin
                end else
                casez (s_awaddr)
                    12'h000: {cfg_preempt_en, cfg_mode_adaptive, cfg_enable}
                                            <= s_wdata[2:0];
                    12'h004: cfg_gcl_len    <= s_wdata[4:0];
                    12'h008: cfg_base_time[31:0]  <= s_wdata;
                    12'h00C: begin
                             cfg_base_time[47:32] <= s_wdata[15:0];
                             cfg_apply <= 1'b1;
                             end
                    12'h010: cfg_preempt_mask <= s_wdata[7:0];
                    12'h014: stat_clr <= s_wdata[0];
                    12'h1??: if (s_awaddr[2]) gcl_ival[s_awaddr[6:3]] <= s_wdata;
                             else             gcl_mask[s_awaddr[6:3]] <= s_wdata[7:0];
                    12'h2??: case (s_awaddr[7:6])
                                 2'd0: idle_slope[s_awaddr[4:2]] <= s_wdata;
                                 2'd1: send_slope[s_awaddr[4:2]] <= s_wdata;
                                 2'd2: hi_credit [s_awaddr[4:2]] <= s_wdata;
                                 2'd3: lo_credit [s_awaddr[4:2]] <= s_wdata;
                             endcase
                    default: s_bresp <= 2'b10;   // SLVERR
                endcase
            end
        end
    end

    // ------------------------------------------------------------------- read
    assign s_arready = s_arvalid && (!s_rvalid || s_rready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_rvalid <= 1'b0; s_rdata <= 32'd0; s_rresp <= 2'b00;
        end else begin
            if (s_rvalid && s_rready) s_rvalid <= 1'b0;
            if (s_arready) begin
                s_rvalid <= 1'b1;
                s_rresp  <= 2'b00;
                case (s_araddr)
                    12'h000: s_rdata <= {29'd0, cfg_preempt_en,
                                         cfg_mode_adaptive, cfg_enable};
                    12'h004: s_rdata <= {27'd0, cfg_gcl_len};
                    12'h010: s_rdata <= {24'd0, cfg_preempt_mask};
                    12'h020: s_rdata <= stat_bytes_tt;
                    12'h024: s_rdata <= stat_bytes_be;
                    12'h028: s_rdata <= stat_preempt;
                    12'h02C: s_rdata <= stat_reclaim;
                    default: s_rdata <= 32'hDEAD_BEEF;
                endcase
            end
        end
    end

    // -------------------------------------------------------------- statistics
    always @(posedge clk or negedge rst_n) begin
        // stat_clr is a SYNCHRONOUS clear and must not appear in the async
        // reset condition -- doing so infers a second asynchronous edge and is
        // a sim/synth mismatch (Yosys: "multiple edge sensitive events").
        if (!rst_n) begin
            stat_bytes_tt <= 32'd0; stat_bytes_be <= 32'd0;
            stat_preempt  <= 32'd0; stat_reclaim  <= 32'd0;
        end else if (stat_clr) begin
            stat_bytes_tt <= 32'd0; stat_bytes_be <= 32'd0;
            stat_preempt  <= 32'd0; stat_reclaim  <= 32'd0;
        end else begin
            if (ev_tx_done && ev_tx_express)
                stat_bytes_tt <= stat_bytes_tt + {18'd0, ev_tx_bytes};
            if (ev_tx_done && !ev_tx_express)
                stat_bytes_be <= stat_bytes_be + {18'd0, ev_tx_bytes};
            if (ev_preempt)
                stat_preempt  <= stat_preempt + 32'd1;
            if (|ev_reclaim_ns)
                stat_reclaim  <= stat_reclaim + ev_reclaim_ns;
        end
    end

endmodule

`default_nettype wire
