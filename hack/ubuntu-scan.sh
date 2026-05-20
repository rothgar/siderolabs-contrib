#!/bin/bash
# Boot an Ubuntu cloud image in QEMU, count unique installed binaries,
# and run a Grype CVE scan of the root filesystem.
#
# Usage: ubuntu-scan.sh <ubuntu-version>
# Example: ubuntu-scan.sh 22.04
#
# Companion to siderolabs/talos issue #13356 — generates the
# "binary count" and "Critical+High CVE" numbers for Ubuntu Server
# (the Talos-side numbers are produced separately).
#
# Environment overrides:
#   QEMU_MEMORY      RAM in MiB (default 4096)
#   QEMU_CPUS        vCPU count (default 2)
#   QEMU_DISK_SIZE   overlay disk size (default 10G)
#   SSH_PORT         host port forwarded to guest:22 (default random)
#   GRYPE_VERSION    grype release to install in the guest, pinned for
#                    reproducibility and verified via sha256 (default v0.112.0,
#                    must match ^v?[0-9]+\.[0-9]+\.[0-9]+$)
#   OUTPUT_DIR       where reports are written (default ./scan-ubuntu-<ver>-<ts>)
#   KEEP_WORKDIR=1   keep the temporary workdir (disk, seed, qemu log) after exit

set -Eeuo pipefail

UBUNTU_VERSION="${1:-}"
if [[ -z "$UBUNTU_VERSION" ]]; then
    echo "Usage: $0 <ubuntu-version>" >&2
    echo "Example: $0 22.04" >&2
    exit 2
fi

QEMU_MEMORY="${QEMU_MEMORY:-4096}"
QEMU_CPUS="${QEMU_CPUS:-2}"
QEMU_DISK_SIZE="${QEMU_DISK_SIZE:-10G}"
SSH_PORT="${SSH_PORT:-$((20000 + RANDOM % 20000))}"
GRYPE_VERSION="${GRYPE_VERSION:-v0.112.0}"
if [[ ! "$GRYPE_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "GRYPE_VERSION must look like v0.112.0 (got: ${GRYPE_VERSION})" >&2
    exit 2
fi
GRYPE_VERSION_BARE="${GRYPE_VERSION#v}"
OUTPUT_DIR="${OUTPUT_DIR:-./scan-ubuntu-${UBUNTU_VERSION}-$(date +%Y%m%d-%H%M%S)}"

WORK_DIR="$(mktemp -d -t ubuntu-scan-XXXXXX)"
QEMU_PID=""

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

cleanup() {
    local rc=$?
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        log "Stopping QEMU (pid=$QEMU_PID)"
        kill -TERM "$QEMU_PID" 2>/dev/null || true
        for _ in {1..20}; do
            kill -0 "$QEMU_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [[ -d "$WORK_DIR" ]]; then
        if [[ "${KEEP_WORKDIR:-0}" == "1" ]]; then
            log "Preserving workdir at $WORK_DIR"
        else
            rm -rf "$WORK_DIR"
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

require() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        echo "Missing required commands: ${missing[*]}" >&2
        exit 1
    fi
}

make_seed_iso() {
    local out="$1" userdata="$2" metadata="$3"
    if command -v cloud-localds >/dev/null 2>&1; then
        cloud-localds "$out" "$userdata" "$metadata"
    elif command -v genisoimage >/dev/null 2>&1; then
        genisoimage -output "$out" -volid cidata -joliet -rock \
            "$userdata" "$metadata" >/dev/null 2>&1
    elif command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs -output "$out" -volid CIDATA -joliet -rock \
            "$userdata" "$metadata" >/dev/null 2>&1
    else
        echo "Need cloud-localds, genisoimage, or xorriso to build cloud-init seed" >&2
        exit 1
    fi
}

require qemu-system-x86_64 qemu-img curl ssh ssh-keygen

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

IMG_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_VERSION}/release/ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
IMG_FILE="${WORK_DIR}/ubuntu-${UBUNTU_VERSION}.img"
DISK_FILE="${WORK_DIR}/disk.qcow2"
SEED_FILE="${WORK_DIR}/seed.iso"
SSH_KEY="${WORK_DIR}/id_ed25519"

log "Downloading $IMG_URL"
curl --fail --location --progress-bar --output "$IMG_FILE" "$IMG_URL"

log "Creating qcow2 overlay disk (${QEMU_DISK_SIZE})"
qemu-img create -f qcow2 -F qcow2 -b "$IMG_FILE" "$DISK_FILE" "$QEMU_DISK_SIZE" >/dev/null

log "Generating throwaway SSH key"
ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -q -C "ubuntu-scan"
SSH_PUB="$(cat "${SSH_KEY}.pub")"

log "Building cloud-init seed"
cat >"${WORK_DIR}/user-data" <<EOF
#cloud-config
hostname: ubuntu-scan
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUB}
ssh_pwauth: false
package_update: false
package_upgrade: false
EOF

