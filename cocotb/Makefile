TOPLEVEL_LANG = verilog
SIM          ?= icarus
VERILOG_SOURCES = $(PWD)/../rtl/guard_band.v
TOPLEVEL      = guard_band
MODULE        = test_gb
COMPILE_ARGS += -g2005
include $(shell cocotb-config --makefiles)/Makefile.sim
