# create_adc_qsys.tcl — auto-generates adc_system Qsys project for fpga-voltmeter.
# Interface names verified from altera_modular_adc_hw.tcl (Quartus 17.1)
package require -exact qsys 14.0

# ---- Create system ----
create_system {adc_system}
set_project_property DEVICE_FAMILY {MAX 10}
set_project_property DEVICE {10M50DAF484C7G}

# ---- Clock source ----
# Represents the external 50 MHz from MAX10_CLK1_50.
# clk_in  = exported INPUT  (receives clock from top-level RTL)
# clk     = internal output (drives ADC instances)
add_instance clk_0 clock_source
set_instance_parameter_value clk_0 {clockFrequency}       {50000000}
set_instance_parameter_value clk_0 {clockFrequencyKnown}  {1}
set_instance_parameter_value clk_0 {resetSynchronousEdges} {NONE}

# ---- Modular ADC Core ----
# CORE_VAR=0: Standard sequencer + Avalon-MM sample storage.
#   Exposes sequencer_csr (addr 0-3: cmd, cmd_fifo, resp_fifo, status)
#   and sample_store_csr (unused — left unconnected, generates warning only).
add_instance adc_0 altera_modular_adc
set_instance_parameter_value adc_0 {CORE_VAR}         {0}
# use_ch1 is user-settable BOOLEAN; analog_input_pin_mask is DERIVED (cannot be set directly)
set_instance_parameter_value adc_0 {use_ch1}          {true}
# Sequencer: 1 slot, slot_1 → CH1
set_instance_parameter_value adc_0 {seq_order_length} {1}
set_instance_parameter_value adc_0 {seq_order_slot_1} {1}

# ---- Internal connections ----
add_connection clk_0.clk       adc_0.clock
add_connection clk_0.clk       adc_0.adc_pll_clock
add_connection clk_0.clk_reset adc_0.reset_sink

# ---- Exported top-level ports ----
# Export clk_0.clk_in (the INPUT to clock_source) — becomes clk_clk port
add_interface clk clock end
set_interface_property clk EXPORT_OF clk_0.clk_in

# Export clk_0.clk_in_reset (the INPUT reset to clock_source) — becomes reset_reset_n port
add_interface reset reset end
set_interface_property reset EXPORT_OF clk_0.clk_in_reset

# Export ADC sequencer CSR (1-bit addr) → ports: adc_address, adc_read,
#   adc_readdata, adc_write, adc_writedata  (no waitrequest)
add_interface adc avalon end
set_interface_property adc EXPORT_OF adc_0.sequencer_csr

# Export sample store CSR (7-bit addr, 2-cycle read latency) → ports: ss_address,
#   ss_read, ss_readdata, ss_write, ss_writedata  (no waitrequest)
# addr 0 = slot-0 result (CH1 ADC reading), addr 0x40 = IER, addr 0x41 = ISR
add_interface ss avalon end
set_interface_property ss EXPORT_OF adc_0.sample_store_csr

# Export adc_pll_locked conduit (required by ADC control FSM) → port: adc_pll_locked_export
# Tie HIGH in RTL when clock source is a stable oscillator (no PLL).
add_interface adc_pll_locked conduit end
set_interface_property adc_pll_locked EXPORT_OF adc_0.adc_pll_locked

# ---- Save ----
file mkdir {adc_system}
save_system {adc_system/adc_system.qsys}
puts "adc_system.qsys saved."
