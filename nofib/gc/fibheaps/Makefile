TOP = ../..
include $(TOP)/mk/boilerplate.mk

NORM_OPTS = 300000

SRC_RUNTEST_OPTS += +RTS -K64m -RTS

ifeq "$(HEAP)" "LARGE"
SRC_RUNTEST_OPTS += +RTS -H128m -RTS
endif
ifeq "$(HEAP)" "OLD"
SRC_RUNTEST_OPTS += +RTS -H10m -RTS
endif

include $(TOP)/mk/target.mk
