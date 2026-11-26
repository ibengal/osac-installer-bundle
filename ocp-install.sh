#!/usr/bin/env bash
# Install a configurable x86_64, libvirt-backed OpenShift cluster with dev-scripts.
# By default, this wrapper clones or refreshes dev-scripts from origin/master
# (for example, in /root). Use --repo for another location. It does not depend
# on the caller's current directory. Run it in tmux for ocp_run.
#
# The user supplies the CI token and pull secret. This script checks them but
# does not fetch, prompt for, copy, or invent credentials. It does handle
# repeatable host preparation and the six Makefile stages we have inspected.
# Each run records full stdout/stderr and a short result in /tmp/ocp-install-logs.
# Keep these files private: dev-scripts may print cluster credentials in its logs.
# Do not run it while another dev-scripts installation is in progress.
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


script_path=$(realpath -- "${BASH_SOURCE[0]}")
script_dir=$(cd -- "$(dirname -- "$script_path")" && pwd)
repo_arg=${DEV_SCRIPTS_DIR:-}
dev_scripts_url=https://github.com/openshift-metal3/dev-scripts.git
installer_config_arg=
check_config=false
config_json=false
preflight_only=false
verify_only=false
health_timeout_arg=
stage_selection=false
ci_token_file_arg=
pull_secret_arg=
repo_file_arg=
use_subscription_manager=false
rhsm_org=
rhsm_activation_key_file=
first_stage=requirements
last_stage=ocp_run
stages=(requirements configure build_installer ironic install_config ocp_run)
stage=preparation

usage() {
    cat <<'HELP'
Usage: ocp-install.sh [--config PATH] [--check-config | --verify-only]
                      [--repo PATH] [--ci-token-file PATH]
                      [--pull-secret PATH] [repository options]
                      [--from STAGE] [--through STAGE] [--health-timeout SECONDS]
       ocp-install.sh --help

Install a configurable OpenShift test cluster with dev-scripts.
Run as root, preferably inside tmux so an SSH disconnect does not stop it.
The script works from any current directory.

Required before the installation stages:
  * Access to https://github.com/openshift-metal3/dev-scripts. The wrapper
    clones it beside this script when missing (for example, /root/dev-scripts
    beside /root/ocp-install.sh). Fresh runs fetch origin/master.
    Use --repo PATH for another location.
  * An x86_64 RHEL 9, CentOS Stream 9, AlmaLinux 9, or Rocky Linux 9 host
    with /dev/kvm, a d_type-capable filesystem, and 80 GiB free for
    WORKING_DIR (/opt/dev-scripts by default). At least 64 GiB RAM and a
    bare-metal host are recommended. RHEL needs working BaseOS and
    AppStream package repositories; subscription registration is not
    required for package access if those repositories already work.
  * A personal OpenShift pull secret: download the JSON from
    https://console.redhat.com/openshift/install/pull-secret and save it as
    /root/osac-inputs/pull-secret.json (or set PERSONAL_PULL_SECRET to another absolute
    path in config_root.sh). It must contain a nonempty auths object.
  * An OpenShift CI API token: copy the login command from
    https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/
    and save only its --token value in /root/osac-inputs/ci-token.txt.
    CI_TOKEN_FILE or --ci-token-file PATH can select another file. This lets dev-scripts
    log into the CI cluster and obtain CI registry credentials.

Configuration:
  Edit ocp-install.conf beside this script, or select a file with --config.
  Use literal KEY=value or export KEY=value lines; quote space-separated
  values. Comments are supported; shell commands and expansion are rejected.
  Precedence: command-line flags > installer config > saved external config
  > legacy config_root.sh > defaults.
  DEV_SCRIPTS_DIR in the environment has the same priority as --repo.
  A new release selection in the installer config replaces the old selection
  as a group: STREAM alone selects nightly; VERSION alone selects pinned GA.
  Explicit TYPE=ga needs VERSION; nightly/ci need STREAM or RELEASE_IMAGE;
  okd needs RELEASE_IMAGE. A supplied image takes precedence over the stream.
  Keys use their full OPENSHIFT_ names (listed below). Stream availability is
  checked by dev-scripts during installation, not by --check-config.
  The effective cluster settings are saved beside this script, outside the
  checkout, for every stage. Missing credentials stop the run with instructions; supply them and
  rerun the same command. The script never fetches credentials.
  Default layout: GA 4.22.15, IPv4, 3 masters and 0 workers; each master has
  32 GiB RAM, 12 vCPUs, an 80 GiB system disk and a 150 GiB extra disk for VMaaS.
  Existing external or legacy config_root.sh settings remain authoritative
  unless overridden.
  This wrapper pins the release-extracted installer. KNI_INSTALL_FROM_GIT and
  custom OPENSHIFT_INSTALLER paths require a separate dev-scripts workflow.
  New layouts apply to fresh installations; changing the file does not resize
  an existing cluster. Nonstandard master counts may require additional
  release-specific settings in dev-scripts; they are not all supported by OCP.

Installer configuration keys:
  DEV_SCRIPTS_DIR, CI_TOKEN_FILE,
  LOG_DIR (default /tmp/ocp-install-logs)
  HEALTH_TIMEOUT (seconds, default 1800; overridden by --health-timeout)
  INPUTS_DIR (default osac-inputs beside this script), STEP_TIMEOUT (7200 seconds),
  CLEANUP_TIMEOUT (1800 seconds), REPO_FILE, USE_SUBSCRIPTION_MANAGER (false),
  RHSM_ORG, RHSM_ACTIVATION_KEY_FILE. CLI options override config values.
  CLUSTER_NAME, BASE_DOMAIN, WORKING_DIR, PERSONAL_PULL_SECRET, CI_TOKEN, CI_SERVER
  SERVER_NAME is a wrapper alias for CLUSTER_NAME; it does not select an SSH
  server or change the host name. Prefer the upstream name CLUSTER_NAME.
  OPENSHIFT_RELEASE_TYPE, OPENSHIFT_RELEASE_STREAM, OPENSHIFT_VERSION,
  OPENSHIFT_RELEASE_IMAGE
  NUM_MASTERS, NUM_WORKERS, IP_STACK, HOST_IP_STACK
    IP stacks: v4, v6, v4v6 (IPv4 primary), v6v4 (IPv6 primary).
    Ensure the host and network support the selected stack.
  MASTER_MEMORY, WORKER_MEMORY (MiB); MASTER_DISK, WORKER_DISK (GiB)
  MASTER_VCPU, WORKER_VCPU (virtual CPUs)
  VM_EXTRADISKS (true/false), VM_EXTRADISKS_LIST (e.g. "vdb vdc"),
  VM_EXTRADISKS_SIZE (e.g. "100G" = 100 GiB per extra disk).
    Extra disks are attached to EACH master and worker, unformatted. They
    do not create StorageClasses, PVs, or a storage operator automatically.
  Unknown keys in the installer config are errors. Other advanced upstream
  settings can remain in the external config; the wrapper does not validate them.

Options:
  --config PATH     installer settings file; default is ocp-install.conf
                    beside the script when present. A supplied path must exist.
  --check-config    print resolved settings with the CI token hidden, then exit.
                    No clone, update, logs, configuration writes, or installation actions.
                    Does not authenticate credentials or check host/release access.
  --preflight       local host/input and existing Metal3 task checks only;
                    known libvirt mismatch is reported as installer-fixable.
                    No clone/package/cluster changes.
  --verify-only     run cluster and VM checks using the existing kubeconfig.
                    Reads cluster/VM state and writes logs; skips repository updates,
                    credential checks, host preparation, and installation stages.
                    Cannot be combined with --check-config or stage selection.
  --health-timeout SECONDS
                    wait up to this many seconds for cluster health (default 1800).
                    Timeout returns exit 1 with diagnostics in the run logs.
  --repo PATH       dev-scripts checkout location, cloned when missing;
                    overrides the sibling path and DEV_SCRIPTS_DIR environment.
  --ci-token-file PATH
                    read the CI token from a private file (one token value,
                    not an oc login command); save it in the external config.
  --pull-secret PATH
                    use this existing pull-secret JSON file and save its
                    absolute path in the external config.
  --repo-file PATH  add repositories from an existing local .repo file;
                    use an absolute path. Obtain it and any required keys,
                    certificates, or network access from your lab/IT team.
                    Verify it with existing repositories before installing
                    it as /etc/yum.repos.d/ocp-install.repo (mode 600).
                    Replaces only that managed file; an older copy is backed up.
  --use-subscription-manager
                    RHEL only: use Red Hat Subscription Manager and enable
                    official RHEL 9 x86_64 BaseOS, AppStream, and CodeReady
                    Builder repositories. An already registered host keeps
                    its registration. An unregistered host needs both inputs:
  --rhsm-org ID     numeric Red Hat organization ID for registration.
  --rhsm-activation-key-file PATH
                    absolute path to a private file containing only the
                    activation key name provided by your organization.
                    The key is not saved in the external config or printed.
  --from STAGE      resume the current checkout; earlier stages must already have passed.
                    Existing OpenShift installer state requires manual recovery;
                    this wrapper will not alter upstream cluster creation logic.
  --through STAGE   stop after STAGE; useful for a partial installation run.
  -h, --help        show this help and exit without changing the host.

Repository behavior:
  With no repository options, use the host's existing enabled repositories.
  Refresh metadata and check core OS, virtualization, and container packages;
  repository names and registration status alone do not prove package access.
  If access fails, stop and print setup options. Fix the existing repositories,
  supply --repo-file, or choose --use-subscription-manager, then rerun.
  Explicit repository options are applied even if repositories already work.
  --repo-file and --use-subscription-manager cannot be combined. RHSM inputs
  require --use-subscription-manager. No interactive prompts are used.
  Setup persists on the host; later runs normally need no repository options.
  Registration uses your existing subscription; it does not buy or renew one.
  Custom .repo files must match the installed OS and use unique repository IDs.

Stages (run in this order by default):
  requirements     install dev-scripts dependencies; resets its Metal3 checkout
  configure        configure host networking and libvirt VMs
  build_installer  extract openshift-install from the selected release
  ironic           set up Ironic provisioning services and images
  install_config   generate the OpenShift install-config.yaml
  ocp_run          create the OpenShift cluster, then verify its health

Final health checks (also available with --verify-only):
  API /readyz; expected node count/roles, Ready state, no pressure or cordon;
  ClusterVersion Available=True, Progressing=False, Failing=False;
  all cluster operators Available=True, Progressing=False, Degraded=False;
  machine config pools updated, ready, not updating or degraded;
  pods in openshift, openshift-* and kube-system Running and Ready, or Succeeded;
  schedulable control-plane nodes for a cluster with no dedicated workers;
  console route admitted and reachable from this host;
  live cluster name/domain, release and IP stack match the requested settings;
  libvirt VM CPUs, memory, system disks and requested extra disks match settings.
  Retries every 15 seconds while the cluster settles. Completed jobs are valid;
  failed, pending, unready, and terminating platform pods block success.
  These checks inspect platform health; they do not deploy a test application.

Examples:
  /root/ocp-install.sh
  /root/ocp-install.sh --config /root/ocp-install.conf --check-config
  /root/ocp-install.sh --repo /path/to/dev-scripts
  /root/ocp-install.sh --ci-token-file /root/osac-inputs/ci-token.txt \
      --pull-secret /root/pull_secret.json
  /root/ocp-install.sh --from install_config
  /root/ocp-install.sh --verify-only --health-timeout 600
  /root/ocp-install.sh --through configure
  /root/ocp-install.sh --repo-file /root/lab-rhel9.repo
  /root/ocp-install.sh --use-subscription-manager --rhsm-org 123456 \
      --rhsm-activation-key-file /root/rhsm-activation-key.txt

Logs and status are written under LOG_DIR (/tmp/ocp-install-logs by default). See latest.log
and latest.status for the latest run. latest.d points to that run's separate
dev-scripts stage logs, openshift-install.log, and health/ snapshots and diagnostics.
The native installer log
path in the cluster directory is a link to the log under /tmp.
Keep logs private: they may contain cluster credentials. /tmp may be cleared
on reboot or by system cleanup; copy logs elsewhere for long-term retention.
Do not run two dev-scripts installations at once.
Terminal colours:
  Cyan: stages/information; green: passed checks; yellow: warnings/waiting;
  red: failures; purple: image names; dim text: runtime image IDs.
  Colours are automatic on terminals and disabled for redirected output.
  Set INSTALLER_COLOR=always to force colours (for example in a captured demo),
  INSTALLER_COLOR=never to disable them, or NO_COLOR=1 to disable them globally.
  NO_COLOR takes precedence. Saved logs, status and image reports stay plain.
HELP
}

# Bound each external stage and cancel its entire process group, including
# descendants whose parent exits first. Deliberately daemonized services are
# managed by their service/container lifecycle, not this process group.
active_pid=
run_bounded() {
    python3 - "${step_timeout:-7200}" "$@" <<'RUNPY' &
import os, signal, subprocess, sys, time
child = None
code = 1
cancelled = False
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
    cancelled = True
except InterruptedError as error:
    code = 128 + error.args[0]
    cancelled = True
finally:
    if child is not None and cancelled:
        # Repeated cancellation must not interrupt cleanup itself.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        def send(sig):
            try:
                os.killpg(child.pid, sig)
                return True
            except ProcessLookupError:
                return False
        if send(signal.SIGTERM):
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                child.poll()  # reap the leader, but keep checking its group
                if not send(0):
                    break
                time.sleep(0.1)
            send(signal.SIGKILL)
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

die() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }
step() { printf '\nSTEP  [%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
next() { printf 'NEXT  %s\n' "$*" >&2; }
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }

on_error() {
    local status=$?
    printf '\nFAIL  Stage %s exited with status %s. Inspect its output before retrying.\n' "$stage" "$status" >&2
    if [[ $stage == preparation ]]; then
        next 'Correct the reported input/host issue and rerun the same command.'
    elif [[ $stage == verification ]]; then
        next 'After fixing the cluster, rerun with the same --config/--repo and --verify-only.'
    elif [[ $stage == ocp_run ]]; then
        next 'Preserve installer state and inspect upstream openshift-install recovery before any retry.'
    else
        printf 'NEXT  Once the cause is fixed, resume with --from %s.\n' "$stage" >&2
    fi
    exit "$status"
}
trap on_error ERR

# The status file gives a quick answer after an unattended run, even if the
# verbose dev-scripts output is too large to inspect first. The complete log
# stays outside the checkout, so neither cleanup nor git operations remove it.
write_running_status() {
    printf 'result=running\nstage=%s\nstarted_at=%s\nlog=%s\ndetails=%s\n' \
        "$stage" "$started_at" "$log_file" "$run_log_dir" >"$status_file"
}

