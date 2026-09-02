// ============================================================================
// frame_parser.v -- Ethernet header parse on a 64-bit AXI-Stream
//
// Frame layout (byte offsets on the wire):
//   0..5   destination MAC
//   6..11  source MAC
//   12..13 TPID   (0x8100 => 802.1Q tagged)
//   14..15 TCI    (PCP = TCI[15:13], DEI = [12], VID = [11:0])
//   16..17 EtherType
//   18..   payload
//
// Lane mapping: byte N of the frame lives in s_tdata[8*(N%8) +: 8].  Beat 0
// carries bytes 0..7, beat 1 carries bytes 8..15 -- so both TPID and TCI land
// in beat 1 and the class is known on the second cycle of the frame.  That
// matters: the VOQ manager needs the class *before* the frame ends so it can
// pick a queue while the body is still streaming in.
//
// Two outputs, at different times:
//   hdr_valid  pulses on beat 1 with the traffic class
//   desc_valid pulses on tlast with the final byte count
//
// Untagged frames get class 0.  Byte count comes from a popcount of tkeep on
// the final beat, not a fixed 8 -- the last beat is usually partial.
// ============================================================================
`default_nettype none

module frame_parser (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [63:0] s_tdata,
    input  wire [7:0]  s_tkeep,
    input  wire        s_tvalid,
    output wire        s_tready,
    input  wire        s_tlast,

    output reg         hdr_valid,      // beat 1: class known
    output reg  [2:0]  hdr_class,
    output reg         hdr_tagged,

    output reg         desc_valid,     // tlast: length known
    output reg  [13:0] desc_len,
    output reg  [2:0]  desc_class,

    output wire [63:0] m_tdata,
    output wire [7:0]  m_tkeep,
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire        m_tlast,
    output wire        m_tsop
);

    localparam [15:0] TPID_VLAN = 16'h8100;

    function [3:0] popcnt8;
        input [7:0] v;
        integer i;
        begin
            popcnt8 = 4'd0;
            for (i = 0; i < 8; i = i + 1) popcnt8 = popcnt8 + {3'd0, v[i]};
        end
    endfunction

    wire beat = s_tvalid && s_tready;

    reg  [2:0]  beat_cnt;
    reg  [13:0] byte_cnt;
    reg         in_frame;
    reg  [2:0]  cur_class;

    // big-endian reassembly out of beat 1
    wire [15:0] tpid = {s_tdata[39:32], s_tdata[47:40]};   // bytes 12,13
    wire [15:0] tci  = {s_tdata[55:48], s_tdata[63:56]};   // bytes 14,15
    wire        tagged_now = (tpid == TPID_VLAN);
    wire [2:0]  pcp_now    = tci[15:13];

    wire [13:0] this_beat_bytes = {10'd0, popcnt8(s_tkeep)};

    assign m_tsop = beat && !in_frame;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat_cnt   <= 3'd0;
            byte_cnt   <= 14'd0;
            in_frame   <= 1'b0;
            cur_class  <= 3'd0;
            hdr_valid  <= 1'b0;
            hdr_class  <= 3'd0;
            hdr_tagged <= 1'b0;
            desc_valid <= 1'b0;
            desc_len   <= 14'd0;
            desc_class <= 3'd0;
        end else begin
            hdr_valid  <= 1'b0;
            desc_valid <= 1'b0;

            if (beat) begin
                in_frame <= !s_tlast;
                byte_cnt <= (in_frame ? byte_cnt : 14'd0) + this_beat_bytes;

                if (!in_frame) beat_cnt <= 3'd1;
                else if (beat_cnt != 3'd7) beat_cnt <= beat_cnt + 3'd1;

                // beat 1 of the frame: header fields are on the bus now
                if (in_frame && (beat_cnt == 3'd1)) begin
                    cur_class  <= tagged_now ? pcp_now : 3'd0;
                    hdr_valid  <= 1'b1;
                    hdr_class  <= tagged_now ? pcp_now : 3'd0;
                    hdr_tagged <= tagged_now;
                end

                // runt frame that ends before beat 1: class defaults to 0
                if (!in_frame && s_tlast) begin
                    hdr_valid  <= 1'b1;
                    hdr_class  <= 3'd0;
                    hdr_tagged <= 1'b0;
                end

                if (s_tlast) begin
                    desc_valid <= 1'b1;
                    desc_len   <= (in_frame ? byte_cnt : 14'd0) + this_beat_bytes;
                    desc_class <= (in_frame && (beat_cnt >= 3'd2)) ? cur_class
                                : (in_frame && (beat_cnt == 3'd1) && tagged_now)
                                  ? pcp_now : 3'd0;
                end
            end
        end
    end

    assign m_tdata  = s_tdata;
    assign m_tkeep  = s_tkeep;
    assign m_tvalid = s_tvalid;
    assign m_tlast  = s_tlast;
    assign s_tready = m_tready;

endmodule

`default_nettype wire
