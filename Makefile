# DayShield RootFS - Makefile
# Targets: rootfs, verify, clean

SHELL        := /bin/sh
ARCH         ?= amd64
SUITE        ?= trixie
OUTPUT       ?= rootfs.tar.zst
MIRROR       ?= https://deb.debian.org/debian
SECURITY_MIRROR ?= https://deb.debian.org/debian-security
ENABLE_SUITE_UPDATES ?= 1
UI_DIR       ?=
CORE_REPO_DIR ?=
UI_REPO_DIR   ?=
ROOTFS_REPO_DIR ?=
SCRIPTS_DIR  := scripts
ROOTFS_DIR   ?=

.PHONY: all rootfs verify clean

all: rootfs

## Build the root filesystem archive
rootfs:
	@sh $(SCRIPTS_DIR)/build-rootfs.sh \
		--arch  "$(ARCH)"   \
		--suite "$(SUITE)"  \
		--output "$(OUTPUT)" \
		--mirror "$(MIRROR)" \
		--security-mirror "$(SECURITY_MIRROR)" \
		$(if $(filter 1 true yes TRUE YES,$(ENABLE_SUITE_UPDATES)),--enable-suite-updates) \
		$(if $(UI_DIR),--ui-dir "$(UI_DIR)") \
		$(if $(CORE_REPO_DIR),--core-repo-dir "$(CORE_REPO_DIR)") \
		$(if $(UI_REPO_DIR),--ui-repo-dir "$(UI_REPO_DIR)") \
		$(if $(ROOTFS_REPO_DIR),--rootfs-repo-dir "$(ROOTFS_REPO_DIR)")

## Verify an extracted rootfs (set ROOTFS_DIR= to the path)
verify:
	@if [ -z "$(ROOTFS_DIR)" ]; then \
		echo "Usage: make verify ROOTFS_DIR=<path-to-extracted-rootfs>"; \
		exit 1; \
	fi
	@ROOTFS_DIR="$(ROOTFS_DIR)" sh $(SCRIPTS_DIR)/verify.sh

## Remove build artefacts
clean:
	rm -f "$(OUTPUT)"
	@echo "Cleaned $(OUTPUT)"
