# /// script
# dependencies = ["pyjwt[crypto]", "requests", "pillow"]
# ///
"""Mac App Store listing for Otto (MAC_OS version on the shared record 6818258172; idempotent).

Only ever touches the MAC_OS appStoreVersion and a MAC_OS reviewSubmission. App-level data (name, subtitle,
categories, privacy label, age rating, price, availability) is shared with iOS and already set there.

BUILD_VERSION=78 uv run scripts/asc_listing_mac.py metadata screenshots status
uv run scripts/asc_listing_mac.py submit     # once, on John's go
"""
import hashlib, io, json, os, pathlib, sys, time

import requests
from PIL import Image

sys.path.insert(0, str(pathlib.Path.home() / ".appstoreconnect"))
from asc import call  # noqa: E402

APP, FICHA = "6818258172", "6816432116"
BUILD_VERSION = os.environ.get("BUILD_VERSION", "78")
SHOTS = pathlib.Path(os.environ.get("MAC_SHOTS", pathlib.Path.home() / ".hermes/cache/scratch/otto-mac-shots"))

PROMO = "Your own AI agent, in a native Mac app. Chat, talk, and follow its work while it runs on your own computer."
DESCRIPTION = """Otto is a native Mac app for the AI agent you run on your own computer. Chat with it, talk to it, and keep an eye on everything it's doing, in a fast, keyboard-friendly window.

CHAT WITHOUT LOSING CONTEXT
• Pick up any session and watch replies stream in
• See every tool your agent runs, with the command and its output, as it happens
• Paste or drop images, retry a turn, copy, share, or have a reply read aloud
• Choose the model for each conversation, and run slash commands

ORGANIZED BY WORKSPACE
• A sidebar with your workspaces, pinned chats and everything else
• Start a chat in a workspace, move chats between them, and see each workspace's board

TALK TO IT
• Voice mode: just talk, and hear the answer spoken back
• Dictate messages instead of typing

BUILT FOR THE KEYBOARD
• Return sends, Shift-Return adds a line, Esc stops a reply
• Shortcuts for a new chat, new window, model picker, voice mode and search

KEEP YOUR MAC AWAKE WHILE AGENTS WORK
• One click in the sidebar keeps the Mac from going to sleep while your agents are working, or for a time you choose, and lets it sleep again when they finish

MORE THAN CHAT
• Board: your tasks across every board: move, edit, comment, archive or delete them
• Automations: run, pause, edit, or delete scheduled jobs
• Agents, Skills, Memory, Artifacts and Usage, all in one place

PRIVATE BY DESIGN
No account, no tracking, no analytics. Otto talks only to the server you set up, and your access token is stored in your Mac's Keychain. We collect nothing.

REQUIREMENTS
A free, open-source agent server that you run yourself, on this Mac or elsewhere on your network. On the same Mac, Otto connects with one click. There is no hosted service, nothing to buy, and no in-app purchase."""
KEYWORDS = "agent,ai,assistant,self-hosted,llm,voice,kanban,automation,cron,tailscale,chat,desktop,mac"
REVIEW_NOTES = """Hi, this is the Mac version of Otto (same app record as the iOS version).

Otto is a client for an AI agent server that people run on their own computers. It works with Hermes Agent, a free, open-source, MIT-licensed agent from Nous Research that isn't mine and that I'm not affiliated with. There's no account, no service of mine, nothing for sale and no login I can give you. It works like an SSH or database client: you install the agent, turn on its API server, and Otto talks only to that server.

To try it on a Mac that runs Hermes Agent: open Otto, click Use This Mac, and click Allow in the dialog that shows the same 6-digit code. Hermes hands Otto its access token, which Otto keeps in the Keychain. To use a server elsewhere, enter its address and access key under "Or enter another server".

Entitlements: App Sandbox, outgoing network connections (to the user's own server), microphone (voice mode and dictation, only after the user starts them), and read access to files the user picks in the open panel (to attach an image). No analytics, ads, payments or third-party sign-in.

Keep Mac awake (the cup in the sidebar, View > Keep Mac Awake, Settings > Keep Awake; no menu bar item): by itself Otto only holds a standard IOKit power assertion (PreventUserIdleSystemSleep) while the user's agents are working or until a timer they set ends, and releases it when they finish, when Otto can't reach their server and when Otto quits. The "Stay awake with lid closed" toggle changes nothing on the Mac from inside the app: it sends a request to the user's own Hermes companion, which ships with Hermes and runs on their Mac outside Otto. The first time, that companion sets itself up and macOS shows its standard administrator prompt from the companion's process. Without the companion the toggle does nothing. Otto itself runs no scripts or helpers, asks for no administrator rights, installs nothing and makes no system changes; it is fully sandboxed.

If it helps, I can send a screen recording of the app working against my own server.

Thanks,
John"""


def req(method, path, body=None, allow=()):
    s, d = call(method, path, body)
    if s >= 300 and s not in allow:
        raise SystemExit(f"{method} {path}: {s} {json.dumps(d)[:700]}")
    return s, d


