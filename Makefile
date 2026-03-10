SHELL := /bin/zsh

.PHONY: setup build test run-server open-ios generate-ios

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
	cd server && dune build
	cd server && ./_build/default/test_event_mapper.exe
	cd server && ./_build/default/test_session_store.exe
	cd server && ./_build/default/test_worktree_manager.exe
	cd server && ./_build/default/test_sse.exe
	cd server && ./_build/default/test_integration.exe
	cd ios && swift test --package-path AllHandsKit

run-server:
	cd server && dune exec ./allhands_server.exe -- --host 127.0.0.1 --port 8080

open-ios:
	cd ios && xcodegen generate
	open /Users/tung/Projects/std23/allhands/ios/AllHands.xcodeproj

generate-ios:
	cd ios && xcodegen generate
