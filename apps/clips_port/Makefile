CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra
CLIPS_DIR ?= /usr/local/include/clips
CLIPS_LIB ?= -lclips

SRC_DIR = src
BUILD_DIR = ../cli_proxy/priv

TARGET = $(BUILD_DIR)/clips_port

SRCS = $(SRC_DIR)/main.c $(SRC_DIR)/clips_bridge.c
OBJS = $(SRCS:.c=.o)

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRCS) | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I$(CLIPS_DIR) -o $@ $(SRCS) $(CLIPS_LIB)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -f $(TARGET) $(SRC_DIR)/*.o

test:
	@echo "CLIPS port build complete"
	@test -f $(TARGET) && echo "Binary exists: OK" || echo "Binary missing: FAIL"