cat >"${WORK_DIR}/meta-data" <<EOF
instance-id: ubuntu-scan-$$
local-hostname: ubuntu-scan
EOF

make_seed_iso "$SEED_FILE" "${WORK_DIR}/user-data" "${WORK_DIR}/meta-data"

ACCEL="tcg"
CPU="qemu64"
if [[ -w /dev/kvm ]]; then
    ACCEL="kvm"
    CPU="host"
else
    log "No /dev/kvm access; falling back to TCG (slow)"
fi

log "Booting QEMU (port forward 127.0.0.1:${SSH_PORT} -> guest:22)"
qemu-system-x86_64 \
    -name "ubuntu-scan-${UBUNTU_VERSION}" \
    -machine "type=q35,accel=${ACCEL}" \
    -cpu "$CPU" \
    -smp "$QEMU_CPUS" \
    -m "$QEMU_MEMORY" \
    -nographic \
    -serial "file:${WORK_DIR}/serial.log" \
    -monitor none \
    -display none \
    -device virtio-net-pci,netdev=net0 \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -drive "file=${DISK_FILE},if=virtio,format=qcow2" \
    -drive "file=${SEED_FILE},if=virtio,format=raw,readonly=on" \
    >"${WORK_DIR}/qemu.log" 2>&1 &
QEMU_PID=$!

ssh_opts=(
    -i "$SSH_KEY"
    -o IdentitiesOnly=yes
    -o IdentityAgent=none
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=20
    -p "$SSH_PORT"
)

log "Waiting for SSH on 127.0.0.1:${SSH_PORT} (up to 5 minutes)"
ssh_ready=0
for i in {1..60}; do
    if ssh "${ssh_opts[@]}" -o BatchMode=yes ubuntu@127.0.0.1 true 2>/dev/null; then
        ssh_ready=1
        log "SSH is up after ${i} attempt(s)"
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        log "QEMU exited before SSH came up:"
        tail -n 50 "${WORK_DIR}/qemu.log" >&2
        exit 1
    fi
    sleep 5
done

if [[ "$ssh_ready" != "1" ]]; then
    log "Timed out waiting for SSH"
    exit 1
fi

log "Waiting for cloud-init to finish"
ssh "${ssh_opts[@]}" ubuntu@127.0.0.1 'sudo cloud-init status --wait' >/dev/null || true

# Snapshot the package list of the fresh install for the record.
# Note: dpkg-query's -f uses ${...} as its own format syntax, so we wrap it in
# single quotes on the remote shell to keep both local and remote shells from
# trying to expand it.
ssh "${ssh_opts[@]}" ubuntu@127.0.0.1 \
    "dpkg-query -W -f='\${Package} \${Version}\n' | sort" \
    >"${OUTPUT_DIR}/packages.txt" || true

log "Counting unique binaries in /bin /sbin /usr/bin /usr/sbin (skip symlinks, dedupe hardlinks)"
BIN_COUNT="$(ssh "${ssh_opts[@]}" ubuntu@127.0.0.1 \
    "find /bin /sbin /usr/bin /usr/sbin -xdev -type f -printf '%D:%i\n' 2>/dev/null | sort -u | wc -l")"
BIN_COUNT="${BIN_COUNT//[^0-9]/}"
log "Binary count: ${BIN_COUNT}"

log "Installing grype ${GRYPE_VERSION} into /opt/grype (kept out of the counted bin dirs)"
# Pinned release artifact + sha256 verification rather than `curl | sh` — this
# is reproducible and avoids trusting whatever the upstream install.sh happens
# to be at run time. The version arrives on the guest as $1, so we never have
# to splice user-controlled text into the remote shell command.
ssh "${ssh_opts[@]}" ubuntu@127.0.0.1 bash -s -- "$GRYPE_VERSION_BARE" <<'REMOTE' \
    | tee "${OUTPUT_DIR}/grype-version.txt" >/dev/null
set -eu
ver="$1"
tag="v${ver}"
tarball="grype_${ver}_linux_amd64.tar.gz"
checksums="grype_${ver}_checksums.txt"
base="https://github.com/anchore/grype/releases/download/${tag}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
curl -sSfL -o "$tarball"   "${base}/${tarball}"
curl -sSfL -o "$checksums" "${base}/${checksums}"
grep "  ${tarball}\$" "$checksums" | sha256sum -c -
sudo mkdir -p /opt/grype
sudo tar -xzf "$tarball" -C /opt/grype grype
sudo chmod 0755 /opt/grype/grype
/opt/grype/grype version
REMOTE

