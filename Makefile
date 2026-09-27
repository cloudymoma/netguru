# netguru — secure multi-VPN on one GCP VM.
SHELL := /bin/bash
.NOTPARALLEL:
SERVICES := $(shell . gcp/config.env && echo $$SERVICES)
.PHONY: all infra $(SERVICES) upgrade $(addprefix upgrade-,$(SERVICES)) show verify update-ip test

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
