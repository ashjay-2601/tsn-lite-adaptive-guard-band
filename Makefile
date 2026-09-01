RTL  := $(wildcard rtl/*.v)
IV   := iverilog -g2005 -Wall
.PHONY: all sim debug sweep synth lint clean

all: sim

sim: results/sim.vvp
	vvp results/sim.vvp

results/sim.vvp: tb/tb_sched.v $(RTL) | results
	$(IV) -o $@ tb/tb_sched.v $(RTL)

debug: tb/tb_debug.v $(RTL) | results
	$(IV) -o results/dbg.vvp tb/tb_debug.v $(RTL) && vvp results/dbg.vvp

wave: | results
	$(IV) -o results/sim.vvp tb/tb_sched.v $(RTL) && vvp results/sim.vvp +dump
	gtkwave results/tb_sched.vcd &

sweep: | results
	$(IV) -o results/sweep.vvp tb/tb_sweep.v $(RTL)
	@echo "bewin,mode,be_bytes,goodput_gbps,tt_lat_max,jitter,preempts,errors" > results/sweep.csv
	@for w in 3000 5000 7000 10000 15000 20000 30000 50000; do \
	   for m in 0 1; do \
	     vvp results/sweep.vvp +bewin=$$w +mode=$$m | grep '^CSV' | sed 's/^CSV,//' >> results/sweep.csv; \
	   done; done
	@cat results/sweep.csv

synth:
	yosys scripts/synth.ys

lint:
	verilator --lint-only -Wall -Irtl verilator.vlt rtl/tsn_sched_top.v

formal:
	sby -f formal/gb_props.sby

results:
	mkdir -p results

clean:
	rm -rf results/*.vvp results/*.vcd