log "Updating grype DB and scanning root filesystem (this can take a few minutes)"
GRYPE_TABLE="${OUTPUT_DIR}/grype.txt"
GRYPE_JSON="${OUTPUT_DIR}/grype.json"
GRYPE_STDERR="${OUTPUT_DIR}/grype.stderr"
GRYPE_SCAN_OK=0
: >"$GRYPE_STDERR"

# Pre-fetch the DB once so failures show up clearly and aren't repeated below.
ssh "${ssh_opts[@]}" ubuntu@127.0.0.1 'sudo /opt/grype/grype db update' \
    2>>"$GRYPE_STDERR" >>"$GRYPE_STDERR" || log "grype db update returned non-zero; continuing"

# Build the scan command once so the two invocations stay in sync.
# Exclude grype's own install dir and runtime / pseudo filesystems so we only
# report on what Ubuntu shipped.
read -r -d '' GRYPE_CMD <<'EOS' || true
set -o pipefail
sudo /opt/grype/grype dir:/ \
    --exclude './opt/grype/**' \
    --exclude './proc/**' --exclude './sys/**' --exclude './dev/**' \
    --exclude './run/**' --exclude './tmp/**' --exclude './var/cache/**' \
    --exclude './var/log/**' --exclude './var/lib/grype/**' \
    -o __FORMAT__
EOS

run_grype() {
    local format="$1" outfile="$2"
    local cmd="${GRYPE_CMD//__FORMAT__/$format}"
    if ssh "${ssh_opts[@]}" ubuntu@127.0.0.1 "$cmd" \
            >"$outfile" 2>>"$GRYPE_STDERR"; then
        return 0
    fi
    return 1
}

if run_grype table "$GRYPE_TABLE"; then
    GRYPE_SCAN_OK=1
else
    log "grype table scan failed"
fi
if run_grype json "$GRYPE_JSON"; then
    GRYPE_SCAN_OK=1
else
    log "grype json scan failed"
fi

if [[ "$GRYPE_SCAN_OK" != "1" ]]; then
    log "Last lines of grype stderr (${GRYPE_STDERR}):"
    tail -n 30 "$GRYPE_STDERR" | sed 's/^/    /' >&2
fi

log "Powering off VM"
ssh "${ssh_opts[@]}" ubuntu@127.0.0.1 'sudo poweroff' 2>/dev/null || true
for _ in {1..30}; do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 1
done

CRIT="?"; HIGH="?"; MED="?"; LOW="?"; NEG="?"; UNK="?"; TOTAL="?"
if [[ -s "$GRYPE_JSON" ]] && command -v jq >/dev/null 2>&1; then
    sev_count() {
        jq --arg s "$1" '[.matches[]? | select(.vulnerability.severity == $s)] | length' \
            "$GRYPE_JSON" 2>/dev/null || echo "?"
    }
    CRIT="$(sev_count Critical)"
    HIGH="$(sev_count High)"
    MED="$(sev_count Medium)"
    LOW="$(sev_count Low)"
    NEG="$(sev_count Negligible)"
    UNK="$(sev_count Unknown)"
    TOTAL="$(jq '.matches | length' "$GRYPE_JSON" 2>/dev/null || echo "?")"
fi

REPORT="${OUTPUT_DIR}/report.txt"
{
    echo "============================================="
    echo "Ubuntu ${UBUNTU_VERSION} scan report"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Image:     ${IMG_URL}"
    echo "============================================="
    echo
    echo "Unique binaries (find /bin /sbin /usr/bin /usr/sbin -type f, dedup by inode):"
    echo "  ${BIN_COUNT}"
    echo
    echo "Grype CVE summary (dir:/ scan):"
    printf "  %-12s %s\n" "Critical:"   "$CRIT"
    printf "  %-12s %s\n" "High:"       "$HIGH"
    printf "  %-12s %s\n" "Medium:"     "$MED"
    printf "  %-12s %s\n" "Low:"        "$LOW"
    printf "  %-12s %s\n" "Negligible:" "$NEG"
    printf "  %-12s %s\n" "Unknown:"    "$UNK"
    printf "  %-12s %s\n" "Total:"      "$TOTAL"
    echo
    echo "Artifacts:"
    echo "  ${OUTPUT_DIR}/report.txt"
    echo "  ${OUTPUT_DIR}/grype.txt"
    echo "  ${OUTPUT_DIR}/grype.json"
    echo "  ${OUTPUT_DIR}/grype.stderr"
    echo "  ${OUTPUT_DIR}/grype-version.txt"
    echo "  ${OUTPUT_DIR}/packages.txt"
} | tee "$REPORT"
