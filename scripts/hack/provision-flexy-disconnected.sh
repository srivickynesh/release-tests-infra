#!/usr/bin/env bash
# Provision a Flexy disconnected cluster from a local Mac.
# Uses podman to run the Flexy containerized installer, then configures
# mirroring and proxy whitelist on the resulting disconnected cluster.
#
# Usage:
#   TEMPLATE=private-templates/functionality-testing/aos-4_19/ipi-on-aws/versioned-installer-customer_vpc-disconnected \
#   OPENSHIFT_VERSION=stable-4.19 \
#   ./scripts/hack/provision-flexy-disconnected.sh
#
#   ./scripts/hack/provision-flexy-disconnected.sh --destroy
#
# Required env vars (from .env or Vault):
#   TEMPLATE                   — Flexy template path
#   OPENSHIFT_VERSION          — OCP version (e.g. stable-4.19)
#   AWS credentials            — via Vault or .env (AWS_ACCESS_KEY, AWS_ACCESS_SECRET)
#   PULL_SECRET or pull-secret from Vault
#
# Optional:
#   LAUNCHER_VARS              — JSON Flexy config (default: {"dynamic_bastion_host":"yes"})
#   CLUSTER_NAME               — prefix (default: air)
#   CLUSTER_LIFETIME           — orphan cleanup tag (default: 48h)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/env/.env}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

# shellcheck source=cluster-login.sh
source "$SCRIPT_DIR/cluster-login.sh"

CLUSTER_PREFIX="${CLUSTER_NAME:-air}"
OCP_VERSION="${OPENSHIFT_VERSION:-stable-4.19}"
TEMPLATE="${TEMPLATE:?TEMPLATE is required (e.g. private-templates/functionality-testing/aos-4_19/ipi-on-aws/versioned-installer-customer_vpc-disconnected)}"
if [[ -z "${LAUNCHER_VARS:-}" ]]; then
  LAUNCHER_VARS='{"dynamic_bastion_host":"yes"}'
fi
GIT_TEMPLATES_BRANCH="${GIT_PRIVATE_TEMPLATES_BRANCH:-master}"
GIT_TEMPLATES_URI="${GIT_PRIVATE_TEMPLATES_URI:-https://gitlab.cee.redhat.com/aosqe/flexy-templates.git}"
LIFETIME="${CLUSTER_LIFETIME:-48h}"
ARCH="${ARCH:-linux/amd64}"
FLEXY_IMAGE="${FLEXY_IMAGE:-quay.io/openshift-pipeline/flexy-containerized:v1.16.6}"

CLUSTER_SUFFIX="$(date +%m%d%H%M | cut -c1-6)"
CLUSTER_NAME="${CLUSTER_PREFIX}${CLUSTER_SUFFIX}"
WORK_DIR="${REPO_ROOT}/.clusters/flexy-${CLUSTER_NAME}"

# --- Destroy mode ---
if [[ "${1:-}" == "--destroy" ]]; then
  DESTROY_DIR="${2:-$(ls -td "$REPO_ROOT/.clusters/flexy-"*/ 2>/dev/null | head -1)}"
  [[ -d "$DESTROY_DIR" ]] || die "No flexy cluster directory found"
  echo "=== Destroying Flexy cluster: $(basename "$DESTROY_DIR") ==="
  if [[ -f "$DESTROY_DIR/metadata.json" ]]; then
    CONTAINER_RT=$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || die "podman or docker required")
    "$CONTAINER_RT" run --rm \
      --platform linux/amd64 \
      -v "$DESTROY_DIR:/mnt:Z" \
      -v "${HOME}/.aws:/root/.aws:ro" \
      --entrypoint bash \
      "$FLEXY_IMAGE" -c "/usr/local/bin/install_entrypoint.sh uninstall || true"
  fi
  rm -rf "$DESTROY_DIR"
  echo "Cluster destroyed."
  exit 0
fi