def version():
    _, v = req("GET", f"/v1/apps/{APP}/appStoreVersions?filter[platform]=MAC_OS")
    if not v["data"]:
        _, d = req("POST", "/v1/appStoreVersions", {"data": {"type": "appStoreVersions",
            "attributes": {"platform": "MAC_OS", "versionString": "1.0"},
            "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
        return d["data"]["id"]
    return v["data"][0]["id"]


def build_id():
    for _ in range(60):
        _, b = req("GET", f"/v1/builds?filter[app]={APP}&filter[version]={BUILD_VERSION}"
                          f"&filter[preReleaseVersion.platform]=MAC_OS&fields[builds]=processingState")
        if b["data"] and b["data"][0]["attributes"]["processingState"] == "VALID":
            return b["data"][0]["id"]
        print("waiting for mac build", BUILD_VERSION, b["data"][0]["attributes"]["processingState"] if b["data"] else "not visible")
        time.sleep(30)
    raise SystemExit("mac build never became VALID")


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
    print("mac version: build", BUILD_VERSION, "attached, release after approval")
    _, locs = req("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")
    lid = locs["data"][0]["id"]
    req("PATCH", f"/v1/appStoreVersionLocalizations/{lid}", {"data": {"type": "appStoreVersionLocalizations",
        "id": lid, "attributes": {"description": DESCRIPTION, "keywords": KEYWORDS, "promotionalText": PROMO,
                                   "supportUrl": "https://elier.ai/support", "marketingUrl": "https://elier.ai"}}})
    print("mac localization:", locs["data"][0]["attributes"]["locale"])
    s, rd = call("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail")
    attrs = {**contact(), "demoAccountRequired": False, "notes": REVIEW_NOTES}
    if s == 200 and rd.get("data"):
        req("PATCH", f"/v1/appStoreReviewDetails/{rd['data']['id']}", {"data": {"type": "appStoreReviewDetails",
            "id": rd["data"]["id"], "attributes": attrs}})
    else:
        req("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
    print("mac review details + notes (", len(REVIEW_NOTES), "chars )")


def upload_asset(create_path, rel_name, rel_type, rel_id, type_name, name, data: bytes):
    _, d = req("POST", create_path, {"data": {"type": type_name, "attributes": {
        "fileName": name, "fileSize": len(data)},
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
    assert im.size in [(2880, 1800), (2560, 1600), (1440, 900), (1280, 800)], f"{p}: {im.size} isn't a Mac size"
    buf = io.BytesIO()
    im.save(buf, "PNG")
    return buf.getvalue()


def screenshots():
    vid = version()
    _, locs = req("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")
    lid = locs["data"][0]["id"]
    files = sorted(SHOTS.glob("mac-final-*.png"))
    assert files, f"no mac-final-*.png in {SHOTS}"
    _, sets = req("GET", f"/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets")
    sid = next((x["id"] for x in sets["data"] if x["attributes"]["screenshotDisplayType"] == "APP_DESKTOP"), None)
    if sid:
        _, old = req("GET", f"/v1/appScreenshotSets/{sid}/appScreenshots")
        for o in old["data"]:
            req("DELETE", f"/v1/appScreenshots/{o['id']}")
    else:
        _, s = req("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": "APP_DESKTOP"},
            "relationships": {"appStoreVersionLocalization": {"data": {
                "type": "appStoreVersionLocalizations", "id": lid}}}}})
        sid = s["data"]["id"]
    for p in files:
        upload_asset("/v1/appScreenshots", "appScreenshotSet", "appScreenshotSets", sid, "appScreenshots",
                     p.name, flat_png(p))
    print("APP_DESKTOP", len(files), "uploaded")


def video():
    vid = version()
    _, rd = req("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail")
    rid = rd["data"]["id"]
    _, old = req("GET", f"/v1/appStoreReviewDetails/{rid}/appStoreReviewAttachments")
    for o in old["data"]:
        req("DELETE", f"/v1/appStoreReviewAttachments/{o['id']}")
    p = SHOTS / "mac-review.mp4"
    upload_asset("/v1/appStoreReviewAttachments", "appStoreReviewDetail", "appStoreReviewDetails", rid,
                 "appStoreReviewAttachments", p.name, p.read_bytes())
    print("mac review video attached")


def status():
    _, v = req("GET", f"/v1/apps/{APP}/appStoreVersions?include=build&fields[appStoreVersions]=platform,appStoreState,build"
                      "&fields[builds]=version,processingState")
    builds = {b["id"]: b["attributes"] for b in v.get("included", [])}
    for x in v["data"]:
        bid = ((x["relationships"].get("build") or {}).get("data") or {}).get("id")
        print(x["attributes"]["platform"], x["attributes"]["appStoreState"], "build", builds.get(bid))
    _, subs = req("GET", f"/v1/apps/{APP}/reviewSubmissions?fields[reviewSubmissions]=platform,state,submittedDate")
    for s in subs["data"]:
        print("submission", s["id"], s["attributes"])
    vid = version()
    _, sets = req("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")
    lid = sets["data"][0]["id"]
    _, ss = req("GET", f"/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets?include=appScreenshots")
    print("mac shots", [i["attributes"]["assetDeliveryState"]["state"] for i in ss.get("included", [])])


def submit():
    vid = version()
    _, subs = req("GET", f"/v1/apps/{APP}/reviewSubmissions?filter[platform]=MAC_OS")
    if any(s["attributes"]["state"] in ("WAITING_FOR_REVIEW", "IN_REVIEW") for s in subs["data"]):
        raise SystemExit("a MAC_OS submission is already in review; not submitting again")
    open_sub = next((s for s in subs["data"] if s["attributes"]["state"] == "READY_FOR_REVIEW"), None)
    if not open_sub:
        _, s = req("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
            "attributes": {"platform": "MAC_OS"}, "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
        open_sub = s["data"]
    sid = open_sub["id"]
    req("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sid}},
        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}}, allow=(409,))
    _, s = req("PATCH", f"/v1/reviewSubmissions/{sid}", {"data": {"type": "reviewSubmissions", "id": sid,
        "attributes": {"submitted": True}}})
    print("mac submission", sid, s["data"]["attributes"])
    _, v = req("GET", f"/v1/appStoreVersions/{vid}")
    print("mac version state", v["data"]["attributes"]["appStoreState"])


if __name__ == "__main__":
    for step in sys.argv[1:]:
        globals()[step]()
