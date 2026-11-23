"""每次在 GitHub 的 Mac 上打包，Xcode 都會新開一張「Apple Development」憑證（私鑰跟著那台 Mac 一起消失），
累積到上限就打包失敗。打包前先撤銷舊的這種憑證（名稱是 "Created via API"），只留最新一張。
不會動到用電腦 Xcode 建立的憑證，也不影響已經上架或 TestFlight 的版本（那些用的是發佈憑證）。"""
import base64, json, os, time, urllib.request
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

KEEP = 1
key_id, issuer = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
key = serialization.load_pem_private_key(open(os.path.expanduser(os.environ.get("ASC_KEY_PATH", "~/asc/key.p8")), "rb").read(), None)
b64 = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=")
head = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
now = int(time.time())
body = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}).encode())
r, s = decode_dss_signature(key.sign(head + b"." + body, ec.ECDSA(hashes.SHA256())))
token = (head + b"." + body + b"." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))).decode()

def call(method, path):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req) as res:
        data = res.read()
        return json.loads(data) if data else None

certs = call("GET", "/v1/certificates?filter[certificateType]=DEVELOPMENT&limit=200")["data"]
ci = [c for c in certs if c["attributes"]["displayName"] == "Created via API"]
ci.sort(key=lambda c: c["attributes"]["expirationDate"], reverse=True)
for c in ci[KEEP:]:
    call("DELETE", "/v1/certificates/" + c["id"])
    print("撤銷舊的打包用憑證", c["id"])
print(f"開發憑證共 {len(certs)} 張，撤銷 {max(0, len(ci) - KEEP)} 張")
