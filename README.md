# netguru

sing-box (VLESS-REALITY on tcp/443, Hysteria2 with Salamander obfuscation on udp/8443) on one locked-down Google
Cloud VM, deployed and checked with `make`. Outline (Shadowsocks) is optional and off by default.

## What it creates

With the defaults in [`gcp/config.env`](gcp/config.env), in one project:

| Resource | Default name | Notes |
|---|---|---|
| VPC and subnet | `netguru-net` | subnet `10.10.0.0/24`; nothing else runs in it |
| Firewall rules | `netguru-server-ssh-iap` | tcp:22 from IAP only, see [SSH access](#ssh-access-and-iap_source_range) |
| | `netguru-server-sing-box` | tcp 443 and udp 8443 from anywhere |
| | `netguru-server-outline` | tcp and udp 45362 from anywhere; only while `OUTLINE_ENABLED=true` |
| Static IP | `netguru-jp-ip` | the address clients connect to |
| VM | `netguru-server` | e2-small, Debian 12, 10 GB pd-balanced disk; no service account, Secure Boot, OS Login, deletion protection |

It also enables `iap.googleapis.com` and changes nothing else in the project; `make clean` removes all of it again.
The VM, disk and static IP are billable (about US$21/month in asia-northeast1 at the time of writing), plus internet
egress.

## Prerequisites

- **Workstation:** bash, make, `gcloud` (logged in with `gcloud auth login`), jq, curl, nc, python3, and
  [sing-box](https://github.com/SagerNet/sing-box/releases) on `PATH` (tested with 1.14.2; `make verify` and
  `make test` use it). `make test` also needs shellcheck, openssl and gpg.
- **Project:** billing enabled and the Compute Engine API on:
  `gcloud services enable compute.googleapis.com --project=YOUR_PROJECT`.
- **Permissions:** tested with the project Owner role. For SSH without Owner, see
  [who can connect](#ssh-access-and-iap_source_range).

## Configure

Edit [`gcp/config.env`](gcp/config.env):

- `GCP_PROJECT`: your project ID (or per run: `GCP_PROJECT=my-project make all`).
- `GCP_REGION`, `GCP_ZONE`: where the VM runs. If you move it out of Japan, also set `SINGBOX_REALITY_SNI` to a
  well-known site near the new region that serves TLS 1.3 and HTTP/2 and isn't a commonly abused default such as
  `www.apple.com`. The installer checks TLS 1.3 and HTTP/2 and stops if either is missing.
- `VM_NAME`, `NETWORK_NAME`, `NETWORK_TAG`, `STATIC_IP_NAME`: change only if they clash with existing resources.
- `OUTLINE_ENABLED`, `SINGBOX_ENABLED`: one switch per service. Outline is off by default: its Shadowsocks traffic is
  easy for censors to fingerprint, and a block of the VM's IP also cuts off REALITY and Hysteria2. Turning a service
  off on a deployed VM makes `make all` (or `make infra`) delete its firewall rule and stop it; its keys and
  credentials stay on the VM (`/opt/outline`, `/etc/sing-box`), so turning it back on restores the same client
  configs.
- `SINGBOX_HY2_SALAMANDER`: `true` by default. Every Hysteria2 packet is obfuscated, so a probe without the obfs
  password gets no reply and never sees the server's self-signed certificate. Every Hysteria2 client needs
  Salamander support and the obfs password (both are in the `make show` output); set `false` only for a client
  without it. Switching it changes the Hysteria2 client config, so re-import it from `make show`. The cost is CPU:
  Hysteria2 traffic takes about 3x the server CPU and 2x the client CPU per GB (REALITY is unaffected).
- `SINGBOX_LOG_ENABLED`, `SINGBOX_LOG_LEVEL`: sing-box server logging, on at `warn` by default. At `warn`, users'
  connections aren't logged; failed lookups and dials log the destination without the client IP, and every
  unauthenticated probe of the REALITY port logs one line with the prober's IP, which shows active probing. `info`,
  `debug` and `trace` log every connection with the client IP and destination, so use them only briefly while
  troubleshooting. Startup failures are reported (and shown by `make all`) even with logging off.
- Ports: any free ports, without leading zeros. `tcp:22` is reserved for SSH, and collisions are rejected.
  `OUTLINE_KEYS_PORT` can't be changed once Outline is installed: its existing keys stay on the old port.
- `OUTLINE_INSTALLER_URL`, `OUTLINE_INSTALLER_SHA256`, `SINGBOX_GPG_FINGERPRINT`: authenticity pins. Change them
  only after verifying the new values independently.
- `IAP_SOURCE_RANGE`: leave as is, see [below](#ssh-access-and-iap_source_range).

## Use

| Command | What it does |
|---|---|
| `make` / `make help` | list available targets |
| `make test` | shellcheck and offline unit tests; no GCP access |
| `make all` | create or reconcile the infrastructure, install or adopt each enabled service, stop turned-off ones, then `make show`; safe to re-run |
| `make show` | print `vless://` / `hysteria2://` URIs (plus Outline `ss://` keys when enabled); write a sing-box profile for SFI/SFA/SFM to `netguru-client.json` (mode 600, git-ignored), replaced only when every service answered. **Contains secrets.** |
| `make verify` | end-to-end check from your workstation: each tunnel, blocked metadata server, open and closed ports, what an active scanner sees (the real site's certificate on the REALITY port; silence from Hysteria2 without the Salamander password), VM and firewall settings, and no rules left for turned-off services |
| `make upgrade` | move sing-box to `SINGBOX_VERSION` (latest by default) and, when enabled, Outline to the current `stable` image; a no-op when current |
| `make update-ip CONFIRM=1` | give the VM a new public IP; every client config changes. If the final re-sync fails, finish with `make all`: re-running `update-ip` would rotate again |
| `make clean` | show what would be deleted; `make clean CONFIRM=<project>` deletes every netguru resource on GCP: the VM and its disk (every key and credential), the static IP, netguru's firewall rules, the subnet and the VPC. **Irreversible.** Refuses if the VM or static IP turns out not to be netguru's; keeps the VPC if anything netguru doesn't manage uses it; leaves the IAP API enabled |

`make infra` runs only the infrastructure step; `make sing-box` and `make outline` run it plus one service, and
`make upgrade-sing-box` and `make upgrade-outline` upgrade one service. For a turned-off service these targets stop at
once and name the switch to set.

Server logs (with the default `warn` level, mostly probes of the REALITY port):
`gcloud compute ssh netguru-server --zone=asia-northeast1-a --tunnel-through-iap --command='sudo journalctl -u sing-box --since -1d'`.

## SSH access and `IAP_SOURCE_RANGE`

`IAP_SOURCE_RANGE="35.235.240.0/20"` is **not your computer's IP address**. It is the range that Google's
Identity-Aware Proxy (IAP) uses to open TCP connections to VMs. It is the same for every project and every user,
so don't change it for a new user or workstation.

```
workstation --HTTPS--> tunnel.cloudproxy.app (IAP checks IAM) --tcp:22 from 35.235.240.0/20--> VM
```

- Every step that touches the VM uses `gcloud compute ssh --tunnel-through-iap`. The VM accepts port 22 only from
  IAP, and `make verify` checks that port 22 is closed to your workstation.
- IAM decides who can connect, not your IP address. It works from any network, including home connections whose IP
  changes; your workstation only needs outbound HTTPS to Google.
- Project Owners already have the access they need. Anyone else needs these roles on the project:
  `roles/iap.tunnelResourceAccessor` (IAP-Secured Tunnel User) and `roles/compute.osAdminLogin` (the VM uses
  OS Login, and the scripts run `sudo`).

**Don't set it to your own IP.** IAP could no longer reach port 22: `make infra`, and therefore `make all`, would
time out at `waiting for SSH over IAP`, and `make verify` would report port 22 as open.

**When to change it:** only if Google changes the range published in
[Use IAP for TCP forwarding](https://cloud.google.com/iap/docs/using-tcp-forwarding#create-firewall-rule). Then:

1. Set the new range in `gcp/config.env`. Separate several ranges with commas.
2. Run `make infra`. It updates the rule in place and logs
   `updating firewall rule netguru-server-ssh-iap (source-ranges)`.
3. Run `make verify` and check for `PASS  netguru-server-ssh-iap matches spec`.

If `make infra` gives up with `SSH over IAP to netguru-server not available after 150s`, check the roles above,
that your network allows HTTPS to `tunnel.cloudproxy.app`, and that no organization firewall policy blocks
`35.235.240.0/20`.

## License

[The Bindiego License (BDL), Version 1.0](LICENSE)
