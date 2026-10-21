#!/usr/bin/env bash
# Downloads and installs everything the three labs need, so nothing big has to
# be fetched at the workshop. Safe to leave running and safe to re-run:
#   - every download step retries with growing waits (slow or flaky Wi-Fi)
#   - model files and Docker layers resume where they stopped
#   - a failed step does not stop the others; a summary prints at the end
#
# Run it detached so a dropped SSH session does not kill it:
#   sudo -v && nohup ./prefetch.sh > prefetch.log 2>&1 &
#   tail -f prefetch.log

set -uo pipefail

BASE="$HOME/nemotron-labs"
VENV="$BASE/.venv"
NOTEBOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/notebooks"
MODEL_ID="nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8"
MODEL_DIR="$HOME/models/nemotron-3-nano-fp8"
IMAGES=("vllm/vllm-openai:v0.20.0" "ubuntu:24.04" "buildpack-deps:noble-curl")
RETRIES=5
RESULTS=()
KEEPALIVE=""
NEED_RELOGIN=0

stamp() { date '+%H:%M:%S'; }
log()   { printf '\n[%s] === %s\n' "$(stamp)" "$*"; }

retry() {
  local n=1 delay=10
  until "$@"; do
    if (( n >= RETRIES )); then echo "[$(stamp)] giving up: $*"; return 1; fi
    echo "[$(stamp)] attempt $n failed, retrying in ${delay}s"
    sleep "$delay"; n=$((n + 1)); delay=$((delay * 2))
  done
}

step() {
  local name="$1"; shift
  log "$name"
  if "$@"; then RESULTS+=("[OK]   $name"); else RESULTS+=("[FAIL] $name"); fi
}

trap '[[ -n "$KEEPALIVE" ]] && kill "$KEEPALIVE" 2>/dev/null' EXIT

start_sudo() {
  # The OpenShell installer installs a .deb, so it needs sudo. Ask once, then keep
  # the ticket alive so a long download does not let it expire.
  sudo -n true 2>/dev/null || { echo "Enter your sudo password once:"; sudo -v || return 1; }
  ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
  KEEPALIVE=$!
}

# Runs docker as the current user, or with sudo while the user is not yet in the
# docker group (group changes only apply to new logins).
dk() {
  if docker info >/dev/null 2>&1; then docker "$@"; else sudo docker "$@"; fi
}

check_system() {
  nvidia-smi -L | head -1
  uname -m
  df -h "$HOME" | tail -1
  return 0
}

gpu_in_docker() {
  dk run --rm --gpus all ubuntu:24.04 nvidia-smi -L >/dev/null 2>&1
}

ensure_docker() {
  # Installs only what is missing. The NVIDIA driver is not installed here.
  nvidia-smi -L >/dev/null 2>&1 || { echo "nvidia-smi does not work: the NVIDIA driver must be installed first."; return 1; }

  if ! command -v docker >/dev/null; then
    echo "Docker is not installed. Installing docker.io from the Ubuntu repository."
    sudo apt-get update && sudo apt-get install -y docker.io || return 1
    sudo systemctl enable --now docker || return 1
  fi

  # Test real GPU access instead of looking at Docker's runtime list: a working
  # setup should not be touched. Only configure the toolkit if this test fails.
  retry dk pull ubuntu:24.04 || return 1
  if ! gpu_in_docker; then
    echo "A container cannot see the GPU. Setting up the NVIDIA Container Toolkit."
    if ! command -v nvidia-ctk >/dev/null; then
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg || return 1
      curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null || return 1
      sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit || return 1
    fi
    sudo nvidia-ctk runtime configure --runtime=docker || return 1
    sudo systemctl restart docker || return 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "Adding $USER to the docker group."
    sudo usermod -aG docker "$USER" || return 1
    NEED_RELOGIN=1
  fi

  gpu_in_docker || { echo "A container still cannot see the GPU."; return 1; }
  echo "Docker is ready: a container can see the GPU."
}

