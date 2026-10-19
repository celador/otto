# /// script
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Public TestFlight link for Hermes - unofficial: beta info, external group, build 19, beta review."""
import json, pathlib, sys

sys.path.insert(0, str(pathlib.Path.home() / ".appstoreconnect"))
from asc import call  # noqa: E402

import os
APP, FICHA = "6818258172", "6816432116"
BUILD_VERSION = os.environ.get("BUILD_VERSION", "41")


def req(method, path, body=None, allow=()):
    s, d = call(method, path, body)
    if s >= 300 and s not in allow:
        raise SystemExit(f"{method} {path}: {s} {json.dumps(d)[:600]}")
    return s, d


# Build 19, processed.
_, b = req("GET", f"/v1/builds?filter[app]={APP}&filter[version]={BUILD_VERSION}&fields[builds]=version,processingState")
if not b["data"]:
    raise SystemExit(f"build {BUILD_VERSION} not visible yet")
build = b["data"][0]
print("build", build["attributes"])
if build["attributes"]["processingState"] != "VALID":
    raise SystemExit("still processing")
req("PATCH", f"/v1/builds/{build['id']}", {"data": {"type": "builds", "id": build["id"],
    "attributes": {"usesNonExemptEncryption": False}}}, allow=(409,))

# Beta app description + feedback email.
_, loc = req("GET", f"/v1/apps/{APP}/betaAppLocalizations")
attrs = {"feedbackEmail": "john@elier.ai", "description":
         "An unofficial iPhone and Apple Watch remote for Hermes Agent. Chat, talk by voice, and manage your "
         "agents, board and automations from your phone. Requires your own Hermes Agent server."}
if loc["data"]:
    req("PATCH", f"/v1/betaAppLocalizations/{loc['data'][0]['id']}",
        {"data": {"type": "betaAppLocalizations", "id": loc["data"][0]["id"], "attributes": attrs}})
else:
    req("POST", "/v1/betaAppLocalizations", {"data": {"type": "betaAppLocalizations",
        "attributes": {**attrs, "locale": "en-US"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})

# Beta review contact: reuse John's details from Ficha's beta review record.
_, fr = req("GET", f"/v1/apps/{FICHA}/betaAppReviewDetail")
fa = fr["data"]["attributes"]
if not fa.get("contactPhone"):  # fall back to Ficha's App Store review contact
    _, fv = req("GET", f"/v1/apps/{FICHA}/appStoreVersions?fields[appStoreVersions]=versionString")
    _, rd = req("GET", f"/v1/appStoreVersions/{fv['data'][0]['id']}/appStoreReviewDetail")
    fa = {**rd["data"]["attributes"], **{k: v for k, v in fa.items() if v}}
_, hr = req("GET", f"/v1/apps/{APP}/betaAppReviewDetail")
req("PATCH", f"/v1/betaAppReviewDetails/{hr['data']['id']}", {"data": {"type": "betaAppReviewDetails",
    "id": hr["data"]["id"], "attributes": {
        "contactFirstName": fa.get("contactFirstName") or "John", "contactLastName": fa.get("contactLastName") or "Nelson",
        "contactEmail": fa.get("contactEmail") or "john@elier.ai", "contactPhone": fa["contactPhone"],
        "demoAccountRequired": False,
        "notes": "Hermes - unofficial is a client for Hermes Agent, open-source (MIT) software that users run on "
                 "their own computer. On first launch the user enters their own server address and access key. "
                 "There is no account system or hosted service; every user brings their own server."}}})

# What to test, for this build.
_, bl = req("GET", f"/v1/builds/{build['id']}/betaBuildLocalizations")
wt = {"whatsNew": "First TestFlight build: chat, voice mode, Apple Watch voice, board, automations."}
if bl["data"]:
    req("PATCH", f"/v1/betaBuildLocalizations/{bl['data'][0]['id']}",
        {"data": {"type": "betaBuildLocalizations", "id": bl["data"][0]["id"], "attributes": wt}})
else:
    req("POST", "/v1/betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations",
        "attributes": {**wt, "locale": "en-US"},
        "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}})

# External group with a public link.
_, gs = req("GET", f"/v1/apps/{APP}/betaGroups")
group = next((g for g in gs["data"] if g["attributes"]["name"] in ("Hermes Friends", "Friends")), None)
if not group:
    _, g = req("POST", "/v1/betaGroups", {"data": {"type": "betaGroups", "attributes": {
        "name": "Friends", "publicLinkEnabled": True, "publicLinkLimitEnabled": True, "publicLinkLimit": 100,
        "feedbackEnabled": True},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    group = g["data"]
req("POST", f"/v1/betaGroups/{group['id']}/relationships/builds",
    {"data": [{"type": "builds", "id": build["id"]}]}, allow=(409,))

# Submit the build for beta review.
s, sub = req("POST", "/v1/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions",
    "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}}}}, allow=(409, 422))
print("beta review submit", s, (sub.get("errors") or [{}])[0].get("detail") if s >= 300 else sub["data"]["attributes"])

_, g = req("GET", f"/v1/betaGroups/{group['id']}")
print("public link", g["data"]["attributes"].get("publicLink"))
