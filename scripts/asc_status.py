# /// script
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Read-only snapshot of the Hermes - unofficial App Store record."""
import json, pathlib, sys

sys.path.insert(0, str(pathlib.Path.home() / ".appstoreconnect"))
from asc import call  # noqa: E402

APP = "6818258172"
FICHA = "6816432116"

def get(path):
    s, d = call("GET", path)
    return d if s < 300 else {"_status": s, "_err": (d or {}).get("errors", [{}])[0].get("detail")}

v = get(f"/v1/apps/{APP}/appStoreVersions?include=build&fields[appStoreVersions]=versionString,appStoreState,platform")
print("versions", [(x["id"], x["attributes"]) for x in v.get("data", [])])
b = get(f"/v1/builds?filter[app]={APP}&fields[builds]=version,processingState,uploadedDate")
print("builds", [(x["id"], x["attributes"]) for x in b.get("data", [])])
ai = get(f"/v1/apps/{APP}/appInfos")
print("appInfos", [(x["id"], x["attributes"].get("appStoreState"), x["attributes"].get("state")) for x in ai.get("data", [])])
print("availability", get(f"/v1/apps/{APP}/appAvailabilityV2").get("_status", "set"))
print("price", get(f"/v1/apps/{APP}/appPriceSchedule").get("_status", "set"))
# Ficha's review contact (John's own details) to reuse.
fv = get(f"/v1/apps/{FICHA}/appStoreVersions?fields[appStoreVersions]=versionString")
for x in fv.get("data", [])[:1]:
    rd = get(f"/v1/appStoreVersions/{x['id']}/appStoreReviewDetail")
    a = (rd.get("data") or {}).get("attributes", {})
    print("ficha contact", {k: a.get(k) for k in ["contactFirstName", "contactLastName", "contactEmail"]},
          "phone set" if a.get("contactPhone") else "no phone")
