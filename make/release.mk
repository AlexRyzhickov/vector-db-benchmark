# Release: pack the self-contained bench archive for one platform.
# Runs on any host: import/goose are cross-compiled for $(LINUX_X86_TARGET)
# and casper/qdrant are downloaded for it (see dev.mk).

DIST_ARCHIVE ?= vector-db-benchmark-$(LINUX_X86_TARGET).tar.gz
# Top-level directory inside the archive (independent of the clone's name).
DIST_DIR := vector-db-benchmark
# The archive is packed from a staging copy, so no tar-specific renaming flags
# are needed (GNU tar on Linux, bsdtar on macOS).
DIST_STAGE := $(TOOLS_DIR)/dist

# Whitelist of what goes into the archive: everything needed to run
# `make bench-*` on the target box, nothing else (no sources, datasets,
# results or stale archives).
DIST_FILES := \
	Makefile \
	make \
	scripts \
	README.md \
	LICENSE \
	casper/casper \
	qdrant/qdrant \
	import/import \
	goose/goose

.PHONY: package-linux-x86

package-linux-x86: download-binaries build-tools-linux-x86
	@echo "Packing $(DIST_ARCHIVE)"
	@rm -rf "$(DIST_STAGE)" && mkdir -p "$(DIST_STAGE)/$(DIST_DIR)"
	@for f in $(DIST_FILES); do \
		mkdir -p "$(DIST_STAGE)/$(DIST_DIR)/$$(dirname $$f)" && \
		cp -pR "$(HERE)/$$f" "$(DIST_STAGE)/$(DIST_DIR)/$$f" || exit 1; \
	done
	@tmp_archive="$(HERE)/.$(DIST_ARCHIVE).tmp"; \
		rm -f "$$tmp_archive"; \
		COPYFILE_DISABLE=1 tar -C "$(DIST_STAGE)" --no-xattrs -czf "$$tmp_archive" "$(DIST_DIR)" \
			|| { rm -f "$$tmp_archive"; exit 1; }; \
		mv -f "$$tmp_archive" "$(HERE)/$(DIST_ARCHIVE)"
	@rm -rf "$(DIST_STAGE)"
	@echo "Archive created: $(HERE)/$(DIST_ARCHIVE)"
