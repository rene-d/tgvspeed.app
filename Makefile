# TGVSpeed — build d'une app AppKit sans Xcode
APP        := TGVSpeed.app
DMG        := TGVSpeed.dmg
CONFIG     := release
BUILD_DIR  := .build/$(CONFIG)
BUNDLE     := TGVSpeed_TGVSpeed.bundle
UNIVERSAL_DIR := .build/universal
CODESIGN_ID ?= -

.PHONY: all help build app run sim demo check clean install universal dmg

.DEFAULT_GOAL := help

## Construit TGVSpeed.app (identique à `make app`)
all: app

## Liste les cibles disponibles
help:
	@awk 'BEGIN { FS = ":" } \
	  /^## / { doc = substr($$0, 4); next } \
	  /^[a-zA-Z][a-zA-Z0-9_-]*:/ { \
	    if (doc != "") { printf "  \033[1m%-10s\033[0m %s\n", $$1, doc; doc = "" } \
	    next } \
	  { doc = "" }' $(MAKEFILE_LIST)

## Compile le paquet SwiftPM
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
#
# Une passe par architecture, réunies au lipo, plutôt que `swift build --arch
# arm64 --arch x86_64` : cette forme bascule sur XCBuild, dont la génération de
# plan échoue sur les toolchains 6.1 (« duplicate output file », SWIFT_VERSION
# vide). Deux builds SwiftPM ordinaires donnent le même binaire partout.
universal:
	swift build -c release --triple arm64-apple-macosx14.0
	swift build -c release --triple x86_64-apple-macosx14.0
	rm -rf $(UNIVERSAL_DIR)
	mkdir -p $(UNIVERSAL_DIR)
	cp -R .build/arm64-apple-macosx/release/$(BUNDLE) $(UNIVERSAL_DIR)/
	lipo -create -output $(UNIVERSAL_DIR)/TGVSpeed \
		.build/arm64-apple-macosx/release/TGVSpeed \
		.build/x86_64-apple-macosx/release/TGVSpeed
	$(MAKE) app BUILD_DIR=$(UNIVERSAL_DIR)

## Image disque prête à distribuer (`make universal dmg` pour un binaire universel)
dmg:
	@test -d $(APP) || $(MAKE) app
	rm -rf $(DMG) .build/dmg
	mkdir -p .build/dmg
	cp -R $(APP) .build/dmg/
	ln -s /Applications .build/dmg/Applications
	hdiutil create -volname TGVSpeed -srcfolder .build/dmg \
		-ov -format UDZO -quiet $(DMG)
	rm -rf .build/dmg
	@echo "==> $(DMG) prête"

## Construit puis ouvre l'application
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

## Copie l'application dans /Applications
install: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "==> installée dans /Applications"

## Supprime .build et l'app assemblée
clean:
	rm -rf .build $(APP) $(DMG)
