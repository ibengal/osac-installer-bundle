#!/usr/bin/env bash
# Deploy OSAC to an existing OpenShift lab cluster using the upstream installer.
set +x
set -Eeuo pipefail
umask 077

# BEGIN INSTALLER TERMINAL OUTPUT
# Render only at the terminal boundary. The existing log writers receive plain
# output, and child installer helpers inherit the guard to avoid double colour.
# Keep this block self-contained so each script can be copied independently.
installer_colorize() {
    awk '
        BEGIN { esc = sprintf("%c", 27); reset = esc "[0m" }
        {
            style = ""
            if ($0 ~ /^(FAIL|MISSING|RESULT failed)([[:space:]]|$)/ ||
                $0 ~ /(^|[[:space:]])(Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull|Failed)([[:space:]]|$)/ ||
                $0 ~ /^Result: [1-9][0-9]* failure/)
                style = "1;31"
            else if ($0 ~ /^(WARN|WAIT|NEXT|DRY RUN)([[:space:]:]|$)/ ||
                     $0 ~ /^Result: 0 failure\(s\), [1-9][0-9]* warning/)
                style = "1;33"
            else if ($0 ~ /^(PASS|FIXED|CREATED|RESULT success)([[:space:]]|$)/ ||
                     $0 ~ /successfully rolled out|rolling update complete|roll out complete/ ||
                     $0 ~ /^Result: 0 failure\(s\), 0 warning/)
                style = "1;32"
            else if ($0 ~ /^STEP([[:space:]]|$)|^OSAC CONTAINER IMAGES|^OpenShift dev-scripts preflight|^[Uu]sage:|^NAME[[:space:]]/ ||
                     $0 ~ /^[A-Za-z][A-Za-z /()-]*:$/)
                style = "1;36"
            else if ($0 ~ /^[[:space:]]*Image: /)
                style = "1;35"
            else if ($0 ~ /^[[:space:]]*Image ID: /)
                style = "2"
            else if ($0 ~ /^(INFO|CONFIG|API|OCP|REVISION|REPOSITORY|IMAGES|LOG|STATUS|DETAILS|TARGET|DISK)([[:space:]]|$)/ ||
                     $0 ~ /^[A-Z][A-Z_0-9]*=/ || $0 ~ /^[[:space:]]*(Containers:|--[a-z])/)
                style = "36"
            if (style != "") printf "%s[%sm%s%s\n", esc, style, $0, reset
            else print
            fflush()
        }
    '
}
installer_setup_terminal() {
    local mode=${INSTALLER_COLOR:-auto} color_stdout=false color_stderr=false
    case "$mode" in
        auto|always|never) ;;
        *) printf 'FAIL INSTALLER_COLOR must be auto, always or never\n' >&2; return 2 ;;
    esac
    [[ ${INSTALLER_OUTPUT_ACTIVE:-} != 1 && -z ${NO_COLOR:-} && $mode != never ]] || return 0
    command -v awk >/dev/null || return 0
    if [[ $mode == always ]]; then
        color_stdout=true; color_stderr=true
    elif [[ ${TERM:-dumb} != dumb ]]; then
        [[ ! -t 1 ]] || color_stdout=true
        [[ ! -t 2 ]] || color_stderr=true
    fi
    if $color_stdout || $color_stderr; then
        export INSTALLER_OUTPUT_ACTIVE=1
        if $color_stdout; then exec > >(installer_colorize); fi
        if $color_stderr; then exec 2> >(installer_colorize >&2); fi
    fi
}
installer_setup_terminal || exit "$?"
# END INSTALLER TERMINAL OUTPUT


