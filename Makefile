SHELL := /bin/bash
LABEL := com.jonaprieto.tesela
AGENT := $(HOME)/Library/LaunchAgents/$(LABEL).plist
BIN   := $(CURDIR)/build/tesela
APP   := /Applications/tesela.app
VERSION := $(shell sed -n 's/^let version = "\(.*\)"/\1/p' Sources/tesela/Version.swift)
# Signed with a certificate so macOS keeps the Accessibility grant across rebuilds; the
# ad-hoc fallback ("-") changes with every build and loses it.
SIGN ?= $(or $(shell security find-identity -v -p codesigning | grep -v REVOKED | grep -m1 -o '[0-9A-F]\{40\}'),-)

.PHONY: build test mutants coverage e2e format lint hooks app dist deps install uninstall

deps:
	@if ! PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v folio >/dev/null; then \
	  command -v brew >/dev/null || { echo "Install Homebrew, then run brew install jonaprieto/tap/folio"; exit 1; }; \
	  brew install jonaprieto/tap/folio; \
	fi

# Built next to the running copy and renamed over it: overwriting a running binary in place
# invalidates its signature and macOS kills it.
build:
	swift build -c release
	mkdir -p build
	cp "$$(swift build -c release --show-bin-path)/tesela" build/tesela.new
	codesign -f -s "$(SIGN)" -i $(LABEL) build/tesela.new
	mv -f build/tesela.new build/tesela

# `swift test` exits 0 even when a test process ended early: each
# target's summary is the proof that it ran to the end.
test:
	@mkdir -p .build
	@set -o pipefail; swift test 2>&1 | tee .build/test.log
	@[ "$$(grep -cE 'Test run with [0-9]+ tests? .*passed' .build/test.log)" = 2 ] || { echo "make test: a test target did not finish"; exit 1; }

# SwiftPM's own report leaves the app out: this reads the app's test
# binary. Lines covered per file, TOTAL last.
coverage:
	find .build/out/Products/Debug/codecov -name '*.profraw' -delete 2>/dev/null || true
	swift test --enable-code-coverage
	find .build/out/Products/Debug/codecov -name '*.profraw' -print0 | xargs -0 xcrun llvm-profdata merge -sparse -o .build/coverage.profdata
	xcrun llvm-cov report .build/out/Products/Debug/SettingsTests.xctest/Contents/MacOS/SettingsTests -instr-profile=.build/coverage.profdata Sources/tesela

# Every mutant takes about 40 minutes; N=40 is a sample.
mutants:
	python3 -I Tests/mutants.py $(N)

format:
	swift format --in-place --recursive --parallel Sources Tests Package.swift

# What the pre-commit hook checks, on everything: format and no compiler warnings.
lint:
	pre-commit run --all-files

hooks:
	pre-commit install

# Moves real windows, of apps it opens and quits itself: see the script.
e2e: build
	./Tests/ribbon-e2e.sh

# Opened from Finder or Spotlight it shows Settings, or starts tesela again after a Quit.
app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp Sources/tesela/Info.plist "$(APP)/Contents/Info.plist"
	cp build/tesela "$(APP)/Contents/MacOS/tesela"
	cp assets/tesela.icns "$(APP)/Contents/Resources/tesela.icns"
	codesign -f -s "$(SIGN)" -i $(LABEL) "$(APP)"

# What a release carries and the Homebrew formula installs: the binary, tesela.app and the
# license, without the metadata files macOS's tar would add.
dist:
	rm -rf build/dist
	mkdir -p build/dist
	$(MAKE) app APP=$(CURDIR)/build/dist/tesela.app
	cp build/tesela LICENSE build/dist/
	COPYFILE_DISABLE=1 tar czf build/tesela-$(VERSION)-macos-arm64.tar.gz -C build/dist tesela tesela.app LICENSE
	shasum -a 256 build/tesela-$(VERSION)-macos-arm64.tar.gz

# Started at login and restarted after a crash or a watchdog exit, not after Quit.
install: deps app
	mkdir -p $(HOME)/.local/bin
	ln -sf $(BIN) $(HOME)/.local/bin/tesela
	sed -e 's|BIN|$(BIN)|g' -e 's|HOME|$(HOME)|g' $(LABEL).plist > "$(AGENT)"
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	@# bootout returns before the job is gone, and bootstrap fails with EIO until it is.
	@for i in 1 2 3 4 5 6 7 8 9 10; do launchctl print gui/$$(id -u)/$(LABEL) >/dev/null 2>&1 || break; sleep 0.5; done
	launchctl bootstrap gui/$$(id -u) "$(AGENT)"
	@$(BIN) doctor || echo "Setup needs attention; rerun tesela doctor after addressing the checks above."

uninstall:
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -f "$(AGENT)" $(HOME)/.local/bin/tesela
	rm -rf "$(APP)"
