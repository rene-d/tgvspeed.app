# TGVSpeed — build d'une app AppKit sans Xcode
APP        := TGVSpeed.app
CONFIG     := release
BUILD_DIR  := .build/$(CONFIG)
BUNDLE     := TGVSpeed_TGVSpeed.bundle
CODESIGN_ID ?= -

.PHONY: all build app run sim demo check clean install universal

all: app

build:
	swift build -c $(CONFIG)

## Assemble TGVSpeed.app à partir du binaire SwiftPM
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BUILD_DIR)/TGVSpeed $(APP)/Contents/MacOS/TGVSpeed
	cp Support/Info.plist $(APP)/Contents/Info.plist
	cp Support/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp -R $(BUILD_DIR)/$(BUNDLE) $(APP)/Contents/Resources/
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign --force --deep --options runtime \
		--entitlements Support/TGVSpeed.entitlements \
		--sign "$(CODESIGN_ID)" $(APP)
	@echo "==> $(APP) prête"

## Binaire universel arm64 + x86_64
universal: BUILD_DIR := .build/apple/Products/Release
universal:
	swift build -c release --arch arm64 --arch x86_64
	$(MAKE) app BUILD_DIR=.build/apple/Products/Release

run: app
	open $(APP)

## Simulateur : sert les 4 endpoints sur http://localhost:8000
sim:
	swift run tgvsim

## Lance l'app en mode démo contre le simulateur (faire `make sim` dans un autre terminal)
demo: app
	TGVSPEED_BASE_URL=http://localhost:8000 $(APP)/Contents/MacOS/TGVSpeed

## Imprime le menu tel qu'il serait construit, contre un simulateur éphémère
check: app
	@swift build -c $(CONFIG) --product tgvsim >/dev/null
	@$(BUILD_DIR)/tgvsim --port 8321 >/dev/null 2>&1 & \
	  until curl -s -m 1 -o /dev/null http://localhost:8321/train/gps; do :; done; \
	  TGVSPEED_BASE_URL=http://localhost:8321 $(APP)/Contents/MacOS/TGVSpeed --dump-menu; \
	  status=$$?; \
	  pkill -f "tgvsim --port 8321"; \
	  exit $$status

install: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "==> installée dans /Applications"

clean:
	rm -rf .build $(APP)
