# netguru

**English** | [繁體中文](README.zh-TW.md)

Your own encrypted proxy server on Google Cloud, set up in a few minutes from your browser.

An encrypted proxy relays your internet traffic: your phone or computer sends it, encrypted, to your server, and the
server passes it on to the websites and services you use, which see the server's address instead of yours. netguru
creates one small, locked-down server on Google Cloud (in Tokyo by default) and runs
[sing-box](https://sing-box.sagernet.org/) on it with two proxy protocols that are hard to detect and block:

- **VLESS-REALITY** on tcp/443: looks like an ordinary HTTPS connection to `www.yahoo.co.jp`.
- **Hysteria2** on udp/8443: fast even on poor connections, with every packet obfuscated (Salamander).

Your phones and computers connect with the free sing-box app, which sends their internet traffic through the proxy.
Outline (Shadowsocks) is optional and off by default.

## What you need

- **A Google Cloud account with billing turned on.** New customers get a
  [free trial](https://console.cloud.google.com/freetrial) with US$300 of credit for 90 days. Google doesn't charge
  you when the trial ends; it stops the server until you upgrade to a paid account. A personal Google account is
  simplest: work or school accounts may have policies that block parts of the setup.
- **A project you own.** You're the Owner of any project you create; netguru is tested with that role.
- **About 15 minutes.** Nothing to install: everything runs in Cloud Shell, the terminal built into the Google Cloud
  console.

**Cost:** about **US$21 a month** for the server, its disk and its fixed IP address in Tokyo, plus data transfer at
about US$0.12–0.23 per GB depending on where you use it (US$0.23 for mainland China), so 50 GB a month adds about
US$6–12. See Google's [network pricing](https://cloud.google.com/vpc/network-pricing#internet-egress). To stop all
charges, delete everything with [`make clean`](#everyday-commands). A
[budget alert](https://console.cloud.google.com/billing/budgets) emails you if the bill grows more than you expect.

## Quick start

### 1. Get a project with billing

1. Sign in to the [Google Cloud console](https://console.cloud.google.com/). New to Google Cloud? Start the
   [free trial](https://console.cloud.google.com/freetrial); it asks for a card to verify your identity.
2. Use your existing project (new accounts usually get "My First Project") or
   [create one](https://console.cloud.google.com/projectcreate). Note its **Project ID**, such as `my-proxy-123456`:
   it's shown in the project picker at the top of the console and can differ from the project's name.
3. Make sure the project has a billing account on the
   [billing projects page](https://console.cloud.google.com/billing/projects).

### 2. Deploy from Cloud Shell

1. In the console, click **Activate Cloud Shell** (the `>_` icon at the top), or open
   [shell.cloud.google.com](https://shell.cloud.google.com/). If Cloud Shell asks to authorize, click **Authorize**.
2. Replace `your-project-id` in the first line with your Project ID, paste all six lines into Cloud Shell, and press
   Enter:

   ```bash
   PROJECT=your-project-id
   git clone https://github.com/cloudymoma/netguru.git ~/netguru
   cd ~/netguru
   sed -i "s/^GCP_PROJECT=.*/GCP_PROJECT=\"\${GCP_PROJECT:-$PROJECT}\"/" gcp/config.env
   gcloud services enable compute.googleapis.com --project="$PROJECT"
   make all
   ```

   They download netguru, save your Project ID in [`gcp/config.env`](gcp/config.env), turn on the Compute Engine API
   and build your server, which takes a few minutes. At the end you see your server's IP address, a `vless://` link,
   a `hysteria2://` link and the paths of `netguru-client.json` (and `netguru-client-full.json`), ready-made profiles
   for the sing-box app (1.14.0 or later).

If something fails, check [Troubleshooting](#troubleshooting), then paste the lines again: every step is safe to
repeat (`git clone` just reports that the folder already exists).

Using your own Linux or Mac computer instead? See [Run it from your own computer](#run-it-from-your-own-computer).

### 3. Connect your devices

1. Install the official **sing-box** app (**1.14.0 or later**) from the
   [sing-box download page](https://sing-box.sagernet.org/clients/):
   the App Store for iPhone, iPad and Mac (needs an Apple account outside mainland China); Google Play, F-Droid or
   GitHub for Android; GitHub for Windows and Linux.
2. Download your profile by running this in Cloud Shell; your browser saves it to your Downloads folder:

   ```bash
   cloudshell download ~/netguru/netguru-client.json
   ```

   For a phone, move it over in a private way, such as AirDrop or a USB cable. Try a changed profile on one device
   before rolling it out to the rest. (`netguru-client-full.json` is a full-tunnel fallback that needs no rule-set
   download on its first launch — useful if `netguru-reality` is unreachable before `netguru-client.json` has cached
   its rule-sets.)
3. In the app, go to **Profiles → New Profile → Local → Import** and pick the file, then start it on the
   **Dashboard**. The first time, allow the permission prompt: that's how the app routes your traffic through the
   proxy.
4. To check, open a site such as https://ipinfo.io: it should show the IP address that `make all` printed.

Once your devices are set up, you can close Cloud Shell: the server keeps running on its own, and you only need Cloud
Shell again to manage it.

> [!IMPORTANT]
> The profile and the links are your keys: anyone who has them can use your server, so keep them private. You can
> print them again any time with `make show`, because they're stored on the server.

**Other apps:** the `vless://` link works in most apps that support VLESS with REALITY. Use the `hysteria2://` link
only in apps that honor its `pinSHA256` certificate pin (the official Hysteria2 client and sing-box based apps); other
apps may skip the certificate check.

## Everyday commands

Run them in the netguru folder: in a new Cloud Shell session, run `cd ~/netguru` first.

| Command | What it does |
|---|---|
| `make show` | Print your links again and rewrite `netguru-client.json` and `netguru-client-full.json`. **Contains secrets.** |
| `make all` | Apply your changes after editing `gcp/config.env`. Safe to run any time. |
| `make upgrade` | Update sing-box (and Outline, when on) on the server to the latest version. |
| `make update-ip CONFIRM=1` | Give the server a new IP address, for example if the old one is blocked. Every device must then re-import the new profile or links, which it prints at the end. |
| `make verify` | Test everything end to end; needs [extra tools](#run-it-from-your-own-computer). |
| `make clean` | List what would be deleted; `make clean CONFIRM=your-project-id` then deletes the server and everything else netguru created, keys included. **Can't be undone.** |
| `make help` | List all commands (plain `make` does the same). |

More detail:

- `make all` creates or repairs the infrastructure, installs (or adopts) each enabled service, stops turned-off ones,
  then runs `make show`. `make infra` runs only the infrastructure step; `make sing-box` and `make outline` run it plus
  one service.
- `make show` prints the `vless://` and `hysteria2://` links (plus Outline `ss://` keys when enabled) and writes two
  sing-box 1.14+ profiles for SFI/SFA/SFM (mode 600, git-ignored), replacing them only when every service answered:
  `netguru-client.json` (honoring `CLIENT_BYPASS_CN`) and `netguru-client-full.json` (always full-tunnel, with no
  first-launch rule-set download).
- `make upgrade` moves sing-box to `SINGBOX_VERSION` (latest by default) and, when enabled, Outline to the current
  `stable` image; it's a no-op when they're current. `make upgrade-sing-box` and `make upgrade-outline` upgrade one
  service. For a turned-off service, these targets stop at once and name the switch to set.
- `make update-ip`: if the final re-sync fails, finish with `make all`; re-running `update-ip` would rotate again.
- `make verify` checks, from where you run it: each tunnel, the blocked metadata server, open and closed ports, what
  an active scanner sees (the real site's certificate over TLS 1.3 + X25519 + HTTP/2 on the REALITY port, rejection of
  unrelated hostnames, warnings on TCP-close differences from the genuine site, and silence from Hysteria2 without the
  Salamander password), VM and firewall settings, and that no rules are left for turned-off services.
- `make clean` deletes the VM and its disk (every key and credential), the static IP, netguru's firewall rules, the
  subnet and the VPC. It refuses if the VM or static IP turns out not to be netguru's, keeps the VPC if anything
  netguru doesn't manage uses it, and leaves the IAP API enabled and your local `netguru-client*.json` files in place.
- `make test` runs shellcheck and offline unit tests, without GCP access; `make test-upstream` (Linux) also verifies
  SagerNet's live GPG signing key and runs the tests against the newest signed stable and testing `sing-box` packages
  without installing them.

## Settings

All settings are in [`gcp/config.env`](gcp/config.env), and the defaults work: the only one you must set is
`GCP_PROJECT`, which the Quick start does for you. After changing anything, run `make all`. In Cloud Shell,
`cloudshell edit ~/netguru/gcp/config.env` opens the file in an editor.

- `GCP_PROJECT`: your Project ID (or per run: `GCP_PROJECT=my-project make all`).
- `GCP_REGION`, `GCP_ZONE`: where the VM runs. Choose them before the first deploy; to move an existing VM, run
  `make clean` first (every client then needs the new keys and IP). If you move it out of Japan, also set
  `SINGBOX_REALITY_SNI` to a dedicated origin near the new region that is reachable from your network, serves TLS 1.3,
  HTTP/2 and X25519 on its own infrastructure (not a shared CDN such as Cloudflare or Akamai), and isn't a commonly
  abused default such as `www.apple.com`. The installer checks TLS 1.3, HTTP/2, X25519 and that the target IP does not
  return valid certificates for unrelated hostnames.
- `VM_NAME`, `NETWORK_NAME`, `NETWORK_TAG`, `STATIC_IP_NAME`: change only before the first deploy, and only if they
  clash with existing resources. `VM_MACHINE_TYPE`, `VM_DISK_*`, `VM_IMAGE_*` and `SUBNET_RANGE` apply only when the
  resource is first created.
- `OUTLINE_ENABLED`, `SINGBOX_ENABLED`: one switch per service. Outline is off by default: its Shadowsocks traffic is
  easy for censors to fingerprint, and a block of the VM's IP also cuts off REALITY and Hysteria2. Turning a service
  off on a deployed VM makes `make all` (or `make infra`) delete its firewall rule and stop it; its keys and
  credentials stay on the VM (`/opt/outline`, `/etc/sing-box`), so turning it back on restores the same client
  configs. With Outline on, import its `ss://` keys into the [Outline client](https://getoutline.org/).
- `SINGBOX_REALITY_MAX_TIME_DIFF`: `1m` by default (`""` disables). Rejects REALITY handshakes whose client clock
  differs from the server's by more than 1 minute, forwarding delayed replays to `SINGBOX_REALITY_SNI`. A device with
  an inaccurate clock fails REALITY with `reality verification failed`, while Hysteria2 continues to work.
- `SINGBOX_HY2_SALAMANDER`: `true` by default. Every Hysteria2 packet is obfuscated, so a probe without the obfs
  password gets no reply (matching a firewalled UDP port) and never sees the server's self-signed certificate. Every
  Hysteria2 client needs Salamander support and the obfs password (both are in the `make show` output); set `false`
  only for a client without it — **with Salamander off, Hysteria2 is detectable by active probing** (even though
  unauthenticated HTTP/3 requests are reverse-proxied to `SINGBOX_HY2_SNI`, the self-signed certificate is visible).
  Switching it changes the Hysteria2 client config, so re-import it from `make show`. The cost is CPU: Hysteria2
  traffic takes about 3x the server CPU and 2x the client CPU per GB (REALITY is unaffected).
- `CLIENT_BYPASS_CN`: `true` by default. In `netguru-client.json` (requires sing-box 1.14.0+), Mainland China domains
  and IPs (`geosite-cn`, `geoip-cn`) go direct with AliDNS DoH (`223.5.5.5`), so domestic traffic doesn't loop across
  the border through the VM; the rule-sets download through the proxy and are cached locally across restarts. Note
  that `geosite-cn` also includes foreign domains served from China (such as `www.gstatic.com` and
  `fonts.googleapis.com`). Set `false` (or import `netguru-client-full.json`) to send all non-private traffic through
  the proxy.
- `CLIENT_AUTO_FAILOVER`: `false` by default. When `true` and at least two server outbounds exist, both generated
  client profiles add an `auto` (`urltest`) group (`interval: 5m`, `idle_timeout: 5m`, `tolerance: 5000ms`) that
  prefers REALITY, switches to Hysteria2 within about five minutes if REALITY stops working, and stays on Hysteria2
  until Hysteria2 fails or the app restarts. Every individual server remains selectable in **Groups**, but a server
  picked there stays selected across restarts and profile imports, and failover is inactive for as long as it is: on a
  device where `proxy` was ever switched by hand, select `auto` once after importing, and again after any later manual
  switch. It is off by default because probing wakes the otherwise-silent Hysteria2 UDP port whenever the tunnel
  carries traffic (on a phone, background traffic means most of the time): at start, on the first use after five idle
  minutes, and about every ten minutes in steady use. sing-box 1.14.4 sends one burst of about 50–60 datagrams
  (30–35 KB) per probe and nothing in between (stopping once `idle_timeout` passes), whereas 1.14.2 also sends 2
  keepalive datagrams every 10 seconds even after probing stops. First launch of `netguru-client.json` while REALITY is
  down still needs `netguru-client-full.json`, which then reaches Hysteria2 by itself.
- `CLIENT_SERVER_HOST`: `""` (off) by default. Set it to a DNS hostname you control (with **only an `A` record**
  pointing at the VM's static IP and a short TTL, such as 60–300 seconds) so both generated client profiles connect by
  hostname instead of IP literal (`vless://`, `hysteria2://` and `ss://` share links still carry the IP). After an IP
  rotation, REALITY recovers on the first request once the TTL expires, and Hysteria2 recovers after about 30 seconds
  when the old IP is silently dropped — with no re-import on devices using `netguru-client*.json`. **Privacy and
  blocking cost:** DoH (`223.5.5.5`, `ipv4_only`) encrypts the lookup only between the device and AliDNS; AliDNS then
  queries your domain's authoritative name servers, and if those are outside mainland China that lookup crosses the
  border in clear text. Anyone who sees that lookup can follow the name to each new IP (giving up the secrecy a fresh
  IP otherwise has), and if the name itself is DNS-poisoned every device needs a new profile anyway. It also makes
  AliDNS something the tunnel depends on: when `223.5.5.5` cannot be reached, new REALITY connections fail once the
  cached answer expires (Hysteria2 only when it has to reconnect), although the server itself is fine.
- `SINGBOX_LOG_ENABLED`, `SINGBOX_LOG_LEVEL`: sing-box server logging, on at `warn` by default. At `warn`, users'
  connections aren't logged; failed lookups and dials log the destination without the client IP, and every
  unauthenticated probe of the REALITY port logs one line with the prober's IP, which shows active probing. `info`,
  `debug` and `trace` log every connection with the client IP and destination, so use them only briefly while
  troubleshooting. Startup failures are reported (and shown by `make all`) even with logging off.
- `SINGBOX_VERSION`: `latest` (the default) or a fixed `X.Y.Z`, installed on first deploy and by `make upgrade`.
- `SINGBOX_ENABLE_BBR`: when `true` (the default), turns on BBR congestion control on the VM for faster TCP (8 MiB UDP
  socket buffers for Hysteria2 are always configured).
- Ports: any free ports, without leading zeros. `tcp:22` is reserved for SSH, and collisions are rejected.
  `OUTLINE_API_PORT` and `OUTLINE_KEYS_PORT` can't be changed once Outline is installed: its existing keys stay on the
  old port.
- `OUTLINE_INSTALLER_URL`, `OUTLINE_INSTALLER_SHA256`, `SINGBOX_GPG_FINGERPRINT`: authenticity pins. Change them
  only after verifying the new values independently.
- `IAP_SOURCE_RANGE`: leave as is, see [below](#ssh-access-and-iap_source_range).

## What it creates

With the defaults in [`gcp/config.env`](gcp/config.env), in your project:

| Resource | Default name | Notes |
|---|---|---|
| VPC and subnet | `netguru-net` | subnet `10.10.0.0/24`; nothing else runs in it |
| Firewall rules | `netguru-server-ssh-iap` | tcp:22 from IAP only, see [SSH access](#ssh-access-and-iap_source_range) |
| | `netguru-server-sing-box` | tcp 443 and udp 8443 from anywhere |
| | `netguru-server-outline` | tcp and udp 45362 from anywhere; only while `OUTLINE_ENABLED=true` |
| Static IP | `netguru-jp-ip` | the address clients connect to |
| VM | `netguru-server` | e2-small, Debian 12, 10 GB pd-balanced disk; no service account, Secure Boot, OS Login, deletion protection |

Apart from the Compute Engine API you turn on in the Quick start (which brings the OS Login API with it), netguru
enables only the IAP API (`iap.googleapis.com`) and changes nothing else in the project. `make clean` removes all of
the above again; the APIs stay on.

"Locked down" means: SSH is reachable only through Google's Identity-Aware Proxy, never straight from the internet;
the VM holds no cloud credentials; sing-box refuses to connect to private addresses and the cloud metadata server (and
includes a best-effort guard against plaintext BitTorrent); and Secure Boot, OS Login and deletion protection are on.

## Run it from your own computer

You can also run netguru from a Linux or Mac terminal instead of Cloud Shell (on Windows, use Cloud Shell):

- **To deploy and manage:** bash, make, the [gcloud CLI](https://cloud.google.com/sdk/docs/install) (logged in with
  `gcloud auth login`), jq and curl. Clone the repository, set `GCP_PROJECT` in `gcp/config.env` with a text editor,
  then run `gcloud services enable compute.googleapis.com --project=YOUR_PROJECT_ID` and `make all`.
- **For `make verify`:** also nc, python3 and [sing-box](https://github.com/SagerNet/sing-box/releases) on `PATH`
  (tested with 1.14.2).
- **For `make test`:** also shellcheck 0.11 or newer, python3, openssl, gpg, ar (from binutils) and sing-box.

## Troubleshooting

| Problem | What to do |
|---|---|
| An error about **billing** | Link a billing account to the project on the [billing projects page](https://console.cloud.google.com/billing/projects), then paste the Quick start lines again. |
| `was not found`, `permission denied`, or "Compute Engine API has not been used ... or it is disabled" | Check the Project ID with `grep GCP_PROJECT ~/netguru/gcp/config.env`. To fix it, paste the Quick start lines again with the right ID. |
| An error naming an organization policy (`constraints/...`) | Your work or school account blocks part of the setup: use a personal Google account, or ask your admin. |
| `jq: command not found` | Install jq: `sudo apt-get install -y jq` on Debian or Ubuntu, `brew install jq` on a Mac. |
| `latest GitHub release is not a stable X.Y.Z release (got '')` | GitHub's API didn't answer, often a rate limit. Wait a few minutes and run `make all` again, or set `SINGBOX_VERSION` to a fixed version. |
| `newest signed sing-box in apt is ... retry later` | A new sing-box release isn't in its package repository yet. Wait a while, then run `make all` again. |
| `cannot reach REALITY target ...`, `... must speak HTTP/2 over TLS 1.3`, or `... serves a valid certificate for unrelated hostname ...` | Choose another `SINGBOX_REALITY_SNI` on dedicated infrastructure (see [Settings](#settings)). |
| `VM clock is not NTP-synchronized` | Wait a moment on a brand-new VM and re-run `make all`, fix NTP on the VM, or set `SINGBOX_REALITY_MAX_TIME_DIFF=""` in `gcp/config.env`. |
| `reality verification failed` on a client device | Either the device's clock is off by more than `SINGBOX_REALITY_MAX_TIME_DIFF` (1 minute by default) or its profile holds old credentials (for example after `make clean`). Turn on automatic date and time (switch `proxy` to `netguru-hy2` in **Groups** in the meantime — Hysteria2 still works); if the clock is right, re-import the profile from `make show`. |
| First launch of `netguru-client.json` exits with `initialize rule-set` | `netguru-reality` could not be reached to fetch the initial rule-sets (turning on `CLIENT_AUTO_FAILOVER` does not change this). Import `netguru-client-full.json` instead (no rule-set download) and switch `proxy` to `netguru-hy2` in **Groups** (with `CLIENT_AUTO_FAILOVER=true`, leave `proxy` on `auto`: it reaches Hysteria2 by itself). |
| `SSH over IAP to netguru-server not available after 150s` | See [SSH access](#ssh-access-and-iap_source_range). |
| It worked before, but no longer connects | In the app's **Groups** view, switch `proxy` between `netguru-reality` and `netguru-hy2`. With `CLIENT_AUTO_FAILOVER=true` the app does this on its own within about five minutes, as long as `proxy` is on `auto` (a server picked by hand stays picked until you select `auto` again). If neither protocol works, the IP address is probably blocked: see [If the server's IP is blocked](#if-the-servers-ip-is-blocked). |

Server logs (with the default `warn` level, mostly probes of the REALITY port):

```bash
gcloud compute ssh netguru-server --project=YOUR_PROJECT_ID --zone=asia-northeast1-a --tunnel-through-iap \
  --command='sudo journalctl -u sing-box --since -1d'
```

## If the server's IP is blocked

When a censor blocks the VM's IP address, both REALITY and Hysteria2 stop working at once because they share that IP.
The fix is `make update-ip CONFIRM=1`, which swaps in a new static IP on Google Cloud and re-syncs the server.

- **Keep an independent way into Google Cloud.** Running `make update-ip CONFIRM=1` requires Cloud Shell (or `gcloud`),
  and from mainland China Google Cloud itself is normally reached through this proxy. Before you need it, make sure you
  have a path that does not depend on this server — for example a roaming SIM, a backup proxy, or a trusted person
  abroad with access to the project.
- **Without `CLIENT_SERVER_HOST` (the default):** `make update-ip CONFIRM=1` prints new links and rewrites
  `netguru-client*.json` with the new IP. Every device must re-import its profile or links, and the new IP starts with
  no prior tie to the old one.
- **With `CLIENT_SERVER_HOST` set before deploying profiles:** devices using `netguru-client*.json` need no re-import —
  update the hostname's `A` record to the new IP that `make update-ip CONFIRM=1` prints (`make show` warns until the
  `A` record matches), while share links (`vless://`, `hysteria2://`, `ss://`) still change. In return, you give up
  fresh-IP secrecy: because devices resolve the name through AliDNS (`223.5.5.5`), an observer who sees AliDNS's
  clear-text query to foreign authoritative name servers can follow the hostname to each new IP, and if the hostname
  itself is DNS-poisoned every device must re-import a new profile anyway.

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
  changes; your workstation (or Cloud Shell) only needs outbound HTTPS to Google.
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

## Disclaimer

netguru is for technical learning purposes only. Use it with caution and at your own risk: laws and regulations on
encrypted proxies and similar network tools differ between countries and regions, and running or using one may be
restricted or illegal where you are or where your server runs. Check your local laws before you deploy or use netguru,
and consult a qualified legal professional if you're unsure. You're also responsible for complying with Google
Cloud's [Terms of Service](https://cloud.google.com/terms) and
[Acceptable Use Policy](https://cloud.google.com/terms/aup), and with any other rules that apply to you. netguru is
provided "as is", without warranty of any kind; to the extent permitted by law, the author accepts no liability for any
legal, compliance or other consequences of its use (see the [LICENSE](LICENSE)).
