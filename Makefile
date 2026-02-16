APP_NAME=YazbozNoteApp

.PHONY: build run clean

build:
	swift build

run:
	swift run $(APP_NAME)

clean:
	rm -rf .build
