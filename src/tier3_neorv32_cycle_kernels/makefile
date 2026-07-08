# NEORV32 application makefile for the flat Tier 3 cycle kernels.

MARCH = rv32i_zicsr_zifencei
EFFORT = -O2

TIER3_USE_GGUF_FIXTURE ?= 1
TIER3_ROM_SIZE ?= 256k
TIER3_RAM_SIZE ?= 128k

ifeq ($(TIER3_USE_GGUF_FIXTURE),1)
USER_FLAGS += -DTIER3_USE_GGUF_FIXTURE
endif

USER_FLAGS += -Wl,--defsym,__neorv32_rom_size=$(TIER3_ROM_SIZE)
USER_FLAGS += -Wl,--defsym,__neorv32_ram_size=$(TIER3_RAM_SIZE)
USER_FLAGS += $(USER_FLAGS_EXTRA)

APP_SRC ?= q1_matvec.c

NEORV32_HOME ?= ../../neorv32-setups/neorv32

include $(NEORV32_HOME)/sw/common/common.mk
