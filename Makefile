.PHONY: build release test smoke run app clean

build:
	swift build

release:
	swift build -c release

test:
	swift test

smoke: build
	./scripts/smoke.sh .build/debug/sauron-cli

check: test smoke

run:
	swift run SauronApp

app:
	./scripts/make_app.sh

clean:
	rm -rf .build Sauron.app
