LABEL := com.jonaprieto.tess
AGENT := $(HOME)/Library/LaunchAgents/$(LABEL).plist
BIN   := $(CURDIR)/build/tess
APP   := /Applications/tess.app
# Signed with a certificate so macOS keeps the Accessibility grant across rebuilds; the
# ad-hoc fallback ("-") changes with every build and loses it.
SIGN ?= $(or $(shell security find-identity -v -p codesigning | grep -v REVOKED | grep -m1 -o '[0-9A-F]\{40\}'),-)

.PHONY: build test app install uninstall

# Built next to the running copy and renamed over it: overwriting a running binary in place
# invalidates its signature and macOS kills it.
build:
	swift build -c release
	mkdir -p build
	cp "$$(swift build -c release --show-bin-path)/tess" build/tess.new
	codesign -f -s "$(SIGN)" -i $(LABEL) build/tess.new
	mv -f build/tess.new build/tess

test:
	swift test

# Opened from Finder or Spotlight it shows Settings, or starts tess again after a Quit.
app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp Sources/tess/Info.plist "$(APP)/Contents/Info.plist"
	cp build/tess "$(APP)/Contents/MacOS/tess"
	cp assets/tess.icns "$(APP)/Contents/Resources/tess.icns"
	codesign -f -s "$(SIGN)" -i $(LABEL) "$(APP)"

# Started at login and restarted after a crash or a watchdog exit, not after Quit.
install: app
	mkdir -p $(HOME)/.local/bin
	ln -sf $(BIN) $(HOME)/.local/bin/tess
	sed -e 's|BIN|$(BIN)|g' -e 's|HOME|$(HOME)|g' $(LABEL).plist > "$(AGENT)"
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	@# bootout returns before the job is gone, and bootstrap fails with EIO until it is.
	@for i in 1 2 3 4 5 6 7 8 9 10; do launchctl print gui/$$(id -u)/$(LABEL) >/dev/null 2>&1 || break; sleep 0.5; done
	launchctl bootstrap gui/$$(id -u) "$(AGENT)"

uninstall:
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -f "$(AGENT)" $(HOME)/.local/bin/tess
	rm -rf "$(APP)"
