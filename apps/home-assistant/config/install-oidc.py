# Init container: auth_oidc (hass-oidc-auth), a custom integration, at its pinned
# release. Check it still fits before each Home Assistant bump.
import hashlib
import io
import json
import shutil
import time
import urllib.request
import zipfile

VERSION = "1.3.0"
SHA256 = "e5badaaacaa63cfd6fe733924a05e76d75058836190398598fb24de57cd47ccd"
URL = f"https://github.com/christiaangoossens/hass-oidc-auth/releases/download/v{VERSION}/hass-oidc-auth.zip"
TARGET = "/config/custom_components/auth_oidc"


def installed():
    try:
        return json.load(open(TARGET + "/manifest.json"))["version"]
    except OSError:
        return None


if installed() != VERSION:
    for attempt in range(30):  # kube-router admits a new pod a moment after it starts
        try:
            data = urllib.request.urlopen(URL, timeout=30).read()
            break
        except OSError as e:
            print("waiting for the network:", e, flush=True)
            time.sleep(2)
    else:
        raise SystemExit("could not download auth_oidc")
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit("auth_oidc's checksum doesn't match")
    shutil.rmtree(TARGET, ignore_errors=True)
    zipfile.ZipFile(io.BytesIO(data)).extractall(TARGET)
print("auth_oidc", VERSION, "in place", flush=True)
