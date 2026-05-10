CC ?= cc
CFLAGS ?= -O2 -Wall -w
CLIPS_SRC ?= /tmp/clips_build/clips_core_source_640/core
CLIPS_LIB ?= $(CLIPS_SRC)/libclips.a

SRC_DIR = src
BUILD_DIR = ../cli_proxy/priv

TARGET = $(BUILD_DIR)/clips_port

SRCS = $(SRC_DIR)/main.c $(SRC_DIR)/clips_bridge.c

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SRCS) $(CLIPS_LIB) | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I$(CLIPS_SRC) -I$(SRC_DIR) -o $@ $(SRCS) $(CLIPS_LIB) -lm

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(CLIPS_LIB):
	@echo "Building CLIPS library..."
	cd $(CLIPS_SRC) && $(CC) -c -O2 -w *.c && ar rcs libclips.a *.o

clean:
	rm -f $(TARGET)

test: $(TARGET)
	@echo '{"op":"reset"}' | $(TARGET)
	@echo "CLIPS port test: OK"
