
import base64, pathlib, sys
sys.path.insert(0, str(pathlib.Path.home() / ".appstoreconnect"))
import asc
UDID = "00008110-001824C00E46801E"
s, d = asc.call("GET", f"/v1/devices?filter[udid]={UDID}")
if not d["data"]:
    s, r = asc.call("POST", "/v1/devices", {"data": {"type": "devices", "attributes": {"name": "Apple TV (living room)", "udid": UDID, "platform": "IOS"}}})
    print("register", s, r.get("errors") or r["data"]["attributes"].get("deviceClass"))
else:
    print("already registered", d["data"][0]["attributes"].get("deviceClass"))
_, d = asc.call("GET", "/v1/devices?filter[status]=ENABLED&limit=200")
tvs = [x["id"] for x in d["data"] if x["attributes"].get("deviceClass") == "APPLE_TV"]
print("tv devices", len(tvs))
name = "ai.elier.hermes tvOS Development"
_, ex = asc.call("GET", f"/v1/profiles?filter[name]={name}")
for p in ex["data"]: asc.call("DELETE", f"/v1/profiles/{p['id']}")
body = {"data": {"type": "profiles", "attributes": {"name": name, "profileType": "TVOS_APP_DEVELOPMENT"},
  "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": "B82KZ74G25"}},
    "certificates": {"data": [{"type": "certificates", "id": "6RD5UK8DD2"}]},
    "devices": {"data": [{"type": "devices", "id": i} for i in tvs]}}}}
s, p = asc.call("POST", "/v1/profiles", body)
if s != 201: raise SystemExit(f"profile {s} {p}")
a = p["data"]["attributes"]
dest = pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
(dest / f"{a['uuid']}.mobileprovision").write_bytes(base64.b64decode(a["profileContent"]))
print("profile", a["uuid"], a["platform"])
