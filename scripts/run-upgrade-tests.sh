#!/usr/bin/env bash
# Create an upgrade-tests PipelineRun from env/.env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HACK_DIR="${SCRIPT_DIR}/hack"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/env/.env}"
export ENV_FILE

die() { echo "ERROR: $*" >&2; exit 1; }

env_file_get() {
  local key=$1 file=$2 line val
  [[ -f "$file" ]] || return 1
  line=$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -1) || return 1
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

normalize_bool() {
  case "$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1|on) printf '%s' true ;;
    *) printf '%s' false ;;
  esac
}

parse_test_suites() {
  local raw="${TEST_SUITES:-}" s
  # pre-upgrade and post-upgrade always run — not user-configurable
  TEST_SUITE_ITEMS=(release-tests-pre-upgrade release-tests-post-upgrade)

  raw="${raw// /,}"
  IFS=',' read -ra parts <<< "$raw"
  for s in "${parts[@]}"; do
    s="${s// /}"
    [[ -z "$s" ]] && continue
    # skip if already in the list
    [[ " ${TEST_SUITE_ITEMS[*]} " == *" $s "* ]] && continue
    TEST_SUITE_ITEMS+=("$s")
  done
}

ci_config_major_minor() {
  local v="${1#v}"
  v="${v%%-*}"
  printf '%s' "$v" | awk -F. '{ if (NF >= 2) printf "%s.%s", $1, $2; else printf "%s", $0 }'
}

ci_config_get() {
  local ver="$1" key="$2" cfg="${REPO_ROOT}/ci-config.yaml"
  [[ -f "$cfg" ]] || return 1
  python3 - "$cfg" "$ver" "$key" <<'PY'
import sys
try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required to read ci-config.yaml (pip install pyyaml)", file=sys.stderr)
    sys.exit(1)
cfg, ver, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(cfg) as f:
    c = yaml.safe_load(f) or {}
node = c.get(ver)
if node is None:
    for k, val in c.items():
        if str(k) == str(ver):
            node = val
            break
if node is None:
    sys.exit(1)
for k in key.split("."):
    if not isinstance(node, dict):
        sys.exit(1)
    node = node.get(k)
    if node is None:
        sys.exit(1)
print(node, end="")
PY
}

resolve_channel() {
  local ver=$1 ch=$2 short
  short="$(ci_config_major_minor "$ver")"
  if [[ -z "$ch" || "$ch" == latest ]]; then
    ch=$(ci_config_get "$short" channel) || ch="pipelines-${short}"
  fi
  printf '%s' "$ch"
}

