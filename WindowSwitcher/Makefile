# WindowSwitcher Makefile
# Builds a macOS menu-bar app for trackpad gesture window switching.

APP_NAME       := WindowSwitcher
APP_BUNDLE     := $(APP_NAME).app
BUILD_DIR      := .build
SDK            := $(shell xcrun --show-sdk-path --sdk macosx)
ARCH           := $(shell uname -m)
TARGET         := $(ARCH)-apple-macos14.0

# ── Signing ──────────────────────────────────────────
# Override to switch identities:
#   make SIGN_IDENTITY="-"                               → ad-hoc (TCC breaks on code change)
#   make SIGN_IDENTITY="WindowSwitcher Signing"           → self-signed cert
SIGN_IDENTITY  ?= Apple Development: 1807819314@qq.com (84298355F8)

SWIFT_SOURCES  := $(shell find Sources -name '*.swift')
C_SOURCES      := Sources/GestureEngine/GestureEngine.c \
                  Sources/WindowManager/WindowCapture.c
C_OBJECTS      := $(patsubst Sources/%.c,$(BUILD_DIR)/%.o,$(C_SOURCES))
BRIDGING_HDR   := Sources/bridging-header.h

FRAMEWORKS     := -framework AppKit -framework SwiftUI -framework CoreGraphics

# ──────────────────────────────────────────────────
# Top-level targets
# ──────────────────────────────────────────────────

.PHONY: all clean run debug install

all: $(APP_BUNDLE)

clean:
	rm -rf $(BUILD_DIR)
	@echo "==> Cleaned build artifacts (app bundle preserved for TCC identity)"

run: $(APP_BUNDLE)
	open $(APP_BUNDLE)

debug: $(APP_BUNDLE)
	rm -f log.txt
	$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)

# Automated consistency test: starts the app briefly, then checks the log.
test-order: $(APP_BUNDLE)
	@rm -f log.txt
	@$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) &
	@sleep 3
	@killall $(APP_NAME) 2>/dev/null || true
	@sleep 1
	@echo ""
	@echo "=== LRU order ==="
	@grep -A 30 "Initial LRU order" log.txt | head -25 || echo "(not found)"
	@echo ""
	@echo "=== App z-order ==="
	@grep -A 30 "App z-order" log.txt | head -25 || echo "(not found)"
	@echo ""
	@echo "=== Consistency check ==="
	@grep -A 10 "ORDER CONSISTENCY CHECK" log.txt || echo "(not found)"

# ──────────────────────────────────────────────────
# App bundle
# ──────────────────────────────────────────────────

$(APP_BUNDLE): $(BUILD_DIR)/$(APP_NAME) Resources/Info.plist
	@if [ ! -d "$(APP_BUNDLE)" ]; then \
		echo "==> Creating app bundle (first time)..."; \
		rm -rf $(APP_BUNDLE); \
		mkdir -p $(APP_BUNDLE)/Contents/MacOS; \
		mkdir -p $(APP_BUNDLE)/Contents/Resources; \
		cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist; \
	fi
	@echo "==> Updating binary in bundle..."
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@echo "==> Signing $(APP_BUNDLE) with identity: $(SIGN_IDENTITY)..."
	codesign --force --sign "$(SIGN_IDENTITY)" \
		--entitlements Resources/WindowSwitcher.entitlements \
		--timestamp=none \
		$(APP_BUNDLE)
	@echo "==> Done: $(APP_BUNDLE)"

# ──────────────────────────────────────────────────
# Executable
# ──────────────────────────────────────────────────

$(BUILD_DIR)/$(APP_NAME): $(C_OBJECTS) $(SWIFT_SOURCES) $(BRIDGING_HDR)
	@echo "==> Linking $(APP_NAME)..."
	@mkdir -p $(BUILD_DIR)
	swiftc \
		$(SWIFT_SOURCES) \
		$(C_OBJECTS) \
		-import-objc-header $(BRIDGING_HDR) \
		$(FRAMEWORKS) \
		-sdk $(SDK) \
		-target $(TARGET) \
		-Xlinker -rpath -Xlinker /System/Library/PrivateFrameworks \
		-o $(BUILD_DIR)/$(APP_NAME)

# ──────────────────────────────────────────────────
# C objects
# ──────────────────────────────────────────────────

$(BUILD_DIR)/GestureEngine/%.o: Sources/GestureEngine/%.c
	@echo "==> Compiling $<..."
	@mkdir -p $(dir $@)
	clang -c $< -o $@ -isysroot $(SDK) -target $(TARGET) -O2

$(BUILD_DIR)/WindowManager/%.o: Sources/WindowManager/%.c
	@echo "==> Compiling $<..."
	@mkdir -p $(dir $@)
	clang -c $< -o $@ -isysroot $(SDK) -target $(TARGET) -O2

# ──────────────────────────────────────────────────
# Unit tests
# ──────────────────────────────────────────────────

TEST_SOURCES := Tests/TestRunner.swift \
                Sources/WindowManager/LRUOrderingEngine.swift \
                Sources/WindowManager/ActivationHistory.swift \
                Sources/WindowManager/ActivationSuppressor.swift \
                Sources/WindowManager/WindowInfo.swift \
                Sources/Common/Logger.swift \
                Sources/Common/Constants.swift

.PHONY: test
test: $(BUILD_DIR)/WindowSwitcherTests
	@$(BUILD_DIR)/WindowSwitcherTests; EXIT_CODE=$$?; \
	echo ""; \
	echo "Test exit code: $$EXIT_CODE"; \
	exit $$EXIT_CODE

$(BUILD_DIR)/WindowSwitcherTests: $(TEST_SOURCES)
	@echo "==> Compiling unit tests..."
	@mkdir -p $(BUILD_DIR)
	swiftc \
		$(TEST_SOURCES) \
		-framework AppKit -framework CoreGraphics \
		-sdk $(SDK) \
		-target $(TARGET) \
		-o $(BUILD_DIR)/WindowSwitcherTests


# ──────────────────────────────────────────────────
# Code signing diagnostics
# ──────────────────────────────────────────────────

.PHONY: sign-check tcc-reset

sign-check: $(APP_BUNDLE)
	@echo "=== Code Signature Info ==="
	@codesign -dvvv $(APP_BUNDLE) 2>&1
	@echo ""
	@echo "=== Designated Requirement ==="
	@codesign -d --requirements - $(APP_BUNDLE) 2>&1 | grep "designated" || echo "(not found)"

tcc-reset:
	@echo "==> Resetting TCC permissions for com.windowswitcher.app..."
	-tccutil reset Accessibility com.windowswitcher.app
	-tccutil reset ScreenCapture com.windowswitcher.app
	@echo "==> Done. Re-run 'make run' and grant permissions when prompted."
# ──────────────────────────────────────────────────
# Install (for development)
# ──────────────────────────────────────────────────

install: $(APP_BUNDLE)
	@echo "==> Installing to /Applications..."
	rm -rf /Applications/$(APP_BUNDLE)
	cp -R $(APP_BUNDLE) /Applications/
	@echo "==> Installed."
