.PHONY: all build build-server build-server-app build-client build-client-release clean clean-server clean-client install install-server install-server-app install-client help

all: build-server-app

build: build-server-app build-client

build-server:
	@cd pippinVR-Server && swift build -c release

build-server-app:
	@cd pippinVR-Server && ./build-app.sh release

build-client:
	@echo "Building PippinVR Client as debug"
	@cd pippinVR-client && ./gradlew assembleDebug

build-client-release:
	@echo "Building PippinVR Client as release"
	@cd pippinVR-client && ./gradlew assembleRelease

clean: clean-server clean-client

clean-server:
	@cd pippinVR-Server && swift package clean
	@rm -rf pippinVR-Server/.build
	@rm -rf pippinVR-Server/PippinVR.app

clean-client:
	@cd pippinVR-client && ./gradlew clean

install-server: build-server
	@echo "Installing server executable to /usr/local/bin..."
	@install -m 755 pippinVR-Server/.build/release/pippinvr-server /usr/local/bin/pippinvr-server

install-server-app: build-server-app
	@rm -rf /Applications/PippinVR.app
	@cp -R pippinVR-Server/PippinVR.app /Applications/

install: install-server-app

run-server: build-server
	@pippinVR-Server/.build/release/pippinvr-server --gui

run-server-cli: build-server
	@pippinVR-Server/.build/release/pippinvr-server --config pippinVR-Server/pippinvr.example.json --tcp 9943

install-client: build-client
	@echo "Installing client APK to headset"
	@adb install -r pippinVR-client/app/build/outputs/apk/debug/app-debug.apk

help:
	@echo "PippinVR Build System"
	@echo ""
	@echo "Main Targets:"
	@echo "  make                    - Build PippinVR.app (default)"
	@echo "  make build              - Build app bundle and client"
	@echo "  make install            - Install PippinVR.app to /Applications"
	@echo ""
	@echo "Server Targets:"
	@echo "  make build-server-app   - Build PippinVR.app bundle"
	@echo "  make build-server       - Build server executable only"
	@echo "  make install-server-app - Install app to /Applications"
	@echo "  make install-server     - Install executable to /usr/local/bin"
	@echo "  make run-server         - Run server in GUI mode"
	@echo "  make run-server-cli     - Run server in CLI mode"
	@echo ""
	@echo "Client Targets:"
	@echo "  make build-client       - Build Android client (debug)"
	@echo "  make build-client-release - Build client (release, unsigned)"
	@echo "  make install-client     - Install client to device via adb"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean              - Clean all build artifacts"
	@echo "  make clean-server       - Clean server build"
	@echo "  make clean-client       - Clean client build"
	@echo ""
	@echo "Help:"
	@echo "  make help               - Show this message"
