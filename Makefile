# DayShield RootFS - Makefile
# Targets: rootfs, verify, clean

SHELL        := /bin/sh
ARCH         ?= amd64
SUITE        ?= trixie
OUTPUT       ?= rootfs.tar.zst
MIRROR       ?= http://deb.debian.org/debian
UI_DIR       ?=
SCRIPTS_DIR  := scripts
ROOTFS_DIR   ?=

.PHONY: all rootfs verify clean

all: rootfs

## Build the root filesystem archive
rootfs:
	@UI_DIR="$(UI_DIR)" sh $(SCRIPTS_DIR)/build-rootfs.sh \
		--arch  "$(ARCH)"   \
		--suite "$(SUITE)"  \
		--output "$(OUTPUT)" \
		--mirror "$(MIRROR)"

## Verify an extracted rootfs (set ROOTFS_DIR= to the path)
verify:
	@if [ -z "$(ROOTFS_DIR)" ]; then \
		echo "Usage: make verify ROOTFS_DIR=<path-to-extracted-rootfs>"; \
		exit 1; \
	fi
	@ROOTFS_DIR="$(ROOTFS_DIR)" sh $(SCRIPTS_DIR)/verify.sh

## Remove build artefacts
clean:
	rm -f $(OUTPUT)
	@echo "Cleaned $(OUTPUT)"
