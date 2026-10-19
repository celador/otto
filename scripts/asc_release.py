# /// script
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""App Store Connect helpers for Hermes - unofficial (app 6818258172).

uv run scripts/asc_release.py profiles   # download App Store profiles for app/widgets/watch
"""
import base64, json, pathlib, sys

sys.path.insert(0, str(pathlib.Path.home() / ".appstoreconnect"))
from asc import call  # noqa: E402

APP_ID = "6818258172"
BUNDLES = ["ai.elier.hermes", "ai.elier.hermes.widgets", "ai.elier.hermes.share", "ai.elier.hermes.watchkitapp", "ai.elier.hermes.watchkitapp.widgets"]
PROFILE_DIR = pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"


def ok(status, data, what):
    if status >= 300:
        raise SystemExit(f"{what}: {status} {json.dumps(data)[:800]}")
    return data


def profiles():
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    s, d = call("GET", "/v1/profiles?filter[profileType]=IOS_APP_STORE&limit=200"
                       "&fields[profiles]=name,profileState,uuid,profileContent,bundleId&include=bundleId")
    ok(s, d, "list profiles")
    out = {}
    for p in d["data"]:
        a = p["attributes"]
        if a["name"] in [f"{b} AppStore" for b in BUNDLES] and a["profileState"] == "ACTIVE":
            (PROFILE_DIR / f"{a['uuid']}.mobileprovision").write_bytes(base64.b64decode(a["profileContent"]))
            out[a["name"].removesuffix(" AppStore")] = a["name"]
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    globals()[sys.argv[1]](*sys.argv[2:])
