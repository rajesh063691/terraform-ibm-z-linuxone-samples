#!/usr/bin/env bash
# setup.sh — TFE Ansible playbook setup script.
# Usage: source setup.sh   (activates the venv in your current shell)
#        bash setup.sh     (runs in a subshell; venv won't persist)

# Detect whether the script was sourced or executed.
# Works in both bash (BASH_SOURCE) and zsh (ZSH_EVAL_CONTEXT).
_is_sourced=false
if [ -n "${ZSH_EVAL_CONTEXT:-}" ]; then
    [[ "$ZSH_EVAL_CONTEXT" == *:file* ]] && _is_sourced=true
elif [ -n "${BASH_SOURCE:-}" ]; then
    [[ "${BASH_SOURCE[0]}" != "${0}" ]] && _is_sourced=true
fi

if $_is_sourced; then
    _script_path="${BASH_SOURCE[0]:-$0}"
    # Run the setup in a subshell to protect the parent shell from exit/options pollution.
    if ORIGINAL_INVOCATION_SOURCED=true bash "$_script_path"; then
        # Setup succeeded — activate the venv in the parent shell.
        _script_dir="$(cd "$(dirname "$_script_path")" && pwd)"
        if [ -f "${_script_dir}/.ansible-env/bin/activate" ]; then
            source "${_script_dir}/.ansible-env/bin/activate"
        fi
        unset _is_sourced _script_path _script_dir
        return 0
    else
        unset _is_sourced _script_path
        return 1
    fi
fi

set -eo pipefail
# Note: -u (nounset) is intentionally omitted — zsh passes unset variables
# such as RPROMPT through the environment and -u would cause false errors.

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

info()   { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}── $* ──────────────────────────────────────────${RESET}"; }

# ── working directory ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── load configuration ────────────────────────────────────────────────────────
if [[ -f "setup.env" ]]; then
    # shellcheck source=/dev/null
    source "setup.env"
else
    error "setup.env not found. Please create setup.env and configure your variables."
fi

# ── validate configuration ────────────────────────────────────────────────────
header "Validating configuration"

[[ -z "$TFE_HOSTNAME"           ]] && error "TFE_HOSTNAME is not set in setup.env."
[[ -z "$TFE_HOST_IP"            ]] && error "TFE_HOST_IP is not set in setup.env."
[[ -z "$TFE_LICENSE"            ]] && error "TFE_LICENSE is not set in setup.env."
[[ -z "$TFE_ENCRYPTION_PASSWORD" ]] && error "TFE_ENCRYPTION_PASSWORD is not set in setup.env."
[[ -z "$TFE_ADMIN_USERNAME"     ]] && error "TFE_ADMIN_USERNAME is not set in setup.env."
[[ -z "$TFE_ADMIN_EMAIL"        ]] && error "TFE_ADMIN_EMAIL is not set in setup.env."
[[ -z "$TFE_ADMIN_PASSWORD"     ]] && error "TFE_ADMIN_PASSWORD is not set in setup.env."
[[ -z "$ANSIBLE_USER"           ]] && error "ANSIBLE_USER is not set in setup.env."
[[ -z "$ANSIBLE_PASSWORD"       ]] && error "ANSIBLE_PASSWORD is not set in setup.env."

info "All required values are present."

# ── prerequisite checks ───────────────────────────────────────────────────────
header "Checking prerequisites"

command -v python3 >/dev/null 2>&1 || error "python3 is required but not found."
command -v openssl >/dev/null 2>&1 || error "openssl is required but not found."
command -v sed     >/dev/null 2>&1 || error "sed is required but not found."

info "python3 : $(python3 --version)"
info "openssl : $(openssl version)"

# ── portable in-place sed (GNU and BSD/macOS) ─────────────────────────────────
sedi() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# ── Step 1: create tfe.env ────────────────────────────────────────────────────
header "Step 1 — Creating tfe.env"

TFE_HOSTNAME="${TFE_HOSTNAME}" \
TFE_HOST_IP="${TFE_HOST_IP}" \
TFE_LICENSE="${TFE_LICENSE}" \
TFE_ENCRYPTION_PASSWORD="${TFE_ENCRYPTION_PASSWORD}" \
TFE_ADMIN_USERNAME="${TFE_ADMIN_USERNAME}" \
TFE_ADMIN_EMAIL="${TFE_ADMIN_EMAIL}" \
TFE_ADMIN_PASSWORD="${TFE_ADMIN_PASSWORD}" \
ANSIBLE_USER="${ANSIBLE_USER}" \
ANSIBLE_PASSWORD="${ANSIBLE_PASSWORD}" \
python3 -c '
import os, shlex
replacements = {
    "<host-host-name>": os.environ.get("TFE_HOSTNAME", ""),
    "<host-ip-address>": os.environ.get("TFE_HOST_IP", ""),
    "<tfe-license>": os.environ.get("TFE_LICENSE", ""),
    "<tfe-encryption-pass>": os.environ.get("TFE_ENCRYPTION_PASSWORD", ""),
    "<initial-admin>": os.environ.get("TFE_ADMIN_USERNAME", ""),
    "<initial-email>": os.environ.get("TFE_ADMIN_EMAIL", ""),
    "<initial-pass>": os.environ.get("TFE_ADMIN_PASSWORD", ""),
    "<host-user-name>": os.environ.get("ANSIBLE_USER", ""),
    "<host-paas>": os.environ.get("ANSIBLE_PASSWORD", "")
}
with open("tfe-example.env", "r") as f:
    content = f.read()
