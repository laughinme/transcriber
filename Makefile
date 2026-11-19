FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TEST_FLAGS := -Xswiftc -F$(FW) -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xlinker -F$(FW) -Xlinker -rpath -Xlinker $(FW)

.PHONY: build test test-e2e app install run clean

build:            ## debug build
	swift build

test:             ## unit tests (seconds)
	swift test $(TEST_FLAGS)

test-e2e:         ## + end-to-end run on the real whisper-cli
	TRANSCRIBER_E2E=1 swift test $(TEST_FLAGS)

app:              ## release build packed into dist/Расшифровка.app
	./scripts/build-app.sh

install: app      ## copy the app to /Applications
	rm -rf "/Applications/Расшифровка.app"
	cp -R "dist/Расшифровка.app" /Applications/
	@echo "Installed /Applications/Расшифровка.app"

run: app
	open "dist/Расшифровка.app"

clean:
	rm -rf .build dist
