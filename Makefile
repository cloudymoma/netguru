# netguru — secure multi-VPN on one GCP VM.
SHELL := /bin/bash
.NOTPARALLEL:
# Enabled services in deploy order, as gcp/lib.sh derives them from the *_ENABLED switches in gcp/config.env.
SERVICES := $(shell bash -c '. gcp/lib.sh && echo "$$SERVICES"')
OFF_SERVICES := $(filter-out $(SERVICES),$(notdir $(patsubst %/service.env,%,$(wildcard gcp/services/*/service.env))))
.PHONY: help all infra $(SERVICES) $(OFF_SERVICES) upgrade $(addprefix upgrade-,$(SERVICES) $(OFF_SERVICES)) show verify update-ip test

help:
	@printf '%s\n' \
	  'Usage: make <target>' \
	  '' \
	  'Targets:' \
	  '  help                 Show this help message (default)' \
	  '  all                  Ensure infra, deploy enabled services, and show client configs' \
	  '  infra                Ensure VPC, subnet, firewall rules, static IP, VM, SSH over IAP; stop turned-off services' \
	  '  outline              Ensure infra and deploy Outline (only when OUTLINE_ENABLED=true)' \
	  '  sing-box             Ensure infra and deploy sing-box: VLESS-REALITY + Hysteria2 (when SINGBOX_ENABLED=true)' \
	  '  upgrade              Upgrade all enabled services to their latest upstream image/release' \
	  '  upgrade-outline      Upgrade Outline shadowbox container to the latest stable digest (when enabled)' \
	  '  upgrade-sing-box     Upgrade sing-box package to SINGBOX_VERSION (latest by default)' \
	  '  show                 Print client URIs/keys and write netguru-client.json (contains secrets)' \
	  '  verify               Run end-to-end tunnel, metadata-blocking, port, and firewall checks' \
	  '  update-ip CONFIRM=1  Rotate the VM'\''s public static IP and re-sync services (every client config changes)' \
	  '  test                 Run shellcheck and offline unit tests'

all: infra $(SERVICES) show

infra:
	gcp/infra.sh

$(SERVICES): infra
	gcp/deploy.sh $@

# A turned-off service: deploy.sh refuses and names the switch to set, before infra or any GCP call.
ifneq ($(OFF_SERVICES),)
$(OFF_SERVICES) $(addprefix upgrade-,$(OFF_SERVICES)):
	@gcp/deploy.sh $(patsubst upgrade-%,%,$@)
endif

upgrade: $(addprefix upgrade-,$(SERVICES))

# Static pattern rule: plain pattern rules are skipped for .PHONY targets.
$(addprefix upgrade-,$(SERVICES)): upgrade-%:
	UPGRADE=yes gcp/deploy.sh $*

show:
	gcp/show.sh

verify:
	gcp/verify.sh

update-ip:
	gcp/update-ip.sh

test:
	shellcheck -x -P SCRIPTDIR gcp/*.sh gcp/services/*/*.sh gcp/tests/*.sh
	gcp/tests/run.sh
