PREFIX ?= $(HOME)/.local
BIN    := .build/release/siesta

.PHONY: build test install uninstall clean next-version release

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

next-version:
	scripts/release.sh next

release: test
	scripts/release.sh