on_exit() {
    local result=$? outcome
    if ((result == 0)); then outcome=success; else outcome=failed; fi
    printf 'result=%s\nexit_code=%s\nstage=%s\nstarted_at=%s\nfinished_at=%s\nlog=%s\ndetails=%s\n' \
        "$outcome" "$result" "$stage" "$started_at" "$(date --iso-8601=seconds)" "$log_file" "$run_log_dir" >"$status_file"
    printf '\nRESULT %s (exit %s) at stage %s\nLOG %s\nSTATUS %s\nDETAILS %s\n' \
        "$outcome" "$result" "$stage" "$log_file" "$status_file" "$run_log_dir"
}

# Health checks read the installed cluster through its own kubeconfig and
# inspect the local libvirt VMs; neither check changes the cluster or VMs.
# An overall deadline bounds retries, including a hung oc request. Keep the
# snapshots private alongside the existing run logs for failure diagnosis.
health_oc() {
    local remaining=$((health_deadline - SECONDS))
    ((remaining > 0)) || return 1
    ((remaining <= 20)) || remaining=20
    timeout --kill-after=2s "${remaining}s" oc --kubeconfig="$kubeconfig" \
        --request-timeout="${remaining}s" "$@"
}

health_virsh() {
    local remaining=$((health_deadline - SECONDS))
    ((remaining > 0)) || return 124
    ((remaining <= 20)) || remaining=20
    LC_ALL=C timeout --kill-after=2s "${remaining}s" virsh "$@"
}

health_fetch() {
    local filename=$1
    shift
    if ! health_oc "$@" >"$health_dir/$filename" 2>"$health_dir/api-error.txt"; then
        printf 'WAIT  Cannot read cluster health: oc %s\n' "$*"
        cat "$health_dir/api-error.txt"
        return 1
    fi
}

