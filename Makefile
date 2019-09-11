STAGEDIR := "$(CURDIR)/stage"
DESTDIR := "$(CURDIR)/install"

ARCH ?= $(shell dpkg --print-architecture)
SERIES ?= "bionic"
ifeq ($(ARCH),arm64)
	MKIMAGE_ARCH := "arm64"
else
	MKIMAGE_ARCH := "arm"
endif

SERIES_HOST ?= $(shell lsb_release --codename --short)
SOURCES_HOST ?= "/etc/apt/sources.list"
SOURCES_MULTIVERSE := "$(STAGEDIR)/apt/multiverse.sources.list"

define stage_package
	( \
		cd $(2)/debs && \
		apt-get download \
			-o APT::Architecture=$(3) \
			-o Dir::Etc::sourcelist=$(SOURCES_MULTIVERSE) $$( \
				apt-cache \
					-o APT::Architecture=$(3) \
					-o Dir::Etc::sourcelist=$(SOURCES_MULTIVERSE) \
					showpkg $(1) | \
					sed -n -e 's/^Package: *//p' | \
					sort -V | tail -1 \
		); \
	)
	dpkg-deb --extract $$(ls $(2)/debs/$(1)*.deb | tail -1) $(2)/unpack
endef

define enable_multiverse
	mkdir -p $(STAGEDIR)/apt
	cp $(SOURCES_HOST) $(SOURCES_MULTIVERSE)
	sed -i "/^deb/ s/\b$(SERIES_HOST)/$(SERIES)/" $(SOURCES_MULTIVERSE)
	sed -i "/^deb/ s/$$/ multiverse/" $(SOURCES_MULTIVERSE)
	apt-get update \
		-o Dir::Etc::sourcelist=$(SOURCES_MULTIVERSE) \
		-o APT::Architecture=$(ARCH) 2>/dev/null
endef


all: clean
	# The only supported pi architectures are armhf and arm64
	if [ "$(ARCH)" != "armhf" ] && [ "$(ARCH)" != "arm64" ]; then \
		echo "Build architecture is not supported."; \
		exit 1; \
	fi
	# XXX: This is a hack that we can hopefully get rid of once. Currently
	# the livefs Launchpad builders don't have multiverse enabled.
	# We wanto to work-around that by actually enabling multiverse just
	# for this one build here as we need it for linux-firmware-raspi2.
	$(call enable_multiverse)
	# Preparation stage
	mkdir -p $(STAGEDIR)/debs $(STAGEDIR)/unpack
	# u-boot
	$(call stage_package,flash-kernel,$(STAGEDIR),$(ARCH))
	$(call stage_package,u-boot-rpi,$(STAGEDIR),$(ARCH))
	cp boot.scr.in $(STAGEDIR)/boot.scr.in
ifeq ($(ARCH),arm64)
	sed -i s/bootz/booti/ $(STAGEDIR)/boot.scr.in
endif
	# boot-firmware
	$(call stage_package,linux-firmware-raspi2,$(STAGEDIR),$(ARCH))
	# devicetrees
	$(call stage_package,linux-modules-*-raspi2,$(STAGEDIR),$(ARCH))
	# Staging stage
	mkimage -A $(MKIMAGE_ARCH) -O linux -T script -C none -n "boot script" \
		-d $(STAGEDIR)/unpack/etc/flash-kernel/bootscript/bootscr.rpi* \
		$(STAGEDIR)/boot.scr
	mkdir -p $(DESTDIR)/boot-assets
	# u-boot
	for platform_path in $(STAGEDIR)/unpack/usr/lib/u-boot/*; do \
		cp $$platform_path/u-boot.bin $(DESTDIR)/boot-assets/uboot_$${platform_path##*/}.bin; \
	done
	cp $(STAGEDIR)/boot.scr $(DESTDIR)
	# boot-firmware
	for file in fixup start bootcode; do \
		cp $(STAGEDIR)/unpack/usr/lib/linux-firmware-raspi2/$${file}* $(DESTDIR)/boot-assets/; \
	done
	# devicetrees
	cp -a $(STAGEDIR)/unpack/lib/firmware/*/device-tree/* $(DESTDIR)/boot-assets
ifeq ($(ARCH),arm64)
	cp -a $(STAGEDIR)/unpack/lib/firmware/*/device-tree/broadcom/*.dtb $(DESTDIR)/boot-assets
endif
	# configs
	cp configs/*.txt $(DESTDIR)/boot-assets/
	cp configs/config.txt.$(ARCH) $(DESTDIR)/boot-assets/config.txt
	cp configs/user-data $(DESTDIR)/boot-assets/
	cp configs/meta-data $(DESTDIR)/boot-assets/
	cp configs/network-config $(DESTDIR)/boot-assets/
	cp configs/README $(DESTDIR)/boot-assets/
	# gadget.yaml
	mkdir -p $(DESTDIR)/meta
	cp gadget.yaml $(DESTDIR)/meta/

clean:
	-rm -rf $(DESTDIR)
	-rm -rf $(STAGEDIR)
