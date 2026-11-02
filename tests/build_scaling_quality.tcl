# Run TD from project/: td_commands_prompt.exe ../tests/build_scaling_quality.tcl
# Output stays under project/quality_build.
set source_root [file normalize [file join [file dirname [info script]] ..]]
set output_dir [file join $source_root project quality_build]
cd [file join $source_root project]
import_device eagle_s20.db -package EG4S20BG256
open_project media_player_excellence.al -single_run
load_run_param -run syn_1
elaborate -top media_player_excellence_top
read_adc ../board/player_excellence/constraints/media_player_excellence_top.adc
read_sdc ../board/player_excellence/constraints/media_player_excellence_top.sdc
file mkdir $output_dir
cd $output_dir
optimize_rtl
report_area -file quality_rtl.area
optimize_gate -packarea quality_gate.area
legalize_phy_inst
export_db quality_gate.db
place
export_db quality_place.db
set_param route fix_hold on
route
fix_hold
export_db quality_pr.db
report_area -io_info -file quality_phy.area
update_timing -mode final
report_timing_summary -file quality_pr.timing
bitgen -bit media_player_excellence_quality.bit
puts QUALITY_BITGEN_CHECK_OK
exit