# --- Validate ---
command -v podman &>/dev/null || command -v docker &>/dev/null || die "podman or docker required"
CONTAINER_RT=$(command -v podman 2>/dev/null || command -v docker 2>/dev/null)

# Vault login if configured
if [[ "${CRED_SOURCE:-local}" == "vault" ]]; then
  echo "=== Fetching secrets from Vault ==="
  bash "$SCRIPT_DIR/create-secrets.sh" --vault-login 2>/dev/null || true
  [[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
fi

# AWS credentials
if [[ -z "${AWS_ACCESS_KEY:-${AWS_ACCESS_KEY_ID:-}}" ]]; then
  [[ -f ~/.aws/credentials ]] || die "AWS credentials required: set in .env or ~/.aws/credentials"
fi

# Pull secret
PULL_SECRET_FILE=""
for ps in "$REPO_ROOT/.pull-secret.json" ~/.aws/pull-secret.txt ~/.pull-secret.json; do
  [[ -f "$ps" ]] && { PULL_SECRET_FILE="$ps"; break; }
done
[[ -n "$PULL_SECRET_FILE" ]] || die "Pull secret required: save to .pull-secret.json"

# SSH key
SSH_KEY_FILE=""
for key in ~/.ssh/psi-pipelines-shared.pem "$REPO_ROOT/.clusters/ssh/psi-pipelines-shared.pem"; do
  [[ -f "$key" ]] && { SSH_KEY_FILE="$key"; break; }
done

echo "============================================================"
echo "  Flexy Disconnected Cluster Provisioning"
echo "============================================================"
echo "  Cluster:      ${CLUSTER_NAME}"
echo "  OCP version:  ${OCP_VERSION}"
echo "  Template:     ${TEMPLATE}"
echo "  Launcher:     ${LAUNCHER_VARS}"
echo "  Work dir:     ${WORK_DIR}"
echo "============================================================"

# --- Resolve OCP payload ---
echo ""
echo "=== Resolving OCP release payload ==="
TARGET_ARCH=$(echo "$ARCH" | cut -d"/" -f2)
[[ -z "$TARGET_ARCH" ]] && TARGET_ARCH=amd64
MIRROR_URL="https://mirror.openshift.com/pub/openshift-v4/${TARGET_ARCH}/clients/ocp"

if [[ "$OCP_VERSION" == *dev-preview* ]]; then
  RELEASE_URL="${MIRROR_URL}-${OCP_VERSION}"
else
  RELEASE_URL="${MIRROR_URL}/${OCP_VERSION}"
fi

PAYLOAD=$(curl -ksSL "${RELEASE_URL}/release.txt" 2>/dev/null | grep "Pull From:" | cut -d" " -f3) \
  || die "Could not resolve payload from ${RELEASE_URL}/release.txt"
echo "  Payload: ${PAYLOAD}"

MERGED_VARS=$(echo \
  "{\"installer_payload_image\":\"$PAYLOAD\"}" \
  "{\"pull_secret_file\":\"/mnt/config/pull-secret\"}" \
  "{\"credentials_file\":\"awscreds\"}" \
  "$LAUNCHER_VARS" | jq -c -s add)

# --- Prepare work directory ---
mkdir -p "$WORK_DIR/config"
cp "$PULL_SECRET_FILE" "$WORK_DIR/config/pull-secret"

if [[ -n "${AWS_ACCESS_KEY:-${AWS_ACCESS_KEY_ID:-}}" ]]; then
  cat > "$WORK_DIR/config/awscreds" <<AWSEOF
[flexy-installer]
aws_access_key_id = ${AWS_ACCESS_KEY:-${AWS_ACCESS_KEY_ID}}
aws_secret_access_key = ${AWS_ACCESS_SECRET:-${AWS_SECRET_ACCESS_KEY}}
AWSEOF
elif [[ -f ~/.aws/credentials ]]; then
  # Rewrite profile header to [flexy-installer] for Flexy compatibility
  sed 's/^\[.*\]/[flexy-installer]/' ~/.aws/credentials > "$WORK_DIR/config/awscreds"
fi

[[ -n "$SSH_KEY_FILE" ]] && cp "$SSH_KEY_FILE" "$WORK_DIR/config/psi-pipelines-shared.pem"
# Generate public key from private key for Flexy template
[[ -n "$SSH_KEY_FILE" ]] && ssh-keygen -y -f "$SSH_KEY_FILE" > "$WORK_DIR/config/psi-pipelines-shared.pub" 2>/dev/null

# Create BushSlicer private config overlay for AWS host_opts
cat > "$WORK_DIR/config/config.yaml" <<'CFGEOF'
services:
  AWS:
    host_opts:
      ssh_private_key: psi-pipelines-shared.pem
      user: core
    install_base_domain: aws.ospqa.com
CFGEOF

# Build AWS_CREDENTIALS string (key:secret format for Flexy)
if [[ -n "${AWS_ACCESS_KEY:-${AWS_ACCESS_KEY_ID:-}}" ]]; then
  FLEXY_AWS_CREDS="${AWS_ACCESS_KEY:-${AWS_ACCESS_KEY_ID}}:${AWS_ACCESS_SECRET:-${AWS_SECRET_ACCESS_KEY}}"
elif [[ -f ~/.aws/credentials ]]; then
  _ak=$(grep aws_access_key_id ~/.aws/credentials | head -1 | awk -F= '{print $2}' | xargs)
  _sk=$(grep aws_secret_access_key ~/.aws/credentials | head -1 | awk -F= '{print $2}' | xargs)
  FLEXY_AWS_CREDS="${_ak}:${_sk}"
fi
[[ -n "${FLEXY_AWS_CREDS:-}" ]] || die "Cannot determine AWS credentials for Flexy"

# --- Run Flexy ---
echo ""
echo "=== Running Flexy installer ==="

# BushSlicer config override via env (merged last, highest priority) — inline YAML
BUSHSLICER_CFG='{services: {AWS: {host_opts: {ssh_private_key: psi-pipelines-shared.pem, user: core}, install_base_domain: aws.ospqa.com}}}'

FLEXY_ENV=(
  -e "BUSHSLICER_PRIVATE_DIR=/mnt/config"
  -e "BUSHSLICER_CONFIG=${BUSHSLICER_CFG}"
  -e "AWS_CREDENTIALS=${FLEXY_AWS_CREDS}"
  -e "AWS_SHARED_CREDENTIALS_FILE=/mnt/config/awscreds"
  -e "FLEXY_URI=https://github.com/ppitonak/verification-tests.git"
  -e "FLEXY_BRANCH=psych"
  -e "GIT_PRIVATE_TEMPLATES_BRANCH=${GIT_TEMPLATES_BRANCH}"
  -e "GIT_PRIVATE_TEMPLATES_URI=${GIT_TEMPLATES_URI}"
  -e "HOME=/home/jenkins"
  -e "INSTANCE_NAME_PREFIX=${CLUSTER_NAME}"
  -e "LAUNCHER_VARS=${MERGED_VARS}"
  -e "VARIABLES_LOCATION=${TEMPLATE}"
  -e "OCM_CLI_URL_PREFIX=https://github.com/openshift-online/ocm-cli/releases/download/v0.1.60"
  -e "GIT_SSL_NO_VERIFY=true"
)

# Create a wrapper script that patches config between clone and installer
cat > "$WORK_DIR/flexy-install-wrapper.sh" <<'WRAPPER'
#!/bin/bash -xe
export BASEDIR=$(pwd)
export WORKSPACE="$BASEDIR/flexy"
export BUSHSLICER_VMINFO_YAML="$WORKSPACE/vminfo.yml"
export BUSHSLICER_HOSTS_SPEC_FILE="$WORKSPACE/host.spec"

# Re-use entrypoint functions by extracting them
eval "$(sed -n '/^function /,/^}/p' /usr/local/bin/install_entrypoint.sh)"

# Clone repos and install gems
git_clone_all
gem_deps

# Patch the base config to add host_opts for AWS-CI (used by disconnected template)
cd "$WORKSPACE"
ruby -ryaml -e '
  cfg = YAML.load_file("config/config.yaml")
  cfg["services"] ||= {}
  %w[AWS AWS-CI].each do |svc|
    cfg["services"][svc] ||= {}
    cfg["services"][svc]["host_opts"] = {
      "ssh_private_key" => "psi-pipelines-shared.pem",
      "user" => "core"
    }
    cfg["services"][svc]["install_base_domain"] = "aws.ospqa.com"
  end
  File.write("config/config.yaml", cfg.to_yaml)
'
echo "=== Patched config/config.yaml with host_opts for AWS and AWS-CI ==="

# Run the installer
rm -f "$BUSHSLICER_HOSTS_SPEC_FILE" "$BUSHSLICER_VMINFO_YAML"
ruby tools/launch_instance.rb template -c "$(echo ${VARIABLES_LOCATION} | xargs)" -l "$(echo ${INSTANCE_NAME_PREFIX} | xargs)"
WRAPPER
chmod +x "$WORK_DIR/flexy-install-wrapper.sh"

"$CONTAINER_RT" run --rm \
  --platform linux/amd64 \
  -w /mnt \
  -v "$WORK_DIR:/mnt:Z" \
  --entrypoint bash \
  "${FLEXY_ENV[@]}" \
  "$FLEXY_IMAGE" \
  /mnt/flexy-install-wrapper.sh 2>&1 | tee "$WORK_DIR/install.log"

# --- Extract results ---
echo ""
echo "=== Extracting cluster info ==="

SRC_DIR="$WORK_DIR/flexy/workdir/install-dir"

if [ -f "$SRC_DIR/OCPINFO.yml" ]; then
  KUBEADMIN_PASS=$(grep password "$SRC_DIR/OCPINFO.yml" | cut -d' ' -f2)
  API_URL=$(grep ocp_api_url "$SRC_DIR/OCPINFO.yml" | cut -d' ' -f2)
else
  API_URL=$(oc config view --kubeconfig="$SRC_DIR/auth/kubeconfig" --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")
  KUBEADMIN_PASS=$(cat "$SRC_DIR/auth/kubeadmin-password" 2>/dev/null || echo "unknown")
fi

MIRROR_REG="quay.io"
if [ -f "$SRC_DIR/cf_stack_output" ]; then
  BASTION=$(grep my_IntSvc_PublicDnsName "$SRC_DIR/cf_stack_output" | cut -d "=" -f2)
  MIRROR_REG="${BASTION}:5000"
fi

echo ""
echo "============================================================"
echo "  Flexy Disconnected Cluster Ready!"
echo "============================================================"
echo "  API:            ${API_URL}"
echo "  kubeadmin:      ${KUBEADMIN_PASS}"
echo "  Mirror Reg:     ${MIRROR_REG}"
echo "  KUBECONFIG:     ${SRC_DIR}/auth/kubeconfig"
echo ""
echo "  Login: oc login -u kubeadmin -p '${KUBEADMIN_PASS}' ${API_URL} --insecure-skip-tls-verify"
echo ""

cat > "$WORK_DIR/cluster.env" <<EOF
# Generated by provision-flexy-disconnected.sh on $(date)
INSTALLER=flexy
APISERVER=${API_URL}
KUBEADMIN_PASSWORD=${KUBEADMIN_PASS}
KUBEADMIN_USER=kubeadmin
CLUSTER_NAME=${CLUSTER_NAME}
IS_DISCONNECTED=true
MIRROR_REGISTRY=${MIRROR_REG}
EOF

echo "  Cluster .env snippet: ${WORK_DIR}/cluster.env"
echo "  Destroy: $0 --destroy ${WORK_DIR}"
echo "============================================================"