for placeholder, val in replacements.items():
    content = content.replace(placeholder, shlex.quote(val))
with open("tfe.env", "w") as f:
    f.write(content)
'

info "tfe.env written."

# ── Step 2: update inventory.ini ─────────────────────────────────────────────
header "Step 2 — Updating inventory.ini"

sedi "s|<host-ip-address>|${TFE_HOST_IP}|g" inventory.ini

info "inventory.ini updated."

# ── Step 3: rename host_vars file ────────────────────────────────────────────
header "Step 3 — Renaming host_vars file"

HOST_VARS_SRC="host_vars/<host-ip-address>.yml"
HOST_VARS_DST="host_vars/${TFE_HOST_IP}.yml"

if [[ -f "$HOST_VARS_SRC" ]]; then
    mv "$HOST_VARS_SRC" "$HOST_VARS_DST"
    info "Renamed: ${HOST_VARS_SRC} → ${HOST_VARS_DST}"
elif [[ -f "$HOST_VARS_DST" ]]; then
    info "host_vars file already named correctly: ${HOST_VARS_DST}"
else
    warn "host_vars source file not found — skipping rename."
fi

# ── Step 4: generate TLS certificates ────────────────────────────────────────
header "Step 4 — Generating TLS certificates"

CERT_DIR="files/certs/"
mkdir -p "$CERT_DIR"

openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
    -keyout "${CERT_DIR}/key.pem" \
    -out    "${CERT_DIR}/cert.pem" \
    -subj   "/CN=${TFE_HOSTNAME}" \
    -addext "subjectAltName=DNS:${TFE_HOSTNAME},IP:${TFE_HOST_IP}" \
    2>/dev/null

cp "${CERT_DIR}/cert.pem" "${CERT_DIR}/bundle.pem"

info "Certificates written to ${CERT_DIR}/"
info "  cert.pem   — server certificate (CN=${TFE_HOSTNAME}, SAN=DNS:${TFE_HOSTNAME},IP:${TFE_HOST_IP})"
info "  key.pem    — private key"
info "  bundle.pem — CA bundle (copy of cert.pem for self-signed)"

# ── Step 5: set up Python virtual environment ─────────────────────────────────
header "Step 5 — Setting up Python virtual environment"

# Always recreate the venv against the local Python to avoid stale/version-mismatched envs.
python3 -m venv --clear .ansible-env
info "Virtual environment created ($(python3 --version))."

# shellcheck source=/dev/null
source .ansible-env/bin/activate

info "Upgrading pip..."
python -m pip install --upgrade pip -q

info "Installing ansible..."
pip install ansible -q

info "Ansible installed: $(ansible --version | head -1)"

# ── Done ──────────────────────────────────────────────────────────────────────
header "Setup complete"
echo
echo -e "  ${GREEN}✔${RESET}  tfe.env populated"
echo -e "  ${GREEN}✔${RESET}  inventory.ini updated"
echo -e "  ${GREEN}✔${RESET}  host_vars/${TFE_HOST_IP}.yml ready"
echo -e "  ${GREEN}✔${RESET}  TLS certificates in files/certs/"
echo -e "  ${GREEN}✔${RESET}  Ansible virtual environment ready"
echo

# Detect whether the script was sourced or executed.
# Works in both bash (BASH_SOURCE) and zsh (ZSH_EVAL_CONTEXT).
_is_sourced=false
if [ -n "${ZSH_EVAL_CONTEXT:-}" ]; then
    [[ "$ZSH_EVAL_CONTEXT" == *:file* ]] && _is_sourced=true
elif [ -n "${BASH_SOURCE:-}" ]; then
    [[ "${BASH_SOURCE[0]}" != "${0}" ]] && _is_sourced=true
fi

if [ "${ORIGINAL_INVOCATION_SOURCED:-false}" = "true" ]; then
    _is_sourced=true
fi

if ! $_is_sourced; then
    warn "Script was run as 'bash setup.sh' — the virtual environment is NOT active in your shell."
    warn "To activate it, run:  source .ansible-env/bin/activate"
    echo
    echo -e "Then run the playbook with:"
    echo -e "  ${BOLD}source tfe.env && ansible-playbook -i inventory.ini install-tfe.yml${RESET}"
else
    info "Virtual environment is active in your current shell session."
    echo
    echo -e "Run the playbook with:"
    echo -e "  ${BOLD}source tfe.env && ansible-playbook -i inventory.ini install-tfe.yml${RESET}"
    echo
    warn "Run 'deactivate' when you are finished."
fi

# ── Reset shell options so sourcing this script doesn't leave set -eo pipefail
# ── active in the caller's interactive shell session.
set +eo pipefail 2>/dev/null || true
