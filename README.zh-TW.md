# netguru

[English](README.md) | **繁體中文**

在 Google Cloud 上架設你自己的加密代理伺服器，只要用瀏覽器，幾分鐘就能完成。

加密代理會幫你轉送網路流量：你的手機或電腦先把流量加密後送到你的伺服器，再由伺服器轉給你使用的網站和服務，對方看到的會是伺服器的位址，而不是你的。netguru 會在 Google Cloud 上建立一台小型、經過安全強化的伺服器（預設位於東京），並在上面執行 [sing-box](https://sing-box.sagernet.org/)，提供兩種難以偵測和封鎖的代理協定：

- **VLESS-REALITY**（tcp/443）：看起來就像一般連往 `www.yahoo.co.jp` 的 HTTPS 連線。
- **Hysteria2**（udp/8443）：即使網路品質不佳也很快，而且每個封包都經過混淆（Salamander）。

你的手機和電腦使用免費的 sing-box App 連線，App 會讓裝置的網路流量經由代理傳送。Outline（Shadowsocks）為選用功能，預設關閉。

## 事前準備

- **已啟用計費功能的 Google Cloud 帳戶。** 新客戶可以申請[免費試用](https://console.cloud.google.com/freetrial)，在 90 天內使用 300 美元的抵免額。試用期結束時 Google 不會向你收費，而是會停止伺服器，直到你升級為付費帳戶。使用個人 Google 帳戶最簡單；公司或學校帳戶可能有政策擋下部分設定步驟。
- **一個你擁有的專案。** 你自己建立的專案，你就是它的擁有者（Owner）；netguru 是以這個角色測試的。
- **大約 15 分鐘。** 不需要安裝任何東西：所有步驟都在 Cloud Shell 中執行，它是 Google Cloud 控制台內建的終端機。

**費用：** 東京的伺服器、磁碟和固定 IP 位址每月約 **21 美元**，另加資料移轉（流量）費用：依使用地點約每 GB 0.12–0.23 美元（中國大陸為 0.23 美元），例如每月 50 GB 約增加 6–12 美元。詳情請參閱 Google 的[網路定價](https://cloud.google.com/vpc/network-pricing?hl=zh-tw#internet-egress)。如要停止所有費用，請用 [`make clean`](#日常指令) 刪除所有資源。設定[預算快訊](https://console.cloud.google.com/billing/budgets)後，帳單超出預期時就會寄電子郵件通知你。

## 快速入門

### 1. 準備一個已啟用計費功能的專案

1. 登入 [Google Cloud 控制台](https://console.cloud.google.com/)。第一次使用 Google Cloud？請先開始[免費試用](https://console.cloud.google.com/freetrial)，過程中會要求提供信用卡等付款資訊以驗證身分。
2. 使用現有專案（新帳戶通常會有一個「My First Project」），或[建立新專案](https://console.cloud.google.com/projectcreate)。記下它的**專案 ID**，例如 `my-proxy-123456`：專案 ID 會顯示在控制台頂端的專案挑選器中，而且可能和專案名稱不同。
3. 到 [Cloud Billing 的專案頁面](https://console.cloud.google.com/billing/projects)確認該專案已連結 Cloud Billing 帳戶。

### 2. 從 Cloud Shell 部署

1. 在控制台中點選「**啟用 Cloud Shell**」（頂端的 `>_` 圖示），或開啟 [shell.cloud.google.com](https://shell.cloud.google.com/)。如果 Cloud Shell 要求授權，請點選「**授權**」。
2. 把第一行的 `your-project-id` 換成你的專案 ID，再將這六行全部貼到 Cloud Shell，然後按 Enter 鍵：

   ```bash
   PROJECT=your-project-id
   git clone https://github.com/cloudymoma/netguru.git ~/netguru
   cd ~/netguru
   sed -i "s/^GCP_PROJECT=.*/GCP_PROJECT=\"\${GCP_PROJECT:-$PROJECT}\"/" gcp/config.env
   gcloud services enable compute.googleapis.com --project="$PROJECT"
   make all
   ```

   這些指令會下載 netguru、把你的專案 ID 寫入 [`gcp/config.env`](gcp/config.env)、啟用 Compute Engine API 並建置你的伺服器，整個過程需要幾分鐘。完成後會顯示伺服器的 IP 位址、一個 `vless://` 連結、一個 `hysteria2://` 連結，以及 `netguru-client.json` 的路徑；這個檔案是給 sing-box App 使用的現成設定檔。

如果有步驟失敗，請先參閱[疑難排解](#疑難排解)，然後再貼上一次這些指令：每個步驟都可以安全地重複執行（`git clone` 只會提示資料夾已經存在）。

想改用自己的 Linux 或 Mac 電腦？請參閱[在自己的電腦上執行](#在自己的電腦上執行)。

### 3. 連接你的裝置

1. 從 [sing-box 下載頁面](https://sing-box.sagernet.org/zh/clients/)安裝官方的 **sing-box** App：iPhone、iPad 和 Mac 請用 App Store（需要中國大陸以外地區的 Apple 帳號）；Android 可用 Google Play、F-Droid 或 GitHub；Windows 和 Linux 請從 GitHub 下載。
2. 在 Cloud Shell 執行下列指令下載設定檔，瀏覽器會把它存到「下載」資料夾：

   ```bash
   cloudshell download ~/netguru/netguru-client.json
   ```

   如果要在手機上使用，請用私密的方式傳過去，例如 AirDrop 或 USB 傳輸線。
3. 在 App 中依序點選 **設定檔 → 新增設定檔 → 本地 → 匯入**（英文介面為 **Profiles → New Profile → Local → Import**）並選取該檔案，然後在**儀表**（Dashboard）頁面啟動。第一次啟動時請允許系統的權限要求：App 需要這項權限，才能讓流量經由代理傳送。
4. 檢查方式：開啟 https://ipinfo.io 之類的網站，畫面上應該會顯示 `make all` 印出的 IP 位址。

裝置都設定好之後就可以關閉 Cloud Shell：伺服器會自行持續運作，只有在需要管理時才要再開啟 Cloud Shell。

> [!IMPORTANT]
> 設定檔和連結就是你的金鑰：任何人拿到都能使用你的伺服器，請妥善保管。金鑰存放在伺服器上，隨時可以用 `make show` 再次顯示。

**其他 App：** `vless://` 連結適用於大多數支援 VLESS + REALITY 的 App。`hysteria2://` 連結則只能用在會遵守其 `pinSHA256` 憑證釘選的 App（官方 Hysteria2 用戶端，以及以 sing-box 為核心的 App）；其他 App 可能會略過憑證檢查。

## 日常指令

請在 netguru 資料夾中執行這些指令：開啟新的 Cloud Shell 工作階段後，請先執行 `cd ~/netguru`。

| 指令 | 用途 |
|---|---|
| `make show` | 再次顯示你的連結，並重新產生 `netguru-client.json`。**內含機密資訊。** |
| `make all` | 修改 `gcp/config.env` 後套用變更。隨時都可以安全地執行。 |
| `make upgrade` | 將伺服器上的 sing-box（以及已開啟的 Outline）更新到最新版本。 |
| `make update-ip CONFIRM=1` | 為伺服器更換新的 IP 位址，例如舊位址遭到封鎖時。之後每台裝置都必須重新匯入新的設定檔或連結，指令最後會顯示它們。 |
| `make verify` | 端對端測試所有功能；需要[額外工具](#在自己的電腦上執行)。 |
| `make clean` | 列出將被刪除的項目；接著執行 `make clean CONFIRM=your-project-id`，就會刪除伺服器以及 netguru 建立的所有其他資源，包括金鑰。**無法復原。** |
| `make help` | 列出所有指令（直接執行 `make` 也一樣）。 |

更多細節：

- `make all` 會建立或修復基礎架構、安裝（或接管）每個已開啟的服務、停止已關閉的服務，最後執行 `make show`。`make infra` 只執行基礎架構步驟；`make sing-box` 和 `make outline` 則會在基礎架構步驟之外，再部署單一服務。
- `make show` 會顯示 `vless://` 和 `hysteria2://` 連結（開啟 Outline 時另有 `ss://` 金鑰），並把給 SFI/SFA/SFM 使用的 sing-box 設定檔寫入 `netguru-client.json`（權限 600，已列入 git 忽略清單）；只有在每個服務都有回應時才會取代舊檔案。
- `make upgrade` 會把 sing-box 升級到 `SINGBOX_VERSION`（預設為最新版），並在 Outline 開啟時將它更新到目前的 `stable` 映像檔；已是最新版本時不會做任何變更。`make upgrade-sing-box` 和 `make upgrade-outline` 只升級單一服務。如果服務已關閉，這些目標會立即停止，並指出需要設定哪個開關。
- `make update-ip`：如果最後的重新同步失敗，請執行 `make all` 完成；再次執行 `update-ip` 會再換一次 IP。
- `make verify` 會從執行它的地方檢查：每條通道、中繼資料伺服器是否已封鎖、哪些連接埠開啟或關閉、主動掃描者會看到什麼（REALITY 連接埠回應的是真實網站的憑證；沒有 Salamander 密碼的 Hysteria2 探測得不到任何回應）、VM 和防火牆設定，以及已關閉的服務沒有殘留任何規則。
- `make clean` 會刪除 VM 及其磁碟（連同所有金鑰和憑證）、靜態 IP、netguru 的防火牆規則、子網路和 VPC。如果 VM 或靜態 IP 看起來不屬於 netguru，它會拒絕執行；如果有 netguru 以外的資源在使用該 VPC，就會保留 VPC；IAP API 會維持啟用，你本機的 `netguru-client.json` 也會保留。
- `make test` 會執行 shellcheck 和離線單元測試，不需要存取 GCP。

## 設定

所有設定都在 [`gcp/config.env`](gcp/config.env) 中，預設值即可直接使用：唯一必須設定的是 `GCP_PROJECT`，快速入門已經幫你設定好了。修改任何設定後，請執行 `make all`。在 Cloud Shell 中執行 `cloudshell edit ~/netguru/gcp/config.env`，即可用編輯器開啟這個檔案。

- `GCP_PROJECT`：你的專案 ID（也可以在每次執行時指定：`GCP_PROJECT=my-project make all`）。
- `GCP_REGION`、`GCP_ZONE`：VM 所在的區域和可用區。請在第一次部署前決定；如要搬移現有的 VM，請先執行 `make clean`（之後每個用戶端都需要新的金鑰和 IP）。如果搬到日本以外，也請把 `SINGBOX_REALITY_SNI` 改為新區域附近、支援 TLS 1.3 和 HTTP/2 的知名網站，並避開 `www.apple.com` 這類常被濫用的預設值。安裝程式會檢查 TLS 1.3 和 HTTP/2，缺少任一項就會停止。
- `VM_NAME`、`NETWORK_NAME`、`NETWORK_TAG`、`STATIC_IP_NAME`：只有在第一次部署前、而且與現有資源衝突時才需要修改。`VM_MACHINE_TYPE`、`VM_DISK_*`、`VM_IMAGE_*` 和 `SUBNET_RANGE` 只在資源首次建立時生效。
- `OUTLINE_ENABLED`、`SINGBOX_ENABLED`：每個服務各有一個開關。Outline 預設關閉：它的 Shadowsocks 流量很容易被審查者辨識出特徵，而 VM 的 IP 一旦遭到封鎖，REALITY 和 Hysteria2 也會一併中斷。在已部署的 VM 上關閉某個服務後，`make all`（或 `make infra`）會刪除它的防火牆規則並停止該服務；它的金鑰和憑證會保留在 VM 上（`/opt/outline`、`/etc/sing-box`），所以重新開啟後，用戶端設定仍然相同。開啟 Outline 時，請把它的 `ss://` 金鑰匯入 [Outline 用戶端](https://getoutline.org/zh-TW/)。
- `SINGBOX_HY2_SALAMANDER`：預設為 `true`。每個 Hysteria2 封包都會經過混淆，因此沒有混淆密碼（obfs password）的探測得不到任何回應，也看不到伺服器的自簽憑證。每個 Hysteria2 用戶端都必須支援 Salamander 並具備混淆密碼（兩者都在 `make show` 的輸出中）；只有在用戶端不支援時才設為 `false`。切換這項設定會改變 Hysteria2 的用戶端設定，請從 `make show` 重新匯入。代價是 CPU：每 GB 的 Hysteria2 流量約耗用 3 倍的伺服器 CPU 和 2 倍的用戶端 CPU（REALITY 不受影響）。
- `SINGBOX_LOG_ENABLED`、`SINGBOX_LOG_LEVEL`：sing-box 伺服器日誌，預設開啟，等級為 `warn`。在 `warn` 等級下不會記錄使用者的連線；DNS 查詢或連線失敗時會記錄目的地，但不含用戶端 IP；每次對 REALITY 連接埠的未經驗證探測都會記錄一行，包含探測者的 IP，可藉此發現主動探測。`info`、`debug` 和 `trace` 會記錄每條連線的用戶端 IP 和目的地，請只在疑難排解時短暫使用。即使關閉日誌，啟動失敗仍會回報（並由 `make all` 顯示）。
- `SINGBOX_VERSION`：`latest`（預設）或固定版本 `X.Y.Z`，會在首次部署和執行 `make upgrade` 時安裝。
- `SINGBOX_ENABLE_BBR`：設為 `true`（預設）時，會在 VM 上開啟 BBR 壅塞控制，讓 TCP 更快。
- 連接埠：任何未使用的連接埠都可以，但不能有前導零。`tcp:22` 保留給 SSH，連接埠衝突會被拒絕。Outline 安裝後就不能再修改 `OUTLINE_API_PORT` 和 `OUTLINE_KEYS_PORT`：它現有的金鑰會留在舊的連接埠上。
- `OUTLINE_INSTALLER_URL`、`OUTLINE_INSTALLER_SHA256`、`SINGBOX_GPG_FINGERPRINT`：用來確保下載內容真實可信的固定值。只有在自行獨立驗證過新值之後才可以修改。
- `IAP_SOURCE_RANGE`：請保持原樣，詳見[下方說明](#ssh-存取與-iap_source_range)。

## 會建立哪些資源

使用 [`gcp/config.env`](gcp/config.env) 的預設值時，會在你的專案中建立：

| 資源 | 預設名稱 | 說明 |
|---|---|---|
| VPC 和子網路 | `netguru-net` | 子網路 `10.10.0.0/24`；裡面不會執行其他任何東西 |
| 防火牆規則 | `netguru-server-ssh-iap` | 只允許來自 IAP 的 tcp:22，詳見 [SSH 存取](#ssh-存取與-iap_source_range) |
| | `netguru-server-sing-box` | 允許來自任何地方的 tcp 443 和 udp 8443 |
| | `netguru-server-outline` | 允許來自任何地方的 tcp 和 udp 45362；只在 `OUTLINE_ENABLED=true` 時存在 |
| 靜態 IP | `netguru-jp-ip` | 用戶端連線的位址 |
| VM | `netguru-server` | e2-small、Debian 12、10 GB pd-balanced 磁碟；沒有服務帳戶，已開啟安全啟動、OS 登入和防刪除功能 |

除了你在快速入門中啟用的 Compute Engine API（會連帶啟用 OS Login API）之外，netguru 只會啟用 IAP API（`iap.googleapis.com`），不會變更專案中的其他任何設定。`make clean` 會再次移除上述所有資源；API 則維持啟用。

「安全強化」是指：SSH 只能透過 Google 的 Identity-Aware Proxy 連線，無法從網際網路直接連入；VM 上沒有任何雲端憑證；sing-box 會拒絕連往私人位址和雲端中繼資料伺服器；並且已開啟安全啟動、OS 登入和防刪除功能。

## 在自己的電腦上執行

你也可以不用 Cloud Shell，改從 Linux 或 Mac 的終端機執行 netguru（Windows 使用者請用 Cloud Shell）：

- **部署和管理：** 需要 bash、make、[gcloud CLI](https://cloud.google.com/sdk/docs/install?hl=zh-tw)（已用 `gcloud auth login` 登入）、jq 和 curl。複製（clone）這個存放區，用文字編輯器設定 `gcp/config.env` 中的 `GCP_PROJECT`，然後執行 `gcloud services enable compute.googleapis.com --project=YOUR_PROJECT_ID` 和 `make all`。
- **`make verify`：** 另外需要 nc、python3，以及位於 `PATH` 中的 [sing-box](https://github.com/SagerNet/sing-box/releases)（已用 1.14.2 測試）。
- **`make test`：** 另外需要 shellcheck、openssl、gpg 和 sing-box。

## 疑難排解

| 問題 | 解決方式 |
|---|---|
| 出現與**帳單**（billing）有關的錯誤 | 到 [Cloud Billing 的專案頁面](https://console.cloud.google.com/billing/projects)為專案連結 Cloud Billing 帳戶，然後重新貼上快速入門的指令。 |
| `was not found`、`permission denied`，或「Compute Engine API has not been used ... or it is disabled」 | 用 `grep GCP_PROJECT ~/netguru/gcp/config.env` 檢查專案 ID。如需修正，請用正確的 ID 重新貼上快速入門的指令。 |
| 錯誤訊息提到機構政策（`constraints/...`） | 你的公司或學校帳戶擋下了部分設定：請改用個人 Google 帳戶，或洽詢管理員。 |
| `jq: command not found` | 安裝 jq：Debian 或 Ubuntu 執行 `sudo apt-get install -y jq`，Mac 執行 `brew install jq`。 |
| `latest GitHub release is not a stable X.Y.Z release (got '')` | GitHub 的 API 沒有回應，通常是因為速率限制。請等幾分鐘再執行 `make all`，或將 `SINGBOX_VERSION` 設為固定版本。 |
| `newest signed sing-box in apt is ... retry later` | sing-box 的新版本還沒進入它的套件庫。請稍候再執行 `make all`。 |
| `cannot reach REALITY target ...` 或 `... must speak HTTP/2 over TLS 1.3` | 改用其他 `SINGBOX_REALITY_SNI`（請參閱[設定](#設定)）。 |
| `SSH over IAP to netguru-server not available after 150s` | 請參閱 [SSH 存取](#ssh-存取與-iap_source_range)。 |
| 之前可以用，現在連不上 | 在 App 的**群組**（Groups）頁面，將 `proxy` 在 `netguru-reality` 和 `netguru-hy2` 之間切換。如果兩者都不行，可能是 IP 位址遭到封鎖：請執行 `make update-ip CONFIRM=1`，並在每台裝置上重新匯入。 |

伺服器日誌（在預設的 `warn` 等級下，內容大多是對 REALITY 連接埠的探測）：

```bash
gcloud compute ssh netguru-server --project=YOUR_PROJECT_ID --zone=asia-northeast1-a --tunnel-through-iap \
  --command='sudo journalctl -u sing-box --since -1d'
```

## SSH 存取與 `IAP_SOURCE_RANGE`

`IAP_SOURCE_RANGE="35.235.240.0/20"` **不是你電腦的 IP 位址**，而是 Google 的 Identity-Aware Proxy（IAP）用來對 VM 建立 TCP 連線的位址範圍。這個範圍對每個專案、每位使用者都相同，所以不要因為換了使用者或工作站就修改它。

```
workstation --HTTPS--> tunnel.cloudproxy.app (IAP checks IAM) --tcp:22 from 35.235.240.0/20--> VM
```

- 所有會連到 VM 的步驟都使用 `gcloud compute ssh --tunnel-through-iap`。VM 只接受來自 IAP 的 22 連接埠連線，`make verify` 也會檢查你的工作站無法直接連到 22 連接埠。
- 決定誰能連線的是 IAM，而不是你的 IP 位址。因此從任何網路都能連線，包括 IP 會變動的家用網路；你的工作站（或 Cloud Shell）只需要能以 HTTPS 連出到 Google。
- 專案擁有者（Owner）已具備所需的權限。其他人需要在專案上擁有這兩個角色：`roles/iap.tunnelResourceAccessor`（受 IAP 保護的通道使用者）和 `roles/compute.osAdminLogin`（VM 使用 OS 登入，而且指令碼會執行 `sudo`）。

**不要把它設成你自己的 IP。** 否則 IAP 將無法連到 22 連接埠：`make infra`（以及 `make all`）會在 `waiting for SSH over IAP` 階段逾時，而 `make verify` 會回報 22 連接埠是開啟的。

**何時需要修改：** 只有在 Google 變更了[使用 IAP 進行 TCP 轉送](https://cloud.google.com/iap/docs/using-tcp-forwarding?hl=zh-tw#create-firewall-rule)中公布的範圍時才需要。屆時請：

1. 在 `gcp/config.env` 中設定新範圍；多個範圍請用逗號分隔。
2. 執行 `make infra`。它會直接更新規則，並記錄 `updating firewall rule netguru-server-ssh-iap (source-ranges)`。
3. 執行 `make verify`，確認輸出中有 `PASS  netguru-server-ssh-iap matches spec`。

如果 `make infra` 顯示 `SSH over IAP to netguru-server not available after 150s` 並放棄，請檢查上述角色、你的網路是否允許以 HTTPS 連到 `tunnel.cloudproxy.app`，以及是否有機構防火牆政策封鎖了 `35.235.240.0/20`。

## 授權條款

[The Bindiego License (BDL), Version 1.0](LICENSE)

## 免責聲明

netguru 僅供技術學習用途。請謹慎使用並自行承擔風險：各國家和地區對加密代理及類似網路工具的法律規範不盡相同，在你所在地或伺服器所在地，架設或使用這類工具可能受到限制，甚至違法。部署或使用 netguru 之前，請先查明當地法律；如有疑問，請諮詢專業法律人士。你也有責任遵守 Google Cloud 的[服務條款](https://cloud.google.com/terms)和[可接受使用政策](https://cloud.google.com/terms/aup)，以及其他適用於你的規範。netguru 依「現狀」提供，不提供任何形式的擔保；在法律允許的最大範圍內，作者對使用 netguru 所產生的任何法律、法規遵循或其他後果概不負責（詳見 [LICENSE](LICENSE)）。
