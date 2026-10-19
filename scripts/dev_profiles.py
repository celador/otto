"""Create (or refresh) IOS_APP_DEVELOPMENT profiles for Hermes covering every enabled device, and the
MAC_APP_DEVELOPMENT profiles Otto for Mac signs with (manual signing, project.yml: the
keychain-access-groups entitlement needs a profile) covering every enabled Mac.

Xcode on this Mac has no Apple account signed in, so automatic signing can't add new devices to the
wildcard team profile. This makes explicit dev profiles via the App Store Connect API and installs them.
Usage: uv run --with pyjwt --with cryptography --with requests scripts/dev_profiles.py
"""
import base64
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path.home() / ".appstoreconnect"))
import asc  # noqa: E402

BUNDLES = {"ai.elier.hermes": "B82KZ74G25", "ai.elier.hermes.widgets": "K69J5RKCY8",
           "ai.elier.hermes.share": "53ZT9476G2",
           "ai.elier.hermes.watchkitapp": "6HNGUJ3X66", "ai.elier.hermes.watchkitapp.widgets": "Y5D5T69H8G"}
# Otto (Release, installed) and Otto Dev (Debug). MAC_OS bundle ids, registered 2026-10-18.
MAC_BUNDLES = {"ai.elier.hermes.mac": "G2R45K36HZ", "ai.elier.hermes.mac.dev": "9L62RFSM9Y"}
CERT = "6RD5UK8DD2"  # Apple Development: john nelson
DEST = pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"


def main():
    _, all_devices = asc.call("GET", "/v1/devices?filter[status]=ENABLED&limit=200")
    # iOS dev profiles reject Mac/TV devices with 409 "Invalid deviceClass for profile type".
    ios = [x for x in all_devices["data"] if x["attributes"].get("deviceClass") in ("IPHONE", "IPAD", "APPLE_WATCH", "IPOD")]
    macs = [x for x in all_devices["data"] if x["attributes"].get("deviceClass") == "MAC"]
    print("devices:", ", ".join(x["attributes"]["name"] for x in ios))
    print("macs:", ", ".join(x["attributes"]["name"] for x in macs))
    DEST.mkdir(parents=True, exist_ok=True)
    for ident, bid in BUNDLES.items():
        make(ident, bid, "IOS_APP_DEVELOPMENT", [x["id"] for x in ios], "mobileprovision")
    for ident, bid in MAC_BUNDLES.items():
        make(ident, bid, "MAC_APP_DEVELOPMENT", [x["id"] for x in macs], "provisionprofile")


def make(ident, bid, kind, devices, ext):
    name = f"{ident} Development"
    _, existing = asc.call("GET", f"/v1/profiles?filter[name]={name}")
    for p in existing["data"]:
        asc.call("DELETE", f"/v1/profiles/{p['id']}")
    body = {"data": {"type": "profiles",
                     "attributes": {"name": name, "profileType": kind},
                     "relationships": {
                         "bundleId": {"data": {"type": "bundleIds", "id": bid}},
                         "certificates": {"data": [{"type": "certificates", "id": CERT}]},
                         "devices": {"data": [{"type": "devices", "id": i} for i in devices]}}}}
    s, p = asc.call("POST", "/v1/profiles", body)
    if s != 201:
        raise SystemExit(f"{ident}: {s} {p}")
    a = p["data"]["attributes"]
    (DEST / f"{a['uuid']}.{ext}").write_bytes(base64.b64decode(a["profileContent"]))
    print(f"{name}: {a['uuid']}")


if __name__ == "__main__":
    main()