[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE (cp env/env.template env/.env)"
set -a; source "$ENV_FILE"; set +a

# shellcheck source=cluster-login.sh
source "$HACK_DIR/cluster-login.sh"

command -v oc >/dev/null || die "oc CLI required"
NS="${NAMESPACE:-pipelines-ci}"
INSTALLER="${INSTALLER:-aws-ipi}"

ensure_namespace() {
  oc get namespace "$NS" &>/dev/null \
    && echo "Namespace ${NS} exists" \
    || { echo "Creating namespace ${NS}..."; oc new-project "$NS"; }
}

# For existing clusters: auto-detect OCP version
if is_existing_cluster; then
  cluster_login || die "cluster login failed"
  ensure_namespace
  if [[ -z "${OPENSHIFT_VERSION:-}" || "${OPENSHIFT_VERSION}" == stable* ]]; then
    OPENSHIFT_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
    [[ -n "$OPENSHIFT_VERSION" ]] || die "Could not detect OCP version from cluster"
    echo "Auto-detected OCP version: ${OPENSHIFT_VERSION}"
  fi
fi

# --- Validate required vars ---
missing=()
for v in PRE_UPGRADE_VERSION UPGRADE_VERSION INSTALLER TEST_FRAMEWORK; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done

case "${INSTALLER,,}" in
  aws-ipi)
    [[ -n "${OPENSHIFT_VERSION:-}" ]] || missing+=("OPENSHIFT_VERSION")
    oc get secret aws-creds -n "$NS" &>/dev/null \
      || missing+=("aws-creds secret (run ./scripts/hack/create-secrets.sh with INSTALLER=aws-ipi)")
    oc get secret aws-install-config -n "$NS" &>/dev/null \
      || missing+=("aws-install-config secret (run ./scripts/hack/create-secrets.sh with INSTALLER=aws-ipi)")
    ;;
  aro)
    [[ -n "${OPENSHIFT_VERSION:-}" ]] || missing+=("OPENSHIFT_VERSION")
    oc get secret azure-creds -n "$NS" &>/dev/null \
      || missing+=("azure-creds secret (run ./scripts/hack/create-secrets.sh with INSTALLER=aro)")
    ;;
  *)
    if is_existing_cluster && ! cluster_secret_exists "$NS"; then
      echo "Cluster secret missing — running create-secrets.sh..."
      validate_cluster_env || missing+=("cluster connection (set APISERVER + KUBEADMIN_PASSWORD in ${ENV_FILE})")
      if [[ ${#missing[@]} -eq 0 ]]; then
        NAMESPACE="$NS" bash "$HACK_DIR/create-secrets.sh" || missing+=("create-secrets.sh failed")
      fi
    fi
    ;;
esac

# Validate pre-upgrade operator environment
OPERATOR_ENVIRONMENT="${PRE_UPGRADE_OPERATOR_ENVIRONMENT:-prod}" \
  CATALOG_SOURCE="${PRE_UPGRADE_CATALOG_SOURCE:-redhat-operators}" \
  KONFLUX_INDEX_IMAGE="${PRE_UPGRADE_KONFLUX_INDEX_IMAGE:-}" \
  validate_operator_env || missing+=("PRE_UPGRADE env/catalog mismatch (see error above)")

# Validate upgrade operator environment
OPERATOR_ENVIRONMENT="${UPGRADE_OPERATOR_ENVIRONMENT:-pre-stage}" \
  CATALOG_SOURCE="${UPGRADE_CATALOG_SOURCE:-custom-operators}" \
  KONFLUX_INDEX_IMAGE="${UPGRADE_KONFLUX_INDEX_IMAGE:-}" \
  validate_operator_env || missing+=("UPGRADE env/catalog mismatch (see error above)")

FW="$(printf '%s' "${TEST_FRAMEWORK:-gauge}" | tr '[:upper:]' '[:lower:]')"
# Empty branch vars from env.template must not block ci-config.yaml auto-resolve.
[[ -z "${GIT_RELEASE_TESTS_BRANCH:-}" ]] && unset GIT_RELEASE_TESTS_BRANCH
[[ -z "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]] && unset GIT_RELEASE_TESTS_GINKGO_BRANCH
[[ -z "${PRE_UPGRADE_GIT_RELEASE_TESTS_BRANCH:-}" ]] && unset PRE_UPGRADE_GIT_RELEASE_TESTS_BRANCH
[[ -z "${PRE_UPGRADE_GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]] && unset PRE_UPGRADE_GIT_RELEASE_TESTS_GINKGO_BRANCH

# Auto-resolve git branches from ci-config.yaml using UPGRADE_VERSION (e.g. 1.15.5 → 1.15)
ver_short="$(ci_config_major_minor "${UPGRADE_VERSION:-}")"
if [[ "$FW" == gauge && -z "${GIT_RELEASE_TESTS_BRANCH:-}" ]]; then
  if GIT_RELEASE_TESTS_BRANCH=$(ci_config_get "$ver_short" release-tests.revision); then
    echo "Auto-resolved GIT_RELEASE_TESTS_BRANCH=${GIT_RELEASE_TESTS_BRANCH} from ci-config.yaml (${ver_short})"
  else
    missing+=("GIT_RELEASE_TESTS_BRANCH (ci-config.yaml has no release-tests.revision for ${ver_short} from UPGRADE_VERSION=${UPGRADE_VERSION:-})")
  fi
fi
if [[ "$FW" == ginkgo && -z "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]]; then
  if GIT_RELEASE_TESTS_GINKGO_BRANCH=$(ci_config_get "$ver_short" release-tests-ginkgo.revision); then
    echo "Auto-resolved GIT_RELEASE_TESTS_GINKGO_BRANCH=${GIT_RELEASE_TESTS_GINKGO_BRANCH} from ci-config.yaml (${ver_short})"
  else
    missing+=("GIT_RELEASE_TESTS_GINKGO_BRANCH (ci-config.yaml has no release-tests-ginkgo.revision for ${ver_short} from UPGRADE_VERSION=${UPGRADE_VERSION:-})")
  fi
fi

# Auto-resolve pre-upgrade git branches from ci-config.yaml using PRE_UPGRADE_VERSION
pre_ver_short="$(ci_config_major_minor "${PRE_UPGRADE_VERSION:-}")"
if [[ "$FW" == gauge && -z "${PRE_UPGRADE_GIT_RELEASE_TESTS_BRANCH:-}" ]]; then
  if PRE_UPGRADE_GIT_RELEASE_TESTS_BRANCH=$(ci_config_get "$pre_ver_short" release-tests.revision); then
    echo "Auto-resolved PRE_UPGRADE_GIT_RELEASE_TESTS_BRANCH=${PRE_UPGRADE_GIT_RELEASE_TESTS_BRANCH} from ci-config.yaml (${pre_ver_short})"
  else
    missing+=("PRE_UPGRADE_GIT_RELEASE_TESTS_BRANCH (ci-config.yaml has no release-tests.revision for ${pre_ver_short} from PRE_UPGRADE_VERSION=${PRE_UPGRADE_VERSION:-})")
  fi
fi
if [[ "$FW" == ginkgo && -z "${PRE_UPGRADE_GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]]; then
  if PRE_UPGRADE_GIT_RELEASE_TESTS_GINKGO_BRANCH=$(ci_config_get "$pre_ver_short" release-tests-ginkgo.revision); then
    echo "Auto-resolved PRE_UPGRADE_GIT_RELEASE_TESTS_GINKGO_BRANCH=${PRE_UPGRADE_GIT_RELEASE_TESTS_GINKGO_BRANCH} from ci-config.yaml (${pre_ver_short})"
  else
    missing+=("PRE_UPGRADE_GIT_RELEASE_TESTS_GINKGO_BRANCH (ci-config.yaml has no release-tests-ginkgo.revision for ${pre_ver_short} from PRE_UPGRADE_VERSION=${PRE_UPGRADE_VERSION:-})")
  fi
fi

case "$FW" in
  gauge)
    [[ -n "${GIT_RELEASE_TESTS_BRANCH:-}" ]] || missing+=("GIT_RELEASE_TESTS_BRANCH (set in env/.env or add to ci-config.yaml)")
    [[ -n "${PRE_UPGRADE_GIT_RELEASE_TESTS_BRANCH:-}" ]] || missing+=("PRE_UPGRADE_GIT_RELEASE_TESTS_BRANCH (set in env/.env or add to ci-config.yaml)") ;;
  ginkgo)
    [[ -n "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]] || missing+=("GIT_RELEASE_TESTS_GINKGO_BRANCH (set in env/.env or add to ci-config.yaml)")
    [[ -n "${PRE_UPGRADE_GIT_RELEASE_TESTS_GINKGO_BRANCH:-}" ]] || missing+=("PRE_UPGRADE_GIT_RELEASE_TESTS_GINKGO_BRANCH (set in env/.env or add to ci-config.yaml)") ;;
  *) missing+=("TEST_FRAMEWORK must be gauge or ginkgo (got: $FW)") ;;
esac

if ((${#missing[@]})); then
  echo "ERROR: Missing required configuration:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

# Auto-create secrets if test secrets are missing
if ! oc get secret github -n "$NS" &>/dev/null; then
  echo "=== Running create-secrets.sh (test secrets missing) ==="
  bash "$HACK_DIR/create-secrets.sh" || die "create-secrets.sh failed"
fi

# Install Logging + Loki operator if requested
is_enabled() {
  case "$(printf '%s' "${1:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1|on) return 0 ;; *) return 1 ;; esac
}
if is_enabled "${INSTALL_LOGGING_OPERATOR:-false}"; then
  if ! oc get pods -n openshift-logging -l name=cluster-logging-operator --no-headers 2>/dev/null | grep -q Running; then
    echo "=== Installing Logging + Loki operator ==="
    bash "$REPO_ROOT/config/operators/install-logging.sh" || echo "WARNING: Logging operator install failed (non-fatal)"
  else
    echo "Logging operator already installed"
  fi
fi

# Install Serverless operator if requested
if is_enabled "${INSTALL_SERVERLESS_OPERATOR:-false}"; then
  if ! oc get csv -n openshift-serverless --no-headers 2>/dev/null | grep -q Succeeded; then
    echo "=== Installing Serverless operator ==="
    bash "$REPO_ROOT/config/operators/install-serverless.sh" || echo "WARNING: Serverless operator install failed (non-fatal)"
  else
    echo "Serverless operator already installed"
  fi
fi

# Auto-run setup if upgrade-tests pipeline is missing.
# Maps PRE_UPGRADE vars to standard vars so setup installs the pre-upgrade operator.
if ! oc get pipeline upgrade-tests -n "$NS" &>/dev/null; then
  echo "=== Running setup-pipelines-ci.sh (using PRE_UPGRADE vars for initial install) ==="
  OPERATOR_VERSION="$PRE_UPGRADE_VERSION" \
  OPERATOR_ENVIRONMENT="${PRE_UPGRADE_OPERATOR_ENVIRONMENT:-prod}" \
  CATALOG_SOURCE="${PRE_UPGRADE_CATALOG_SOURCE:-redhat-operators}" \
  KONFLUX_INDEX_IMAGE="${PRE_UPGRADE_KONFLUX_INDEX_IMAGE:-}" \
  CHANNEL="$(resolve_channel "$PRE_UPGRADE_VERSION" "${PRE_UPGRADE_CHANNEL:-}")" \
    bash "$HACK_DIR/setup-pipelines-ci.sh" \
    || die "setup-pipelines-ci.sh failed"
fi
FW="$(printf '%s' "${TEST_FRAMEWORK:-gauge}" | tr '[:upper:]' '[:lower:]')"
SEND_SLACK_NOTIFICATION=$(normalize_bool "$(env_file_get SEND_SLACK_NOTIFICATION "$ENV_FILE")")
INSTALL_PIPELINES_OPERATOR=$(normalize_bool "${INSTALL_PIPELINES_OPERATOR:-true}")

PRE_UPGRADE_CHANNEL="$(resolve_channel "$PRE_UPGRADE_VERSION" "${PRE_UPGRADE_CHANNEL:-}")"
UPGRADE_CHANNEL="$(resolve_channel "$UPGRADE_VERSION" "${UPGRADE_CHANNEL:-}")"

parse_test_suites

TAGS="${TAGS:-$([ "$FW" = ginkgo ] && echo sanity || echo e2e)}"

# Build descriptive PipelineRun name: upgrade-tests-aro-1212-to-1222-on-419-
case "${INSTALLER,,}" in
  none|cluster-platforms|cluster-platform|cp) _installer_tag="cp-" ;;
  aws-ipi|aro|rosa) _installer_tag="${INSTALLER,,}-" ;;
  *) _installer_tag="" ;;
esac
_pre_short=$(echo "${PRE_UPGRADE_VERSION}" | sed 's/\.//g')
_upg_short=$(echo "${UPGRADE_VERSION}" | sed 's/\.//g')
_ocp_short=$(echo "${OPENSHIFT_VERSION:-ocp}" | sed 's/[^0-9]//g; s/\([0-9]\{2,3\}\).*/\1/')
[[ -z "$_ocp_short" ]] && _ocp_short="ocp"
PREFIX="upgrade-tests-${_installer_tag}${_pre_short}-to-${_upg_short}-on-${_ocp_short}-"

echo "=== Upgrade PipelineRun → ${NS} ==="
echo "    installer: ${INSTALLER}"
echo "    framework: ${FW}"
echo "    pre-upgrade: ${PRE_UPGRADE_VERSION} (${PRE_UPGRADE_OPERATOR_ENVIRONMENT:-prod}/${PRE_UPGRADE_CATALOG_SOURCE:-redhat-operators}) branch=${PRE_UPGRADE_GIT_RELEASE_TESTS_BRANCH:-${PRE_UPGRADE_GIT_RELEASE_TESTS_GINKGO_BRANCH:-}}"
echo "    upgrade:     ${UPGRADE_VERSION} (${UPGRADE_OPERATOR_ENVIRONMENT:-pre-stage}/${UPGRADE_CATALOG_SOURCE:-custom-operators}) branch=${GIT_RELEASE_TESTS_BRANCH:-${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}}"
echo "    suites: ${TEST_SUITE_ITEMS[*]}"

write_pipelinerun() {
  local pr pr_name
  pr="$(mktemp "${TMPDIR:-/tmp}/pipelinerun.XXXXXX")"
  trap 'rm -f "$pr"' RETURN

  cat > "$pr" <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: ${PREFIX}
spec:
  pipelineRef:
    name: upgrade-tests
  params:
    - name: INSTALLER
      value: "${INSTALLER}"
    - name: BASE_DOMAIN
      value: "${BASE_DOMAIN:-aws.ospqa.com}"
    - name: AWS_REGION
      value: "${AWS_REGION:-us-east-2}"
    - name: OPENSHIFT_VERSION
      value: "${OPENSHIFT_VERSION:-stable}"
    - name: KEEP_CLUSTER
      value: "${KEEP_CLUSTER:-false}"
    - name: CLUSTER_LIFETIME
      value: "${CLUSTER_LIFETIME:-6h}"
    - name: CLUSTER_NAME
      value: "${CLUSTER_NAME:-upgrd}"
    - name: ARCH
      value: "${ARCH:-linux/amd64}"
    - name: GIT_INFRA_BRANCH
      value: "${GIT_INFRA_BRANCH:-main}"
    - name: GIT_RELEASE_TESTS_URI
      value: "${GIT_RELEASE_TESTS_URI:-https://github.com/openshift-pipelines/release-tests.git}"
    - name: GIT_RELEASE_TESTS_BRANCH
      value: "${GIT_RELEASE_TESTS_BRANCH:-}"
    - name: PRE_UPGRADE_GIT_RELEASE_TESTS_BRANCH
      value: "${PRE_UPGRADE_GIT_RELEASE_TESTS_BRANCH:-}"
    - name: GIT_RELEASE_TESTS_GINKGO_URI
      value: "${GIT_RELEASE_TESTS_GINKGO_URI:-https://github.com/openshift-pipelines/release-tests-ginkgo.git}"
    - name: GIT_RELEASE_TESTS_GINKGO_BRANCH
      value: "${GIT_RELEASE_TESTS_GINKGO_BRANCH:-}"
    - name: PRE_UPGRADE_GIT_RELEASE_TESTS_GINKGO_BRANCH
      value: "${PRE_UPGRADE_GIT_RELEASE_TESTS_GINKGO_BRANCH:-}"
    - name: TEST_FRAMEWORK
      value: "${FW}"
    - name: IMAGE
      value: "${IMAGE:-quay.io/openshift-pipeline/ci:latest}"
    - name: TKN_DOWNLOAD_URL
      value: "${TKN_DOWNLOAD_URL:-}"
    - name: TAGS
      value: "${TAGS}"
    - name: PRE_UPGRADE_VERSION
      value: "${PRE_UPGRADE_VERSION}"
    - name: PRE_UPGRADE_OPERATOR_ENVIRONMENT
      value: "${PRE_UPGRADE_OPERATOR_ENVIRONMENT:-prod}"
    - name: PRE_UPGRADE_CATALOG_SOURCE
      value: "${PRE_UPGRADE_CATALOG_SOURCE:-redhat-operators}"
    - name: PRE_UPGRADE_KONFLUX_INDEX_IMAGE
      value: "${PRE_UPGRADE_KONFLUX_INDEX_IMAGE:-}"
    - name: PRE_UPGRADE_CHANNEL
      value: "${PRE_UPGRADE_CHANNEL}"
    - name: UPGRADE_VERSION
      value: "${UPGRADE_VERSION}"
    - name: UPGRADE_OPERATOR_ENVIRONMENT
      value: "${UPGRADE_OPERATOR_ENVIRONMENT:-pre-stage}"
    - name: UPGRADE_CATALOG_SOURCE
      value: "${UPGRADE_CATALOG_SOURCE:-custom-operators}"
    - name: UPGRADE_KONFLUX_INDEX_IMAGE
      value: "${UPGRADE_KONFLUX_INDEX_IMAGE:-}"
    - name: UPGRADE_CHANNEL
      value: "${UPGRADE_CHANNEL}"
    - name: INSTALL_PIPELINES_OPERATOR
      value: "${INSTALL_PIPELINES_OPERATOR}"
    - name: UNINSTALL_PIPELINES_OPERATOR
      value: "${UNINSTALL_PIPELINES_OPERATOR:-false}"
    - name: SEND_SLACK_NOTIFICATION
      value: "${SEND_SLACK_NOTIFICATION}"
    - name: TEST_SUITES
      value:
EOF

  for s in "${TEST_SUITE_ITEMS[@]}"; do
    printf '        - %s\n' "$s" >> "$pr"
  done

  cat >> "$pr" <<EOF
  timeouts:
    pipeline: 3h
  workspaces:
    - name: data
      volumeClaimTemplate:
        metadata:
          labels:
            app: release-tests-infra
            release-tests-infra/pvc-role: upgrade-tests-workspace
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: ${PIPELINE_WORKSPACE_SIZE:-5Gi}
EOF

  pr_name=$(oc create -f "$pr" -n "$NS" -o jsonpath='{.metadata.name}') &&
  echo "PipelineRun: pipelinerun.tekton.dev/${pr_name}"
}

write_pipelinerun
