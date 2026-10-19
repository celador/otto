Hermes Agent logo ("Nous girl") from NousResearch/hermes-agent `assets/` (MIT-licensed repo).
- `icon-ios-*.svg`: `assets/icon-master*.svg` with the desktop squircle frame removed (iOS masks icons itself).
- Render: `rsvg-convert -w 1024 -h 1024 icon-ios-light.svg | magick - -background white -alpha remove -alpha off icon-light.png` (App Store icons must be opaque).
Before any public App Store release, confirm Nous Research is OK with the mark being used in a third-party client.
