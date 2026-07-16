# Create a proposal-specific or combined Tang Nano 9K NEORV32 project.
# Run from the Gowin IDE console with: source /absolute/path/create_project.tcl

set script_dir [file normalize [file dirname [info script]]]
set repo_dir [file normalize [file join $script_dir ../../..]]
if {![info exists bonsai_profile]} {
  set bonsai_profile proposal_a
}
if {$bonsai_profile ni {proposal_a proposal_b_cpu_push proposal_b_mem_stream combined}} {
  error "unsupported bonsai_profile: $bonsai_profile"
}
set project_name bonsai_tang_nano_9k_${bonsai_profile}
set build_dir [file join $script_dir build]

file mkdir $build_dir
catch {close_project}
create_project -name $project_name -dir $build_dir \
  -pn GW1NR-LV9QN88PC6/I5 -device_version C -force
set project_dir [file join $build_dir $project_name]
open_project [file join $project_dir ${project_name}.gprj]

set core_dir [file join $repo_dir neorv32-setups neorv32 rtl core]
foreach source [lsort [glob [file join $core_dir *.vhd]]] {
  if {[file tail $source] ne "neorv32_cfs.vhd"} {
    import_files -file $source -force
    set_file_prop -lib neorv32 [file join $project_dir src [file tail $source]]
  }
}

set accel_dir [file join $repo_dir src neorv32_bonsai_accelerator rtl]
set accel_sources {
  bonsai_accel_pkg.vhd
  local_buffer_bank.vhd
  stream_frontend.vhd
  frontend_control.vhd
  memory_streamer.vhd
  q1_matvec_engine.vhd
  attn_kv_engine.vhd
  accel_top.vhd
  counter_block.vhd
  cfs_reg_file.vhd
  bonsai_cfs_core.vhd
}
foreach source $accel_sources {
  set path [file join $accel_dir $source]
  import_files -file $path -force
  set_file_prop -lib neorv32 [file join $project_dir src $source]
}

if {$bonsai_profile eq "proposal_a"} {
  set cfs_wrapper [file join $script_dir neorv32_cfs_proposal_a.vhd]
} elseif {$bonsai_profile eq "proposal_b_cpu_push"} {
  set cfs_wrapper [file join $script_dir neorv32_cfs_proposal_b.vhd]
} elseif {$bonsai_profile eq "proposal_b_mem_stream"} {
  set cfs_wrapper [file join $script_dir neorv32_cfs_proposal_b_mem_stream.vhd]
} else {
  set cfs_wrapper [file join $accel_dir neorv32_cfs.vhd]
}
import_files -file $cfs_wrapper -force
set_file_prop -lib neorv32 [file join $project_dir src [file tail $cfs_wrapper]]

if {$bonsai_profile eq "proposal_b_mem_stream"} {
  import_files -file [file join $script_dir psram_stream_boundary.vhd] -force
  set board_top [file join $script_dir bonsai_tang_nano_9k_proposal_b_mem_stream_top.vhd]
  set psram_ip_dir [file join $script_dir ip psram_hs]
  set pll_ip_dir [file join $script_dir ip pll_27_to_54]
  foreach ip_dir [list $psram_ip_dir $pll_ip_dir] {
    if {![file isdirectory $ip_dir]} {
      error "missing generated Gowin IP directory: $ip_dir"
    }
    foreach source [lsort [glob -nocomplain -directory $ip_dir *.v *.vh]] {
      if {[string match *_tmp.v [file tail $source]]} {
        continue
      }
      import_files -file $source -force
    }
  }
} elseif {$bonsai_profile eq "proposal_b_cpu_push"} {
  import_files -file [file join $script_dir stream_memory_boundary.vhd] -force
  set_file_prop -lib neorv32 [file join $project_dir src stream_memory_boundary.vhd]
  set board_top [file join $script_dir bonsai_tang_nano_9k_proposal_b_top.vhd]
} else {
  import_files -file [file join $script_dir stream_memory_boundary.vhd] -force
  set_file_prop -lib neorv32 [file join $project_dir src stream_memory_boundary.vhd]
  set board_top [file join $script_dir bonsai_tang_nano_9k_top.vhd]
}
import_files -file $board_top -force
import_files -file [file join $repo_dir neorv32-setups gowineda tang-nano-9k tang-nano-9k_test_setup_bootloader.cst] -force
import_files -file [file join $script_dir tang_nano_9k.sdc] -force

set_option -top_module bonsai_tang_nano_9k_top
set_option -synthesis_tool gowinsynthesis
set_option -vhdl_std vhd2008
set_option -global_freq 27
set_option -output_base_name bonsai_tang_nano_9k
set_option -use_done_as_gpio 1

puts "BONSAI_GOWIN_PROJECT_READY profile=$bonsai_profile path=$project_dir"