python_env() {
  if ! python3 -c 'import venv, ensurepip' 2>/dev/null; then
    sudo apt-get install -y python3-venv python3-pip || return 1
  fi
  [[ -d "$VENV" ]] || python3 -m venv "$VENV" || return 1
  "$VENV/bin/pip" install --quiet --upgrade pip &&
  "$VENV/bin/pip" install --quiet jupyterlab huggingface_hub openai requests
}

download_model() {
  mkdir -p "$(dirname "$MODEL_DIR")"
  "$VENV/bin/python" - <<PY
from huggingface_hub import snapshot_download
snapshot_download(repo_id="$MODEL_ID", local_dir="$MODEL_DIR")
PY
  du -sh "$MODEL_DIR"
}

pull_images() {
  local rc=0 img
  for img in "${IMAGES[@]}"; do
    echo "[$(stamp)] pulling $img"
    retry dk pull "$img" || rc=1
  done
  return "$rc"
}

install_hermes() {
  # Same command as Part 2: --non-interactive skips the sign-in and gateway stages.
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
    | bash -s -- --non-interactive &&
  PATH="$HOME/.local/bin:$PATH" command -v hermes
}

install_openshell() {
  # Same command as Part 3, pinned to 0.1.4, the version the notebooks were verified on.
  # Without the pin the installer takes the latest release (0.1.5 on 2026-10-20).
  curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | OPENSHELL_VERSION=v0.1.4 sh &&
  openshell status
}

verify() {
  # Confirms the files are actually there, instead of trusting the step results.
  local rc=0 img
  if [[ -f "$MODEL_DIR/config.json" ]]; then echo "model:   $(du -sh "$MODEL_DIR" | cut -f1) in $MODEL_DIR"; else echo "model:   MISSING"; rc=1; fi
  for img in "${IMAGES[@]}"; do
    if dk image inspect "$img" >/dev/null 2>&1; then echo "image:   $img"; else echo "image:   MISSING $img"; rc=1; fi
  done
  if PATH="$HOME/.local/bin:$PATH" command -v hermes >/dev/null; then echo "hermes:  installed"; else echo "hermes:  MISSING"; rc=1; fi
  if command -v openshell >/dev/null; then echo "openshell: installed"; else echo "openshell: MISSING"; rc=1; fi
  return "$rc"
}

mkdir -p "$BASE"
echo "Prefetch started $(date)"
start_sudo || true

step "System check (informational)" check_system
step "Docker with GPU access"       ensure_docker
step "Python environment"           retry python_env
step "Model weights"                retry download_model
step "Docker images"                pull_images
step "Hermes Agent"                 retry install_hermes
step "OpenShell"                    retry install_openshell
step "Verify everything is in place" verify

log "Summary"
printf '%s\n' "${RESULTS[@]}"
echo
if printf '%s\n' "${RESULTS[@]}" | grep -q '^\[FAIL\]'; then
  echo "Some steps failed. Re-run this script: finished downloads are skipped."
else
  if (( NEED_RELOGIN )); then
    echo "IMPORTANT: you were added to the docker group. Log out and back in (or reboot)"
    echo "before running the notebooks, so that 'docker' works without sudo."
    echo
  fi
  echo "All done. To open the notebooks, start JupyterLab:"
  echo
  echo "  $VENV/bin/jupyter lab --notebook-dir \"$NOTEBOOKS_DIR\" --ip=127.0.0.1 --port=8888 --no-browser"
  echo
  echo "It prints a URL with a token. From your own computer, tunnel to it first:"
  echo "  ssh -L 8888:localhost:8888 <user>@<this-machine-IP>"
  echo "then open http://localhost:8888 with that token. Run Part 1, Part 2, Part 3 in order;"
  echo "the notebooks start and stop the model server themselves."
  echo "(To reach it directly instead, use --ip=0.0.0.0 and the machine's IP address, not its"
  echo " hostname. That lets anyone on the network with the token run code, so only do it on a"
  echo " network you trust.)"
fi