usage() {
    cat <<'HELP'
Usage: osac-install.sh [--config PATH] [--check-config] [options]
       osac-install.sh --help

Deploy OSAC on an existing, dedicated OpenShift cluster. Defaults to VMaaS QE.
Use tmux for long runs. Root is supported but not required: cluster-admin
credentials and write access to the checkout's parent/log directory are required.

Prerequisites:
  * Git access to https://github.com/osac-project/osac.git for a new checkout.
    The script clones main when OSAC_REPO does not exist. The destination
    defaults to the containing monorepo when run from osac-installer/scripts,
    otherwise ./osac-main beside this script. Existing checkouts fetch upstream
    and fast-forward before installation.
  * A working OpenShift 4.17+ cluster, ready nodes, DNS and outbound access
    to github.com, ghcr.io, quay.io and registry.redhat.io.
  * Explicit KUBECONFIG in this script's config or --kubeconfig PATH.
    The shell's KUBECONFIG and ~/.kube/config are deliberately not selected.
    With Ido's default dev-scripts layout, use:
      /root/dev-scripts/ocp/ostest/auth/kubeconfig
  * bash 4+, oc, helm 3, git, make, jq, python3, flock, timeout, tee (Linux).
    Install these tools before running; no package installer is invoked.
  * An AAP subscription manifest (license.zip) from the Red Hat Customer
    Portal: Subscriptions > Subscription Allocations > Export Manifest.
    Put license.zip and your Red Hat pull-secret.json in osac-inputs beside
    this script (normally /root/osac-inputs/). Use directory mode 700 and
    file mode 600. Override sources with --license and --pull-secret.
    The credentials stage validates both files and copies them with mode 600
    into <repo>/osac-installer/values/<profile>/, after checking Git ignores
    those destinations. Existing copies are replaced from the supplied inputs.
  * The cluster must already have its OpenShift registry pull secret.
    The pull secret is consumed by the OCP installer; this wrapper stages
    a copy in the profile but does not replace the cluster pull secret.
    CI_TOKEN is needed by the OCP installer, not by this OSAC wrapper.
  * For the default VMaaS profile: hardware virtualization exposed to OCP
    nodes and unused disks for LVMS. In ocp-install.conf enable
    VM_EXTRADISKS=true BEFORE creating the OCP VMs. Choose disk capacity for
    AAP, Kafka and VM images; the upstream Kafka profile requests 100Gi per
    replica. Merely attaching a small extra disk is not sufficient sizing.
    LVMS consumes unused disks. Use this on a dedicated lab cluster.

Configuration:
  osac-install.conf beside this script is loaded automatically when present.
  --config selects another file (must exist). Only literal KEY=value or
  export KEY=value assignments are accepted; optional single/double quotes
  and trailing comments are supported. No shell expansion or commands run.
  Precedence: CLI options > config file > defaults.
  Additional config keys: INPUTS_DIR, STATE_DIR, STEP_TIMEOUT (7200 seconds),
  CLEANUP_TIMEOUT (600 seconds per deletion), CHAIN_LOG_DIR.
  All paths are absolute
  and must contain only letters, digits, underscore, dot, slash or hyphen
  because the upstream Makefile interpolates paths into shell recipes.
  Use full infra/instance YAML files to customize chart settings and images.
  These files replace the corresponding profile file, not an extra overlay.
  Image versions follow the selected values files and chart defaults. Updating
  Git does not change pinned image tags; main/latest can move independently.
  To override an image, copy the profile's full instance.yaml, edit its image
  setting (for example ui.images.ui), then select it with --instance-values.
  The wrapper does not build images or force restarts to refresh mutable tags.
  OSAC_REPO_REF selects the upstream branch/tag to fetch (default: main).
  New checkouts are shallow clones. Existing checkouts must have no tracked
  changes; they fetch the selected ref and merge it with --ff-only. The final
  checkout commit must exactly match the fetched upstream commit. Local commits
  ahead of upstream and divergent histories stop the run for manual resolution;
  no reset, forced checkout or rebase is done.
  A destination that exists but is not a Git checkout is rejected untouched.

Options:
  --config PATH           configuration file
  --check-config          print resolved settings only; no logs or API calls
  --preflight             prepare checkout/inputs and validate before deployment
  --post-config-only      configure UI OIDC after OSAC is already deployed
  --verify-only           inspect installed OSAC; no clone/license/Make required
  --check-inputs          validate local input files only (used by the chain)
  --repo PATH             OSAC checkout/clone destination
  --repo-ref NAME         upstream branch/tag to fetch (default: main)
  --kubeconfig PATH       target cluster-admin kubeconfig (required)
  --profile NAME          vmaas-ci (default), caas-ci, bmaas-ci, full-ci
  --namespace NAME        OSAC namespace (default: osac)
  --license PATH          source AAP subscription manifest ZIP
  --pull-secret PATH      source Red Hat registry pull-secret JSON
  --infra-values PATH     full infrastructure values YAML
  --instance-values PATH  full OSAC instance values YAML
  --log-dir PATH          default: /tmp/astra-osac-install-logs
  --verify-timeout N      rollout timeout in seconds (default: 600)
  --from STAGE            resume recorded revision; credentials/preflight still run
  --through STAGE         stop after a stage
  -h, --help              show this help without reading config or changing files

Stages (default: all, in this order):
  repository    clone if absent; otherwise fetch upstream and fast-forward
  credentials   validate user inputs; copy into the selected values directory
  preflight     check tools, input files, API access, cluster-admin and readiness
  dependencies  make helm-deps
  infra         make install-infra (osac-deps, then osac-infra)
  osac          make install-osac (platform, AAP bootstrap and Helm hooks)
  post-config   set Keycloak UI redirect/origin from the deployed OSAC Route
  verify        check Helm releases/rollouts, print/save images, display routes

Quick start (after OCP installation):
  1. Put license.zip and pull-secret.json in /root/osac-inputs/ (see above).
  2. Pass --kubeconfig /absolute/path or set KUBECONFIG in optional config.
     No config is required; PROFILE defaults to vmaas-ci.
  3. Preview settings; no clone, copying, cluster calls or installation:
  /root/osac-install.sh --config /root/osac-install.conf --check-config
  4. Clone/update the repo, copy credentials and check prerequisites:
  /root/osac-install.sh --config /root/osac-install.conf --through preflight
  5. Install infrastructure and OSAC, configure UI login, then verify:
  /root/osac-install.sh --config /root/osac-install.conf
  6. Run only the post-deployment UI login configuration on an existing install:
  /root/osac-install.sh --config /root/osac-install.conf --post-config-only
  7. Recheck an existing deployment without reinstalling:
  /root/osac-install.sh --config /root/osac-install.conf --verify-only
  8. After fixing a failure, resume at the appropriate stage, for example:
  /root/osac-install.sh --config /root/osac-install.conf --from osac

Use your own config path consistently. For long installations, run inside tmux.

Verification checks and output:
  * osac-deps, osac-infra and osac Helm releases must report deployed.
  * At least one Deployment or StatefulSet must exist in the OSAC namespace;
    every such workload and DaemonSet must finish its rollout (600 seconds each
    by default). OSAC Deployments/StatefulSets must not be paused or scaled to zero.
    Owned infrastructure workloads and current hook jobs are checked too.
    Routes must be admitted; retained failed attempts of successful jobs are
    historical output, not proof that the current job failed.
  * Prints image references (including tags) and observed runtime image IDs,
    grouped by image/ID with container names. Also saves per-pod images.tsv.
    Includes init containers and retained job pods in the OSAC namespace.
    An unavailable image ID means the runtime has not reported one.
  * The post-config stage reconciles the Keycloak osac-ui client to the actual
    admitted UI Route. It uses the existing keycloak-admin-credentials Secret
    and ca-bundle; no separate admin password is requested or logged.
  * Displays pod status and routes for inspection. It does not perform browser
    login, API workflow or VM provisioning tests. Image output does not certify
    compatibility or compare deployed tags with the latest registry images.
  * Failed checks return a nonzero exit code; logs/status identify the stage.

Repository preparation writes the local checkout; it does not contact OCP.
--through repository needs Git, Python 3 and basic Linux tools (no kubeconfig/license).
Preflight is read-only against the cluster; it writes only local logs/status.
--through credentials prepares the files without needing cluster access.
Fresh installations fetch upstream; resumes require the recorded revision
and cluster identity. Rebuilt OCP requires a fresh full run, even if its API
hostname and kubeconfig path are unchanged. Resume state defaults to
.astra-osac-state beside this script, separate from the original installer.
--from osac requires both infrastructure Helm releases to be deployed.
Preflight waits up to VERIFY_TIMEOUT for healthy OCP operators and schedulable
Ready nodes without resource pressure. Terminating installation namespaces
may finish cleanup within CLEANUP_TIMEOUT; finalizers are never stripped here.
Pending/uninstalling/unknown Helm releases stop before deployment. Inspect
their history and complete/recover the prior operation; failed, superseded,
or uninstalled releases can be retried through the ordinary Helm upgrade.
No automatic Helm rollback or
release-secret deletion is performed. An installer rerun upgrades existing
releases; it does not erase test data or replace teardown for weekly rebuilds.
Failures after cluster access save bounded diagnostics.txt summaries in the
run directory while preserving the original exit status.
Credential preparation and preflight run again on resumes.
--verify-only (also --from verify) needs kubeconfig, oc, Helm, jq, Python 3
and basic Linux tools. It needs no checkout, license, Git or Make.
--post-config-only requires a deployed osac Helm release, admitted UI and
Keycloak routes, the Keycloak admin Secret, and the OSAC ca-bundle. It skips
repository updates, credential staging, chart dependencies and Helm installs.
Normal installs run this configuration automatically after the OSAC stage.
Preflight runs before deployment; cluster health checks also run before
verification and --post-config-only. No cluster creation,
teardown, credential download, snapshot repair or CaaS agent VM creation is
performed. Install targets use Helm upgrade --install; inspect failures
before retrying. Infrastructure settings are cluster-wide. CI profiles use
test credentials and ephemeral services and are not production profiles.

Each run has a private directory under LOG_DIR with run.log and status.
The verify stage prints an image summary and writes images.tsv with per-pod
image references and image IDs. Both normal installation and --from verify
produce these outputs. With the default LOG_DIR, inspect the latest results:
  cat /tmp/astra-osac-install-logs/latest/status
  cat /tmp/astra-osac-install-logs/latest/images.tsv
  less /tmp/astra-osac-install-logs/latest/run.log
latest is a symlink to the latest run. Logs can include sensitive output from
upstream tools: keep them private. /tmp may be cleared on reboot. Operation locks
prevent concurrent OSAC operations against a cluster from this host, regardless
of LOG_DIR. Use one automation host per cluster.
Terminal colours:
  Cyan: stages/information; green: passed checks; yellow: warnings/waiting;
  red: failures; purple: image names; dim text: runtime image IDs.
  Colours are automatic on terminals and disabled for redirected output.
  Set INSTALLER_COLOR=always to force colours (for example in a captured demo),
  INSTALLER_COLOR=never to disable them, or NO_COLOR=1 to disable them globally.
  NO_COLOR takes precedence. Saved logs, status and image reports stay plain.
HELP
}

