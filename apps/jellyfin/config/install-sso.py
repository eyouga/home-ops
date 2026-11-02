# Init container: the SSO plugin at its pinned version, its configuration from git,
# and Jellyfin's known proxies.
# The plugin isn't in Jellyfin's catalogue, and the upstream repository (9p4) is
# archived; this is MaxRink's fork, the one built for Jellyfin 12.
import glob, hashlib, io, os, re, shutil, time, urllib.request, zipfile

VERSION = "6.1.0.0"
SHA256 = "6311d6b16e89a91e44ce9b5a32c09d28eda292a11b75cd6b942d7bc62664cd00"
URL = f"https://github.com/MaxRink/jellyfin-plugin-sso/releases/download/v{VERSION}/sso-auth_{VERSION}.zip"
TARGET = f"/config/plugins/SSO-Auth_{VERSION}"

if not os.path.isdir(TARGET):
    for attempt in range(30):  # kube-router admits a new pod a moment after it starts
        try:
            data = urllib.request.urlopen(URL, timeout=30).read()
            break
        except OSError as e:
            print("waiting for the network:", e, flush=True)
            time.sleep(2)
    else:
        raise SystemExit("could not download the plugin")
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit("the plugin's checksum doesn't match")
    for old in glob.glob("/config/plugins/SSO-Auth_*"):
        shutil.rmtree(old)
    zipfile.ZipFile(io.BytesIO(data)).extractall(TARGET + ".tmp")
    os.rename(TARGET + ".tmp", TARGET)

with open("/files/SSO-Auth.xml") as f:
    xml = f.read().replace("__OIDC_CLIENT_SECRET__", os.environ["OIDC_CLIENT_SECRET"])
fd = os.open("/config/plugins/configurations/SSO-Auth.xml", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(xml)
shutil.copyfile("/files/branding.xml", "/config/config/branding.xml")

# Traefik's pods are proxies to trust for the client's address (k3s's cluster CIDR).
with open("/config/config/network.xml") as f:
    network = f.read()
known = "<KnownProxies><string>10.42.0.0/16</string></KnownProxies>"
network, n = re.subn(r"<KnownProxies\s*/>|<KnownProxies>.*?</KnownProxies>", known, network, flags=re.S)
if n != 1:
    raise SystemExit("KnownProxies not found in network.xml")
with open("/config/config/network.xml", "w") as f:
    f.write(network)
print("SSO plugin", VERSION, "in place", flush=True)
