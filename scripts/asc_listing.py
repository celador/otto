# /// script
# dependencies = ["pyjwt[crypto]", "requests", "pillow"]
# ///
"""Fill the App Store listing for Otto Agent (idempotent).

uv run scripts/asc_listing.py metadata | screenshots | pricing | status
"""
import hashlib, io, json, os, pathlib, sys, time

import requests
from PIL import Image

sys.path.insert(0, str(pathlib.Path.home() / ".appstoreconnect"))
from asc import call  # noqa: E402

APP, FICHA = "6818258172", "6816432116"
BUILD_VERSION = os.environ.get("BUILD_VERSION", "48")
SHOTS = pathlib.Path.home() / ".hermes/cache/scratch"

SUBTITLE = "Your own AI agent, anywhere"
PROMO = "Talk to the AI agent you run on your own computer from your iPhone, iPad and Apple Watch. Tap, speak, and hear it answer."
DESCRIPTION = """Otto puts the AI agent you run on your own computer in your pocket, on your iPad and on your wrist. Chat, talk, and run your whole agent setup from iPhone, iPad and Apple Watch.

CHAT WITHOUT LOSING CONTEXT
• Pick up any session from your desktop and watch replies stream in
• See every tool your agent runs, with the command and its output, as it happens
• Attach or paste photos, retry a turn, copy, share, or have a reply read aloud
• Choose the model for each conversation

TALK TO IT
• Voice mode: just talk, and hear the answer spoken back
• Interrupt it any time; it listens again as soon as it finishes
• Start from Siri, Shortcuts, Control Center, or the Action button

APPLE WATCH
• Tap once, speak, and get a spoken answer right on your wrist
• Keeps the conversation going: tap again to reply

BUILT FOR IPAD TOO
• A sidebar with your chats and tools next to a roomy, readable conversation
• Works in every orientation and alongside other apps

FOLLOW LONG-RUNNING WORK
• Live Activities show what your agent is doing on the Lock Screen
• Home Screen widgets start a new chat or voice conversation

MORE THAN CHAT
• Board: your tasks across every board: move, edit, comment, archive or delete them
• Automations: run, pause, edit, or delete scheduled jobs, or start from templates
• Agents: switch between your agent profiles
• Skills: browse and turn skills on or off
• Memory: review and edit what your agent remembers
• Usage: tokens, cost, and model status at a glance

PRIVATE BY DESIGN
No account, no tracking, no analytics. Otto talks only to the server you set up, and your access token is stored in the iPhone Keychain. We collect nothing.

REQUIREMENTS
A free, open-source agent server that you run yourself, reachable from your iPhone (for example over Tailscale). There is no hosted service, nothing to buy, and no in-app purchase."""
KEYWORDS = "agent,ai,assistant,self-hosted,llm,voice,watch,kanban,automation,cron,tailscale,remote,chat"
REVIEW_NOTES = """Hi, thanks for taking another look. I renamed the app to Otto and replaced the name, icon, subtitle, description and screenshots, so nothing in the listing refers to another developer's app anymore.

Otto is a remote for an AI agent server that people run on their own computers (it works with the free, open-source, MIT-licensed Hermes Agent, which isn't mine). There's no account, no service of mine, nothing for sale and no API key to buy. The access token the app asks for is a password the user makes up in their own server's config file, a bit like an SSH app asking for your server's password. So there's no key or QR code I can give you: both come from the user's own server. The QR code is just a shortcut that fills in the address and token.

The attached video, recorded on my iPhone from the Home Screen, shows the whole app working against my own server.

Thanks,
John"""

def req(method, path, body=None, allow=()):
    s, d = call(method, path, body)
    if s >= 300 and s not in allow:
        raise SystemExit(f"{method} {path}: {s} {json.dumps(d)[:700]}")
    return s, d


def version():
    _, v = req("GET", f"/v1/apps/{APP}/appStoreVersions?filter[platform]=IOS")
    return v["data"][0]["id"]