# Bound each external stage and forward cancellation to its whole process tree.
active_pid=
run_bounded() {
    python3 - "${step_timeout:-7200}" "$@" <<'RUNPY' &
import os, signal, subprocess, sys, time
child = None
code = 1
def interrupted(signum, frame):
    raise InterruptedError(signum)
signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
try:
    child = subprocess.Popen(sys.argv[2:], start_new_session=True, stdin=subprocess.DEVNULL)
    code = child.wait(timeout=int(sys.argv[1]))
except subprocess.TimeoutExpired:
    print('FAIL Stage exceeded its configured timeout', flush=True)
    code = 124
except InterruptedError as error:
    code = 128 + error.args[0]
finally:
    # A Make/Helm parent may exit before its grandchildren. Cancel the entire
    # process group before releasing locks, even when that parent has exited.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    if child is not None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                child.poll()  # reap the leader while checking the whole group
                try:
                    os.killpg(child.pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()

sys.exit(code if code >= 0 else 128 - code)
RUNPY
    active_pid=$!
    local code=0
    wait "$active_pid" || code=$?
    active_pid=
    return "$code"
}
stop_stage() {
    trap '' INT TERM
    if [[ -n ${active_pid:-} ]]; then
        kill -TERM "$active_pid" 2>/dev/null || true
        wait "$active_pid" 2>/dev/null || true
    fi
    exit "$1"
}

die() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
for arg in "$@"; do
    case "$arg" in -h|--help) usage; exit 0 ;; esac
done
((BASH_VERSINFO[0] >= 4)) || die 'bash 4 or later is required'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
default_repo="$script_dir/osac-main"
if [[ -f "$script_dir/../Makefile" && -f "$script_dir/lib.sh" ]]; then
    default_repo=$(cd -- "$script_dir/../.." && pwd)
fi
declare -A settings=(
    [OSAC_REPO]="$default_repo" [KUBECONFIG]='' [PROFILE]=vmaas-ci
    [OSAC_REPO_REF]=main
    [NAMESPACE]=osac [AAP_LICENSE_FILE]='' [PULL_SECRET_FILE]=''
    [INFRA_VALUES]='' [INSTANCE_VALUES]=''
    [LOG_DIR]=/tmp/astra-osac-install-logs [VERIFY_TIMEOUT]=600
    [INPUTS_DIR]="$script_dir/osac-inputs" [STEP_TIMEOUT]=7200 [CLEANUP_TIMEOUT]=600
    [STATE_DIR]="$script_dir/.astra-osac-state" [CHAIN_LOG_DIR]=/tmp/osac-install-chain-logs
)
declare -A overrides=()
config="$script_dir/osac-install.conf"
explicit_config=false
check_config=false
config_json=false
check_inputs=false
post_config_only=false
first=repository
last=verify
while (($#)); do
    case "$1" in
        --check-config) check_config=true; shift; continue ;;
        --config-json) check_config=true; config_json=true; shift; continue ;;
        --check-inputs) check_inputs=true; shift; continue ;;
        --post-config-only) post_config_only=true; shift; continue ;;
        --verify-only) first=verify; shift; continue ;;
        --preflight) last=preflight; shift; continue ;;
        --config|--repo|--repo-ref|--kubeconfig|--profile|--namespace|--license|--pull-secret|--infra-values|--instance-values|--log-dir|--verify-timeout|--from|--through)
            if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
                die "Missing value for $1"
            fi
            case "$1" in
                --config) config=$2; explicit_config=true ;;
                --repo) overrides[OSAC_REPO]=$2 ;;
                --repo-ref) overrides[OSAC_REPO_REF]=$2 ;;
                --kubeconfig) overrides[KUBECONFIG]=$2 ;;
                --profile) overrides[PROFILE]=$2 ;;
                --namespace) overrides[NAMESPACE]=$2 ;;
                --license) overrides[AAP_LICENSE_FILE]=$2 ;;
                --pull-secret) overrides[PULL_SECRET_FILE]=$2 ;;
                --infra-values) overrides[INFRA_VALUES]=$2 ;;
                --instance-values) overrides[INSTANCE_VALUES]=$2 ;;
                --log-dir) overrides[LOG_DIR]=$2 ;;
                --verify-timeout) overrides[VERIFY_TIMEOUT]=$2 ;;
                --from) first=$2 ;;
                --through) last=$2 ;;
            esac
            shift 2 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done
if $post_config_only; then
    [[ $first == repository && $last == verify && $check_inputs == false ]] || \
        die '--post-config-only cannot be combined with --from, --through, --preflight, --verify-only or --check-inputs'
    first=post-config
    last=post-config
