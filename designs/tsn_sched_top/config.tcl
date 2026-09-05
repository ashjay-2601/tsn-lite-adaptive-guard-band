set ::env(DESIGN_NAME) "tsn_sched_top"
set ::env(VERILOG_FILES) "\
    $::env(DESIGN_DIR)/src/ptp_clock.v \
    $::env(DESIGN_DIR)/src/gcl_ctrl.v \
    $::env(DESIGN_DIR)/src/cbs_shaper.v \
    $::env(DESIGN_DIR)/src/guard_band.v \
    $::env(DESIGN_DIR)/src/tx_arbiter.v \
    $::env(DESIGN_DIR)/src/tx_engine.v \
    $::env(DESIGN_DIR)/src/csr_axil.v \
    $::env(DESIGN_DIR)/src/tsn_sched_top.v"
set ::env(CLOCK_PORT) "clk"
set ::env(CLOCK_PERIOD) "6.4"
set ::env(FP_CORE_UTIL) 35
set ::env(PL_TARGET_DENSITY) 0.45
set ::env(SYNTH_STRATEGY) "AREA 0"
