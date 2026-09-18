#!/usr/bin/env bash
# reset.sh — Reverts setup.sh changes, restoring the repo to its template state.
# Usage: bash reset.sh

set -eo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

info()   { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
header() { echo -e "\n${BOLD}── $* ──────────────────────────────────────────${RESET}"; }

# ── working directory ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── portable in-place sed (GNU and BSD/macOS) ─────────────────────────────────
sedi() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# ── Step 1: remove TLS certificates ──────────────────────────────────────────
header "Step 1 — Removing TLS certificates"

for f in files/certs/key.pem files/certs/cert.pem files/certs/bundle.pem; do
    if [[ -f "$f" ]]; then
        rm "$f"
        info "Removed: $f"
    else
        warn "Not found, skipping: $f"
    fi
done

# ── Step 2: rename host_vars file back to template name ──────────────────────
header "Step 2 — Resetting host_vars filename"

PLACEHOLDER="<host-ip-address>"
TEMPLATE_FILE="host_vars/${PLACEHOLDER}.yml"

# Find any .yml file in host_vars/ that is NOT already the template placeholder.
shopt -s nullglob
renamed=false
for f in host_vars/*.yml; do
    basename_f="$(basename "$f")"
    if [[ "$basename_f" != "${PLACEHOLDER}.yml" ]]; then
        mv "$f" "$TEMPLATE_FILE"
        info "Renamed: $f → $TEMPLATE_FILE"
        renamed=true
        break   # there should be exactly one file; stop after the first rename
    fi
done
shopt -u nullglob

if ! $renamed; then
    if [[ -f "$TEMPLATE_FILE" ]]; then
        info "host_vars file is already the template placeholder: $TEMPLATE_FILE"
    else
        warn "No host_vars .yml file found — nothing to rename."
    fi
fi

# ── Step 3: reset inventory.ini back to placeholder ──────────────────────────
header "Step 3 — Resetting inventory.ini"

# Replace any IPv4 address on its own line (under [tfe]) with the placeholder.
sedi "s|^[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}$|${PLACEHOLDER}|" inventory.ini
info "inventory.ini reset (IP → ${PLACEHOLDER})."

# ── Step 4: remove tfe.env ────────────────────────────────────────────────────
header "Step 4 — Removing tfe.env"

if [[ -f "tfe.env" ]]; then
    rm tfe.env
    info "Removed: tfe.env"
else
    warn "tfe.env not found — nothing to remove."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
header "Reset complete"
echo
echo -e "  ${GREEN}✔${RESET}  TLS certificates removed"
echo -e "  ${GREEN}✔${RESET}  host_vars file reset to template name"
echo -e "  ${GREEN}✔${RESET}  inventory.ini reset to placeholder"
echo -e "  ${GREEN}✔${RESET}  tfe.env removed"
echo