fi
trim() {
    trimmed=${1#"${1%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
}
if [[ -f "$config" ]]; then
    line_number=0
    assignment='^(export[[:space:]]+)?([A-Z_][A-Z_0-9]*)[[:space:]]*=(.*)$'
    quoted_single="^'([^']*)'[[:space:]]*(#.*)?$"
    quoted_double='^"([^"\\]*)"[[:space:]]*(#.*)?$'
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        trim "$line"; line=$trimmed
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ $assignment ]] || die "Invalid assignment at $config:$line_number"
        key=${BASH_REMATCH[2]}; value=${BASH_REMATCH[3]}
        case "$key" in
            OSAC_REPO|OSAC_REPO_REF|KUBECONFIG|PROFILE|NAMESPACE|AAP_LICENSE_FILE|PULL_SECRET_FILE|INFRA_VALUES|INSTANCE_VALUES|LOG_DIR|VERIFY_TIMEOUT|INPUTS_DIR|STEP_TIMEOUT|CLEANUP_TIMEOUT|STATE_DIR|CHAIN_LOG_DIR) ;;
            *) die "Unknown setting at $config:$line_number" ;;
        esac
        trim "$value"; value=$trimmed
        if [[ "$value" =~ $quoted_single || "$value" =~ $quoted_double ]]; then
            value=${BASH_REMATCH[1]}
        else
            value=${value%%[[:space:]]#*}
            trim "$value"; value=$trimmed
        fi
        [[ "$value" =~ ^[a-zA-Z0-9_./-]*$ ]] || die "Nonliteral or unsupported value at $config:$line_number"
        settings[$key]=$value
    done < "$config"
elif $explicit_config; then
    die "Config file not found: $config"
fi
for key in "${!overrides[@]}"; do settings[$key]=${overrides[$key]}; done
repo=${settings[OSAC_REPO]}
repo_ref=${settings[OSAC_REPO_REF]}
[[ "$repo_ref" =~ ^[a-zA-Z0-9][a-zA-Z0-9_./-]*$ ]] || die 'OSAC_REPO_REF must be a branch or tag name'
installer="$repo/osac-installer"
profile=${settings[PROFILE]}
namespace=${settings[NAMESPACE]}
[[ "$profile" =~ ^(vmaas-ci|caas-ci|bmaas-ci|full-ci)$ ]] || die 'Unsupported PROFILE'
[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#namespace} -le 63 ]] || die 'Invalid NAMESPACE'
timeout=${settings[VERIFY_TIMEOUT]}
[[ "$timeout" =~ ^[1-9][0-9]{0,4}$ ]] || die 'VERIFY_TIMEOUT must be 1..99999 seconds'
settings[AAP_LICENSE_FILE]=${settings[AAP_LICENSE_FILE]:-"${settings[INPUTS_DIR]}/license.zip"}
settings[PULL_SECRET_FILE]=${settings[PULL_SECRET_FILE]:-"${settings[INPUTS_DIR]}/pull-secret.json"}
prepared_license="$installer/values/$profile/license.zip"
settings[INFRA_VALUES]=${settings[INFRA_VALUES]:-"$installer/values/$profile/infra.yaml"}
settings[INSTANCE_VALUES]=${settings[INSTANCE_VALUES]:-"$installer/values/$profile/instance.yaml"}
for key in OSAC_REPO KUBECONFIG AAP_LICENSE_FILE PULL_SECRET_FILE INFRA_VALUES INSTANCE_VALUES LOG_DIR INPUTS_DIR STATE_DIR CHAIN_LOG_DIR; do
    value=${settings[$key]}
    [[ "$key" == KUBECONFIG && -z "$value" ]] && continue
    [[ "$value" =~ ^/[a-zA-Z0-9_./-]+$ ]] || die "$key must be an absolute path without spaces or shell metacharacters"
done
[[ "$namespace" != default && "$namespace" != kube-* && "$namespace" != openshift* && "$namespace" != osac-infra && "$namespace" != osac-deps ]] || die 'Protected namespace cannot be used for OSAC'
step_timeout=${settings[STEP_TIMEOUT]}
for key in STEP_TIMEOUT CLEANUP_TIMEOUT; do
    [[ ${settings[$key]} =~ ^[1-9][0-9]{0,4}$ ]] || die "$key must be 1..99999 seconds"
done
stages=(repository credentials preflight dependencies infra osac post-config verify)
start=-1; stop=-1
for i in "${!stages[@]}"; do
    [[ "${stages[$i]}" != "$first" ]] || start=$i
    [[ "${stages[$i]}" != "$last" ]] || stop=$i
done
((start >= 0 && stop >= start)) || die 'Invalid stage range (see --help)'
show_config() {
    for key in OSAC_REPO OSAC_REPO_REF KUBECONFIG PROFILE NAMESPACE AAP_LICENSE_FILE PULL_SECRET_FILE INFRA_VALUES INSTANCE_VALUES LOG_DIR VERIFY_TIMEOUT INPUTS_DIR STATE_DIR STEP_TIMEOUT CLEANUP_TIMEOUT CHAIN_LOG_DIR; do
        printf '%s=%s\n' "$key" "${settings[$key]}"
    done
    printf 'STAGES=%s..%s\n' "$first" "$last"
}
if $check_config; then
    if $config_json; then
        show_config | python3 -c 'import json,sys; print(json.dumps(dict(line.rstrip("\n").split("=",1) for line in sys.stdin)))'
    else show_config; fi
    exit 0
fi
if $check_inputs; then
    command -v python3 >/dev/null || die 'Missing tool: python3'
    python3 - "${settings[AAP_LICENSE_FILE]}" "${settings[PULL_SECRET_FILE]}" <<'INPUTPY'
import json, sys, zipfile
from pathlib import Path
try:
    with zipfile.ZipFile(sys.argv[1]) as archive:
        if not archive.namelist() or archive.testzip() is not None:
            raise ValueError()
    data = json.loads(Path(sys.argv[2]).read_bytes())
    if not isinstance(data, dict) or not isinstance(data.get('auths'), dict) or not data['auths']:
        raise ValueError()
except (OSError, ValueError, RuntimeError, zipfile.BadZipFile):
    sys.exit('FAIL Supply a readable AAP license ZIP and pull-secret JSON with nonempty auths')
print('PASS Local OSAC input files')
INPUTPY
    exit 0
fi

if ((stop >= 2)); then
    [[ -n ${settings[KUBECONFIG]} && -s ${settings[KUBECONFIG]} && -r ${settings[KUBECONFIG]} ]] || die 'Missing explicit cluster kubeconfig: set KUBECONFIG in config or use --kubeconfig PATH'
fi
for tool in flock python3 timeout; do
    command -v "$tool" >/dev/null || die "Missing tool: $tool"
done
command -v tee >/dev/null || die 'Missing tool: tee'
log_dir=${settings[LOG_DIR]}
[[ ! -L "$log_dir" ]] || die 'LOG_DIR must not be a symlink'
mkdir -p -- "$log_dir"
[[ -O "$log_dir" ]] || die 'LOG_DIR must be owned by the current user'
chmod 700 "$log_dir"
[[ ! -L "$log_dir/.lock" ]] || die 'Log lock must not be a symlink'
lock_root="/tmp/osac-operation-locks-$EUID"
if ! mkdir -m 700 "$lock_root" 2>/dev/null; then
    [[ -d $lock_root && ! -L $lock_root && -O $lock_root && $(stat -c %a "$lock_root") == 700 ]] || die 'Unsafe operation lock directory'
fi
if [[ $first != verify ]] && ! $post_config_only; then
    repo_key=$(printf '%s' "$repo" | sha256sum); repo_key=${repo_key%% *}
    [[ ! -L "$lock_root/repo-$repo_key.lock" ]] || die 'Unsafe checkout lock'
    exec 9>"$lock_root/repo-$repo_key.lock"
    flock -n 9 || die 'Another installer is using this checkout'
fi
run_dir=$(mktemp -d "$log_dir/run-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
ln -sfnT -- "$run_dir" "$log_dir/latest"
    stage=$first
started=$(date -u +%FT%TZ)
write_status() {
    printf 'result=%s\nstage=%s\nexit_code=%s\nstarted_at=%s\nupdated_at=%s\n' \
        "$1" "$stage" "$2" "$started" "$(date -u +%FT%TZ)" > "$run_dir/status"
}
finish() {
    local result=$? outcome=failed
    trap - EXIT
    trap '' INT TERM
    set +e
    if [[ ${ownership_validated:-false} == true && ( $stage == infra || $stage == osac ) && $result != 0 ]]; then
        record_ownership || printf 'WARN Could not record all partial-install ownership; teardown will check it\n'
    fi
    [[ "$result" != 0 ]] || outcome=success
    write_status "$outcome" "$result"
    if ((result != 0)) && [[ ${cluster_inspected:-false} == true ]]; then
        collect_diagnostics
    fi
    printf '\nRESULT %s at %s (exit %s)\nLOG %s/run.log\n' "$outcome" "$stage" "$result" "$run_dir"
    if ((result != 0)); then
        if [[ $stage == infra || $stage == osac || $stage == dependencies ]]; then
            printf 'NEXT Inspect diagnostics, fix the cause, then use --from %s with the same settings and cluster.\n' "$stage"
        elif [[ $stage == post-config ]]; then
            printf 'NEXT Fix the Keycloak/Route prerequisite, then rerun --post-config-only with the same kubeconfig.\n'
        elif [[ $stage == verify ]]; then
            printf 'NEXT Fix the health check and run --verify-only.\n'
        else
            printf 'NEXT Fix the reported prerequisite and rerun the same command; use a full run after rebuilding OCP.\n'
        fi
    fi
    exit "$result"
}
trap finish EXIT
trap 'stop_stage 130' INT
trap 'stop_stage 143' TERM
exec > >(tee "$run_dir/run.log") 2>&1
write_status running 0
show_config

collect_diagnostics() {
    # Summaries only: don't dump Secrets, Helm values/manifests or application logs.
    # Variables are expanded by the child shell, not this shell.
    # shellcheck disable=SC2016
    timeout --kill-after=2s 45s bash -c '
        for ns in "$1" osac-infra osac-deps; do
            printf "\nNAMESPACE %s\n" "$ns"
            oc --request-timeout=5s -n "$ns" get pods,jobs,pvc,deployments,statefulsets,daemonsets
        done
        for release in osac-deps osac-infra osac; do
            ns=$release; [[ $release != osac ]] || ns=$1
            printf "\nHELM %s\n" "$release"
            timeout --kill-after=1s 5s helm history "$release" -n "$ns" --max 5
        done
        oc --request-timeout=5s get clusteroperators
    ' bash "$namespace" >"$run_dir/diagnostics.txt" 2>&1 || true
    printf 'DETAILS %s/diagnostics.txt\n' "$run_dir"
}

# Helm inspection has no API request timeout flag in Helm 3.
helm_read() { timeout --kill-after=2s 30s helm "$@"; }

repository() {
    local actual_root
    command -v git >/dev/null || die 'Missing tool: git'
    if [[ -e "$repo" || -L "$repo" ]]; then
        [[ -d "$repo" && ( -d "$repo/.git" || -f "$repo/.git" ) ]] || die "OSAC_REPO exists but is not a Git checkout: $repo; choose another destination"
        actual_root=$(git -C "$repo" rev-parse --show-toplevel)
        [[ "$actual_root" == "$(cd -- "$repo" && pwd -P)" ]] || die 'OSAC_REPO must be the root of a Git checkout'
        [[ -s "$installer/Makefile" && -s "$installer/scripts/lib.sh" ]] || die 'Checkout does not contain the OSAC installer'
        [[ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ]] || die 'Checkout has tracked changes; commit or stash them before installing'
        printf 'REPOSITORY fetching upstream %s into %s\n' "$repo_ref" "$repo"
        run_bounded env GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch --no-tags -- https://github.com/osac-project/osac.git "$repo_ref"
        if ! git -C "$repo" merge --ff-only FETCH_HEAD; then
            die 'Cannot fast-forward the checkout; resolve divergent history or obstructing files before installing'
        fi
        [[ $(git -C "$repo" rev-parse --verify HEAD) == "$(git -C "$repo" rev-parse --verify FETCH_HEAD)" ]] || \
            die 'Checkout has local commits ahead of upstream; select a clean checkout to install the exact upstream revision'
    else
        printf 'REPOSITORY cloning upstream %s into %s\n' "$repo_ref" "$repo"
        run_bounded env GIT_TERMINAL_PROMPT=0 git clone --depth 1 --single-branch --branch "$repo_ref" -- \
            https://github.com/osac-project/osac.git "$repo"
    fi
    actual_root=$(git -C "$repo" rev-parse --show-toplevel)
    [[ "$actual_root" == "$(cd -- "$repo" && pwd -P)" ]] || die 'OSAC_REPO must be the root of a Git checkout'
    [[ -s "$installer/Makefile" && -s "$installer/scripts/lib.sh" ]] || die 'Checkout does not contain the OSAC installer'
    printf 'REVISION %s\n' "$(git -C "$repo" rev-parse --verify HEAD)"
}

credentials() {
    local name destination
    command -v python3 >/dev/null || die 'Missing tool: python3'
    for name in license.zip pull-secret.json; do
        destination="osac-installer/values/$profile/$name"
        if git -C "$repo" ls-files --error-unmatch -- "$destination" >/dev/null 2>&1; then
            die "Credential destination is tracked by Git: $destination"
        fi
        git -C "$repo" check-ignore -q -- "$destination" || die "Credential destination must be gitignored: $destination"
    done
    python3 - "${settings[AAP_LICENSE_FILE]}" "${settings[PULL_SECRET_FILE]}" "$repo" "$profile" <<'PY'
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import zipfile

try:
    license_data = Path(sys.argv[1]).read_bytes()
    pull_data = Path(sys.argv[2]).read_bytes()
    with zipfile.ZipFile(io.BytesIO(license_data)) as archive:
        if not archive.namelist() or archive.testzip() is not None:
            raise ValueError('invalid manifest archive')
    pull = json.loads(pull_data)
    if not isinstance(pull, dict) or not isinstance(pull.get('auths'), dict) or not pull['auths']:
        raise ValueError('missing registry auths')
    directory = Path(sys.argv[3]).resolve() / 'osac-installer' / 'values' / sys.argv[4]
    if not directory.is_dir() or directory.resolve() != directory:
        raise ValueError('missing or symlinked values directory')
    for name in ('license.zip', 'pull-secret.json'):
        if (directory / name).is_symlink():
            raise ValueError('symlinked credential destination')
    # Validate both inputs before replacing either destination. Never print data.
    for name, data in [('license.zip', license_data), ('pull-secret.json', pull_data)]:
        fd, temporary = tempfile.mkstemp(prefix='.osac-input-', dir=directory)
        try:
            with os.fdopen(fd, 'wb') as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(data)
            os.replace(temporary, directory / name)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
except (OSError, ValueError, RuntimeError, zipfile.BadZipFile):
    sys.exit('FAIL credential preparation: supply a readable, valid AAP ZIP and pull-secret JSON with nonempty auths; destinations must be regular files in the profile directory')
PY
    printf 'PASS credentials prepared in %s/values/%s (mode 600)\n' "$installer" "$profile"
}

cluster_preflight() {
    local state server cluster_key tool deadline reason
    for tool in oc helm jq python3; do
        command -v "$tool" >/dev/null || die "Missing inspection tool: $tool"
    done
    [[ -n ${settings[KUBECONFIG]} && -s ${settings[KUBECONFIG]} && -r ${settings[KUBECONFIG]} ]] || die 'Missing explicit cluster kubeconfig: set KUBECONFIG in config or use --kubeconfig PATH'
    export KUBECONFIG=${settings[KUBECONFIG]}
    [[ -z "${OC_IMPERSONATE:-}" ]] || die 'Unset OC_IMPERSONATE'
    unset HELM_KUBECONTEXT HELM_KUBEAPISERVER HELM_KUBETOKEN HELM_KUBEASUSER HELM_KUBEASGROUPS
    unset HELM_KUBECAFILE HELM_KUBETLS_SERVER_NAME HELM_KUBEINSECURE_SKIP_TLS_VERIFY
    [[ -z ${HELM_DRIVER:-} || ${HELM_DRIVER:-} == secret || ${HELM_DRIVER:-} == secrets ]] || die 'Unset HELM_DRIVER; this installer uses standard Helm Secret storage'
    server=$(oc --request-timeout=20s whoami --show-server)
    printf 'API %s\n' "$server"
    cluster_key=$(printf '%s' "${server%/}" | sha256sum); cluster_key=${cluster_key%% *}
    [[ ! -L "$lock_root/cluster-$cluster_key.lock" ]] || die 'Unsafe cluster lock'
    exec 8>"$lock_root/cluster-$cluster_key.lock"
    flock -n 8 || die 'Another OSAC install or teardown targets this cluster from this host'
    [[ "$(oc --request-timeout=20s auth can-i '*' '*' --all-namespaces)" == yes ]] || die 'Cluster-admin access is required'
    cluster_inspected=true
    deadline=$((SECONDS + timeout))
    while true; do
        if reason=$(cluster_health); then break; fi
        printf 'WAIT %s\n' "$reason"
        ((SECONDS < deadline)) || die "Cluster readiness did not recover within ${timeout}s: $reason"
        sleep 1
    done
    state=$(oc --request-timeout=20s get clusterversion version -o json)
    printf 'OCP %s\n' "$(jq -r '.status.desired.version' <<< "$state")"
    if [[ $first != verify && $post_config_only == false ]]; then
        local uid identity identity_file
        uid=$(oc --request-timeout=20s get namespace kube-system -o jsonpath='{.metadata.uid}')
        [[ -n $uid ]] || die 'Cannot identify the target cluster'
        identity=$(printf '%s\n%s\n' "$server" "$uid")
        if ((start > 0)); then
            [[ -r $state_file.cluster && $(cat "$state_file.cluster") == "$identity" ]] || die 'Resume cluster identity differs or was not recorded; use a fresh full run after rebuilding OCP'
        else
            identity_file=$(mktemp "${state_file}.cluster-XXXXXX")
            printf '%s\n' "$identity" >"$identity_file"
            mv -f -- "$identity_file" "$state_file.cluster"
        fi
    fi
    printf '\nPASS cluster access and readiness\n'
}
cluster_health() {
    local state
    state=$(oc --request-timeout=20s get clusterversion version -o json) || { printf 'Cannot read OpenShift version'; return 1; }
    jq -e '.status.desired.version | capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)") | (.major|tonumber) > 4 or ((.major|tonumber) == 4 and (.minor|tonumber) >= 17)' <<< "$state" >/dev/null || { printf 'OpenShift 4.17+ is required'; return 1; }
    jq -e '.status.conditions | any(.type == "Available" and .status == "True") and all(.[]; (.type != "Failing" and .type != "Progressing") or .status == "False")' <<< "$state" >/dev/null || { printf 'OpenShift is unavailable, failing or updating'; return 1; }
    state=$(oc --request-timeout=20s get clusteroperators -o json) || { printf 'Cannot read cluster operators'; return 1; }
    jq -e '.items | length > 0 and all(.[]; .status.conditions | any(.type == "Available" and .status == "True") and any(.type == "Degraded" and .status == "False") and any(.type == "Progressing" and .status == "False"))' <<< "$state" >/dev/null || { printf 'OpenShift operators are unavailable, degraded or progressing'; return 1; }
    state=$(oc --request-timeout=20s get nodes -o json) || { printf 'Cannot read nodes'; return 1; }
    jq -e '.items | length > 0 and all(.[]; (.metadata.deletionTimestamp == null) and (.spec.unschedulable != true) and any(.status.conditions[]; .type == "Ready" and .status == "True") and all(.status.conditions[]; (.type != "DiskPressure" and .type != "MemoryPressure" and .type != "PIDPressure") or .status == "False"))' <<< "$state" >/dev/null || { printf 'Nodes must be Ready, schedulable and free of resource pressure'; return 1; }
    oc --request-timeout=20s get --raw=/readyz >/dev/null || { printf 'API readiness check failed'; return 1; }
}

deployment_state_preflight() {
    local inventory ns release release_state
    inventory=$(oc --request-timeout=20s get namespace -o json)
    jq -e '.items | type == "array"' <<< "$inventory" >/dev/null || die 'Invalid namespace inventory; cannot check cleanup state'
    jq -e --arg target "$namespace" 'all(.items[] | select(.metadata.name == $target or .metadata.name == "osac-infra" or .metadata.name == "osac-deps"); (.metadata.annotations["osac.openshift.io/installer-namespace"] // $target) == $target)' <<< "$inventory" >/dev/null || die 'Installation namespaces are marked as owned by another OSAC instance; refusing to overwrite ownership'
    # Check before upstream make: its namespace helper may strip finalizers on
    # timeout. Let ordinary deletion finish, then fail with evidence if stuck.
    for ns in "$namespace" osac-deps osac-infra ansible-aap cert-manager-operator cert-manager openshift-storage metallb-system multicluster-engine openshift-cnv osac-kafka keycloak; do
        if jq -e --arg ns "$ns" 'any(.items[]; .metadata.name == $ns and (.metadata.deletionTimestamp != null or .status.phase == "Terminating"))' <<< "$inventory" >/dev/null; then
            printf 'WAIT Namespace %s is terminating; allowing cleanup to finish\n' "$ns"
            run_bounded oc wait --for=delete "namespace/$ns" --timeout="${settings[CLEANUP_TIMEOUT]}s" || die "Namespace $ns is still terminating or cleanup could not be checked; finish teardown before installing (finalizers preserved)"
        fi
    done
    for release in osac-deps osac-infra osac; do
        ns=$release; [[ $release != osac ]] || ns=$namespace
        inventory=$(helm_read list --namespace "$ns" --all --filter "^$release$" -o json) || die "Cannot inspect Helm release $release; refusing to assume it is absent"
        release_state=$(jq -er 'if type != "array" or length > 1 then error("invalid release inventory") elif length == 0 then "absent" else .[0].status end' <<< "$inventory") || die "Invalid Helm inventory for $release"
        printf 'INFO Helm %s: %s\n' "$release" "$release_state"
        case "$release_state" in
            absent|deployed|failed|superseded|uninstalled) ;;
            *) die "Helm $release is $release_state; inspect helm history in namespace $ns and finish/recover the prior operation before rerunning; no release records were deleted" ;;
        esac
        if [[ $first == osac && $release != osac && $release_state != deployed ]]; then
            die "Cannot resume OSAC: $release is $release_state; resume from infra or run the full installer"
        fi
    done
}

preflight() {
    local tool file failed=0
    for tool in oc helm git make jq python3; do
        command -v "$tool" >/dev/null || { printf 'MISSING tool: %s\n' "$tool"; failed=1; }
    done
    for file in "$installer/Makefile" "${settings[INFRA_VALUES]}" "${settings[INSTANCE_VALUES]}" "$prepared_license"; do
        [[ -r "$file" && -s "$file" ]] || { printf 'MISSING readable input: %s\n' "$file"; failed=1; }
    done
    ((failed == 0)) || die 'Supply prerequisites; see --help'
    helm version --short | grep -q '^v3\.' || die 'Installation requires Helm 3'
    # Helm parses the same values that deployment consumes; no PyYAML dependency.
    mkdir -p "$run_dir/values-check"
    printf 'apiVersion: v2\nname: values-check\nversion: 0.0.1\n' >"$run_dir/values-check/Chart.yaml"
    for file in "${settings[INFRA_VALUES]}" "${settings[INSTANCE_VALUES]}"; do
        run_bounded helm lint "$run_dir/values-check" --values "$file" --quiet
    done
    cluster_preflight
    deployment_state_preflight
    local resource available
    available=$(oc --request-timeout=20s api-resources -o name)
    for resource in agentserviceconfigs.agent-install.openshift.io multiclusterengines.multicluster.openshift.io; do
        if grep -qx "$resource" <<< "$available"; then
            oc --request-timeout=20s get "$resource" -o json | jq -e --arg ns "$namespace" 'all(.items[]; .metadata.annotations["osac.openshift.io/installer-namespace"] == $ns)' >/dev/null || die "Existing $resource has unverified ownership; inspect before using this dedicated-cluster installer"
        fi
    done
    printf 'REVISION %s\n' "$(git -C "$repo" rev-parse HEAD)"
    ownership_validated=true
    printf 'PASS preflight; entitlement and unused-disk suitability are checked by deployment\n'
}

record_ownership() {
    local ns release namespaces
    for release in osac-deps osac-infra; do
        if helm_read status "$release" -n "$release" -o json >/dev/null 2>&1; then
            oc --request-timeout=20s annotate namespace "$release" "osac.openshift.io/installer-namespace=$namespace" --overwrite
        fi
    done
    # Chart-created singleton ownership can only be assigned if preflight
    # confirmed it was absent or already explicitly owned by this deployment.
    for ns in agentserviceconfigs.agent-install.openshift.io multiclusterengines.multicluster.openshift.io; do
        if oc --request-timeout=20s api-resources -o name | grep -qx "$ns"; then
            namespaces=$(oc --request-timeout=20s get "$ns" -o name)
            while IFS= read -r release; do
                [[ -n $release ]] || continue
                oc --request-timeout=20s annotate "$release" "osac.openshift.io/installer-namespace=$namespace" --overwrite
            done <<< "$namespaces"
        fi
    done
}

run_make() {
    # Do not inherit parallelism, alternate kube contexts or injected Make variables.
    run_bounded env -u MAKEFLAGS -u MFLAGS -u GNUMAKEFLAGS -u MAKEFILES -u HELM_KUBECONTEXT \
        -u HELM_KUBEAPISERVER -u HELM_KUBETOKEN -u HELM_KUBEASUSER -u HELM_KUBEASGROUPS \
        make -C "$installer" "$1" PLATFORM=openshift "PROFILE=$profile" "NS=$namespace" \
        "INFRA_VALUES=${settings[INFRA_VALUES]}" "INSTANCE_VALUES=${settings[INSTANCE_VALUES]}" \
        "AAP_LICENSE_FILE=$prepared_license" EXTRA_HELM_ARGS= \
        INFRA_VALUES_EXTRA= INSTANCE_VALUES_EXTRA=
}
post_config() {
    local release_json ui_route keycloak_route ui_host keycloak_host ca_bundle secret_json admin_user admin_password helper
    release_json=$(helm_read status osac --namespace "$namespace" -o json) || die 'Cannot inspect the OSAC Helm release'
    jq -e '.info.status == "deployed"' <<< "$release_json" >/dev/null || die 'OSAC Helm release must be deployed before post-configuration'

    ui_route=$(oc -n "$namespace" --request-timeout=20s get route osac-ui -o json) || die 'Cannot read the OSAC UI Route'
    ui_host=$(jq -er 'select(.spec.host != null and .spec.tls != null and any(.status.ingress[]?.conditions[]?; .type == "Admitted" and .status == "True")) | .spec.host' <<< "$ui_route") || die 'The OSAC UI Route must have TLS and be admitted before post-configuration'
    keycloak_route=$(oc -n keycloak --request-timeout=20s get route keycloak -o json) || die 'Cannot read the Keycloak Route in namespace keycloak'
    keycloak_host=$(jq -er 'select(.spec.host != null and .spec.tls != null and any(.status.ingress[]?.conditions[]?; .type == "Admitted" and .status == "True")) | .spec.host' <<< "$keycloak_route") || die 'The Keycloak Route must have TLS and be admitted before post-configuration'

    ca_bundle="$run_dir/keycloak-ca-bundle.pem"
    oc -n "$namespace" --request-timeout=20s get configmap ca-bundle \
        -o jsonpath='{.data.bundle\.pem}' > "$ca_bundle" || die 'Cannot read OSAC ca-bundle ConfigMap'
    [[ -s $ca_bundle ]] || die 'OSAC ca-bundle ConfigMap is empty'
    chmod 600 "$ca_bundle"

    secret_json=$(oc -n keycloak --request-timeout=20s get secret keycloak-admin-credentials -o json) || die 'Cannot read Keycloak admin credentials Secret'
    admin_user=$(jq -er '.data["admin-username"] | @base64d | select(length > 0)' <<< "$secret_json") || die 'Keycloak admin Secret has no admin-username value'
    admin_password=$(jq -er '.data["admin-password"] | @base64d | select(length > 0)' <<< "$secret_json") || die 'Keycloak admin Secret has no admin-password value'
    unset secret_json

    helper="$run_dir/configure-keycloak-ui-client.py"
    cat > "$helper" <<'PY'
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

host, ui_origin, ca_file = sys.argv[1:]
username = os.environ.get("KEYCLOAK_ADMIN_USERNAME", "")
password = os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "")
if not username or not password:
    sys.exit("FAIL Keycloak admin credentials are missing")

base = f"https://{host}"
context = ssl.create_default_context(cafile=ca_file)

def request(path, method="GET", payload=None, token=None, form=False):
    headers = {"Accept": "application/json"}
    data = None
    if payload is not None:
        if form:
            data = urllib.parse.urlencode(payload).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=context, timeout=20) as response:
            body = response.read()
            return response.status, json.loads(body) if body else None
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Keycloak returned HTTP {exc.code} for {method} {path.split('?')[0]}") from None
    except (urllib.error.URLError, TimeoutError, ssl.SSLError, OSError) as exc:
        raise RuntimeError(f"Keycloak request failed ({type(exc).__name__})") from None

