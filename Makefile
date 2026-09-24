PAK_NAME := $(shell jq -r .name pak.json)
PAK_TYPE := $(shell jq -r .type pak.json)
PAK_FOLDER := $(shell echo $(PAK_TYPE) | cut -c1)$(shell echo $(PAK_TYPE) | tr '[:upper:]' '[:lower:]' | cut -c2-)s

PUSH_SDCARD_PATH ?= /mnt/SDCARD
PUSH_PLATFORM ?= tg5040

SHELL_SCRIPTS := launch.sh scrobble_monitor.sh tests/test_scrobble_monitor.sh
TEST_SHELLS ?= sh

clean:
	true

build:
	true

lint:
	shellcheck -s sh -x $(SHELL_SCRIPTS)

test:
	for shell in $(TEST_SHELLS); do echo "== $$shell"; $$shell tests/test_scrobble_monitor.sh || exit 1; done

# Run the tests with BusyBox's shell and applets (awk, sed, ...), as on the device
test-busybox:
	bb="$$(mktemp -d)" && \
	for applet in $$(busybox --list); do ln -s "$$(command -v busybox)" "$$bb/$$applet"; done && \
	PATH="$$bb:$$PATH" busybox sh tests/test_scrobble_monitor.sh; \
	status=$$?; rm -rf "$$bb"; exit $$status

release: build
	mkdir -p dist
	git archive --format=zip --output "dist/$(PAK_NAME).pak.zip" HEAD
	while IFS= read -r file; do zip -r "dist/$(PAK_NAME).pak.zip" "$$file"; done < .gitarchiveinclude
	$(MAKE) bump-version
	zip -r "dist/$(PAK_NAME).pak.zip" pak.json
	ls -lah dist

bump-version:
	jq '.version = "$(RELEASE_VERSION)"' pak.json > pak.json.tmp
	mv pak.json.tmp pak.json

.PHONY: clean build lint test test-busybox release bump-version push

push: release
	rm -rf "dist/$(PAK_NAME).pak"
	cd dist && unzip "$(PAK_NAME).pak.zip" -d "$(PAK_NAME).pak"
	adb push "dist/$(PAK_NAME).pak/." "$(PUSH_SDCARD_PATH)/$(PAK_FOLDER)/$(PUSH_PLATFORM)/$(PAK_NAME).pak"
