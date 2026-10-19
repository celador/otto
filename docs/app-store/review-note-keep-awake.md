# App Review note: Otto for Mac — Keep Mac awake

Paste into App Review Information → Notes for the Mac App Store build (with the general note about
Hermes being a self-hosted agent).

---

Otto has a "Keep Mac awake" option in its own window (the cup in the sidebar footer), in View → Keep Mac
Awake and in Settings → Keep Awake. It has no menu bar item. By itself it only holds a standard IOKit power
assertion (PreventUserIdleSystemSleep) while the user's agents are working or until a timer they set ends,
and releases it when they finish, when Otto can't reach their server and when Otto quits.

The "Stay awake with lid closed" toggle doesn't change anything on the Mac from inside the app, and Otto
never asks for administrator rights. It sends a request to the user's own self-hosted Hermes companion (the
relay that ships with Hermes, installed separately and running on their Mac outside Otto), over the same
authenticated connection Otto uses for everything else. The first time the user turns the toggle on, that
companion sets itself up: macOS shows its standard administrator prompt ("Otto wants to keep this Mac awake
with the lid closed.") from the companion's process, and the user approves it with Touch ID or their password.
Without the companion the toggle does nothing. Otto runs no scripts or helper tools, installs nothing,
requests no root privileges and makes no system changes; it is fully sandboxed.

---

Internal (don't paste): 2.4.5 risk — Otto never requests root, but the companion's prompt says "Otto" and
appears right after a click in Otto, so Review may read it as the app escalating. Answer with the paragraph
above plus a short screen recording; fallback is hiding the lid-closed toggle in the Mac App Store build.
