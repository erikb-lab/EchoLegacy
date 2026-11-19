APP_NAME    := EchoLegacy
TOOLCHAIN   := /home/erik/theos/toolchain/linux/iphone/bin
SDK         := /home/erik/theos/sdks/iPhoneOS4.1.sdk

CC          := $(TOOLCHAIN)/clang
LDID        := $(TOOLCHAIN)/ldid
LIPO        := $(TOOLCHAIN)/lipo
STRIP       := $(TOOLCHAIN)/strip
AR          := $(TOOLCHAIN)/llvm-ar
RANLIB      := $(TOOLCHAIN)/ranlib

BUILD_DIR   := build
OBJ_DIR     := $(BUILD_DIR)/obj
APP_DIR     := $(BUILD_DIR)/$(APP_NAME).app
IPA_FILE    := $(BUILD_DIR)/$(APP_NAME).ipa

MBED_DIR    := third_party/mbedtls
MBED_INC    := $(MBED_DIR)/include
MBED_LIBS   := third_party/build/libmbedtls.a third_party/build/libmbedx509.a third_party/build/libmbedcrypto.a
CJSON_DIR   := third_party/cjson

ARCH_FLAGS  := -target armv6-apple-darwin10 -arch armv6 -mcpu=arm1176jzf-s \
               -miphoneos-version-min=4.1 \
               -isysroot $(SDK) \
               -B$(TOOLCHAIN)

COMMON_FLAGS := $(ARCH_FLAGS) \
                -Os -fvisibility=hidden -ffunction-sections -fdata-sections \
                -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
                -DMBEDTLS_USER_CONFIG_FILE=\"mbedtls/el_user_config.h\" \
                -Isrc -I$(MBED_INC) -I$(CJSON_DIR)

CFLAGS      := $(COMMON_FLAGS)
OBJCFLAGS   := $(COMMON_FLAGS) -fno-objc-arc
LDFLAGS     := $(ARCH_FLAGS) \
               -Wl,-dead_strip \
               -framework Foundation \
               -framework UIKit \
               -framework CoreGraphics \
               -framework QuartzCore \
               -framework AVFoundation \
               -framework AudioToolbox \
               -lz -lpthread -lobjc

C_SRCS      := src/el_fmp4_adts.c $(CJSON_DIR)/cJSON.c
M_SRCS      := $(wildcard src/*.m)

C_OBJS      := $(patsubst %.c,$(OBJ_DIR)/%.o,$(notdir $(C_SRCS)))
M_OBJS      := $(patsubst src/%.m,$(OBJ_DIR)/%.o,$(M_SRCS))
ALL_OBJS    := $(C_OBJS) $(M_OBJS)

.PHONY: all clean ipa mbedtls

all: $(APP_DIR)/$(APP_NAME)

$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

$(OBJ_DIR)/el_fmp4_adts.o: src/el_fmp4_adts.c src/el_fmp4_adts.h | $(OBJ_DIR)
	$(CC) $(CFLAGS) -O2 -c $< -o $@

$(OBJ_DIR)/cJSON.o: $(CJSON_DIR)/cJSON.c $(CJSON_DIR)/cJSON.h | $(OBJ_DIR)
	$(CC) $(CFLAGS) -Wno-sign-compare -c $< -o $@

$(OBJ_DIR)/%.o: src/%.m | $(OBJ_DIR)
	$(CC) $(OBJCFLAGS) -c $< -o $@

third_party/build/libmbedtls.a: $(MBED_INC)/mbedtls/el_user_config.h
	$(MAKE) -C $(MBED_DIR)/library clean
	$(MAKE) -C $(MBED_DIR)/library static \
		CC="$(CC)" AR="$(AR)" RL="$(RANLIB)" APPLE_BUILD=0 \
		CFLAGS="$(ARCH_FLAGS) -Os -fvisibility=hidden -ffunction-sections -fdata-sections -DMBEDTLS_USER_CONFIG_FILE=\\\"mbedtls/el_user_config.h\\\""
	mkdir -p third_party/build
	cp -f $(MBED_DIR)/library/libmbedtls.a $(MBED_DIR)/library/libmbedx509.a $(MBED_DIR)/library/libmbedcrypto.a third_party/build/

third_party/build/libmbedx509.a: third_party/build/libmbedtls.a
	@:

third_party/build/libmbedcrypto.a: third_party/build/libmbedtls.a
	@:

mbedtls: $(MBED_LIBS)

$(APP_DIR)/$(APP_NAME): $(ALL_OBJS) $(MBED_LIBS) Info.plist resources/cacert.pem
	mkdir -p $(APP_DIR)
	$(CC) $(ALL_OBJS) $(MBED_LIBS) $(LDFLAGS) -o $@
	$(STRIP) -x $@
	$(LDID) -S $@
	cp Info.plist $(APP_DIR)/Info.plist
	cp resources/cacert.pem $(APP_DIR)/cacert.pem
	@if [ -f resources/Icon.png ]; then cp resources/Icon.png $(APP_DIR)/Icon.png; fi
	@if [ -f resources/Icon@2x.png ]; then cp resources/Icon@2x.png $(APP_DIR)/Icon@2x.png; fi
	printf 'APPL????' > $(APP_DIR)/PkgInfo
	chmod 755 $@
	$(LIPO) -info $@

ipa: all
	rm -rf $(BUILD_DIR)/Payload $(IPA_FILE)
	mkdir -p $(BUILD_DIR)/Payload
	cp -a $(APP_DIR) $(BUILD_DIR)/Payload/
	cd $(BUILD_DIR) && zip -qr $(APP_NAME).ipa Payload
	rm -rf $(BUILD_DIR)/Payload
	ls -lh $(IPA_FILE)

clean:
	rm -rf $(BUILD_DIR)
