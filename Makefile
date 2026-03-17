SHELL := /bin/zsh

SERVER_RELEASE_DIR := $(CURDIR)/dist/server-release
SERVER_RELEASE_VERSION ?= $(shell git describe --tags --always --dirty)

.PHONY: setup build test server-test server-release-local run-server open-ios generate-ios tailscalekit

setup:
	cd server && opam install . --deps-only --with-test --yes
	cd ios && swift package resolve --package-path AllHandsKit
	cd ios && xcodegen generate

build:
	cd server && dune build
	cd ios && swift build --package-path AllHandsKit
	cd ios && xcodegen generate
	cd ios && xcodebuild -project AllHands.xcodeproj -scheme AllHands -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

test:
	$(MAKE) server-test
	cd ios && swift test --package-path AllHandsKit

server-test:
	cd server && dune build
	cd server && ./_build/default/test_event_mapper.exe
	cd server && ./_build/default/test_session_store.exe
	cd server && ./_build/default/test_worktree_manager.exe
	cd server && ./_build/default/test_sse.exe
	cd server && ./_build/default/test_launcher_catalog.exe
	cd server && ./_build/default/test_host_server_api.exe
	cd server && ./_build/default/test_integration.exe
	cd server && node --test web_ui/*.test.js

server-release-local: server-test
	rm -rf "$(SERVER_RELEASE_DIR)"
	TARGET_ARCH=amd64 VERSION="$(SERVER_RELEASE_VERSION)" OUTPUT_DIR="$(SERVER_RELEASE_DIR)" ./scripts/build_server_release_docker.sh
	TARGET_ARCH=arm64 VERSION="$(SERVER_RELEASE_VERSION)" OUTPUT_DIR="$(SERVER_RELEASE_DIR)" ./scripts/build_server_release_docker.sh
	./scripts/generate_release_checksums.sh "$(SERVER_RELEASE_DIR)"

run-server:
	cd server && dune exec ./allhands_server.exe -- --host 0.0.0.0 --port 21991

open-ios:
	cd ios && xcodegen generate
	open /Users/tung/Projects/std23/allhands/ios/AllHands.xcodeproj

generate-ios:
	cd ios && xcodegen generate

tailscalekit:
	./scripts/bootstrap_tailscalekit.sh
