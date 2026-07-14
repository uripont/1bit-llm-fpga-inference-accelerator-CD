# NEORV32 firmware for Proposal A hardware-cycle characterization.

MARCH = rv32i_zicsr_zifencei
EFFORT = -Os
RISCV_PREFIX ?= riscv32-unknown-elf-

Q1_ROWS ?= 1
Q1_COLS ?= 128
TIER3_USE_GGUF_FIXTURE ?= 0
ROM_SIZE ?= 16k
RAM_SIZE ?= 8k

USER_FLAGS += -DUART0_SIM_MODE
USER_FLAGS += -DQ1_ROWS=$(Q1_ROWS)u
USER_FLAGS += -DQ1_COLS=$(Q1_COLS)u
USER_FLAGS += -DTIER3_USE_GGUF_FIXTURE=$(TIER3_USE_GGUF_FIXTURE)
USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=$(ROM_SIZE)
USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=$(RAM_SIZE)

APP_SRC = main.c

NEORV32_HOME ?= ../../../../neorv32-setups/neorv32

include $(NEORV32_HOME)/sw/common/common.mk

.PHONY: q1-sim
q1-sim: $(APP_VHD)
	IMEM_SIZE=$(IMEM_SIZE) DMEM_SIZE=$(DMEM_SIZE) STOP_TIME=$(STOP_TIME) \
	../../sim/run-ghdl.sh "$(CURDIR)/$(APP_VHD)"
