################################################################################
#
# nvmemfuse
#
################################################################################

NVMEMFUSE_VERSION = 1.0
NVMEMFUSE_SITE = ../../packages/buildroot-external/nvmemfuse/src
NVMEMFUSE_SITE_METHOD = local
NVMEMFUSE_INSTALL_STAGING = NO

define NVMEMFUSE_BUILD_CMDS
	$(MAKE) CC="$(TARGET_CC)" LD="$(TARGET_LD)" -C $(@D)
endef

define NVMEMFUSE_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/nvmemfuse $(TARGET_DIR)/usr/bin
endef

$(eval $(generic-package))