def build_id():
    for _ in range(40):
        _, b = req("GET", f"/v1/builds?filter[app]={APP}&filter[version]={BUILD_VERSION}&fields[builds]=processingState")
        if b["data"] and b["data"][0]["attributes"]["processingState"] == "VALID":
            return b["data"][0]["id"]
        print("waiting for build", BUILD_VERSION, b["data"][0]["attributes"]["processingState"] if b["data"] else "not visible")
        time.sleep(20)
    raise SystemExit("build never became VALID")


def contact():
    _, fv = req("GET", f"/v1/apps/{FICHA}/appStoreVersions")
    _, rd = req("GET", f"/v1/appStoreVersions/{fv['data'][0]['id']}/appStoreReviewDetail")
    a = rd["data"]["attributes"]
    return {k: a[k] for k in ["contactFirstName", "contactLastName", "contactEmail", "contactPhone"]}


def metadata():
    vid = version()
    req("PATCH", f"/v1/appStoreVersions/{vid}", {"data": {"type": "appStoreVersions", "id": vid,
        "attributes": {"copyright": "2026 Atelier", "releaseType": "AFTER_APPROVAL"},
        "relationships": {"build": {"data": {"type": "builds", "id": build_id()}}}}})
    print("version: build attached, release after approval")

    _, locs = req("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")
    lid = locs["data"][0]["id"]
    req("PATCH", f"/v1/appStoreVersionLocalizations/{lid}", {"data": {"type": "appStoreVersionLocalizations",
        "id": lid, "attributes": {"description": DESCRIPTION, "keywords": KEYWORDS, "promotionalText": PROMO,
                                   "supportUrl": "https://elier.ai/support", "marketingUrl": "https://elier.ai"}}})
    print("localization: description, keywords, promo, URLs")

    _, infos = req("GET", f"/v1/apps/{APP}/appInfos")
    info = infos["data"][0]["id"]
    req("PATCH", f"/v1/appInfos/{info}", {"data": {"type": "appInfos", "id": info, "relationships": {
        "primaryCategory": {"data": {"type": "appCategories", "id": "PRODUCTIVITY"}},
        "secondaryCategory": {"data": {"type": "appCategories", "id": "UTILITIES"}}}}})
    _, il = req("GET", f"/v1/appInfos/{info}/appInfoLocalizations")
    ilid = il["data"][0]["id"]
    req("PATCH", f"/v1/appInfoLocalizations/{ilid}", {"data": {"type": "appInfoLocalizations", "id": ilid,
        "attributes": {"subtitle": SUBTITLE, "privacyPolicyUrl": "https://elier.ai/privacy"}}})
    print("app info: Productivity / Utilities, subtitle, privacy URL")

    s, ar = req("GET", f"/v1/appInfos/{info}/ageRatingDeclaration")
    arid = ar["data"]["id"]
    none = "NONE"
    attrs = {k: none for k in ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated",
             "horrorOrFearThemes", "matureOrSuggestiveThemes", "medicalOrTreatmentInformation",
             "profanityOrCrudeHumor", "sexualContentGraphicAndNudity", "sexualContentOrNudity",
             "violenceCartoonOrFantasy", "violenceRealistic", "violenceRealisticProlongedGraphicOrSadistic",
             "gunsOrOtherWeapons"]}
    attrs.update({"gambling": False, "unrestrictedWebAccess": False, "lootBox": False, "messagingAndChat": False,
                  "parentalControls": False, "ageAssurance": False, "userGeneratedContent": False,
                  "healthOrWellnessTopics": False, "advertising": False})
    for _ in range(len(attrs)):  # drop fields this API version doesn't know, one at a time
        s, d = call("PATCH", f"/v1/ageRatingDeclarations/{arid}", {"data": {"type": "ageRatingDeclarations",
                    "id": arid, "attributes": attrs}})
        if s < 300:
            break
        err = (d.get("errors") or [{}])[0]
        bad = (err.get("source") or {}).get("pointer", "").rsplit("/", 1)[-1]
        if bad in attrs and "provide a value" not in err.get("detail", ""):
            print("  age field dropped:", bad); attrs.pop(bad); continue
        raise SystemExit(f"age rating: {s} {err.get('detail')}")
    print("age rating answered")

    req("PATCH", f"/v1/apps/{APP}", {"data": {"type": "apps", "id": APP,
        "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}})
    print("content rights")

    s, rd = call("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail")
    attrs = {**contact(), "demoAccountRequired": False, "notes": REVIEW_NOTES}
    if s == 200 and rd.get("data"):
        req("PATCH", f"/v1/appStoreReviewDetails/{rd['data']['id']}", {"data": {"type": "appStoreReviewDetails",
            "id": rd["data"]["id"], "attributes": attrs}})
    else:
        req("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
    print("review details + notes")


def upload_asset(create_path, rel_name, rel_type, rel_id, type_name, path: pathlib.Path, data: bytes):
    s, d = req("POST", create_path, {"data": {"type": type_name, "attributes": {
        "fileName": path.name, "fileSize": len(data)},
        "relationships": {rel_name: {"data": {"type": rel_type, "id": rel_id}}}}})
    obj = d["data"]
    for op in obj["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        r = requests.request(op["method"], op["url"], data=chunk,
                             headers={h["name"]: h["value"] for h in op["requestHeaders"]}, timeout=120)
        r.raise_for_status()
    req("PATCH", f"/v1/{type_name}/{obj['id']}", {"data": {"type": type_name, "id": obj["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    return obj["id"]


def flat_png(p: pathlib.Path) -> bytes:
    im = Image.open(p).convert("RGB")
    buf = io.BytesIO()
    im.save(buf, "PNG")
    return buf.getvalue()


def screenshots():
    vid = version()
    _, locs = req("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")
    lid = locs["data"][0]["id"]
    plan = {"APP_IPHONE_67": [f"final-{i}" for i in range(1, 8)],
            "APP_IPAD_PRO_3GEN_129": [f"ipad-final-{i}" for i in range(1, 6)],
            "APP_WATCH_SERIES_10": ["h-watch"]}
    _, sets = req("GET", f"/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets")
    existing = {x["attributes"]["screenshotDisplayType"]: x["id"] for x in sets["data"]}
    for dtype, names in plan.items():
        sid = existing.get(dtype)
        if sid:
            _, old = req("GET", f"/v1/appScreenshotSets/{sid}/appScreenshots")
            for o in old["data"]:
                req("DELETE", f"/v1/appScreenshots/{o['id']}")
        else:
            _, s = req("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": dtype},
                "relationships": {"appStoreVersionLocalization": {"data": {
                    "type": "appStoreVersionLocalizations", "id": lid}}}}})
            sid = s["data"]["id"]
        for n in names:
            p = SHOTS / f"{n}.png"
            upload_asset("/v1/appScreenshots", "appScreenshotSet", "appScreenshotSets", sid, "appScreenshots",
                         p.with_name(f"{n}.png"), flat_png(p))
        print(dtype, len(names), "uploaded")
    time.sleep(15)
    for dtype in plan:
        _, sets = req("GET", f"/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets?include=appScreenshots")
        states = [i["attributes"]["assetDeliveryState"]["state"] for i in sets.get("included", [])]
    print("screenshot states", states)


def video():
    vid = version()
    _, rd = req("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail")
    rid = rd["data"]["id"]
    _, old = req("GET", f"/v1/appStoreReviewDetails/{rid}/appStoreReviewAttachments")
    for o in old["data"]:
        req("DELETE", f"/v1/appStoreReviewAttachments/{o['id']}")
        print("removed old attachment", o["attributes"].get("fileName"))
    p = SHOTS / "review.mp4"
    upload_asset("/v1/appStoreReviewAttachments", "appStoreReviewDetail", "appStoreReviewDetails", rid,
                 "appStoreReviewAttachments", p, p.read_bytes())
    print("review video attached")


def pricing():
    _, pts = req("GET", f"/v1/apps/{APP}/appPricePoints?filter[territory]=USA&limit=10")
    free = next(p for p in pts["data"] if float(p["attributes"]["customerPrice"]) == 0)
    s, d = req("POST", "/v1/appPriceSchedules", {"data": {"type": "appPriceSchedules", "relationships": {
        "app": {"data": {"type": "apps", "id": APP}},
        "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
        "manualPrices": {"data": [{"type": "appPrices", "id": "${p1}"}]}}},
        "included": [{"type": "appPrices", "id": "${p1}", "attributes": {"startDate": None},
                      "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]},
        allow=(409,))
    print("price: free", s)
    terrs, url = [], "/v1/territories?limit=200"
    while url:
        _, t = req("GET", url)
        terrs += [x["id"] for x in t["data"]]
        nxt = t.get("links", {}).get("next")
        url = nxt.replace("https://api.appstoreconnect.apple.com", "") if nxt else None
    s, d = req("POST", "/v2/appAvailabilities", {"data": {"type": "appAvailabilities",
        "attributes": {"availableInNewTerritories": True},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}},
                          "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities",
                                                                "id": f"${{{t}}}"} for t in terrs]}}},
        "included": [{"type": "territoryAvailabilities", "id": f"${{{t}}}", "attributes": {"available": True},
                      "relationships": {"territory": {"data": {"type": "territories", "id": t}}}} for t in terrs]},
        allow=(409,))
    print("availability:", len(terrs), "territories", s)


def age():
    _, infos = req("GET", f"/v1/apps/{APP}/appInfos")
    info = infos["data"][0]["id"]
    _, ar = req("GET", f"/v1/appInfos/{info}/ageRatingDeclaration")
    print({k: v for k, v in ar["data"]["attributes"].items() if v not in (None, "NONE", False)})
    _, i = req("GET", f"/v1/appInfos/{info}")
    print("rating:", i["data"]["attributes"].get("appStoreAgeRating"))


def submit():
    vid = version()
    _, subs = req("GET", f"/v1/apps/{APP}/reviewSubmissions?filter[platform]=IOS")
    open_sub = next((s for s in subs["data"] if s["attributes"]["state"] == "READY_FOR_REVIEW"), None)
    if not open_sub:
        _, s = req("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
            "attributes": {"platform": "IOS"}, "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
        open_sub = s["data"]
    sid = open_sub["id"]
    req("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sid}},
        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}}, allow=(409,))
    _, s = req("PATCH", f"/v1/reviewSubmissions/{sid}", {"data": {"type": "reviewSubmissions", "id": sid,
        "attributes": {"submitted": True}}})
    print("submission", sid, s["data"]["attributes"])
    _, v = req("GET", f"/v1/appStoreVersions/{vid}")
    print("version state", v["data"]["attributes"]["appStoreState"])


def cancel():
    _, subs = req("GET", f"/v1/apps/{APP}/reviewSubmissions?filter[platform]=IOS")
    for s in subs["data"]:
        if s["attributes"]["state"] in ("WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"):
            _, r = req("PATCH", f"/v1/reviewSubmissions/{s['id']}", {"data": {"type": "reviewSubmissions",
                "id": s["id"], "attributes": {"canceled": True}}})
            print("canceled", s["id"], r["data"]["attributes"]["state"])
    _, v = req("GET", f"/v1/appStoreVersions/{version()}")
    print("version state", v["data"]["attributes"]["appStoreState"])


if __name__ == "__main__":
    for step in sys.argv[1:]:
        globals()[step]()