try:
    _, token_data = request(
        "/realms/master/protocol/openid-connect/token",
        method="POST",
        payload={"grant_type": "password", "client_id": "admin-cli", "username": username, "password": password},
        form=True,
    )
    token = token_data.get("access_token") if isinstance(token_data, dict) else None
    if not token:
        raise RuntimeError("Keycloak did not return an admin access token")
    query = urllib.parse.urlencode({"clientId": "osac-ui"})
    _, clients = request(f"/admin/realms/osac/clients?{query}", token=token)
    if not isinstance(clients, list) or len(clients) != 1 or not isinstance(clients[0], dict) or not clients[0].get("id"):
        raise RuntimeError("Expected exactly one osac-ui client in the osac realm")
    client = clients[0]
    client_path = "/admin/realms/osac/clients/" + urllib.parse.quote(client["id"], safe="")
    _, client = request(client_path, token=token)
    if not isinstance(client, dict):
        raise RuntimeError("Keycloak returned an invalid osac-ui client")
    desired = {
        "rootUrl": ui_origin,
        "baseUrl": "/",
        "redirectUris": [ui_origin + "/callback"],
        "webOrigins": [ui_origin],
    }
    changed = any(client.get(key) != value for key, value in desired.items())
    if changed:
        client.update(desired)
        request(client_path, method="PUT", payload=client, token=token)
    _, verified = request(client_path, token=token)
    if not isinstance(verified, dict) or any(verified.get(key) != value for key, value in desired.items()):
        raise RuntimeError("Keycloak osac-ui client did not retain the expected Route settings")
