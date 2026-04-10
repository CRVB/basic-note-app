APP_NAME=NoteLight
APP_BUNDLE_NAME=Yazboz Note.app
APP_CONFIGURATION?=debug

.PHONY: build app run run-cli install-app clean

build:
	swift build

app:
	./scripts/package_app.sh $(APP_CONFIGURATION)

run:
	./scripts/package_app.sh $(APP_CONFIGURATION)
	open "dist/$(APP_CONFIGURATION)/$(APP_BUNDLE_NAME)"

run-cli:
	swift run $(APP_NAME)

install-app:
	./scripts/package_app.sh $(APP_CONFIGURATION)
	rm -rf "/Applications/$(APP_BUNDLE_NAME)"
	cp -R "dist/$(APP_CONFIGURATION)/$(APP_BUNDLE_NAME)" /Applications/
	open "/Applications/$(APP_BUNDLE_NAME)"

clean:
	rm -rf .build
