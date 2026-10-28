# netguru — secure multi-VPN on one GCP VM.
SHELL := /bin/bash
.NOTPARALLEL:
SERVICES := $(shell . gcp/config.env && echo $$SERVICES)
.PHONY: help all infra $(SERVICES) upgrade $(addprefix upgrade-,$(SERVICES)) show verify update-ip test

help:
	@printf '%s\n' \
	  'Usage: make <target>' \
	  '' \
	  'Targets:' \
	  '  help                 Show this help message (default)' \
	  '  all                  Ensure infra, deploy all services, and show client configs' \
	  '  infra                Ensure VPC, subnet, firewall rules, static IP, VM, and SSH over IAP' \
	  '  outline              Ensure infra and deploy Outline' \
	  '  sing-box             Ensure infra and deploy sing-box (VLESS-REALITY + Hysteria2)' \
	  '  upgrade              Upgrade all services to their latest upstream image/release' \
	  '  upgrade-outline      Upgrade Outline shadowbox container to the latest stable digest' \
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
