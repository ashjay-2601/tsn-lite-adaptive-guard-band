`timescale 1ns/1ps
// ============================================================================
// tb_cbs.v -- directed unit test for cbs_shaper (IEEE 802.1Qav)
//
// Every experiment up to this point configured the shaper with zero slopes,
// so credit never left zero, credit_ok was permanently high, and eight
// instances of this block sat in the netlist having never been exercised.
// This closes that gap.
//
// Credit is carried in Q16.16 *bytes*.  At 10 Gb/s on a 64-bit datapath the
// port moves 8 bytes per clock, so:
//     idle_slope_q16 = share * 8 * 65536
//     send_slope_q16 = (share - 1) * 8 * 65536      (negative)
// A 25% share therefore gives +2.0 and -6.0 bytes per clock.
//
// Six checks:
//   1  credit accumulates at idleSlope while queued and not transmitting
//   2  credit is clamped at hiCredit
//   3  credit drains at sendSlope while transmitting and goes negative
//   4  credit_ok deasserts once credit is negative
//   5  credit is forced to zero when the queue empties with credit positive
//      (Qav 8.6.8.2) -- the rule that stops a class banking credit while idle
//   6  closed-loop duty cycle converges on the configured share
//
// Check 6 is the one that matters: it proves the block actually shapes
// bandwidth rather than merely holding a counter that moves in the right
// direction.
// ============================================================================
module tb_cbs;

    localparam real CLK_NS = 6.4;
    reg clk = 0, rst_n = 0;
    always #(CLK_NS/2.0) clk = ~clk;

    localparam signed [31:0] IDLE_25 =  32'sd131072;   //  +2.0 B/clk
    localparam signed [31:0] SEND_25 = -32'sd393216;   //  -6.0 B/clk
    localparam signed [31:0] HI_CR   =  32'sd6553600;  // +100 B
    localparam signed [31:0] LO_CR   = -32'sd6553600;  // -100 B

    reg  enable = 0, q_nonempty = 0, transmitting = 0;
    reg  signed [31:0] idle_s, send_s, hi_c, lo_c;
    wire credit_ok;
    wire signed [31:0] credit;

    cbs_shaper dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .idle_slope_q16(idle_s), .send_slope_q16(send_s),
        .hi_credit_q16(hi_c), .lo_credit_q16(lo_c),
        .q_nonempty(q_nonempty), .transmitting(transmitting),
        .credit_ok(credit_ok), .credit_q16(credit)
    );

    integer errors = 0;

    task chk(input cond, input [255:0] msg);
    begin
        if (!cond) begin
            $display("[FAIL] %0s  (credit=%0d ok=%b)", msg, credit, credit_ok);
            errors = errors + 1;
        end
    end
    endtask

    integer i, tx_cycles, tot_cycles;
    real    achieved;
    reg signed [31:0] c0;

    initial begin
        idle_s = IDLE_25; send_s = SEND_25; hi_c = HI_CR; lo_c = LO_CR;
        repeat (5) @(posedge clk); rst_n = 1; @(posedge clk);
        enable = 1; @(posedge clk);

        $display("\n=== cbs_shaper directed test (25%% share) ===");

        // -- 1: accumulate at idleSlope --------------------------------------
        q_nonempty = 1; transmitting = 0;
        @(posedge clk);          // let the new input take effect first
        c0 = credit;
        repeat (10) @(posedge clk);
        chk(credit == c0 + 10*IDLE_25, "1: idleSlope accumulation wrong");
        $display("  1 idleSlope    credit after 10 clk = %0d (expect %0d)",
                 credit, c0 + 10*IDLE_25);

        // -- 2: clamp at hiCredit ---------------------------------------------
        repeat (200) @(posedge clk);
        chk(credit == HI_CR, "2: hiCredit clamp not applied");
        $display("  2 hiCredit     clamped at %0d", credit);

        // -- 3/4: drain at sendSlope, go negative, credit_ok drops ------------
        transmitting = 1;
        chk(credit_ok == 1'b1, "4a: credit_ok should be high before draining");
        @(posedge clk);          // same settling edge
        c0 = credit;
        repeat (5) @(posedge clk);
        chk(credit == c0 + 5*SEND_25, "3: sendSlope drain wrong");
        $display("  3 sendSlope    credit after 5 clk = %0d", credit);
        repeat (60) @(posedge clk);
        chk(credit < 0,        "3b: credit should have gone negative");
        chk(credit_ok == 1'b0, "4b: credit_ok should be low when negative");
        $display("  4 credit_ok    deasserted at credit=%0d", credit);

        // -- 5: recovery ------------------------------------------------------
        transmitting = 0;
        repeat (200) @(posedge clk);
        chk(credit_ok == 1'b1, "5a: credit_ok should recover");
        $display("  5 recovery     credit_ok back at credit=%0d", credit);

        // -- 5b: idle with positive credit is forced to zero (Qav 8.6.8.2) ----
        chk(credit > 0, "5b: expected positive credit before idling");
        q_nonempty = 0;
        @(posedge clk); @(posedge clk);
        chk(credit == 0, "5c: idle with positive credit must force zero");
        $display("  6 idle reset   credit forced to %0d", credit);

        // -- 6: closed loop -- does it actually shape bandwidth? --------------
        // Backlogged forever; transmit only when credit permits.  The achieved
        // duty cycle is the share the shaper is enforcing.
        q_nonempty = 1; transmitting = 0;
        repeat (500) @(posedge clk);          // settle
        tx_cycles = 0; tot_cycles = 0;
        for (i = 0; i < 200000; i = i + 1) begin
            @(posedge clk);
            transmitting = credit_ok;
            if (transmitting) tx_cycles = tx_cycles + 1;
            tot_cycles = tot_cycles + 1;
        end
        achieved = 100.0 * tx_cycles / tot_cycles;
        $display("  7 duty cycle   %0.2f %% of line rate (configured 25.00 %%)",
                 achieved);
        chk(achieved > 24.0 && achieved < 26.0,
            "7: closed-loop share outside 24-26%");

        if (errors == 0) $display("\n*** PASS: cbs_shaper verified ***\n");
        else             $display("\n*** FAIL: %0d errors ***\n", errors);
        $finish;
    end

    initial begin #20_000_000; $display("[FAIL] timeout"); $finish; end

endmodule