check_cluster_health() {
    local resource
    health_fetch readyz.txt get --raw=/readyz || return 1
    [[ $(<"$health_dir/readyz.txt") == ok ]] || { warn 'API /readyz is not ok.'; return 1; }
    for resource in nodes clusteroperators machineconfigpools; do
        health_fetch "$resource.json" get "$resource" -o json || return 1
    done
    health_fetch clusterversion.json get clusterversion version -o json || return 1
    health_fetch pods.json get pods -A -o json || return 1
    health_fetch infrastructure.json get infrastructure.config.openshift.io cluster -o json || return 1
    health_fetch dns.json get dns.config.openshift.io cluster -o json || return 1
    health_fetch ingress.json get ingresses.config.openshift.io cluster -o json || return 1
    health_fetch network.json get networks.config.openshift.io cluster -o json || return 1
    printf '{}\n' >"$health_dir/scheduler.json"
    if ((num_workers == 0)); then
        health_fetch scheduler.json get scheduler cluster -o json || return 1
    fi

    # Never allow an empty collection or a missing required condition to pass.
    # Control-plane nodes may also have the worker label in compact clusters.
    if ! jq -nr --argjson masters "$num_masters" --argjson workers "$num_workers" \
        --slurpfile nodes "$health_dir/nodes.json" \
        --slurpfile operators "$health_dir/clusteroperators.json" \
        --slurpfile version "$health_dir/clusterversion.json" \
        --slurpfile pools "$health_dir/machineconfigpools.json" \
        --slurpfile pods "$health_dir/pods.json" \
        --slurpfile scheduler "$health_dir/scheduler.json" '
        def condition($type; $value):
            any(.status.conditions[]?; .type == $type and .status == $value);
        def master:
            (.metadata.labels // {}) | has("node-role.kubernetes.io/master") or has("node-role.kubernetes.io/control-plane");
        def worker:
            ((.metadata.labels // {}) | has("node-role.kubernetes.io/worker")) and (master | not);
        # Static-pod operators retain failed installer pods from older revisions.
        # Their stable operator conditions prove the current revision succeeded.
        def historical_installer:
            .status.phase == "Failed" and
            (.metadata.namespace | test("^openshift-(etcd|kube-apiserver|kube-controller-manager|kube-scheduler)$")) and
            (.metadata.name | startswith("installer-"));
        def platform: (.metadata.namespace | test("^(openshift($|-)|kube-system$)")) and
            (historical_installer | not);
        def conditions:
            [.status.conditions[]? | "\(.type)=\(.status)"] | join(", ");
        $nodes[0].items as $ns | $operators[0].items as $ops |
        $pools[0].items as $mcps | [$pods[0].items[] | select(platform)] as $ps |
        [
            (if ($ns | length) != ($masters + $workers) then
                "Node count: \($ns | length); expected \($masters + $workers)" else empty end),
            (if ([$ns[] | select(master)] | length) != $masters or
                ([$ns[] | select(worker)] | length) != $workers then
                "Node roles do not match \($masters) masters/\($workers) dedicated workers" else empty end),
            ($ns[] | select((condition("Ready"; "True") | not) or .spec.unschedulable == true or
                any(.status.conditions[]?; (.type == "MemoryPressure" or .type == "DiskPressure" or .type == "PIDPressure") and .status != "False")) |
                "Node \(.metadata.name): unschedulable=\(.spec.unschedulable // false), \(conditions)"),
            ($version[0] | select((condition("Available"; "True") and condition("Progressing"; "False") and condition("Failing"; "False")) | not) |
                "ClusterVersion: \(conditions)"),
            (if ($ops | length) == 0 then "No cluster operators found" else empty end),
            ($ops[] | select((condition("Available"; "True") and condition("Progressing"; "False") and condition("Degraded"; "False")) | not) |
                "Operator \(.metadata.name): \(conditions)"),
            (if ($mcps | length) == 0 then "No machine config pools found" else empty end),
            ($mcps[] | select((condition("Updated"; "True") and condition("Updating"; "False") and condition("Degraded"; "False") and
                .status.machineCount != null and .status.readyMachineCount == .status.machineCount and
                .status.updatedMachineCount == .status.machineCount and .status.unavailableMachineCount == 0 and .status.degradedMachineCount == 0) | not) |
                "Machine config pool \(.metadata.name): ready=\(.status.readyMachineCount)/\(.status.machineCount), \(conditions)"),
            (if ($ps | length) == 0 then "No platform pods found" else empty end),
            ($ps[] | select(.metadata.deletionTimestamp != null or
                (.status.phase != "Succeeded" and (.status.phase != "Running" or (condition("Ready"; "True") | not)))) |
                "Pod \(.metadata.namespace)/\(.metadata.name): phase=\(.status.phase // "Unknown"), terminating=\(.metadata.deletionTimestamp != null), \(conditions), containers=\([(.status.initContainerStatuses[]?, .status.containerStatuses[]?) | (.state.waiting.reason // .state.terminated.reason // empty)] | join(","))"),
            (if $workers == 0 and $scheduler[0].spec.mastersSchedulable != true then
                "Control-plane nodes must be schedulable when there are no dedicated workers" else empty end)
        ] | .[]
    ' >"$health_dir/issues.txt"; then
        warn "Could not evaluate cluster health JSON; see $health_dir."
        return 1
    fi
    if [[ -s $health_dir/issues.txt ]]; then
        sed 's/^/WAIT  /' "$health_dir/issues.txt"
        return 1
    fi
}

check_console_route() {
    local console_host http_code remaining
    health_fetch console-route.json -n openshift-console get route console -o json || return 1
    if ! jq -e 'any(.status.ingress[]?; any(.conditions[]?; .type == "Admitted" and .status == "True"))' \
        "$health_dir/console-route.json" >/dev/null; then
        warn 'OpenShift console route is not admitted.'
        return 1
    fi
    console_host=$(jq -r '.spec.host // empty' "$health_dir/console-route.json")
    [[ -n $console_host && $console_host =~ ^[a-zA-Z0-9.-]+$ ]] || { warn 'Console route has no valid host.'; return 1; }
    remaining=$((health_deadline - SECONDS))
    ((remaining > 0)) || return 1
    ((remaining <= 15)) || remaining=15
    if ! http_code=$(timeout --kill-after=2s "${remaining}s" curl --noproxy '*' --insecure \
        --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --connect-timeout 5 --max-time "$remaining" "https://$console_host/" \
        2>"$health_dir/console-error.txt"); then
        warn "Console route is not reachable from this host: https://$console_host/"
        cat "$health_dir/console-error.txt"
        return 1
    fi
    printf '%s\n' "$http_code" >"$health_dir/console-http-code.txt"
    [[ $http_code == 2?? || $http_code == 3?? ]] || {
        warn "Console route returned HTTP $http_code: https://$console_host/"
        return 1
    }
}

verify_vm_layout() {
    local role count memory cpu system_disk vm vm_index info actual_capacity expected_capacity disk size multiplier
    local -a extra_disks=()
    command -v virsh >/dev/null 2>&1 || die 'virsh is required to verify the installed VM layout.'
    read -r -a extra_disks <<<"${settings[VM_EXTRADISKS_LIST]}"
    size=${settings[VM_EXTRADISKS_SIZE]}
    case ${size: -1} in
        G) multiplier=1073741824 ;;
        M) multiplier=1048576 ;;
    esac
    expected_capacity=$((${size%?} * multiplier))
    for role in master worker; do
        if [[ $role == master ]]; then
            count=$num_masters
            memory=${settings[MASTER_MEMORY]}
            cpu=${settings[MASTER_VCPU]}
            system_disk=${settings[MASTER_DISK]}
        else
            count=$num_workers
            memory=${settings[WORKER_MEMORY]}
            cpu=${settings[WORKER_VCPU]}
            system_disk=${settings[WORKER_DISK]}
        fi
        for ((vm_index=0; vm_index<count; vm_index++)); do
            vm=${cluster_name}_${role}_${vm_index}
            info=$(health_virsh dominfo "$vm" 2>&1) || die "Cannot inspect expected VM $vm within the health deadline: $info"
            [[ $(awk '$1 == "State:" {print $2}' <<<"$info") == running ]] || die "VM $vm is not running."
            [[ $(awk '$1 == "CPU(s):" {print $2}' <<<"$info") == "$cpu" ]] || die "VM $vm does not have the requested $cpu vCPUs."
            [[ $(awk '$1 == "Max" && $2 == "memory:" {print $3}' <<<"$info") == "$((memory * 1024))" ]] || \
                die "VM $vm does not have the requested $memory MiB memory."
            info=$(health_virsh domblkinfo "$vm" sda 2>&1) || die "Cannot inspect system disk for $vm: $info"
            actual_capacity=$(awk '$1 == "Capacity:" {print $2}' <<<"$info")
            [[ $actual_capacity == "$((system_disk * 1073741824))" ]] || die "VM $vm system disk does not match the requested $system_disk GiB."
            if [[ ${settings[VM_EXTRADISKS]} == true ]]; then
                for disk in "${extra_disks[@]}"; do
                    info=$(health_virsh domblkinfo "$vm" "$disk" 2>&1) || die "Cannot inspect extra disk $disk for $vm: $info"
                    actual_capacity=$(awk '$1 == "Capacity:" {print $2}' <<<"$info")
                    [[ $actual_capacity == "$expected_capacity" ]] || die "VM $vm extra disk $disk does not match the requested $size capacity."
                done
            fi
        done
    done
    pass 'Libvirt VMs match the requested CPUs, memory, system disks and extra disks.'
}

verify_requested_configuration() {
    local expected_domain=$cluster_name.${settings[BASE_DOMAIN]}
    local expected_release=$state_dir/$cluster_name/.ocp-installer-release expected_digest
    if [[ -s $expected_release ]]; then
        expected_digest=$(<"$expected_release")
        expected_digest=${expected_digest##*@}
        [[ $expected_digest =~ ^sha256:[a-f0-9]{64}$ ]] || die 'Invalid recorded release digest'
        jq -e --arg digest "$expected_digest" '.status.desired.image | endswith("@" + $digest)' "$health_dir/clusterversion.json" >/dev/null || \
            die 'Installed payload digest differs from the release selected for this deployment'
    else
        warn 'Legacy installation has no recorded payload digest; checking release version/stream only.'
    fi
    if ! jq -nr \
        --arg expected_domain "$expected_domain" \
        --arg release_type "${settings[OPENSHIFT_RELEASE_TYPE]}" \
        --arg expected_version "${settings[OPENSHIFT_VERSION]}" \
        --arg release_stream "${settings[OPENSHIFT_RELEASE_STREAM]}" \
        --arg ip_stack "${settings[IP_STACK]}" \
        --slurpfile infra "$health_dir/infrastructure.json" \
        --slurpfile dns "$health_dir/dns.json" \
        --slurpfile ingress "$health_dir/ingress.json" \
        --slurpfile network "$health_dir/network.json" \
        --slurpfile version "$health_dir/clusterversion.json" \
        --slurpfile route "$health_dir/console-route.json" '
        def families: map(if contains(":") then "v6" else "v4" end);
        def expected_families($stack):
            if $stack == "v4" then ["v4"]
            elif $stack == "v6" then ["v6"]
            elif $stack == "v4v6" then ["v4", "v6"]
            else ["v6", "v4"] end;
        "https://api.\($expected_domain):6443" as $expected_api |
        "apps.\($expected_domain)" as $expected_ingress |
        ($version[0].status.desired.version // "") as $live_version |
        (($network[0].spec.clusterNetwork // []) | map(.cidr) | families) as $cluster_families |
        (($network[0].spec.serviceNetwork // []) | families) as $service_families |
        [
            (if $infra[0].status.apiServerURL != $expected_api then
                "API URL \($infra[0].status.apiServerURL // "missing") does not match \($expected_api)" else empty end),
            (if $infra[0].status.platformStatus.type != "BareMetal" then
                "Platform is not BareMetal" else empty end),
            (if $dns[0].spec.baseDomain != $expected_domain then
                "Cluster DNS domain \($dns[0].spec.baseDomain // "missing") does not match \($expected_domain)" else empty end),
            (if $ingress[0].spec.domain != $expected_ingress then
                "Ingress domain \($ingress[0].spec.domain // "missing") does not match \($expected_ingress)" else empty end),
            (if $route[0].spec.host != "console-openshift-console.\($expected_ingress)" then
                "Console route does not use the requested ingress domain" else empty end),
            (if $release_type == "ga" and $live_version != $expected_version then
                "OpenShift version \($live_version) does not match requested \($expected_version)"
             elif $release_type != "ga" and $release_stream != "" and ($live_version | startswith($release_stream + ".") | not) then
                "OpenShift version \($live_version) does not match requested stream \($release_stream)"
             else empty end),
            (if $cluster_families != expected_families($ip_stack) then
                "Cluster network IP families \($cluster_families) do not match \($ip_stack)" else empty end),
            (if $service_families != expected_families($ip_stack) then
                "Service network IP families \($service_families) do not match \($ip_stack)" else empty end)
        ] | .[]
    ' >"$health_dir/config-issues.txt"; then
        die "Could not compare live cluster settings with ${installer_config:-$config}; see $health_dir."
    fi
    if [[ -s $health_dir/config-issues.txt ]]; then
        sed 's/^/FAIL  /' "$health_dir/config-issues.txt"
        die "Live cluster does not match ${installer_config:-$config}; see $health_dir/config-issues.txt."
    fi
    pass 'Live cluster identity, release and IP stack match the requested settings.'
    verify_vm_layout
}

health_diagnostics() {
    local resource
    # A separate short budget permits diagnostics after the health deadline.
    health_deadline=$((SECONDS + 90))
    {
        for resource in nodes clusteroperators clusterversion machineconfigpools; do
            printf '\nINFO  oc get %s\n' "$resource"
            health_oc get "$resource" -o wide || true
        done
        printf '\nINFO  Platform pod details are in pods.json and issues.txt when retrieval succeeded.\n'
        if [[ -s $health_dir/console-http-code.txt ]]; then
            printf 'INFO  Last console route HTTP status: %s\n' "$(<"$health_dir/console-http-code.txt")"
        fi
    } >"$health_dir/diagnostics.txt" 2>&1
    cat "$health_dir/diagnostics.txt"
}

verify_cluster_health() {
    local health_deadline health_dir kubeconfig remaining delay installed_version
    stage=verification
    write_running_status
    kubeconfig=$repo/ocp/$cluster_name/auth/kubeconfig
    [[ -s $kubeconfig && -r $kubeconfig ]] || die "Cluster kubeconfig is missing or unreadable: $kubeconfig"
    command -v oc >/dev/null 2>&1 || die 'oc is required for cluster health checks.'
    command -v jq >/dev/null 2>&1 || die 'jq is required for cluster health checks.'
    command -v curl >/dev/null 2>&1 || die 'curl is required for console reachability checks.'
    command -v virsh >/dev/null 2>&1 || die 'virsh is required for VM layout checks.'
    health_dir=$run_log_dir/health
    mkdir -m 700 -- "$health_dir"
    health_deadline=$((SECONDS + health_timeout))
    step "Verify cluster health (timeout ${health_timeout}s)"
    while ((SECONDS < health_deadline)); do
        if check_cluster_health && check_console_route && ((SECONDS < health_deadline)); then
            verify_requested_configuration
            installed_version=$(jq -r '.status.desired.version // "unknown"' "$health_dir/clusterversion.json")
            pass 'API /readyz reports ready.'
            pass "All $((num_masters + num_workers)) nodes are Ready, uncordoned, and match the requested roles."
            pass "ClusterVersion $installed_version and all cluster operators are available and stable."
            pass 'All machine config pools are updated and ready.'
            pass 'All platform pods are Running and Ready or successfully completed.'
            if ((num_workers == 0)); then pass 'Control-plane nodes are schedulable for the zero-worker cluster.'; fi
            pass 'OpenShift console route is admitted and reachable from this host.'
            pass 'Cluster health checks passed.'
            printf 'INFO  Kubeconfig: %s\nINFO  Health details: %s\n' "$kubeconfig" "$health_dir"
            return 0
        fi
        remaining=$((health_deadline - SECONDS))
        ((remaining > 0)) || break
        delay=15
        ((remaining >= delay)) || delay=$remaining
        printf 'WAIT  Cluster is still settling; retry in %ss (%ss remaining).\n' "$delay" "$remaining"
        sleep "$delay"
    done
    health_diagnostics
    next 'After fixing the cluster, rerun with the same --config/--repo and --verify-only.'
    die "Cluster health checks timed out after ${health_timeout}s; see $health_dir."
}

# Read literal assignments only. Neither config validation nor --check-config
# sources a file, expands variables, or runs commands found in a value.
declare -A settings=() prior_settings=() profile=() existing_settings=()
declare -A setting_defaults=(
    [CLUSTER_NAME]=ostest [BASE_DOMAIN]=test.metalkube.org
    [OPENSHIFT_RELEASE_TYPE]=ga [OPENSHIFT_VERSION]=4.22.15
    [OPENSHIFT_RELEASE_STREAM]='' [OPENSHIFT_RELEASE_IMAGE]=''
    [NUM_MASTERS]=3 [NUM_WORKERS]=0 [IP_STACK]=v4 [HOST_IP_STACK]=''
    [MASTER_MEMORY]=32768 [MASTER_DISK]=80 [MASTER_VCPU]=12
    [WORKER_MEMORY]=8192 [WORKER_DISK]=60 [WORKER_VCPU]=4
    [VM_EXTRADISKS]=true [VM_EXTRADISKS_LIST]=vdb [VM_EXTRADISKS_SIZE]=150G
    [WORKING_DIR]=/opt/dev-scripts [PERSONAL_PULL_SECRET]="$script_dir/osac-inputs/pull-secret.json"
    [CI_TOKEN]='' [CI_SERVER]=api.ci.l2s4.p1.openshiftapps.com
)
trim_value() {
    trimmed=$1
    trimmed=${trimmed#"${trimmed%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
}
parse_literal() {
    local raw=$1 origin=$2 single="^'([^']*)'[[:space:]]*(#.*)?$" double='^"([^"\\]*)"[[:space:]]*(#.*)?$'
    trim_value "$raw"; raw=$trimmed
    if [[ $raw =~ $single || $raw =~ $double ]]; then
        parsed_value=${BASH_REMATCH[1]}
    else
        # Unquoted values may have a trailing comment but no embedded spaces.
        raw=${raw%%[[:space:]]#*}
        trim_value "$raw"; parsed_value=$trimmed
        [[ $parsed_value != *[[:space:]]* ]] || die "Quote values containing spaces ($origin)."
    fi
    # No shell expansion, command substitution, escaping, or quote injection.
    [[ $parsed_value != *[\$\`\\\"\'\;\&\|\<\>\(\)]* ]] || \
        die "Use a literal value without shell expressions ($origin)."
}
load_settings() {
    local path=$1 strict=$2 line key rhs line_number=0
    [[ -f $path && -r $path ]] || die "Configuration file is unreadable: $path"
    while IFS= read -r line || [[ -n $line ]]; do
        line_number=$((line_number + 1))
        trim_value "${line%$'\r'}"; line=$trimmed
        [[ -n $line && $line != \#* ]] || continue
        if [[ $line =~ ^(export[[:space:]]+)?([A-Z][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key=${BASH_REMATCH[2]}; rhs=${BASH_REMATCH[3]}
            if [[ -v setting_defaults[$key] ]]; then
                parse_literal "$rhs" "$path:$line_number ($key)"
                # existing_settings is consumed by merge_settings through a nameref.
                # shellcheck disable=SC2034
                if [[ $strict == true ]]; then profile[$key]=$parsed_value; else existing_settings[$key]=$parsed_value; fi
            elif [[ $strict == true ]]; then
                case "$key" in
                    SERVER_NAME|DEV_SCRIPTS_DIR|CI_TOKEN_FILE|LOG_DIR|HEALTH_TIMEOUT|STEP_TIMEOUT|CLEANUP_TIMEOUT|INPUTS_DIR|REPO_FILE|USE_SUBSCRIPTION_MANAGER|RHSM_ORG|RHSM_ACTIVATION_KEY_FILE)
                        parse_literal "$rhs" "$path:$line_number ($key)"
                        profile[$key]=$parsed_value ;;
                    *) die "Unknown installer setting $key at $path:$line_number; see --help and ocp-install.conf." ;;
                esac
            fi
        elif [[ $strict == true ]]; then
            die "Expected KEY=value or export KEY=value at $path:$line_number; shell commands are not allowed."
        fi
    done <"$path"
}
merge_settings() {
    local -n overrides=$1
    local key
    for key in OPENSHIFT_RELEASE_TYPE OPENSHIFT_RELEASE_STREAM OPENSHIFT_VERSION OPENSHIFT_RELEASE_IMAGE; do
        if [[ -v overrides[$key] ]]; then
            settings[OPENSHIFT_RELEASE_TYPE]=nightly
            settings[OPENSHIFT_RELEASE_STREAM]=''
            settings[OPENSHIFT_VERSION]=''
            settings[OPENSHIFT_RELEASE_IMAGE]=''
            if [[ -n ${overrides[OPENSHIFT_VERSION]:-} && ! -v overrides[OPENSHIFT_RELEASE_TYPE] ]]; then settings[OPENSHIFT_RELEASE_TYPE]=ga; fi
            break
        fi
    done
    for key in "${!setting_defaults[@]}"; do
        if [[ -v overrides[$key] ]]; then settings[$key]=${overrides[$key]}; fi
    done
}
validate_settings() {
    local key disk expected_stream
    for key in NUM_MASTERS MASTER_MEMORY MASTER_DISK MASTER_VCPU WORKER_MEMORY WORKER_DISK WORKER_VCPU; do
        [[ ${settings[$key]} =~ ^[1-9][0-9]{0,8}$ ]] || die "$key must be a positive integer."
    done
    [[ ${settings[NUM_WORKERS]} =~ ^(0|[1-9][0-9]{0,8})$ ]] || die 'NUM_WORKERS must be a nonnegative integer.'
    case "${settings[IP_STACK]}" in v4|v6|v4v6|v6v4) ;; *) die 'IP_STACK must be v4, v6, v4v6, or v6v4.' ;; esac
    case "${settings[HOST_IP_STACK]}" in ''|v4|v6|v4v6|v6v4) ;; *) die 'HOST_IP_STACK must be v4, v6, v4v6, or v6v4.' ;; esac
    [[ ${settings[CLUSTER_NAME]} =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ && ${#settings[CLUSTER_NAME]} -le 13 ]] || \
        die 'CLUSTER_NAME must be a lowercase DNS label, start with a letter, and be at most 13 characters (libvirt bridge names).'
    [[ ${settings[BASE_DOMAIN]} =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && ${settings[BASE_DOMAIN]} != *..* && ${#settings[BASE_DOMAIN]} -le 253 ]] || die 'BASE_DOMAIN must be a DNS domain without a scheme or trailing dot.'
    local -a domain_labels=()
    IFS=. read -r -a domain_labels <<<"${settings[BASE_DOMAIN]}"
    for key in "${domain_labels[@]}"; do
        [[ $key =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#key} -le 63 ]] || die 'BASE_DOMAIN contains an invalid DNS label.'
    done
    for key in WORKING_DIR PERSONAL_PULL_SECRET; do
        [[ ${settings[$key]} =~ ^/[A-Za-z0-9._/-]+$ ]] || die "$key must be an absolute path without spaces or shell expressions."
    done
    [[ ${settings[CI_TOKEN]} =~ ^[A-Za-z0-9~._/+=-]*$ ]] || die 'CI_TOKEN must contain only the token value, not an oc login command.'
    [[ ${settings[CI_SERVER]} =~ ^[A-Za-z0-9.-]+$ ]] || die 'CI_SERVER must be a hostname without https:// or a port.'
    case "${settings[VM_EXTRADISKS]}" in true|false) ;; *) die 'VM_EXTRADISKS must be true or false.' ;; esac
    [[ ${settings[VM_EXTRADISKS_SIZE]} =~ ^[1-9][0-9]{0,8}[GM]$ ]] || die 'VM_EXTRADISKS_SIZE needs an integer and M or G, such as 100G (GiB).'
    local -A seen_disks=()
    local -a extra_disks=()
    read -r -a extra_disks <<<"${settings[VM_EXTRADISKS_LIST]}"
    ((${#extra_disks[@]} > 0)) || die 'VM_EXTRADISKS_LIST cannot be empty.'
    for disk in "${extra_disks[@]}"; do
        [[ $disk =~ ^vd[a-z]+$ ]] || die 'VM_EXTRADISKS_LIST must contain space-separated virtio names such as "vdb vdc"; sda/sdb are reserved by this VM layout.'
        [[ ! -v seen_disks[$disk] ]] || die 'VM_EXTRADISKS_LIST contains duplicate disk names.'
        seen_disks[$disk]=1
    done
    settings[VM_EXTRADISKS_LIST]="${extra_disks[*]}"
    case "${settings[OPENSHIFT_RELEASE_TYPE]}" in
        ga)
            [[ ${settings[OPENSHIFT_VERSION]} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'GA requires a pinned OPENSHIFT_VERSION such as 4.22.15.'
            expected_stream=${settings[OPENSHIFT_VERSION]%.*}
            [[ -z ${settings[OPENSHIFT_RELEASE_STREAM]} || ${settings[OPENSHIFT_RELEASE_STREAM]} == "$expected_stream" ]] || die 'GA release stream conflicts with OPENSHIFT_VERSION; use nightly/ci plus a stream for a moving release.'
            settings[OPENSHIFT_RELEASE_STREAM]=$expected_stream
            ;;
        nightly|ci|okd)
            [[ -z ${settings[OPENSHIFT_VERSION]} ]] || die 'For nightly/ci/okd, leave OPENSHIFT_VERSION empty so dev-scripts derives it from the payload.'
            if [[ -z ${settings[OPENSHIFT_RELEASE_IMAGE]} ]]; then
                [[ ${settings[OPENSHIFT_RELEASE_TYPE]} != okd ]] || die 'OPENSHIFT_RELEASE_TYPE=okd requires OPENSHIFT_RELEASE_IMAGE.'
                [[ ${settings[OPENSHIFT_RELEASE_STREAM]} =~ ^[0-9]+\.[0-9]+$ ]] || die 'A nightly/ci release needs OPENSHIFT_RELEASE_STREAM, for example 4.22.'
            fi
            ;;
        *) die 'OPENSHIFT_RELEASE_TYPE must be ga, nightly, ci, or okd.' ;;
    esac
    [[ -z ${settings[OPENSHIFT_RELEASE_IMAGE]} || ${settings[OPENSHIFT_RELEASE_IMAGE]} =~ ^[A-Za-z0-9._:/@+-]+$ ]] || die 'OPENSHIFT_RELEASE_IMAGE must be a container image pull specification.'
}
show_settings() {
    local key
    printf 'CONFIG HEALTH_TIMEOUT=%s\nCONFIG DEV_SCRIPTS_DIR=%s\nCONFIG LOG_DIR=%s\nCONFIG KUBECONFIG=%s\nCONFIG STEP_TIMEOUT=%s\n' "$health_timeout" "$repo" "$log_dir" "$repo/ocp/$cluster_name/auth/kubeconfig" "$step_timeout"
    printf 'INFO  Installer config: %s\nINFO  dev-scripts checkout: %s\nINFO  Log directory: %s\n' "${installer_config:-none}" "$repo" "$log_dir"
    for key in CLUSTER_NAME BASE_DOMAIN OPENSHIFT_RELEASE_TYPE OPENSHIFT_RELEASE_STREAM OPENSHIFT_VERSION OPENSHIFT_RELEASE_IMAGE NUM_MASTERS NUM_WORKERS IP_STACK HOST_IP_STACK MASTER_MEMORY MASTER_DISK MASTER_VCPU WORKER_MEMORY WORKER_DISK WORKER_VCPU VM_EXTRADISKS VM_EXTRADISKS_LIST VM_EXTRADISKS_SIZE WORKING_DIR PERSONAL_PULL_SECRET; do
        printf 'CONFIG %s=%s\n' "$key" "${settings[$key]}"
    done
    if [[ -n ${settings[CI_TOKEN]} ]]; then pass 'CI_TOKEN is present (value hidden).'; else next 'Supply CI_TOKEN_FILE or CI_TOKEN; get the token from https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/'; fi
    if [[ ! -s ${settings[PERSONAL_PULL_SECRET]} ]]; then next 'Supply PERSONAL_PULL_SECRET; download it from https://console.redhat.com/openshift/install/pull-secret'; fi
}
write_settings() {
    local tmp key pattern
    [[ ! -L $state_dir ]] || die "Unsafe installer state directory: $state_dir"
    mkdir -p -m 700 -- "$state_dir"
    [[ -O $state_dir && $(stat -c %a -- "$state_dir") == 700 ]] || die "Installer state directory must be private: $state_dir"
    tmp=$(mktemp "$state_dir/.config_root.XXXXXX")
    pattern=$(IFS='|'; printf '%s' "${!setting_defaults[*]}")
    # Preserve upstream's other settings and comments. Replace this wrapper's
    # managed settings as a single block to make reruns idempotent.
    if [[ -f $source_config ]]; then
        awk -v keys="$pattern" '
            /^# BEGIN OCP INSTALLER SETTINGS$/ { block=1; next }
            /^# END OCP INSTALLER SETTINGS$/ { block=0; next }
            block { next }
            $0 ~ "^[[:space:]]*(export[[:space:]]+)?(" keys ")[[:space:]]*=" { next }
            { print }
        ' "$source_config" >"$tmp"
    else
        printf '#!/usr/bin/env bash\n# Additional dev-scripts options may be placed above the managed block.\n' >"$tmp"
    fi
    printf '# BEGIN OCP INSTALLER SETTINGS\nset +x\n' >>"$tmp"
    for key in "${!setting_defaults[@]}"; do
        printf "export %s='%s'\n" "$key" "${settings[$key]}" >>"$tmp"
    done
    printf 'set -x\n# END OCP INSTALLER SETTINGS\n' >>"$tmp"
    bash -n "$tmp" || { rm -f -- "$tmp"; die 'Generated configuration has invalid shell syntax.'; }
    chmod 600 -- "$tmp"
    mv -f -- "$tmp" "$config"
}

while (($#)); do
    case "$1" in
        --config|--repo|--ci-token-file|--pull-secret|--repo-file|--rhsm-org|--rhsm-activation-key-file|--from|--through|--health-timeout)
            (($# >= 2)) || die "$1 needs a value."
            [[ -n $2 ]] || die "$1 needs a nonempty value."
            [[ $2 != --* ]] || die "$1 needs a value before the next option."
            case "$1" in
                --config) installer_config_arg=$2 ;;
                --repo) repo_arg=$2 ;;
                --ci-token-file) ci_token_file_arg=$2 ;;
                --pull-secret) pull_secret_arg=$2 ;;
                --repo-file) repo_file_arg=$2 ;;
                --rhsm-org) rhsm_org=$2 ;;
                --rhsm-activation-key-file) rhsm_activation_key_file=$2 ;;
                --health-timeout) health_timeout_arg=$2 ;;
                --from) first_stage=$2; stage_selection=true ;;
                --through) last_stage=$2; stage_selection=true ;;
            esac
            shift 2
            ;;
        --check-config) check_config=true; shift ;;
        --config-json) check_config=true; config_json=true; shift ;;
        --preflight) preflight_only=true; shift ;;
        --verify-only) verify_only=true; shift ;;
        --use-subscription-manager) use_subscription_manager=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

# Reject contradictory inputs before logs, config creation, or host changes.
if [[ $verify_only == true ]]; then
    [[ $check_config == false && $stage_selection == false ]] || \
        die '--verify-only cannot be combined with --check-config, --from, or --through.'
    [[ -z $repo_file_arg && $use_subscription_manager == false ]] || \
        die '--verify-only cannot be combined with host repository setup options.'
fi
if [[ -n $repo_file_arg && $use_subscription_manager == true ]]; then
    die 'Choose either --repo-file or --use-subscription-manager.'
fi
if [[ -n $rhsm_org || -n $rhsm_activation_key_file ]]; then
    [[ $use_subscription_manager == true ]] || die 'RHSM inputs require --use-subscription-manager.'
    [[ $rhsm_org =~ ^[0-9]+$ && -n $rhsm_activation_key_file ]] || \
        die 'Supply both --rhsm-org (numeric ID) and --rhsm-activation-key-file.'
fi
for input_path in "$repo_file_arg" "$rhsm_activation_key_file"; do
    [[ -n $input_path ]] || continue
    [[ $input_path == /* && -f $input_path && -r $input_path && -s $input_path ]] || \
        die 'Repository and activation-key inputs must be nonempty readable files at absolute paths.'
done

stage_index() {
    local i
    for i in "${!stages[@]}"; do
        if [[ ${stages[$i]} == "$1" ]]; then
            printf '%s\n' "$i"
            return 0
        fi
    done
    return 1
}
first_index=$(stage_index "$first_stage") || die "Unknown --from stage: $first_stage"
last_index=$(stage_index "$last_stage") || die "Unknown --through stage: $last_stage"
((first_index <= last_index)) || die '--from must be at or before --through.'

[[ $check_config == true || $verify_only == true || $(id -u) -eq 0 ]] || die 'Run this installer as root.'

# Optional wrapper config; paths are resolved from the caller before cd.
installer_config=$installer_config_arg
if [[ -z $installer_config && -f $script_dir/ocp-install.conf ]]; then
    installer_config=$script_dir/ocp-install.conf
fi
if [[ -n $installer_config ]]; then
    installer_config=$(realpath -e -- "$installer_config") || die 'Installer config does not exist.'
    load_settings "$installer_config" true
fi
health_timeout=${health_timeout_arg:-${profile[HEALTH_TIMEOUT]:-1800}}
[[ $health_timeout =~ ^[1-9][0-9]{0,5}$ ]] || die 'HEALTH_TIMEOUT/--health-timeout must be a positive integer (seconds, at most 999999).'
repo_arg=${repo_arg:-${profile[DEV_SCRIPTS_DIR]:-}}
ci_token_file_arg=${ci_token_file_arg:-${profile[CI_TOKEN_FILE]:-}}
inputs_dir=${profile[INPUTS_DIR]:-$script_dir/osac-inputs}
[[ $inputs_dir =~ ^/[A-Za-z0-9_./-]+$ ]] || die 'INPUTS_DIR must be an absolute literal path'
step_timeout=${profile[STEP_TIMEOUT]:-7200}
[[ $step_timeout =~ ^[1-9][0-9]{0,4}$ ]] || die 'STEP_TIMEOUT must be 1..99999 seconds'
pull_secret_arg=${pull_secret_arg:-${profile[PERSONAL_PULL_SECRET]:-}}
log_dir=${profile[LOG_DIR]:-/tmp/ocp-install-logs}
[[ $log_dir == /* ]] || die 'LOG_DIR must be an absolute path.'

# A sibling checkout is the normal layout. Neither choice depends on cwd.
if [[ -z $repo_arg ]]; then
    if [[ -f $script_dir/Makefile && -f $script_dir/01_install_requirements.sh ]]; then repo_arg=$script_dir
    else repo_arg=$script_dir/dev-scripts; fi
fi
repo=$(realpath -m -- "$repo_arg")
repo_needs_clone=false
if [[ ! -d $repo/.git ]]; then
    [[ ! -e $repo && ! -L $repo ]] || die "dev-scripts path exists but is not a checkout: $repo"
    repo_needs_clone=true
fi
validate_checkout() {
    [[ -d $repo/.git ]] || die "dev-scripts checkout missing at $repo"
    local file
    for file in Makefile config_example.sh 01_install_requirements.sh 02_configure_host.sh 03_build_installer.sh 04_setup_ironic.sh 05_create_install_config.sh 06_create_cluster.sh; do
        [[ -f $repo/$file ]] || die "Checkout is missing $file: $repo"
    done
}
if [[ $repo_needs_clone == false ]]; then validate_checkout; fi
state_dir=$script_dir/.ocp-installer-state
config=$state_dir/config_root.sh
source_config=$config
[[ -e $source_config ]] || source_config=$repo/config_root.sh
for key in "${!setting_defaults[@]}"; do settings[$key]=${setting_defaults[$key]}; done
if [[ -e $source_config ]]; then
    bash -n "$source_config" 2>/dev/null || die "Invalid shell syntax: $source_config"
    load_settings "$source_config" false
    merge_settings existing_settings
fi
for key in "${!setting_defaults[@]}"; do prior_settings[$key]=${settings[$key]}; done

# Release selection is a group. A new stream alone means upstream's nightly
# selection, not the old pinned GA version. Explicit profile release choices
# replace the previous selection, so a stale image cannot silently win.
merge_settings profile
if [[ -v profile[SERVER_NAME] ]]; then
    [[ ! -v profile[CLUSTER_NAME] || ${profile[CLUSTER_NAME]} == "${profile[SERVER_NAME]}" ]] || die 'SERVER_NAME and CLUSTER_NAME conflict.'
    settings[CLUSTER_NAME]=${profile[SERVER_NAME]}
fi
if [[ -v profile[INPUTS_DIR] && ! -v profile[PERSONAL_PULL_SECRET] && -z $pull_secret_arg ]]; then
    settings[PERSONAL_PULL_SECRET]=$inputs_dir/pull-secret.json
fi
if [[ -z $ci_token_file_arg && -z ${settings[CI_TOKEN]} ]]; then ci_token_file_arg=$inputs_dir/ci-token.txt; fi
if [[ $verify_only == false && $check_config == false && -n $ci_token_file_arg ]]; then
    [[ $ci_token_file_arg == /* && -s $ci_token_file_arg && -r $ci_token_file_arg ]] || die 'CI_TOKEN_FILE/--ci-token-file needs a nonempty readable file at an absolute path.'
    settings[CI_TOKEN]=$(<"$ci_token_file_arg")
fi
if [[ -n $pull_secret_arg ]]; then settings[PERSONAL_PULL_SECRET]=$pull_secret_arg; fi
validate_settings
working_dir=${settings[WORKING_DIR]}
cluster_name=${settings[CLUSTER_NAME]}
num_masters=${settings[NUM_MASTERS]}
num_workers=${settings[NUM_WORKERS]}
[[ $(realpath -m -- "$working_dir") != "$repo" ]] || die 'WORKING_DIR must differ from the checkout directory.'
if [[ $check_config == true ]]; then
    if $config_json; then
        show_settings 2>/dev/null | python3 -c 'import json,sys; print(json.dumps(dict(line.removeprefix("CONFIG ").rstrip("\n").split("=",1) for line in sys.stdin if line.startswith("CONFIG "))))'
        exit 0
    fi
    show_settings
    if [[ $repo_needs_clone == true ]]; then
        printf 'INFO  dev-scripts will be cloned from %s to %s when installation runs.\n' "$dev_scripts_url" "$repo"
    else
        printf 'INFO  fresh installation runs fetch and select origin/master.\n'
    fi
    pass 'Configuration syntax and values checked; no files, host settings, or cluster resources were changed.'
    printf 'INFO  This does not test credential validity, release availability, or host capacity.\n'
    exit 0
fi

required_disk_mib=$(((num_masters * settings[MASTER_DISK] + num_workers * settings[WORKER_DISK] + 20) * 1024))
if [[ ${settings[VM_EXTRADISKS]} == true ]]; then
    read -r -a capacity_disks <<<"${settings[VM_EXTRADISKS_LIST]}"
    extra_mib=${settings[VM_EXTRADISKS_SIZE]%?}
    [[ ${settings[VM_EXTRADISKS_SIZE]: -1} != G ]] || extra_mib=$((extra_mib * 1024))
    required_disk_mib=$((required_disk_mib + (num_masters + num_workers) * ${#capacity_disks[@]} * extra_mib))
fi

# requirements refreshes Metal3, so inspect without writing in --preflight,
# apply the host compatibility change after requirements, then verify it before
# make configure. Keep all three modes on the same task parser.
# Query and mutation calls both need a deadline when systemd is unhealthy.
systemctl() {
    timeout --kill-after=5s 30s systemctl "$@"
}

libvirt_restart_task() {
    local mode=$1 monolithic=false qemu=false network=false target='' role
    case $mode in check|apply|verify) ;; *) die "Unknown libvirt task mode: $mode" ;; esac
    role=$working_dir/metal3-dev-env/vm-setup/roles/libvirt/tasks/network_setup_tasks.yml
    if [[ $mode == check && ! -f $role ]]; then
        printf 'INFO  Metal3 task is not present yet; requirements will fetch it, then configure will validate and patch it.\n'
        return 0
    fi
    [[ -f $role ]] || die "Metal3 libvirt task file is missing: $role"

    if systemctl is-active --quiet libvirtd.service || systemctl is-active --quiet libvirtd.socket; then monolithic=true; fi
    if systemctl is-active --quiet virtqemud.service || systemctl is-active --quiet virtqemud.socket; then qemu=true; fi
    if systemctl is-active --quiet virtnetworkd.service || systemctl is-active --quiet virtnetworkd.socket; then network=true; fi
    if [[ $monolithic == true && ( $qemu == true || $network == true ) ]]; then
        die 'Both monolithic and modular libvirt units are active; review the host layout.'
    elif [[ $qemu == true && $network == true ]]; then
        target=virtnetworkd.service
        pass 'Libvirt layout: modular (QEMU and network units active).'
    elif [[ $monolithic == true ]]; then
        target=libvirtd
        pass 'Libvirt layout: monolithic (libvirtd active).'
    elif [[ $(systemctl show -p LoadState --value virtqemud.socket) == loaded &&
            $(systemctl show -p LoadState --value virtnetworkd.socket) == loaded ]]; then
        # EL9 configure enables these sockets. Do not require that its startup
        # work already happened before allowing configure to run.
        target=virtnetworkd.service
        pass 'Libvirt layout: modular sockets installed; configure will start them.'
    elif [[ $(systemctl is-enabled libvirtd.service 2>/dev/null || true) == masked* ]]; then
        target=virtnetworkd.service
        pass 'Libvirt layout: monolithic service masked; configuring modular network daemon.'
    elif [[ $mode == check ]]; then
        printf 'INFO  Libvirt layout is not active yet; requirements will prepare it, then configure will recheck.\n'
    else
        die 'Cannot determine the libvirt layout; inspect libvirtd and modular sockets.'
    fi
    if [[ -n $target ]]; then
        [[ $(systemctl is-enabled "$target" 2>/dev/null || true) != masked* ]] || \
            die "Libvirt restart target $target is masked; inspect the host units."
    fi

    python3 - "$role" "$target" "$mode" <<'PY'
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
desired = sys.argv[2]
mode = sys.argv[3]
lines = path.read_text().splitlines(keepends=True)
headers = [i for i, line in enumerate(lines) if line.strip() == '- name: Restart libvirt']
if len(headers) != 1:
    raise SystemExit(f'FAIL  Expected exactly one Restart libvirt task in {path}; found {len(headers)}')
start = headers[0]
indent = len(lines[start]) - len(lines[start].lstrip(' \t'))
end = len(lines)
for i in range(start + 1, len(lines)):
    line = lines[i]
    if re.match(r'^[ \t]*-[ \t]+name:', line):
        next_indent = len(line) - len(line.lstrip(' \t'))
        if next_indent <= indent:
            end = i
            break
pattern = re.compile(r'^([ \t]*)name:[ \t]*([A-Za-z0-9_.-]+)[ \t]*(\r?\n?)$')
names = [(i, match) for i in range(start + 1, end)
         if (match := pattern.match(lines[i]))]
if len(names) != 1:
    raise SystemExit(f'FAIL  Expected one service name in Restart libvirt task; found {len(names)}')
index, match = names[0]
current = match.group(2)
if current not in {'libvirtd', 'libvirtd.service', 'virtnetworkd', 'virtnetworkd.service'}:
    raise SystemExit(f'FAIL  Unexpected Metal3 restart target {current!r}; inspect {path}')
if mode == 'check':
    if not desired:
        print(f'INFO  Metal3 restart task is patchable ({current}); host target will be chosen after requirements')
    elif current == desired:
        print(f'PASS  Metal3 already restarts {desired}')
    else:
        print(f'INFO  Metal3 currently restarts {current}; installer will change it to {desired} after requirements')
    raise SystemExit(0)
if mode == 'verify':
    if current != desired:
        raise SystemExit(f'FAIL  Metal3 restarts {current}, expected {desired}; refusing make configure')
    print(f'PASS  Metal3 restart target verified: {desired}')
    raise SystemExit(0)
if current == desired:
    print(f'PASS  Metal3 already restarts {desired}')
    raise SystemExit(0)
lines[index] = f'{match.group(1)}name: {desired}{match.group(3)}'
old_mode = stat.S_IMODE(path.stat().st_mode)
tmp_path = None
try:
    with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=path.parent,
                                     prefix='.ocp-libvirt-', delete=False) as tmp:
        tmp.writelines(lines)
        tmp_path = Path(tmp.name)
    os.chmod(tmp_path, old_mode)
    os.replace(tmp_path, path)
finally:
    if tmp_path is not None:
        tmp_path.unlink(missing_ok=True)
print(f'FIXED Metal3 restart target: {current} -> {desired}')
PY
}

deployment_lock() {
    local mode=$1 key
    local -a values=()
    for key in "${!setting_defaults[@]}"; do
        case $key in CI_TOKEN|CI_SERVER|PERSONAL_PULL_SECRET) continue ;; esac
        values+=("$key=${settings[$key]}")
    done
    python3 - "$state_dir" "$repo" "$cluster_name" "$config" "$mode" "$first_index" "${values[@]}" <<'LOCKPY'
import hashlib, json, os, re, subprocess, sys, tempfile
from pathlib import Path
state_root, repo, name, config, mode, first = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]), sys.argv[5], int(sys.argv[6])
settings = dict(item.split('=', 1) for item in sys.argv[7:])
directory = state_root / name
assets = repo / 'ocp' / name
lock = directory / '.ocp-installer-inputs.json'
release = directory / '.ocp-installer-release'
binary = assets / 'openshift-install'
def fail(message):
    sys.exit('FAIL ' + message)
def atomic(path, content):
    if path.is_symlink():
        fail('Deployment metadata must not be a symlink')
    fd, temp = tempfile.mkstemp(prefix='.ocp-input-', dir=directory)
    try:
        with os.fdopen(fd, 'w') as out:
            out.write(content)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp): os.unlink(temp)
revision = subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'], text=True, timeout=20).strip()
# Track advanced upstream settings without recording credentials in metadata.
excluded = set(settings) | {'CI_TOKEN','CI_SERVER','PERSONAL_PULL_SECRET'}
advanced = []
if config.exists():
    for line in config.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#') or line in ('set +x','set -x'): continue
        match = re.match(r'(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=', line)
        if match and match[1] in excluded: continue
        advanced.append(line)
expected = dict(settings=settings, revision=revision, advanced_sha256=hashlib.sha256('\n'.join(advanced).encode()).hexdigest())
record = dict(expected)
if lock.exists() or lock.is_symlink():
    try:
        if lock.is_symlink(): raise ValueError()
        record = json.loads(lock.read_text())
        if any(record.get(k) != v for k,v in expected.items()):
            fail('Deployment settings or dev-scripts revision changed; restore the original inputs or teardown before a new installation')
    except (OSError, ValueError, AttributeError):
        fail('Invalid saved deployment inputs; preserve them and inspect before resuming')
if mode in ('init', 'check') and record.get('installer_sha256') and first >= 4:
    if not binary.is_file() or hashlib.sha256(binary.read_bytes()).hexdigest() != record['installer_sha256']:
        fail('Installer binary differs from this deployment; restore the original before resuming')
metadata = assets / 'release_info.json'
if mode == 'built' or (mode == 'init' and not lock.exists() and first >= 3 and metadata.is_file()):
    try:
        info = json.loads(metadata.read_text())
        digest, image = info['digest'], info['image']
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest) or not isinstance(image, str): raise ValueError()
        image = image.split('@')[0]
        if ':' in image.rsplit('/',1)[-1]: image = image.rsplit(':',1)[0]
        record['release_image'] = image + '@' + digest
        record['installer_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        atomic(release, record['release_image'] + '\n')
    except (OSError, KeyError, TypeError, ValueError):
        fail('Cannot pin installer/release metadata; inspect build_installer outputs')
if release.exists() or release.is_symlink():
    if release.is_symlink() or not re.fullmatch(r'[A-Za-z0-9._:/@+-]+\n?', release.read_text()):
        fail('Invalid saved release selection')
    if record.get('release_image') and release.read_text().strip() != record['release_image']:
        fail('Saved release digest differs from deployment metadata')
if mode != 'check':
    directory.mkdir(parents=True, exist_ok=True)
    atomic(lock, json.dumps(record, indent=2, sort_keys=True) + '\n')
LOCKPY
}

# Ask the fetched dev-scripts code to select the release, then freeze that
# selection through its supported OPENSHIFT_RELEASE_IMAGE setting. This runs
# only after requirements has installed oc and the other prerequisites.
resolve_release_image() {
    local image
    image=$(timeout --kill-after=5s 1800s env CONFIG="$config" bash -c '
        # common.sh enables xtrace with a PS4 that expands BASH_SOURCE. In a
        # bash -c top-level context, BASH_SOURCE can be unset, so defer nounset
        # until after sourcing common.sh and disabling its xtrace.
        set -Eeo pipefail
        cd -- "$1"
        source common.sh >/dev/null 2>&1
        set +x
        set -u
        source utils.sh >/dev/null 2>&1
        write_pull_secret >/dev/null 2>&1
        oc adm release info --registry-config "$PULL_SECRET_FILE" "$OPENSHIFT_RELEASE_IMAGE" -o json |
            jq -er '\''select(.digest | test("^sha256:[a-f0-9]{64}$")) | .digest as $digest | (.image | split("@")[0] | sub(":([^/:]+)$"; "")) + "@" + $digest'\''
    ' _ "$repo") || die 'Could not resolve the OpenShift release through upstream dev-scripts; inspect the selected image, pull secret and registry access.'
    [[ $image =~ ^[A-Za-z0-9._:/+-]+@sha256:[a-f0-9]{64}$ ]] || die 'Invalid resolved release image.'
    settings[OPENSHIFT_RELEASE_IMAGE]=$image
    write_settings
    pass "Pinned OpenShift release in external config: $image"
}

prepare_ironic_cache() {
    local details image expected file archive sum_tmp
    details=$(timeout --kill-after=5s 120s env CONFIG="$config" bash -c '
        # common.sh enables xtrace with a PS4 that expands BASH_SOURCE. In a
        # bash -c top-level context, BASH_SOURCE can be unset, so defer nounset
        # until after sourcing common.sh and disabling its xtrace.
        set -Eeo pipefail
        cd -- "$1"
        source common.sh >/dev/null 2>&1
        set +x
        set -u
        source rhcos.sh >/dev/null 2>&1
        printf "%s %s\\n" "$MACHINE_OS_BOOTSTRAP_IMAGE_NAME" "$MACHINE_OS_BOOTSTRAP_IMAGE_SHA256"
    ' _ "$repo") || die 'Cannot inspect the upstream RHCOS image selection before make ironic.'
    read -r image expected <<<"$details"
    [[ $image =~ ^[A-Za-z0-9._+-]+$ && $expected =~ ^[a-fA-F0-9]{64}$ ]] || die 'Upstream supplied an invalid RHCOS image name or checksum.'
    file=$working_dir/ironic/html/images/$image
    mkdir -p -- "$(dirname -- "$file")"
    if [[ -e $file || -L $file ]]; then
        [[ -f $file && ! -L $file ]] || die "Unsafe cached RHCOS image: $file"
        if ! printf '%s  %s\n' "$expected" "$file" | sha256sum --status --check -; then
            archive=$file.invalid-$(date -u +%Y%m%dT%H%M%SZ)
            mv -- "$file" "$archive"
            [[ ! -e $file.sha256sum ]] || mv -- "$file.sha256sum" "$archive.sha256sum"
            warn "Archived corrupt or outdated RHCOS cache: $archive"
        else
            chmod 0644 -- "$file"
            [[ ! -L $file.sha256sum ]] || die "Unsafe RHCOS checksum sidecar: $file.sha256sum"
            sum_tmp=$(mktemp "$file.sha256sum.XXXXXX")
            printf '%s  %s\n' "$expected" "$image" >"$sum_tmp"
            chmod 0644 -- "$sum_tmp"
            mv -f -- "$sum_tmp" "$file.sha256sum"
        fi
    fi
    # The upstream download happens inside make ironic. A default ACL lets the
    # HTTP container read newly created files while this wrapper keeps umask 077.
    command -v setfacl >/dev/null || die 'setfacl is required for private wrapper umask and public RHCOS downloads.'
    setfacl -m d:o::r--,d:m::r-x -- "$(dirname -- "$file")" || die 'Could not set image directory default ACL.'
}

prepare_install_config() {
    local path=$repo/ocp/$cluster_name/install-config.yaml status archive tmp
    if [[ -e $path ]]; then
        [[ ! -L $path ]] || die 'Installation configuration must not be a symlink'
        if validate_install_config_file "$path"; then
            if [[ -e $path.save || -L $path.save ]]; then
                if [[ ! -f $path.save || -L $path.save ]] || ! cmp -s "$path" "$path.save"; then
                    die 'Working and saved install configurations differ; inspect both before retrying'
                fi
            else
                [[ ! -e $repo/ocp/$cluster_name/.openshift_install_state.json && ! -e $repo/ocp/$cluster_name/auth/kubeconfig ]] || \
                    die 'Cannot reconstruct the original configuration after installation started'
                tmp=$(mktemp "$path.save.XXXXXX")
                cp -- "$path" "$tmp"
                chmod 600 "$tmp"
                mv -- "$tmp" "$path.save"
                pass 'Saved the complete pre-installation configuration for future recovery.'
            fi
            return 0
        else
            status=$?
        fi
        ((status == 2)) || die 'Existing installation plan differs from requested settings; inspect it before retrying'
        [[ ! -e $repo/ocp/$cluster_name/.openshift_install_state.json && ! -e $repo/ocp/$cluster_name/auth/kubeconfig ]] || \
            die 'Cannot regenerate a plan after installer state or credentials exist'
        archive=$(mktemp -d "$run_log_dir/incomplete-install-config.XXXXXX")
        mv -- "$path" "$archive/"
        if [[ -e $path.save ]]; then mv -- "$path.save" "$archive/"; fi
        warn "Archived incomplete pre-installation configuration to $archive; it will be regenerated"
    fi
}

validate_install_config_file() {
    command -v yq >/dev/null || { printf 'FAIL yq is required to validate installation plans\n' >&2; return 1; }
    python3 - "$1" "$cluster_name" "${settings[BASE_DOMAIN]}" "$num_masters" "$num_workers" "${settings[IP_STACK]}" <<'CONFIGPY'
import ipaddress, json, subprocess, sys
# Exit 2: incomplete/invalid generated file; exit 3: a complete but different plan.
def fail(message, code=2):
    print('FAIL Install configuration: ' + message, file=sys.stderr)
    sys.exit(code)
try:
    # dev-scripts installs Python yq (JSON by default); some existing hosts use
    # Go yq (requires -o=json). Support both without sourcing the YAML as code.
    version = subprocess.run(['yq', '--version'], capture_output=True, text=True, timeout=20)
    args = ['yq', '-o=json', '.'] if 'mikefarah' in version.stdout else ['yq', '.']
    result = subprocess.run(args + [sys.argv[1]], capture_output=True, text=True, timeout=20)
    if result.returncode:
        fail('cannot parse YAML')
    data = json.loads(result.stdout)
    if not isinstance(data, dict) or data.get('apiVersion') != 'v1':
        fail('missing apiVersion v1')
    name, domain = data['metadata']['name'], data['baseDomain']
    masters = data['controlPlane']['replicas']
    compute = data['compute']
    if not isinstance(compute, list) or len(compute) != 1 or compute[0].get('name') != 'worker':
        fail('expected one worker compute pool')
    workers = compute[0]['replicas']
    if type(masters) is not int or type(workers) is not int:
        fail('replicas must be integers')
    network = data['networking']
    if not network.get('networkType'):
        fail('missing network type')
    families = []
    for field in ('clusterNetwork', 'serviceNetwork', 'machineNetwork'):
        entries = network[field]
        if not isinstance(entries, list) or not entries:
            fail('missing network CIDRs')
        families.append([ipaddress.ip_network(e if isinstance(e, str) else e['cidr'], strict=False).version for e in entries])
    hosts = data['platform']['baremetal']['hosts']
    if not isinstance(hosts, list) or len(hosts) < masters + workers:
        fail('missing baremetal hosts')
    macs = []
    for host in hosts:
        if not host.get('name') or not host.get('bootMACAddress') or not host.get('bmc', {}).get('address'):
            fail('incomplete baremetal host')
        macs.append(host['bootMACAddress'].lower())
    if len(macs) != len(set(macs)):
        fail('duplicate host boot MAC address')
    secret = json.loads(data['pullSecret'])
    if not isinstance(secret.get('auths'), dict) or not secret['auths'] or not data.get('sshKey'):
        fail('missing pull secret or SSH key')
except (OSError, subprocess.TimeoutExpired):
    fail('YAML parser unavailable or timed out', 1)
except (KeyError, TypeError, ValueError, AttributeError):
    fail('invalid or incomplete required fields')
if (name, domain, masters, workers) != (sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])):
    fail('identity/topology differs from requested settings; preserve and inspect it', 3)
expected = {'v4':[4], 'v6':[6], 'v4v6':[4,6], 'v6v4':[6,4]}[sys.argv[6]]
if families[0] != expected or families[1] != expected:
    fail('cluster/service IP families differ from requested settings', 3)
CONFIGPY
}

verify_install_config_topology() {
    local path=${1:-$repo/ocp/$cluster_name/install-config.yaml}
    [[ -s $path ]] || die "Install configuration missing: $path; inspect existing cluster assets before resuming."
    validate_install_config_file "$path" || die "Invalid installation plan: $path"
    pass 'Installation plan identity, topology, networks and required inputs validated.'
}

verify_saved_install_config() {
    local cluster_dir=$repo/ocp/$cluster_name saved working saved_name saved_domain
    saved=$cluster_dir/install-config.yaml.save
    working=$cluster_dir/install-config.yaml
    [[ -s $saved && -r $saved ]] || die "Installer state exists but the original install configuration is missing: $saved. Do not generate a new configuration in this installation directory."
    command -v yq >/dev/null 2>&1 || die 'yq is required to validate the saved install configuration.'
    saved_name=$(yq -r '.metadata.name // ""' "$saved" 2>/dev/null) || die "Cannot parse saved install configuration: $saved"
    saved_domain=$(yq -r '.baseDomain // ""' "$saved" 2>/dev/null) || die "Cannot parse saved install configuration: $saved"
    [[ $saved_name == "$cluster_name" && $saved_domain == "${settings[BASE_DOMAIN]}" ]] || \
        die "Saved install configuration targets $saved_name.$saved_domain, but this run requests $cluster_name.${settings[BASE_DOMAIN]}. Inspect the original installation settings."
    verify_install_config_topology "$saved"
    if [[ -e $working ]]; then
        [[ -f $working && -s $working ]] || die "Unexpected working install configuration: $working"
        cmp -s -- "$working" "$saved" || die "Working install configuration differs from the saved original: $working. Inspect both before resuming."
    fi
    pass 'Saved installation plan matches the requested cluster identity and topology.'
}


guard_installation_state() {
    local name directory state credentials artifact plan
    for name in "${prior_settings[CLUSTER_NAME]}" "$cluster_name"; do
        directory=$repo/ocp/$name
        state=$directory/.openshift_install_state.json
        credentials=$directory/auth/kubeconfig
        if [[ -e $state || -L $state ]]; then
            [[ -f $state && ! -L $state && -s $state ]] || die "Invalid installer state: $state"
            python3 - "$state" <<'STATEPY'
import json, sys
from pathlib import Path
try:
    value = json.loads(Path(sys.argv[1]).read_text())
    assert isinstance(value, dict) and value
except (ValueError, OSError, AssertionError):
    sys.exit('FAIL Installer state is empty or invalid JSON; preserve it and inspect before recovery')
STATEPY
            ((first_index >= 4)) || die "Installer state already exists; $first_stage would repeat host/provisioning setup. Resume with --from ocp_run, or use --verify-only."
            [[ $name == "$cluster_name" ]] || die 'Previous cluster assets exist under a different name; teardown or restore the original settings'
            verify_saved_install_config
            [[ -x $directory/openshift-install ]] || die 'Original openshift-install binary is missing; restore it before resuming'
        else
            for artifact in "$credentials" "$directory"/{bootstrap,master,worker}.ign "$directory/metadata.json"; do
                [[ ! -e $artifact && ! -L $artifact ]] || die "Installer assets exist without state: $artifact; preserve them and inspect before recovery"
            done
        fi
    done
    # Persistent libvirt definitions and disks survive missing local cluster
    # metadata. Never infer a clean host solely from an absent kubeconfig.
    plan=$working_dir/$cluster_name/ironic_nodes.json
    python3 - "$working_dir" "$cluster_name" "$plan" "$first_index" <<'INVENTORYPY'
import sys
from pathlib import Path
work, name, plan, first = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), int(sys.argv[4])
resources = list(Path('/etc/libvirt/qemu').glob(name + '_*.xml'))
resources += [p for p in (Path('/etc/libvirt/qemu/networks') / (name + suffix + '.xml') for suffix in ('bm','pr')) if p.exists()]
resources += list((work / 'pool').glob(name + '_*.qcow2')) + list((work / 'pool').glob(name + '_*_vd*.img'))
has_plan = plan.is_file() and plan.stat().st_size > 0
if resources and not has_plan:
    sys.exit('FAIL Existing cluster VM/network/disk resources have no node plan; inspect or teardown before installing')
if (resources or has_plan) and first == 0:
    sys.exit('FAIL Existing host provisioning found; use an explicit --from stage after inspection, or teardown for a fresh installation')
INVENTORYPY
}

validate_installer_mode() {
    python3 - "$source_config" "$repo" "$cluster_name" <<'MODEPY'
import os, re, shlex, sys
from pathlib import Path
keys = ('KNI_INSTALL_FROM_GIT', 'OPENSHIFT_INSTALLER')
values = {key: os.environ.get(key, '') for key in keys}
path = Path(sys.argv[1])
if path.is_file():
    for line in path.read_text().splitlines():
        match = re.match(r'^\s*(?:export\s+)?(KNI_INSTALL_FROM_GIT|OPENSHIFT_INSTALLER)\s*=(.*)$', line)
        if match:
            try:
                parts = shlex.split(match[2], comments=True)
                if len(parts) > 1: raise ValueError()
                values[match[1]] = parts[0] if parts else ''
            except ValueError:
                sys.exit('FAIL Installer selection must use a literal value')
default = Path('ocp') / sys.argv[3] / 'openshift-install'
allowed = ('', str(default), str(Path(sys.argv[2]) / default))
if values['KNI_INSTALL_FROM_GIT'] or values['OPENSHIFT_INSTALLER'] not in allowed:
    sys.exit('FAIL This wrapper pins the release-extracted installer; source builds and custom installer paths need a separate dev-scripts workflow')
MODEPY
}

if [[ $verify_only == false ]]; then validate_installer_mode; fi

if $preflight_only; then
    [[ ! -s $repo/ocp/$cluster_name/auth/kubeconfig ]] || die 'An OCP cluster already exists; use --verify-only, or teardown before a fresh installation'
    # Local validation only: no checkout update, package install, or cluster calls.
    command -v python3 >/dev/null || die 'Missing tool: python3'
    python3 - "${settings[PERSONAL_PULL_SECRET]}" "${settings[WORKING_DIR]}" "${settings[MASTER_MEMORY]}" "$num_masters" "${settings[WORKER_MEMORY]}" "$num_workers" "$required_disk_mib" <<'PREFLIGHTPY'
import json, os, platform, shutil, sys
from pathlib import Path
try:
    data = json.loads(Path(sys.argv[1]).read_bytes())
    if not isinstance(data, dict) or not isinstance(data.get('auths'), dict) or not data['auths']:
        raise ValueError()
except (OSError, ValueError):
    sys.exit('FAIL Supply a readable pull-secret JSON with nonempty auths')
if os.geteuid() != 0:
    sys.exit('FAIL OCP installation requires root')
if platform.machine() != 'x86_64' or not Path('/dev/kvm').exists():
    sys.exit('FAIL An x86_64 host with /dev/kvm is required')
info = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
if info.get('ID', '').strip('"') not in {'rhel', 'centos', 'almalinux', 'rocky'} or not info.get('VERSION_ID', '').strip('"').startswith('9'):
    sys.exit('FAIL A supported RHEL-family 9 host is required')
work = Path(sys.argv[2])
while not work.exists():
    work = work.parent
if shutil.disk_usage(work).free < int(sys.argv[7]) * 1024**2:
    sys.exit(f'FAIL Requested VM disks plus overhead need {int(sys.argv[7]) // 1024} GiB free space')
mem = int(next(line.split()[1] for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemTotal:'))) // 1024
requested = int(sys.argv[3])*int(sys.argv[4]) + int(sys.argv[5])*int(sys.argv[6]) + 4096
if mem < requested:
    sys.exit(f'FAIL Requested VM layout needs {requested} MiB RAM including host overhead')
print('PASS Local OCP host and input checks; authentication/package access are checked during installation')
PREFLIGHTPY
    [[ -n ${settings[CI_TOKEN]} ]] || die 'Supply CI_TOKEN_FILE or CI_TOKEN'
    libvirt_restart_task check
    exit 0
fi

command -v flock >/dev/null || die 'Missing tool: flock (util-linux)'
[[ ! -L /run/lock/osac-ocp.lock ]] || die 'Unsafe OCP lock'
if [[ ${OCP_CHAIN_LOCK_FD:-} == 7 && -e /proc/self/fd/7 && /proc/self/fd/7 -ef /run/lock/osac-ocp.lock ]]; then
    flock -n 7 || die 'OCP operation lock unavailable'
else
    exec 7>/run/lock/osac-ocp.lock
    flock -n 7 || die 'Another OCP install, teardown or chain is active on this host'
fi
trap 'stop_stage 130' INT
trap 'stop_stage 143' TERM
if [[ $verify_only == false ]]; then guard_installation_state; fi

# Updating VM settings is for a fresh installation, not an in-place resize.
# Guard both the old and selected cluster name before writing config_root.sh.
if [[ $verify_only == false ]] && ((first_index == 0)); then
    for name in "${prior_settings[CLUSTER_NAME]}" "$cluster_name"; do
        [[ ! -s $repo/ocp/$name/auth/kubeconfig ]] || die "A cluster kubeconfig already exists at ocp/$name/auth/kubeconfig. Inspect the cluster before starting from requirements."
    done
fi
prior_plan=${prior_settings[WORKING_DIR]}/${prior_settings[CLUSTER_NAME]}/ironic_nodes.json
# Compare with prior settings only when this bundle has saved its own config.
# Otherwise the defaults above are not prior installation settings and can
# conflict with leftover dev-scripts artifacts from an earlier stage.
if [[ $verify_only == false && -e $config ]] && [[ -s $prior_plan || -s $repo/ocp/${prior_settings[CLUSTER_NAME]}/.openshift_install_state.json ]]; then
    for key in CLUSTER_NAME BASE_DOMAIN WORKING_DIR OPENSHIFT_RELEASE_TYPE OPENSHIFT_RELEASE_STREAM OPENSHIFT_VERSION OPENSHIFT_RELEASE_IMAGE NUM_MASTERS NUM_WORKERS IP_STACK HOST_IP_STACK MASTER_MEMORY MASTER_DISK MASTER_VCPU WORKER_MEMORY WORKER_DISK WORKER_VCPU VM_EXTRADISKS VM_EXTRADISKS_LIST VM_EXTRADISKS_SIZE; do
        [[ ${settings[$key]} == "${prior_settings[$key]}" ]] || die "$key differs from the existing installation settings. Inspect the previous installation before changing its layout or release; this installer does not modify a live cluster in place."
    done
fi

# tee captures both this wrapper and the Makefile subprocesses. mktemp creates
# the log with mode 600; the directory is mode 700, and all filenames are kept
# outside the dev-scripts checkout. A new run never overwrites an older log.
# /tmp is shared: refuse a pre-existing link or a directory another user can
# access, rather than following it while writing potentially sensitive logs.
if ! mkdir -m 700 -- "$log_dir" 2>/dev/null; then
    [[ -d $log_dir && ! -L $log_dir && $(stat -c %u -- "$log_dir") == "$EUID" ]] || \
        die "Unsafe log directory: $log_dir must be a real directory owned by the current user."
    log_dir_mode=$(stat -c %a -- "$log_dir")
    (((8#$log_dir_mode & 077) == 0)) || die "Restrict log directory permissions to 700: $log_dir"
fi
log_file=$(mktemp "$log_dir/ocp-install-$(date +%Y%m%d-%H%M%S).XXXXXX.log")
status_file=${log_file%.log}.status
run_log_dir=${log_file%.log}.d
dev_scripts_log_dir=$run_log_dir/dev-scripts
mkdir -m 700 -- "$run_log_dir" "$dev_scripts_log_dir"
started_at=$(date --iso-8601=seconds)
write_running_status
ln -sfnT -- "$(basename -- "$log_file")" "$log_dir/latest.log"
ln -sfnT -- "$(basename -- "$status_file")" "$log_dir/latest.status"
ln -sfnT -- "$(basename -- "$run_log_dir")" "$log_dir/latest.d"
exec > >(tee -a "$log_file") 2>&1
trap on_exit EXIT
printf 'INFO  Started: %s\nINFO  Log: %s\nINFO  Status: %s\nINFO  Details: %s\n' \
    "$started_at" "$log_file" "$status_file" "$run_log_dir"
if [[ $verify_only == true ]]; then
    verify_cluster_health
    exit 0
fi
pass 'Root has the privileges dev-scripts needs; passwordless sudo is not needed.'

stage=$first_stage
write_running_status
if ! command -v git >/dev/null 2>&1; then
    step 'Install git for the dev-scripts checkout'
    run_bounded dnf install -y git || die 'Could not install git; install it and retry.'
fi
if [[ $repo_needs_clone == true ]]; then
    ((first_index == 0)) || die 'Cannot resume a missing dev-scripts checkout; restore the original checkout or start a fresh installation.'
    step "Clone current dev-scripts origin/master into $repo"
    mkdir -p -- "$(dirname -- "$repo")"
    run_bounded env GIT_TERMINAL_PROMPT=0 git clone --branch master --single-branch -- "$dev_scripts_url" "$repo" || die "Could not clone dev-scripts into $repo; inspect that path before retrying."
    validate_checkout
else
    [[ $(git -C "$repo" remote get-url origin) == "$dev_scripts_url" ]] || die "Checkout origin differs from $dev_scripts_url; inspect $repo before refreshing."
    step 'Fetch current dev-scripts origin/master'
    run_bounded env GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch --prune origin master
    if ((first_index == 0)); then
        if [[ -n $(git -C "$repo" status --porcelain --untracked-files=normal) ]]; then
            backup_root=$script_dir/.ocp-installer-backups
            mkdir -p -m 700 -- "$backup_root"
            [[ -O $backup_root && ! -L $backup_root && $(stat -c %a -- "$backup_root") == 700 ]] || die 'Checkout backup directory is not private.'
            snapshot=$(mktemp -d "$backup_root/dev-scripts-before-refresh-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
            cp -a -- "$repo/." "$snapshot/" || die 'Could not preserve the modified checkout before refresh.'
            pass "Preserved modified checkout: $snapshot"
        fi
        git -C "$repo" reset --hard origin/master || die 'Could not select origin/master; the preserved checkout is in the run details.'
        [[ -z $(git -C "$repo" status --porcelain --untracked-files=normal) ]] || die 'Untracked checkout files remain after refresh; preserve and inspect them before installation.'
        validate_checkout
    else
        [[ $(git -C "$repo" rev-parse HEAD) == $(git -C "$repo" rev-parse origin/master) ]] || die 'The upstream revision changed during this partial installation; preserve the assets and start fresh after teardown.'
    fi
fi
pass "Using dev-scripts revision: $(git -C "$repo" rev-parse --short=12 HEAD)"

cd "$repo"
# A clean fresh installation may supersede external metadata from a previous run.
# Preserve that metadata with this run; never create ocp/<cluster> before requirements.
if ((first_index == 0)) && [[ -d $state_dir/$cluster_name ]]; then
    [[ ! -e $repo/ocp/$cluster_name/.openshift_install_state.json && ! -e $repo/ocp/$cluster_name/auth/kubeconfig && ! -s $working_dir/$cluster_name/ironic_nodes.json ]] || die 'Previous cluster state remains; inspect or teardown before starting from requirements.'
    mv -- "$state_dir/$cluster_name" "$run_log_dir/previous-deployment-state"
fi
deployment_lock check
show_settings
# Supply the external config through dev-scripts' CONFIG setting.
write_settings
pass "Configuration saved: $config"
if [[ -z ${settings[CI_TOKEN]} || ! -s ${settings[PERSONAL_PULL_SECRET]} ]]; then
    next "Edit ${installer_config:-$config}, supply CI_TOKEN/CI_TOKEN_FILE and PERSONAL_PULL_SECRET, then rerun the same command."
    die 'Required credentials are missing; no OpenShift installation stages were run.'
fi
if [[ -n $ci_token_file_arg ]]; then chmod 600 -- "$ci_token_file_arg"; fi
if [[ -n $installer_config ]]; then chmod 600 -- "$installer_config"; fi

# This wrapper targets x86_64/libvirt. Architecture and physical-node layouts
# need different configuration and should be reviewed before host mutation.
[[ -r /etc/os-release ]] || die 'Cannot read /etc/os-release.'
# shellcheck disable=SC1091
. /etc/os-release
case "${ID}:${VERSION_ID}" in
    rhel:9*|centos:9*|almalinux:9*|rocky:9*) ;;
    *) die "Unsupported OS: ${PRETTY_NAME:-${ID}:${VERSION_ID}}" ;;
esac
pass "OS: ${PRETTY_NAME:-${ID}:${VERSION_ID}}"
[[ $(uname -m) == x86_64 ]] || die 'This wrapper covers x86_64; see the dev-scripts ARM instructions for aarch64.'
pass 'CPU architecture: x86_64; ARM setup is not needed.'
printf 'INFO  CPUs: %s\n' "$(nproc)"
[[ -c /dev/kvm ]] || die '/dev/kvm is missing; hardware virtualization must be available.'
pass '/dev/kvm is available.'
if [[ $(systemd-detect-virt 2>/dev/null || true) != none ]]; then
    warn 'Host appears virtualized; nested virtualization must work for libvirt VMs.'
else
    pass 'Bare-metal host.'
fi
mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
requested_ram=$((num_masters * settings[MASTER_MEMORY] + num_workers * settings[WORKER_MEMORY]))
((mem_kib / 1024 >= requested_ram + 4096)) || die "Host needs at least $((requested_ram + 4096)) MiB RAM for the requested VMs plus host overhead"
if ((mem_kib < 64 * 1024 * 1024)); then
    warn "RAM: $((mem_kib / 1024 / 1024)) GiB; README recommends at least 64 GiB."
else
    pass "RAM: $((mem_kib / 1024 / 1024)) GiB."
fi

# Read managed values from the already-validated configuration, not the
# environment or shell evaluation. This also keeps CI credentials out of logs.
config_value() {
    if [[ -v settings[$1] ]]; then printf '%s\n' "${settings[$1]}"
    else
        awk -v key="$1" '$0 ~ "^[[:space:]]*(export[[:space:]]+)?" key "=" {value=$0; sub(/^[^=]*=/,"",value); gsub(/^[\042\047]|[\042\047]$/,"",value)} END {print value}' "$config"
    fi
}
case "$(config_value NODES_PLATFORM)" in
    ''|libvirt) pass 'Cluster nodes: libvirt VMs.' ;;
    *) die 'This wrapper covers libvirt VM nodes; see dev-scripts for physical node configuration.' ;;
esac
pass "Requested cluster topology: $num_masters masters and $num_workers workers."

nodes_plan=$working_dir/$cluster_name/ironic_nodes.json
if [[ -s $nodes_plan ]]; then
    command -v jq >/dev/null 2>&1 || die "jq is needed to inspect the existing node plan: $nodes_plan"
    jq -e --argjson masters "$num_masters" --argjson workers "$num_workers" '
        .nodes | (length == ($masters + $workers)) and
        ([.[] | select(.name | test("-master-[0-9]+$"))] | length == $masters) and
        ([.[] | select(.name | test("-worker-[0-9]+$"))] | length == $workers)
    ' "$nodes_plan" >/dev/null 2>&1 || die "Existing node plan does not match $num_masters masters/$num_workers workers: $nodes_plan. Inspect existing resources before retrying."
fi

# Repository setup is opt-in. Automatic mode only checks existing sources.
# Keep this before the first package installation, including the small tools.
repository_options() {
    next 'Repair/enable the existing repositories and their network or certificate access, then rerun.'
    next 'Or add --repo-file /absolute/path/lab.repo using configuration from your lab/IT team.'
    if [[ $ID == rhel ]]; then
        next 'Or add --use-subscription-manager; for an unregistered host also supply --rhsm-org ID --rhsm-activation-key-file /absolute/path/key.txt.'
        next 'Obtain the organization ID and activation key from your Red Hat organization administrator: https://console.redhat.com/insights/connector/activation-keys'
    fi
    next 'Keep the same --repo, credential, and stage arguments when rerunning. See --help for examples.'
}

check_package_repositories() {
    local available package
    # Fail on inaccessible enabled repositories even when configured to skip
    # them. Merely listing repo IDs or already-installed RPMs is insufficient.
    if ! LC_ALL=C timeout 180s dnf -q "$@" --refresh \
        --setopt='*.skip_if_unavailable=False' --setopt=timeout=20 \
        --setopt=retries=1 makecache; then
        warn 'Could not refresh all enabled repositories (or the 180-second limit was reached).'
        return 1
    fi
    # --showduplicates includes versions already installed on this machine.
    # This checks representative BaseOS/AppStream content, not every package
    # that make requirements might install from additional repositories.
    if ! available=$(LC_ALL=C timeout 60s dnf -q "$@" --showduplicates \
        list --available bash glibc libvirt qemu-kvm podman); then
        warn 'Could not query available host packages.'
        return 1
    fi
    for package in bash glibc libvirt qemu-kvm podman; do
        if ! awk -v package="$package" '
            $1 == package ".x86_64" || $1 == package ".noarch" { found=1 }
            END { exit !found }
        ' <<<"$available"; then
            warn "Enabled repositories do not offer the required host package: $package"
            return 1
        fi
    done
}

setup_repo_file() {
    local check_dir file target=/etc/yum.repos.d/ocp-install.repo backup candidate
    local -a repo_sources=()
    [[ ! -L $target && ( ! -e $target || -f $target ) ]] || die "Refusing to replace a symlink or non-file: $target"
    # Build a temporary combined configuration. A malformed or unreachable
    # supplied file must not replace the host's working configuration.
    check_dir=$(mktemp -d "$log_dir/repo-check.XXXXXX")
    repo_sources=("$check_dir/ocp-install.repo")
    for file in /etc/yum.repos.d/*.repo; do
        [[ -f $file && $file != "$target" ]] || continue
        cp -- "$file" "$check_dir/"
        repo_sources+=("$check_dir/$(basename -- "$file")")
    done
    cp -- "$repo_file_arg" "$check_dir/ocp-install.repo"
    # DNF may warn and ignore duplicate IDs; explicitly reject them instead.
    # Do not source .repo files as shell code or print their contents.
    if ! awk '
        /^[[:space:]]*([#;]|$)/ { next }
        /^[[:space:]]*\[/ {
            line=$0
            sub(/^[[:space:]]*\[/, "", line)
            sub(/\][[:space:]]*$/, "", line)
            if (line !~ /^[A-Za-z0-9_.:-]+$/ || line == "main" || seen[line]++) bad=1
            if (FILENAME == ARGV[1]) supplied_count++
            next
        }
        FILENAME == ARGV[1] {
            if (!supplied_count) bad=1
            if ($0 !~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ && $0 !~ /^[[:space:]]+/) bad=1
        }
        END { exit (bad || !supplied_count) }
    ' "${repo_sources[@]}"; then
        rm -rf -- "$check_dir"
        die 'Invalid repository section or duplicate repository ID; fix the supplied .repo file. No repository file was installed.'
    fi
    if ! check_package_repositories --setopt="reposdir=$check_dir"; then
        rm -rf -- "$check_dir"
        repository_options
        die 'Supplied repository configuration failed validation; no repository file was installed.'
    fi
    install -d -m 755 /etc/yum.repos.d
    if [[ -f $target ]] && cmp -s -- "$target" "$check_dir/ocp-install.repo"; then
        chmod 600 -- "$target"
        pass 'Supplied repository configuration is already installed.'
    else
        if [[ -f $target ]]; then
            backup=$(mktemp /etc/yum.repos.d/ocp-install.repo.backup.XXXXXX)
            install -m 600 -- "$target" "$backup"
            pass "Previous managed repository file backed up: $backup"
        fi
        candidate=$(mktemp /etc/yum.repos.d/.ocp-install.XXXXXX)
        install -m 600 -- "$check_dir/ocp-install.repo" "$candidate"
        mv -f -- "$candidate" "$target"
        pass "Repository configuration installed: $target"
    fi
    rm -rf -- "$check_dir"
}

setup_subscription_manager() {
    local activation_key
    [[ $ID == rhel ]] || die '--use-subscription-manager is only supported on RHEL.'
    command -v subscription-manager >/dev/null 2>&1 || \
        die 'subscription-manager is missing; restore it from your RHEL installation source or use --repo-file.'
    if subscription-manager identity >/dev/null 2>&1; then
        pass 'Host is already registered; keeping its existing registration.'
    else
        [[ -n $rhsm_org && -n $rhsm_activation_key_file ]] || {
            repository_options
            die 'Registration needs --rhsm-org and --rhsm-activation-key-file.'
        }
        chmod 600 -- "$rhsm_activation_key_file"
        activation_key=$(<"$rhsm_activation_key_file")
        [[ -n $activation_key && $activation_key != *$'\n'* && $activation_key != *$'\r'* ]] || \
            die 'Activation-key file must contain one key name on one line.'
        # Do not trace the command or copy its output into installation logs:
        # error messages can include the activation key. Never force-register.
        if ! timeout 120s subscription-manager register --org="$rhsm_org" \
            --activationkey="$activation_key" >/dev/null 2>&1; then
            unset activation_key
            die 'RHEL registration failed or timed out. Check the organization/key, subscription access, and connectivity; then rerun. Key-bearing output was suppressed.'
        fi
        unset activation_key
        pass 'RHEL registration completed.'
    fi
    if ! timeout 120s subscription-manager repos \
        --enable=rhel-9-for-x86_64-baseos-rpms \
        --enable=rhel-9-for-x86_64-appstream-rpms \
        --enable=codeready-builder-for-rhel-9-x86_64-rpms; then
        die 'Could not enable the standard RHEL 9 repositories. Check repository access with your organization administrator (Satellite may use different IDs), then rerun.'
    fi
}

repo_file_arg=${repo_file_arg:-${profile[REPO_FILE]:-}}
rhsm_org=${rhsm_org:-${profile[RHSM_ORG]:-}}
rhsm_activation_key_file=${rhsm_activation_key_file:-${profile[RHSM_ACTIVATION_KEY_FILE]:-}}
if [[ $use_subscription_manager == false ]]; then use_subscription_manager=${profile[USE_SUBSCRIPTION_MANAGER]:-false}; fi
[[ $use_subscription_manager == true || $use_subscription_manager == false ]] || die 'USE_SUBSCRIPTION_MANAGER must be true or false'
[[ -z $repo_file_arg || $use_subscription_manager == false ]] || die 'Choose REPO_FILE or Subscription Manager'
for input_path in "$repo_file_arg" "$rhsm_activation_key_file"; do
    [[ -z $input_path || ( $input_path == /* && -r $input_path && -s $input_path ) ]] || die 'Repository/key file missing or not absolute'
done
if [[ -n $rhsm_org || -n $rhsm_activation_key_file ]]; then
    [[ $use_subscription_manager == true && $rhsm_org =~ ^[0-9]+$ && -n $rhsm_activation_key_file ]] || die 'RHSM requires USE_SUBSCRIPTION_MANAGER=true, RHSM_ORG and RHSM_ACTIVATION_KEY_FILE'
fi
step 'Configure and verify host package repositories' 
command -v dnf >/dev/null 2>&1 || die 'dnf is missing; restore the host package manager first.'
if [[ -n $repo_file_arg ]]; then
    setup_repo_file
elif [[ $use_subscription_manager == true ]]; then
    setup_subscription_manager
fi
if ! check_package_repositories; then
    repository_options
    die 'Host package access is unavailable; no package installations or Makefile stages were run.'
fi
pass 'Enabled repositories are reachable and provide the core OS, virtualization, and container packages.'
if [[ $ID == rhel && $use_subscription_manager == false ]]; then
    pass 'Using existing repository access; Subscription Manager registration was not requested.'
fi

step 'Install small host prerequisites when missing'
packages=()
for spec in git:git make:make wget:wget jq:jq python3:python3 ssh-keygen:openssh-clients xfs_info:xfsprogs; do
    binary=${spec%%:*}
    package=${spec#*:}
    command -v "$binary" >/dev/null 2>&1 || packages+=("$package")
done
if ((${#packages[@]})); then run_bounded dnf install -y "${packages[@]}"; fi
for spec in git:git make:make wget:wget jq:jq python3:python3 ssh-keygen:openssh-clients xfs_info:xfsprogs; do
    binary=${spec%%:*}
    command -v "$binary" >/dev/null 2>&1 || die "$binary is still missing after package installation."
    pass "$binary is available."
done
pass "dev-scripts checkout: $(git -C "$repo" rev-parse --short=12 HEAD)"

step 'Check storage capacity and d_type support'
disk_path=$working_dir
while [[ ! -e $disk_path ]]; do disk_path=$(dirname -- "$disk_path"); done
free_kib=$(df -Pk -- "$disk_path" | awk 'NR == 2 {print $4}')
if ((first_index == 0)); then
    ((free_kib >= required_disk_mib * 1024)) || die "Requested VM disks plus overhead need $((required_disk_mib / 1024)) GiB free space"
fi
((free_kib >= 80 * 1024 * 1024)) || die "Less than 80 GiB free for $working_dir."
pass "Free space for $working_dir: $((free_kib / 1024 / 1024)) GiB."
fs_type=$(findmnt -n -o FSTYPE -T "$disk_path")
case "$fs_type" in
    xfs)
        fs_source=$(findmnt -n -o SOURCE -T "$disk_path")
        xfs_info "$fs_source" 2>/dev/null | grep -q 'ftype=1' || die "XFS filesystem $fs_source does not report ftype=1."
        pass 'XFS supports d_type (ftype=1).'
        ;;
    ext4|btrfs) pass "$fs_type supports d_type." ;;
    *) die "Confirm d_type support for $fs_type before using $working_dir." ;;
esac
if [[ -s /root/.ssh/id_rsa.pub ]]; then
    pass 'Default SSH public key is present.'
else
    warn 'Default SSH public key is missing; the installer will create it after credentials are supplied.'
fi

# Credentials are user supplied. Report both missing inputs together, after
# the host checks, and stop before the first Makefile installation stage.
ci_token=$(config_value CI_TOKEN)
missing_inputs=0
if [[ -z $ci_token ]]; then
    next "Get the login token from https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/"
    next "Set CI_TOKEN in $config inside its set +x / set -x block."
    missing_inputs=1
else
    [[ $ci_token != *[[:space:]]* ]] || die "CI_TOKEN in $config must be the token value, not the full login command."
    pass 'CI_TOKEN is present.'
fi
unset ci_token

pull_secret=$(config_value PERSONAL_PULL_SECRET)
pull_secret=${pull_secret:-$repo/pull_secret.json}
[[ $pull_secret == /* ]] || die "PERSONAL_PULL_SECRET must use an absolute path in $config."
if [[ ! -s $pull_secret ]]; then
    next 'Download a pull secret from https://console.redhat.com/openshift/install/pull-secret'
    next "Save it to $pull_secret, or change PERSONAL_PULL_SECRET in $config."
    missing_inputs=1
fi
if ((missing_inputs != 0)); then
    printf -v retry_command '%q --repo %q --from %q --through %q' \
        "$script_path" "$repo" "$first_stage" "$last_stage"
    next "After editing the config and saving the pull secret, rerun: $retry_command"
    die 'Required credentials are missing; no Makefile installation stages were run.'
fi

step 'Validate the pull secret and SSH key'
jq -e '.auths | type == "object" and length > 0' "$pull_secret" >/dev/null 2>&1 || \
    die "Pull secret is not valid JSON with a nonempty auths object: $pull_secret"
pass "Pull secret is nonempty JSON with auths: $pull_secret"
mode=$(stat -c %a "$pull_secret")
if (((8#$mode & 077) != 0)); then
    chmod 600 "$pull_secret"
    printf 'FIXED Pull-secret permissions to owner-only access.\n'
fi
pass 'Pull secret is accessible only to its owner.'
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [[ ! -s /root/.ssh/id_rsa.pub ]]; then
    if [[ -e /root/.ssh/id_rsa ]]; then
        ssh-keygen -y -P '' -f /root/.ssh/id_rsa >/root/.ssh/id_rsa.pub || \
            die 'Cannot recover the public key from /root/.ssh/id_rsa; provide an unencrypted key.'
    else
        ssh-keygen -q -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa
    fi
    chmod 644 /root/.ssh/id_rsa.pub
    printf 'CREATED /root/.ssh/id_rsa.pub for dev-scripts.\n'
fi
pass 'Default SSH public key is available.'

validate_ci_token() {
    local server token retry_stage retry_command
    command -v oc >/dev/null 2>&1 || die 'oc CLI is missing after requirements; inspect that stage.'
    server=$(config_value CI_SERVER)
    server=${server:-api.ci.l2s4.p1.openshiftapps.com}
    token=$(config_value CI_TOKEN)
    if ! timeout 20s oc whoami --kubeconfig=/dev/null \
        --server="https://${server}:6443" --token="$token" >/dev/null 2>&1; then
        unset token
        case "$stage" in
            preparation) retry_stage=$first_stage ;;
            requirements) retry_stage=configure ;;
            *) retry_stage=$stage ;;
        esac
        printf -v retry_command '%q --repo %q --from %q' "$script_path" "$repo" "$retry_stage"
        next "After correcting CI_TOKEN, rerun: $retry_command"
        die "CI token authentication failed or the CI API is unreachable. Check CI_TOKEN in $config."
    fi
    unset token
    pass 'CI token authenticates.'
    token_validated=true
}

# The wrapper's private umask protects credentials, but dev-scripts also
# creates public RHCOS files for Apache in make ironic. Keep the private umask
# and chmod only those two served artifacts after dev-scripts creates them.
stop_host_sushy_emulator() {
    # This pre-existing unit recreates sushy-tools after dev-scripts removes it.
    # Its certificate differs from the dev-scripts BMC trust bundle, so it must
    # be stopped before make ironic starts the cluster's own emulator.
    local enabled active directory=$script_dir/.ocp-installer-host-state saved tmp
    [[ $(timeout --kill-after=5s 30s systemctl show -p LoadState --value sushy-emulator.service) != not-found ]] || return 0
    enabled=$(timeout --kill-after=5s 30s systemctl is-enabled sushy-emulator.service 2>/dev/null || true)
    active=$(timeout --kill-after=5s 30s systemctl is-active sushy-emulator.service 2>/dev/null || true)
    [[ -n $enabled && -n $active ]] || die 'Cannot inspect host Sushy service state'
    if [[ $enabled == masked* ]]; then
        [[ $active != active ]] || die 'Host Sushy is masked but active; inspect service ownership'
        return 0
    fi
    [[ $enabled != disabled && $enabled != static && $enabled != indirect || $active == active ]] || return 0
    [[ ! -L $directory ]] || die 'Unsafe host service state directory'
    if ! mkdir -m 700 -- "$directory" 2>/dev/null; then
        [[ -d $directory ]] || die 'Cannot create host service state directory'
    fi
    [[ -O $directory && $(stat -c %a "$directory") == 700 ]] || die 'Host service state directory must be private and owned by this user'
    saved=$directory/sushy-emulator.service.state
    [[ ! -L $saved ]] || die 'Unsafe saved host service state'
    if [[ ! -e $saved ]]; then
        tmp=$(mktemp "$directory/.sushy.XXXXXX")
        printf 'enabled=%s\nactive=%s\n' "$enabled" "$active" >"$tmp"
        mv -- "$tmp" "$saved"
    fi
    timeout --kill-after=5s 30s systemctl disable --now sushy-emulator.service || die 'Could not disable and stop host sushy-emulator.service'
    pass "Disabled host Sushy while dev-scripts owns Redfish; previous service state: $saved"
}

token_validated=false
if command -v oc >/dev/null 2>&1; then
    step 'Check CI authentication before changing the host'
    validate_ci_token
else
    printf 'INFO  oc CLI is not installed yet; CI authentication will be checked after requirements.\n'
fi

if $preflight_only; then
    pass 'Host/input preflight completed; no OCP Makefile stages ran'
    exit 0
fi

if ((last_index == 5)) && [[ -z ${TMUX:-} ]]; then
    warn 'This shell is not inside tmux; an SSH disconnect may interrupt ocp_run.'
fi

# openshift-install always appends to .openshift_install.log under --dir.
# Keep cluster assets there, but route this log to the current run in /tmp.
# Preserve any existing regular log before replacing its path with a link.
prepare_installer_log() {
    local cluster_dir=$repo/ocp/$cluster_name native_log target previous
    native_log=$cluster_dir/.openshift_install.log
    target=$run_log_dir/openshift-install.log
    mkdir -p -- "$cluster_dir"
    if [[ -L $native_log && $(readlink -- "$native_log") == "$target" ]]; then
        return 0
    fi
    if [[ -e $native_log && ! -L $native_log ]]; then
        [[ -f $native_log ]] || die "Unexpected installer log type: $native_log"
        previous=$(mktemp "$run_log_dir/openshift-install.previous.XXXXXX.log")
        cat -- "$native_log" >"$previous"
    fi
    touch -- "$target"
    chmod 600 -- "$target"
    ln -sfnT -- "$target" "$native_log"
}

installer_state=$repo/ocp/$cluster_name/.openshift_install_state.json
cluster_kubeconfig=$repo/ocp/$cluster_name/auth/kubeconfig

for i in "${!stages[@]}"; do
    ((i >= first_index && i <= last_index)) || continue
    stage=${stages[$i]}
    write_running_status
    [[ ! -e $installer_state || -s $installer_state ]] || die "Installer state is empty: $installer_state. Inspect it before resuming."
    if [[ $stage == install_config && -s $installer_state ]]; then
        step 'Reuse the original install configuration from existing installer state'
        verify_saved_install_config
        continue
    fi
    if [[ $stage == install_config && -e $cluster_kubeconfig ]]; then
        die "Cluster credentials exist without installer state: $cluster_kubeconfig. Inspect this installation before generating a new configuration."
    fi
    case "$stage" in
        configure)
            step 'Match the Metal3 libvirt restart task to the host'
            libvirt_restart_task apply
            libvirt_restart_task verify
            if [[ $token_validated == false ]]; then validate_ci_token; fi

            ;;
        build_installer|ironic|install_config|ocp_run)
            if [[ $token_validated == false ]]; then validate_ci_token; fi
            prepare_installer_log
            if [[ $stage == build_installer && -z ${settings[OPENSHIFT_RELEASE_IMAGE]} ]]; then
                resolve_release_image
            fi
            if [[ $stage == install_config ]]; then
                prepare_install_config
            fi
            if [[ $stage == ironic ]]; then
                step 'Reserve the Redfish endpoint for this dev-scripts cluster'
                stop_host_sushy_emulator
                step 'Validate the RHCOS cache and prepare public artifact access'
                prepare_ironic_cache
            fi
            ;;
    esac
    if [[ $stage == ocp_run ]]; then
        if [[ -s $installer_state ]]; then
            die 'Installer state already exists. Preserve the original assets and inspect recovery with upstream openshift-install; this wrapper will not rewrite dev-scripts resume behavior.'
        else
            [[ ! -e $cluster_kubeconfig ]] || die "Cluster credentials exist without installer state: $cluster_kubeconfig. Inspect this installation before creating a cluster."
            verify_install_config_topology
            prepare_install_config
        fi
        stop_host_sushy_emulator
    fi
    step "Run make $stage"
    # logging.sh honors LOGDIR. Clear an inherited prefix so every stage log
    # stays alongside this run's combined log, outside the checkout.
    run_bounded env -u MAKEFLAGS -u MFLAGS -u GNUMAKEFLAGS -u MAKEFILES CONFIG="$config" LOGDIR="$dev_scripts_log_dir" LOGPREFIX='' make -j1 "$stage"
    if [[ $stage == requirements ]]; then
        resolve_release_image
        deployment_lock init
    fi
    if [[ $stage == build_installer ]]; then deployment_lock built; fi
    if [[ $stage == install_config ]]; then
        verify_install_config_topology
    fi
    if [[ $stage == requirements && $token_validated == false ]]; then
        validate_ci_token
    fi
done

if ((last_index == 5)); then
    verify_cluster_health

    osac_config=$script_dir/osac-install.conf
    [[ ! -L $osac_config && ( ! -e $osac_config || -f $osac_config ) ]] ||
        die "OSAC installer config is not a regular file: $osac_config"
    osac_config_tmp=$(mktemp "$script_dir/.osac-install.conf.XXXXXX") ||
        die "Could not create temporary OSAC installer config beside $script_path"
    if [[ -f $osac_config ]]; then
        KUBECONFIG_PATH=$cluster_kubeconfig awk '
            BEGIN { path = ENVIRON["KUBECONFIG_PATH"] }
            /^KUBECONFIG=/ {
                if (!found++) print "KUBECONFIG=" path
                next
            }
            { print }
            END { if (!found) print "KUBECONFIG=" path }
        ' "$osac_config" >"$osac_config_tmp" || {
            rm -f -- "$osac_config_tmp"
            die "Could not update KUBECONFIG in $osac_config"
        }
        chown --reference="$osac_config" "$osac_config_tmp" &&
            chmod --reference="$osac_config" "$osac_config_tmp" || {
                rm -f -- "$osac_config_tmp"
                die "Could not preserve permissions for $osac_config"
            }
    else
        printf 'KUBECONFIG=%s\n' "$cluster_kubeconfig" >"$osac_config_tmp" || {
            rm -f -- "$osac_config_tmp"
            die "Could not write $osac_config"
        }
    fi
    mv -f -- "$osac_config_tmp" "$osac_config" || {
        rm -f -- "$osac_config_tmp"
        die "Could not replace $osac_config"
    }
    printf 'INFO  Updated KUBECONFIG in %s: %s\n' "$osac_config" "$cluster_kubeconfig"
    printf '\nPASS  OpenShift installation stages completed.\n'
else
    printf '\nPASS  Completed through make %s.\n' "$last_stage"
fi
