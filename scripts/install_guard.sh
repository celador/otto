# Superseded by scripts/trunk_guard.sh (Weft-gated, single-lane installs; docs/release.md).
# Kept so anything that still sources it gets the new guard.
source "$(dirname "${BASH_SOURCE[0]}")/trunk_guard.sh"
otto_trunk_guard
