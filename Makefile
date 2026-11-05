PREFIX ?= $(HOME)/.local
BIN    := .build/release/siesta

.PHONY: build test install uninstall clean

build:
	swift build -c release

test:
	swift run -c release selftest

install: build
	$(BIN) install

uninstall:
	$(PREFIX)/bin/siesta uninstall

clean:
	rm -rf .build
