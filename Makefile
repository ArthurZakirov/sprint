APP := build/Sprint.app
BIN := $(APP)/Contents/MacOS/Sprint

.PHONY: build install
build: $(BIN)

$(BIN): Sources/main.swift Info.plist
	mkdir -p "$(APP)/Contents/MacOS"
	swiftc -warnings-as-errors Sources/main.swift -o "$(BIN)"
	cp Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"
	codesign --verify "$(APP)"

install: build
	mkdir -p "$(HOME)/Applications" "$(HOME)/.local/bin"
	ditto "$(APP)" "$(HOME)/Applications/Sprint.app"
	install -m 755 sprint "$(HOME)/.local/bin/sprint"
	/bin/bash scripts/install-login-agent.sh "$(HOME)/Applications/Sprint.app/Contents/MacOS/Sprint"
