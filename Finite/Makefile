SCHEME := Finite
XCODEPROJ := Finite.xcodeproj
APP_NAME := Finite.app
DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData
INSTALL_DIR := /Applications

.PHONY: build release clean setup distribute

## Development build
build: setup
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Debug build

## Release build + copy to /Applications
release: setup
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Release build
	@APP=$$(find $(DERIVED_DATA) -path "*/Finite-*/Build/Products/Release/$(APP_NAME)" -maxdepth 5 2>/dev/null | head -1); \
	if [ -z "$$APP" ]; then echo "Error: could not find built $(APP_NAME)"; exit 1; fi; \
	echo "==> Installing $(APP_NAME) to $(INSTALL_DIR)..."; \
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"; \
	cp -R "$$APP" "$(INSTALL_DIR)/$(APP_NAME)"; \
	echo "==> $(APP_NAME) installed to $(INSTALL_DIR)/$(APP_NAME)"

## Run setup.sh (ensure GhosttyKit is linked)
setup:
	@./scripts/setup.sh

## Build, sign, notarize, and publish a release (use --dry-run to preview)
distribute:
	@../scripts/distribute.sh $(ARGS)

## Clean Xcode build
clean:
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) clean
