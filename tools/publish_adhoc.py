"""把 Xcode Cloud 某次打包產出的 Ad Hoc 版放到 GitHub Pages（gh-pages 分支），手機用 Safari 開就能裝。
用法：python tools/publish_adhoc.py <ciBuildRun id>（Xcode Cloud 那次打包的 id）"""
import io, json, pathlib, plistlib, shutil, subprocess, sys, tempfile, time, urllib.request, zipfile
import base64, os
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

# App Store Connect API 金鑰（不進 git）：環境變數 ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_PATH（.p8 檔路徑）
_key = serialization.load_pem_private_key(open(os.environ["ASC_KEY_PATH"], "rb").read(), None)
_b64 = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=")
_h = _b64(json.dumps({"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}).encode())
_p = _b64(json.dumps({"iss": os.environ["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"}).encode())
_r, _s = decode_dss_signature(_key.sign(_h + b"." + _p, ec.ECDSA(hashes.SHA256())))
tok = (_h + b"." + _p + b"." + _b64(_r.to_bytes(32, "big") + _s.to_bytes(32, "big"))).decode()
H = {"Authorization": "Bearer " + tok}
g = lambda u: json.load(urllib.request.urlopen(urllib.request.Request("https://api.appstoreconnect.apple.com" + u, headers=H)))
PAGES = "https://limulidae.github.io/WanderLine"
run = sys.argv[1]
art = None
for a in g(f"/v1/ciBuildRuns/{run}/actions")["data"]:
    for x in g(f"/v1/ciBuildActions/{a['id']}/artifacts")["data"]:
        if x["attributes"]["fileType"] == "ARCHIVE_EXPORT" and "ad-hoc" in x["attributes"]["fileName"]:
            art = g(f"/v1/ciArtifacts/{x['id']}")["data"]["attributes"]
if not art: sys.exit("這次打包沒有 Ad Hoc 版")
z = zipfile.ZipFile(io.BytesIO(urllib.request.urlopen(art["downloadUrl"]).read()))
ipa_name = next(n for n in z.namelist() if n.endswith(".ipa"))
ipa = z.read(ipa_name)
iz = zipfile.ZipFile(io.BytesIO(ipa))
info = plistlib.loads(iz.read(next(n for n in iz.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist"))))
ver, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
print("ad hoc", ver, build, len(ipa), "bytes")

d = pathlib.Path(tempfile.mkdtemp())
(d / "WanderLine.ipa").write_bytes(ipa)
(d / "manifest.plist").write_bytes(plistlib.dumps({"items": [{
    "assets": [{"kind": "software-package", "url": f"{PAGES}/WanderLine.ipa?v={build}"}],
    "metadata": {"bundle-identifier": "wang.chunchieh.wanderline", "bundle-version": build, "kind": "software", "title": "WanderLine"}}]}))
(d / "index.html").write_text(f"""<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>安裝 WanderLine</title>
<style>body{{font:17px -apple-system,sans-serif;margin:0;padding:40px 20px;text-align:center;background:#f2f2f7;color:#111}}
@media (prefers-color-scheme:dark){{body{{background:#000;color:#eee}}}}
a.btn{{display:inline-block;margin:24px 0;padding:14px 40px;border-radius:14px;background:#0a84ff;color:#fff;text-decoration:none;font-weight:600}}
p{{color:#888;font-size:14px;max-width:420px;margin:8px auto}}</style></head><body>
<h1>WanderLine</h1><p>版本 {ver} ({build})</p>
<a class="btn" href="itms-services://?action=download-manifest&amp;url={PAGES}/manifest.plist?v={build}">安裝</a>
<p>用 Safari 打開這頁再按「安裝」。只有登記過的 iPhone 能裝，而且要先打開「設定 → 隱私權與安全性 → 開發者模式」。</p>
</body></html>""", encoding="utf-8")
(d / ".nojekyll").write_text("")
run_git = lambda *a: subprocess.run(["git", *a], cwd=d, check=True, capture_output=True)
run_git("init", "-q", "-b", "gh-pages")
run_git("add", "-A")
run_git("-c", "user.name=Santino Wang", "-c", "user.email=8407046+limulidae@users.noreply.github.com",
        "commit", "-q", "-m", f"網址安裝版 {ver} ({build})，來自 Xcode Cloud")
run_git("push", "-q", "-f", "git@github.com:limulidae/WanderLine.git", "gh-pages")
print("pushed gh-pages")
