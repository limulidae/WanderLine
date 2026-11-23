# WanderLine（自用）

兩個版本：
- **iPhone 版**（`ios/`）：裝在手機上，全部在手機上完成，不用電腦。從 TestFlight 安裝。
- **電腦版**（`wanderline/`）：電腦上的地圖網頁，接傳輸線改位置。跟 iPhone 版各自獨立，不用也沒關係。

## iPhone 版

第一次要做的事（App 裡的「設定」會一步一步帶）：
1. iPhone 打開「開發者模式」：設定 → 隱私權與安全性 → 開發者模式。
2. 配對這支 iPhone（iOS 27 以上）：在 WanderLine 按「開始配對」，到「設定 → 隱私權與安全性 → 開發者模式」點「與 WanderLine 配對」，輸入手機密碼和 WanderLine 顯示的 6 位數代碼。
   - iOS 26 以下不能在手機上配對：用電腦的 [idevice_pair](https://github.com/jkcoxson/idevice_pair) 產生 RPPairing 配對檔，再在 App 裡匯入。
3. 加入本機 VPN：WanderLine 內建，系統問「加入 VPN 設定」時按「允許」。
   - 只把送往 10.7.0.1 的封包在手機內部繞一圈，不會連到外面，也不影響上網。
4. 下載開發者映像檔（約 17 MB，一次就好）。手機重開機後，WanderLine 連線時會自己重新掛上。
5. 允許 WanderLine「永遠」使用位置，這樣切到別的 App 時它還能在背景繼續送位置。

打包流程：
- push 到 main 時，Xcode Cloud（workflow「TestFlight」）會跑 `ios/ci_scripts/ci_post_clone.sh`：裝 XcodeGen、下載 idevice 程式庫、產生專案，再打包上傳到 TestFlight 內部測試。簽名由蘋果代管。
- 備用：GitHub Actions 的 `.github/workflows/testflight.yml`（手動觸發），以及「網址安裝版」`.github/workflows/adhoc.yml`（Ad Hoc 版放到 https://limulidae.github.io/WanderLine/ ，只能裝在帳號登記過的手機）。兩個都要 repo secrets：`ASC_KEY_P8`、`ASC_KEY_ID`、`ASC_ISSUER_ID`。GitHub 的 Mac 每次打包都會新開一張開發用憑證，**不要撤銷這些憑證**。
- 自己的 Mac：`bash ios/setup_mac.sh` 會產生專案並打開 Xcode。

改位置的方法：
- 用 [idevice](https://github.com/jkcoxson/idevice)（MIT）。
- 配對：App 用 Bonjour 廣播 `_remotepairing-pairable-host._tcp`，iOS 27 的「開發者模式」頁面就會出現「與 WanderLine 配對」，配完存成 RPPairing 配對檔。
- 連線：內建本機 VPN（`ios/Tunnel`，做法參考 SideStore 的 [StosVPN](https://github.com/SideStore/StosVPN) / [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN)）→ 連 10.7.0.1 的 RemotePairing → RSD →（沒掛就掛開發者映像檔）→ DVT LocationSimulation。
- 開發者映像檔從 [doronz88/DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage) 下載。

## 電腦版

在電腦上開一個地圖網頁，用傳輸線接 iPhone，就能：

- **定點**：點地圖、按「移到這裡」，iPhone 的位置就變成那裡。之後可以用方向鍵或 WASD 慢慢走。
- **路線**：在地圖上依序點幾個地方，會自動畫成沿著街道走的路線。可以設定速度（km/h），選「走一次」「繞圈」或「來回走」，也能暫停、停止。
- **匯入 GPX**：也可以把路線存起來（存在這台電腦的瀏覽器裡）。
- **還原真實位置**：用完一定要按，手機才會回到真的 GPS。

## 第一次用

1. 電腦要先裝好：
   - **Python 3.10 以上**（https://www.python.org/downloads/ ，安裝時勾「Add python.exe to PATH」）
   - **iTunes 或 Apple Devices**（Microsoft Store），用來連 iPhone 的驅動
2. iPhone 用傳輸線接上電腦，解鎖。跳出「要信任這部電腦嗎？」時按「信任」。
3. iPhone 打開 **開發者模式**：設定 → 隱私權與安全性 → 開發者模式。
   - 如果看不到這個選項，先做第 4 步按一次「連線」，選項就會出現。
   - 打開後手機會重開機，重開後再按一次「開啟」。
4. 雙擊 **start.bat**。跳出要不要給系統管理員權限時按「是」（iOS 17 以上需要）。
   - 第一次會自動安裝需要的東西。
   - 好了以後會自動打開瀏覽器：http://127.0.0.1:8777
5. 按「連線」。第一次會從網路下載蘋果的開發者映像檔，要等一下。

## 注意

- 用的時候傳輸線要一直接著，關掉黑色視窗就停了。
- 關之前先按「還原真實位置」。如果忘了，重開手機也會回到真的位置。
- 在 Niantic 的遊戲（Pikmin Bloom、Pokémon GO）裡改位置違反它們的服務條款，有被警告或停權的風險，後果請自己承擔。

## 技術說明

- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3)
  - iOS 17 以上：`remote tunneld` 開開發者通道，再走 DVT `LocationSimulation`。
  - iOS 16 以下：走 `com.apple.dt.simulatelocation`。
- 網頁：FastAPI，只聽 127.0.0.1。地圖、搜尋用 OpenStreetMap（Nominatim）。
- 「沿著街道走」用 routing.openstreetmap.de 的步行路線服務。
- 程式：`wanderline/device.py`（連手機）、`wanderline/walker.py`（沿路線走）、`wanderline/server.py`（網頁 API）、`wanderline/web/index.html`（畫面）。

## 之後可以做

- 從 PikPals 的路線直接匯入。