except (RuntimeError, ValueError, TypeError, KeyError) as exc:
    sys.exit("FAIL " + str(exc))

if changed:
    print(f"FIXED Keycloak osac-ui redirect/origin settings for {ui_origin}")
else:
    print(f"PASS Keycloak osac-ui redirect/origin settings already match {ui_origin}")
PY
    chmod 700 "$helper"
    printf 'INFO Configuring Keycloak osac-ui client for the admitted UI Route\n'
    KEYCLOAK_ADMIN_USERNAME="$admin_user" KEYCLOAK_ADMIN_PASSWORD="$admin_password" \
        run_bounded python3 "$helper" "$keycloak_host" "https://$ui_host" "$ca_bundle" || die 'Keycloak UI client configuration failed; see the sanitized error above'
    unset admin_user admin_password
}
verify() {
    local release ns workloads workload namespaces jobs workload_json
    for release in osac-deps osac-infra osac; do
        ns=$release
        [[ "$release" != osac ]] || ns=$namespace
        helm_read status "$release" --namespace "$ns" -o json | jq -e '.info.status == "deployed"' >/dev/null || die "Helm release $release is not deployed"
    done
    local namespace_json route_json route_service endpoint_json
    namespace_json=$(oc --request-timeout=20s get namespace -o json)
    [[ -n $namespace_json ]] || die 'Empty namespace inventory'
    namespaces=$(jq -r --arg target "$namespace" '
        .items[] | select(.metadata.name == $target or
          (.metadata.annotations["meta.helm.sh/release-name"] == "osac-deps" and .metadata.annotations["meta.helm.sh/release-namespace"] == "osac-deps") or
          (.metadata.annotations["meta.helm.sh/release-name"] == "osac-infra" and .metadata.annotations["meta.helm.sh/release-namespace"] == "osac-infra") or
          (.metadata.annotations["meta.helm.sh/release-name"] == "osac" and .metadata.annotations["meta.helm.sh/release-namespace"] == $target)) | .metadata.name' <<< "$namespace_json")
    namespaces=$(printf '%s\n' "$namespace" osac-infra osac-deps "$namespaces" | sort -u)
    while IFS= read -r ns; do
        [[ -n $ns ]] || continue
        workload_json=$(oc -n "$ns" --request-timeout=20s get deployment,statefulset,daemonset -o json)
        if [[ $ns == "$namespace" ]]; then
            jq -e '[.items[] | select(.kind == "Deployment" or .kind == "StatefulSet")] | length > 0' <<< "$workload_json" >/dev/null || die 'No OSAC workloads found'
            jq -e 'all(.items[] | select(.kind == "Deployment" or .kind == "StatefulSet"); (.spec.replicas // 1) > 0 and (.spec.paused != true))' <<< "$workload_json" >/dev/null || die 'OSAC workloads are scaled to zero or paused; restore replicas/reconciliation before verification'
        fi
        workloads=$(jq -r '.items[] | (.kind | ascii_downcase) + "/" + .metadata.name' <<< "$workload_json")
        while IFS= read -r workload; do
            [[ -n $workload ]] || continue
            run_bounded oc -n "$ns" rollout status "$workload" --timeout="${timeout}s"
        done <<< "$workloads"
        jobs=$(oc -n "$ns" --request-timeout=20s get jobs -o json)
        [[ -n $jobs ]] || die "Empty job inventory in $ns"
        jq -e 'all(.items[]; any(.status.conditions[]?; .type == "Complete" and .status == "True") or (any(.status.conditions[]?; .type == "Failed" and .status == "True") | not))' <<< "$jobs" >/dev/null || die "Failed current job in $ns"
        while IFS= read -r workload; do
            [[ -n $workload ]] || continue
            run_bounded oc -n "$ns" wait --for=condition=complete "job/$workload" --timeout="${timeout}s"
        done < <(jq -r '.items[] | select((.spec.suspend // false) == false) | select(any(.status.conditions[]?; .type == "Complete" and .status == "True") | not) | .metadata.name' <<< "$jobs")
    done <<< "$namespaces"
    oc -n "$namespace" --request-timeout=20s get pods -o json | jq -r '
        ["POD", "CONTAINER", "IMAGE", "IMAGE_ID"],
        (.items[] | . as $pod |
            ((.spec.initContainers // []) + (.spec.containers // []))[] as $container |
            (((.status.initContainerStatuses // []) + (.status.containerStatuses // [])) |
                map(select(.name == $container.name)) | first // {}) as $status |
            [$pod.metadata.name, $container.name, $container.image,
                ($status.imageID // "unavailable")]) | @tsv
    ' > "$run_dir/images.tsv"
    printf 'IMAGES %s/images.tsv\n' "$run_dir"
    python3 - "$run_dir/images.tsv" "$namespace" <<'PY'
import csv
import sys

images = {}
with open(sys.argv[1]) as stream:
    for row in csv.DictReader(stream, delimiter='\t'):
        images.setdefault((row['IMAGE'], row['IMAGE_ID']), set()).add(row['CONTAINER'])
print(f'\nOSAC CONTAINER IMAGES (namespace: {sys.argv[2]})')
print('Includes init containers and retained job pods. Unavailable IDs were not reported by the runtime.')
for (reference, image_id), containers in sorted(images.items()):
    print(f'  Image: {reference}')
    print(f'    Image ID: {image_id}')
    print(f'    Containers: {", ".join(sorted(containers))}')
print()
PY
    oc -n "$namespace" --request-timeout=20s get pods
    oc -n "$namespace" --request-timeout=20s get routes -o 'custom-columns=NAME:.metadata.name,HOST:.spec.host'
    route_json=$(oc -n "$namespace" --request-timeout=20s get routes -o json)
    [[ -n $route_json ]] || die 'Empty route inventory'
    jq -e '.items | length > 0 and all(.[]; any(.status.ingress[]?.conditions[]?; .type == "Admitted" and .status == "True"))' <<< "$route_json" >/dev/null || die 'OSAC routes are missing or not admitted'
    while IFS= read -r route_service; do
        [[ -n $route_service ]] || continue
        endpoint_json=$(oc -n "$namespace" --request-timeout=20s get endpointslices -l "kubernetes.io/service-name=$route_service" -o json)
        [[ -n $endpoint_json ]] || die "Empty endpoint response for $route_service"
        jq -e 'any(.items[]?.endpoints[]?; .conditions.ready == true and ((.addresses // []) | length) > 0)' <<< "$endpoint_json" >/dev/null || die "No ready backend for route service $route_service"
    done < <(jq -r '.items[].spec.to.name // empty' <<< "$route_json" | sort -u)
    printf 'PASS deployment verification; VM provisioning and UI login require the separate E2E suite\n'
}
if [[ "$first" != verify ]] && ! $post_config_only; then
    printf '\nSTEP repository\n'
    state_key=$(printf '%s' "$repo" | sha256sum); state_key=${state_key%% *}
    state_file="${settings[STATE_DIR]}/$state_key.json"
    if ((start > 0)); then
        python3 - "$state_file" "$repo" "$profile" "$namespace" "${settings[KUBECONFIG]}" "${settings[INFRA_VALUES]}" "${settings[INSTANCE_VALUES]}" "$repo_ref" <<'RESUMEPY'
import hashlib, json, subprocess, sys
from pathlib import Path
try:
    saved = json.loads(Path(sys.argv[1]).read_text())
    head = subprocess.check_output(['git', '-C', sys.argv[2], 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', sys.argv[2], 'status', '--porcelain', '--untracked-files=no'], text=True).strip()
    values = {str(Path(name)): hashlib.sha256(Path(name).read_bytes()).hexdigest() if Path(name).is_file() else None for name in sys.argv[6:8]}
    if dirty or saved != dict(revision=head, repo=sys.argv[2], profile=sys.argv[3], namespace=sys.argv[4], kubeconfig=sys.argv[5], values=values, ref=sys.argv[8]):
        raise ValueError()
except (OSError, ValueError, subprocess.SubprocessError):
    sys.exit('FAIL Resume requires the recorded checkout revision and target settings; start a fresh full run to update upstream')
print('PASS Resuming recorded revision ' + head)
RESUMEPY
    else
        repository
        [[ ! -L ${settings[STATE_DIR]} ]] || die 'STATE_DIR cannot be a symlink'
        mkdir -p -- "${settings[STATE_DIR]}"
        [[ -O ${settings[STATE_DIR]} ]] || die 'STATE_DIR must be owned by the current user'
        chmod 700 "${settings[STATE_DIR]}"
        python3 - "$state_file" "$(git -C "$repo" rev-parse HEAD)" "$repo" "$profile" "$namespace" "${settings[KUBECONFIG]}" "${settings[INFRA_VALUES]}" "${settings[INSTANCE_VALUES]}" "$repo_ref" <<'STATEPY'
import hashlib, json, os, sys, tempfile
from pathlib import Path
path = Path(sys.argv[1])
fd, name = tempfile.mkstemp(dir=path.parent)
with os.fdopen(fd, 'w') as output:
    saved = dict(zip(('revision', 'repo', 'profile', 'namespace', 'kubeconfig'), sys.argv[2:7]))
    saved['values'] = {str(Path(name)): hashlib.sha256(Path(name).read_bytes()).hexdigest() if Path(name).is_file() else None for name in sys.argv[7:9]}
    saved['ref'] = sys.argv[9]
    json.dump(saved, output)
os.replace(name, path)
STATEPY
    fi
    cp -- "$state_file" "$run_dir/revision.json"
    ((stop != 0)) || exit 0
    stage=credentials
    write_status running 0
    printf '\nSTEP credentials\n'
    credentials
    [[ "$last" != credentials ]] || exit 0
fi
stage=preflight
write_status running 0
printf '\nSTEP preflight\n'
if [[ $first == verify ]] || $post_config_only; then cluster_preflight; else preflight; fi
for ((i=start; i<=stop; i++)); do
    stage=${stages[$i]}
    [[ "$stage" != repository && "$stage" != credentials && "$stage" != preflight ]] || continue
    write_status running 0
    printf '\nSTEP %s\n' "$stage"
    case "$stage" in
        dependencies) run_make helm-deps ;;
        infra) run_make install-infra; record_ownership ;;
        osac) run_make install-osac; record_ownership ;;
        post-config) post_config ;;
        verify) verify ;;
    esac
done
