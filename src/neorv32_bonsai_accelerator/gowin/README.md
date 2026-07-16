# Tang Nano 9K Gowin project

This directory creates the pre-PSRAM synthesis project for the combined
NEORV32 SoC and Bonsai accelerator. It targets
`GW1NR-LV9QN88PC6/I5`, enables the CFS, selects VHDL 2008, applies the board
pin mapping, and constrains the input clock to 27 MHz.

Open Gowin FPGA Designer Education, select the Console tab, and run:

```tcl
source {/absolute/path/to/src/neorv32_bonsai_accelerator/gowin/create_project.tcl}
```

Then run **Synthesize** from the Process view. Generated project files live in
`build/` and are recreated from the repository sources.

`stream_memory_boundary.vhd` keeps the PSRAM controller boundary inactive for
this setup checkpoint. The controller integration replaces this file in the
PSRAM checkpoint.

The board implementation profile supports the evaluated attention shapes with
head dimension up to 32, one KV head, and 128 locally stored scores. Gowin
elaborates the complete SoC and both engines without missing entities or HDL
errors. Mapping the monolithic combination reports 32,162 logic elements
against 8,640 available, so proposal-specific synthesis configurations are the
next resource-feasibility step.
