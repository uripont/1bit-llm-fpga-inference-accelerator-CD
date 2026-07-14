# NEORV32 firmware for the first Bonsai accelerator shell integration check.

MARCH = rv32i_zicsr_zifencei
EFFORT = -Os
RISCV_PREFIX ?= riscv32-unknown-elf-

USER_FLAGS += -DUART0_SIM_MODE
USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=16k
USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=8k

APP_SRC = main.c

NEORV32_HOME ?= ../../../../neorv32-setups/neorv32

include $(NEORV32_HOME)/sw/common/common.mk

.PHONY: shell-sim
shell-sim: $(APP_VHD)
	../../sim/run-ghdl.sh "$(CURDIR)/$(APP_VHD)"
