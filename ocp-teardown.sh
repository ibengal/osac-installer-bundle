#!/usr/bin/env bash
# Tear down the existing dev-scripts cluster. Use --dry-run to inspect first.
# Python's standard library handles XML inventory, exact file deletion, and
# logging without evaluating shell configuration while building the plan.
set -euo pipefail

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

exec python3 - "$0" "$@" <<'PY'
import argparse
from datetime import datetime
import hashlib
import fcntl
import signal
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


class TeardownError(Exception):
    pass


def read_settings(path, keys):
    """Inspect selected literal assignments; never source either config file."""
    values = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        match = re.match(r'^\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=(.*)$', line)
        if not match or match[1] not in keys:
            continue
        try:
            words = shlex.split(match[2], comments=True)
        except ValueError:
            raise TeardownError(f'Invalid literal assignment in {path}:{number}') from None
        if len(words) > 1 or any(c in ''.join(words) for c in '$`\\;|&<>\n'):
            raise TeardownError(f'Use a literal {match[1]} value in {path}:{number}')
        values[match[1]] = words[0] if words else ''
    return values


def capture(*args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=30)
    if result.returncode:
        # Do not echo arbitrary command output or configuration contents.
        raise TeardownError(f'Read-only command failed: {shlex.join(args)}')
    return result.stdout


def names(*args):
    return [line.strip() for line in capture(*args).splitlines() if line.strip()]


def resolve(args, script_dir):
    profile = Path(args.config).absolute() if args.config else script_dir / 'ocp-install.conf'
    if args.config and not profile.is_file():
        raise TeardownError(f'Installer config is missing: {profile}')
    preferences = read_settings(profile, {'DEV_SCRIPTS_DIR', 'LOG_DIR', 'CLEANUP_TIMEOUT'}) if profile.is_file() else {}
    repo = Path(args.repo or os.environ.get('DEV_SCRIPTS_DIR') or preferences.get('DEV_SCRIPTS_DIR') or script_dir / 'dev-scripts').resolve()
    if not (repo / '.git').exists() or not (repo / 'Makefile').is_file():
        raise TeardownError(f'dev-scripts checkout missing: {repo}; use --repo PATH')
    config = script_dir / '.ocp-installer-state' / 'config_root.sh'
    if not config.is_file():
        config = repo / 'config_root.sh'  # older installations
    if not config.is_file():
        raise TeardownError(f'Existing deployment config missing: {config}. Restore it before teardown; do not generate a new layout.')
    # Use the ACTUAL deployment config. The installer profile may already
    # describe the user's next cluster, which must not change this target.
    keys = {'CLUSTER_NAME', 'WORKING_DIR', 'OCP_DIR', 'NODES_FILE', 'NODES_PLATFORM',
            'LIBVIRT_VOLUME_POOL', 'PROVISIONING_NETWORK_NAME', 'BAREMETAL_NETWORK_NAME'}
    current = read_settings(config, keys)
    cluster = current.get('CLUSTER_NAME') or 'ostest'
    if not re.fullmatch(r'[a-z](?:[a-z0-9-]*[a-z0-9])?', cluster) or len(cluster) > 13:
        raise TeardownError('Invalid CLUSTER_NAME in the existing deployment config')
    if current.get('NODES_PLATFORM', 'libvirt') != 'libvirt':
        raise TeardownError('This teardown wrapper covers the libvirt VM installation only')
    pool = current.get('LIBVIRT_VOLUME_POOL') or 'oooq_pool'
    if pool != 'oooq_pool':
        raise TeardownError('The pinned host_cleanup.sh does not forward a custom LIBVIRT_VOLUME_POOL. Review upstream cleanup before using it with this pool.')
    work = Path(current.get('WORKING_DIR') or '/opt/dev-scripts')
    if not work.is_absolute() or work in (Path('/'), Path('/root')) or work.resolve() == repo:
        raise TeardownError('Unsafe or nonabsolute WORKING_DIR in the existing deployment config')
    assets = Path(current.get('OCP_DIR') or f'ocp/{cluster}')
    if not assets.is_absolute():
        assets = repo / assets
    # Restrict automatic cleanup to the standard cluster asset directory.
    if assets.resolve() != (repo / 'ocp' / cluster).resolve():
        raise TeardownError('Custom OCP_DIR requires a separate cleanup review')
    node_plan = Path(current.get('NODES_FILE') or work / cluster / 'ironic_nodes.json')
    if not node_plan.is_absolute():
        raise TeardownError('NODES_FILE must be absolute for teardown verification')
    networks = [current.get('PROVISIONING_NETWORK_NAME') or cluster + 'pr',
                current.get('BAREMETAL_NETWORK_NAME') or cluster + 'bm']
    if any(not re.fullmatch(r'[A-Za-z0-9_-]{1,15}', n) for n in networks) or 'default' in networks:
        raise TeardownError(f'Unexpected cluster network names; review {config}')
    log_root = Path(args.log_dir or preferences.get('LOG_DIR') or '/tmp/ocp-install-logs')
    if not log_root.is_absolute():
        raise TeardownError('LOG_DIR/--log-dir must be an absolute path')
    timeout = preferences.get('CLEANUP_TIMEOUT') or '1800'
    if not re.fullmatch(r'[1-9][0-9]{0,4}', timeout):
        raise TeardownError('CLEANUP_TIMEOUT must be 1..99999 seconds')
    return dict(timeout=int(timeout), repo=repo, config=config, cluster=cluster, work=work, assets=assets,
                node_plan=node_plan, networks=networks, pool=pool, log_root=log_root)


def cluster_vm(name, cluster):
    return bool(re.fullmatch(re.escape(cluster) + r'_(?:master|worker|arbiter|extraworker|armworker|landingzone)_\d+', name)
                or re.fullmatch(re.escape(cluster) + r'[-_]bootstrap(?:[-_][a-zA-Z0-9-]+)?', name))


def inventory(plan):
    all_vms = names('virsh', 'list', '--all', '--name')
    vms = [n for n in all_vms if cluster_vm(n, plan['cluster'])]
    other_vms = sorted(set(all_vms) - set(vms))
    if other_vms:
        raise TeardownError('Other libvirt VMs exist: ' + ', '.join(other_vms) + '. Upstream make clean changes shared host networking and storage-pool definitions; inspect this host before proceeding.')
    files = {}
    root_name = re.escape(plan['cluster']) + r'_(?:master|worker|arbiter|extraworker|armworker|landingzone)_\d+'
    managed_file = re.compile(root_name + r'(?:\.qcow2|_vd[a-z]+\.img)')

    def remember(path):
        path = Path(path)
        if not path.is_absolute() or not managed_file.fullmatch(path.name):
            raise TeardownError(f'Unexpected VM disk path requires manual review: {path}')
        try:
            info = path.lstat()
        except FileNotFoundError:
            return
        if not stat.S_ISREG(info.st_mode):
            raise TeardownError(f'VM disk is not a regular file: {path}')
        files[str(path)] = {'device': info.st_dev, 'inode': info.st_ino}

    for vm in vms:
        # Bootstrap assets are owned by openshift-install destroy. Check their
        # VM removal below; do not invent file names or delete its pool.
        if 'bootstrap' in vm:
            continue
        xml = ET.fromstring(capture('virsh', 'dumpxml', vm, '--inactive'))
        for disk in xml.findall('./devices/disk'):
            if disk.get('device') != 'disk':
                continue
            source = disk.find('source')
            if source is None:
                raise TeardownError(f'Missing disk source for {vm}')
            if disk.get('type') == 'volume':
                if source.get('pool') != plan['pool'] or source.get('volume') != vm + '.qcow2':
                    raise TeardownError(f'Unexpected storage volume attached to {vm}; inspect it before teardown')
                remember(capture('virsh', 'vol-path', '--pool', plan['pool'], source.get('volume')).strip())
            elif disk.get('type') == 'file':
                remember(source.get('file', ''))
            else:
                raise TeardownError(f'Non-file disk attached to {vm}; automatic teardown is restricted to the lab VM images')
    # Support a retry after upstream already undefined VMs/pool. Only consider
    # exact dev-scripts image names directly under its usual pool directory.
    pool_path = plan['work'] / 'pool'
    if pool_path.is_dir():
        for path in pool_path.iterdir():
            if managed_file.fullmatch(path.name):
                remember(path)
    return {'vms': vms, 'files': files,
            'networks': [n for n in names('virsh', 'net-list', '--all', '--name') if n in plan['networks']]}


def private_directory(path):
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise TeardownError(f'Log directory must be a real owner-only directory owned by the current user: {path}')


class Log:
    def __init__(self, root, cluster):
        private_directory(root)
        self.folder = root / 'teardown'
        private_directory(self.folder)
        stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
        fd, filename = tempfile.mkstemp(prefix=f'ocp-teardown-{stamp}.', suffix='.log', dir=self.folder)
        self.path = Path(filename)
        self.stream = os.fdopen(fd, 'w', buffering=1)
        self.status = self.path.with_suffix('.status')
        self.details = self.path.with_suffix('.d')
        private_directory(self.details)
        self.started = datetime.now().astimezone().isoformat(timespec='seconds')
        self.cluster = cluster
        self.stage = 'preparation'
        for name, target in [('latest.log', self.path), ('latest.status', self.status), ('latest.d', self.details)]:
            link = self.folder / name
            link.unlink(missing_ok=True)
            link.symlink_to(target.name)
        self.write_status('running')

    def say(self, message):
        print(message, flush=True)
        self.stream.write(message + '\n')

    def write_status(self, result, code=None):
        fields = dict(result=result, stage=self.stage, cluster=self.cluster,
                      started_at=self.started, log=self.path, details=self.details)
        if code is not None:
            fields.update(exit_code=code, finished_at=datetime.now().astimezone().isoformat(timespec='seconds'))
        self.status.write_text(''.join(f'{key}={value}\n' for key, value in fields.items()))


def prepare_native_log(plan, log):
    if not plan['assets'].is_dir():
        return
    native = plan['assets'] / '.openshift_install.log'
    if native.exists() and not native.is_symlink():
        if not native.is_file():
            raise TeardownError('Unexpected native installer log type')
        shutil.copyfile(native, log.details / 'openshift-install.previous.log')
    native.unlink(missing_ok=True)
    target = log.details / 'openshift-install.log'
    target.touch(mode=0o600)
    native.symlink_to(target)


def remove_recorded_files(recorded, log):
    # Called ONLY after successful make clean and verified absence of cluster
    # VMs. Refuse replaced files and links; never use rm -rf or a glob deletion.
    for filename, expected in recorded.items():
        path = Path(filename)
        try:
            info = path.lstat()
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(info.st_mode) or (info.st_dev, info.st_ino) != (expected['device'], expected['inode']):
            raise TeardownError(f'Disk file changed during cleanup; left untouched: {path}')
        path.unlink()
        log.say(f'REMOVED residual VM disk: {path}')


def execute(plan, before, log):
    (log.details / 'inventory.json').write_text(json.dumps(before, indent=2) + '\n')
    prepare_native_log(plan, log)
    # A host-level unit can restart sushy-tools after make clean removes it.
    # Stop that unit first so cleanup cannot race its Restart=on-failure policy.
    service = subprocess.run(['systemctl', 'is-active', '--quiet',
                              'sushy-emulator.service'], timeout=10, check=False)
    if service.returncode == 0:
        log.say('STEP  Stop host sushy-emulator.service before cluster cleanup')
        stopped = subprocess.run(['systemctl', 'stop', 'sushy-emulator.service'],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, timeout=90, check=False)
        for line in stopped.stdout.splitlines():
            log.say(line)
        if stopped.returncode:
            raise TeardownError('Could not stop host sushy-emulator.service')
    log.stage = 'make_clean'
    log.write_status('running')
    stage_logs = log.details / 'dev-scripts'
    private_directory(stage_logs)
    env = dict(os.environ, CONFIG=str(plan['config']), LOGDIR=str(stage_logs), LOGPREFIX='',
               MAKEFLAGS='', GNUMAKEFLAGS='', MFLAGS='',
               CLUSTER_NAME=plan['cluster'], WORKING_DIR=str(plan['work']),
               OCP_DIR=str(plan['assets']), NODES_FILE=str(plan['node_plan']),
               NODES_PLATFORM='libvirt', LIBVIRT_VOLUME_POOL=plan['pool'],
               PROVISIONING_NETWORK_NAME=plan['networks'][0],
               BAREMETAL_NETWORK_NAME=plan['networks'][1])
    log.say('STEP  Run make clean using the existing deployment config')
    env.pop('MAKEFILES', None)
    with subprocess.Popen(['timeout', '--kill-after=15s', str(plan.get('timeout', 1800)), 'make', '-j1', 'clean'], cwd=plan['repo'], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, errors='replace', start_new_session=True) as process:
        try:
            for line in process.stdout:
                log.say(line.rstrip('\n'))
            code = process.wait()
        except BaseException:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
    if code:
        log.say(f'FAIL  make clean exited with status {code}; inspect the log before retrying.')
        return code

    log.stage = 'verification'
    log.write_status('running')
    remaining = [n for n in names('virsh', 'list', '--all', '--name') if cluster_vm(n, plan['cluster'])]
    if remaining:
        raise TeardownError('Cluster VMs remain; disk files were not deleted: ' + ', '.join(remaining))
    # Recheck all domains before unlinking files in case another VM appeared.
    if names('virsh', 'list', '--all', '--name'):
        raise TeardownError('A new libvirt VM appeared during cleanup; inspect disk references before retrying')
    remaining_networks = set(names('virsh', 'net-list', '--all', '--name')) & set(plan['networks'])
    if remaining_networks:
        raise TeardownError('Cluster networks remain: ' + ', '.join(sorted(remaining_networks)))
    if plan['assets'].exists() or plan['node_plan'].exists():
        raise TeardownError('Cluster assets or ironic_nodes.json remain; inspect the cleanup log')
    containers = set(names('podman', 'ps', '--all', '--format', '{{.Names}}'))
    if 'sushy-tools' in containers:
        log.say('STEP  Remove leftover sushy-tools provisioning container')
        result = subprocess.run(['podman', 'rm', '--force', 'sushy-tools'],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=60, check=False)
        for line in result.stdout.splitlines():
            log.say(line)
        if result.returncode:
            raise TeardownError('Could not remove sushy-tools provisioning container')
        containers = set(names('podman', 'ps', '--all', '--format', '{{.Names}}'))
    provisioning = {'ironic', 'ironic-api', 'ironic-conductor', 'ironic-inspector', 'dnsmasq',
                    'httpd-' + plan['networks'][0], 'mariadb', 'vbmc', 'sushy-tools'}
    if containers & provisioning:
        raise TeardownError('Provisioning containers remain: ' + ', '.join(sorted(containers & provisioning)))
    remove_recorded_files(before['files'], log)
    log.say('PASS  Cluster VMs, recorded disks, cluster networks, provisioning containers, and installation assets are removed.')
    log.say('INFO  Kept configuration, user credential files, scripts, installed host packages, and reusable caches.')
    return 0


def main(argv, script_dir):
    parser = argparse.ArgumentParser(prog='ocp-teardown.sh', description='Remove the existing dev-scripts VM cluster with make clean and verify removal.',
        epilog='Terminal colours are automatic; set INSTALLER_COLOR=always to force them or INSTALLER_COLOR=never/NO_COLOR=1 to disable them. NO_COLOR takes precedence and saved logs remain plain. Run inside tmux. This deletes the cluster and its VM data when --dry-run is absent. It does not restore a pristine OS. make realclean is intentionally not used: it removes WORKING_DIR and prunes host-wide Podman images/volumes. Logs may contain credentials; /tmp may be cleared on reboot.')
    parser.add_argument('--repo', help='dev-scripts checkout; defaults to DEV_SCRIPTS_DIR or the adjacent checkout')
    parser.add_argument('--config', help='installer config used ONLY for DEV_SCRIPTS_DIR and LOG_DIR; cluster identity comes from the saved deployment config')
    parser.add_argument('--log-dir', help='override LOG_DIR; teardown logs live under its teardown/ subdirectory')
    parser.add_argument('--dry-run', action='store_true', help='read config and inventory, print the plan, and exit without writes or cleanup')
    args = parser.parse_args(argv)
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    os.umask(0o077)
    log = None
    lock_fd = None
    code = 1
    try:
        plan = resolve(args, script_dir)
        for binary in ['virsh', 'make', 'podman']:
            if not shutil.which(binary):
                raise TeardownError(f'{binary} is missing; restore the installation tools before cleanup')
        if not args.dry_run:
            path = Path('/run/lock/osac-ocp.lock')
            if os.environ.get('OCP_CHAIN_LOCK_FD') == '7' and Path('/proc/self/fd/7').exists() and Path('/proc/self/fd/7').samefile(path):
                lock_fd = os.dup(7)
            else:
                lock_fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise TeardownError('Another OCP operation is active on this host') from None
        before = inventory(plan)
        print(f'TARGET cluster={plan["cluster"]} repo={plan["repo"]}', flush=True)
        print(f'CONFIG {plan["config"]} (existing deployment settings)', flush=True)
        print(f'VMs: {", ".join(before["vms"]) or "none"}', flush=True)
        print(f'Cluster networks: {", ".join(before["networks"]) or "none"}', flush=True)
        for filename in before['files']:
            print(f'DISK {filename}', flush=True)
        print(f'LOG DIRECTORY {plan["log_root"] / "teardown"}', flush=True)
        if args.dry_run:
            print('DRY RUN: would run make -j1 clean, verify removal, then remove only recorded residual VM image files. No files or resources changed.')
            return 0
        if os.geteuid() != 0:
            raise TeardownError('Run teardown as root (or use --dry-run to inspect)')
        log = Log(plan['log_root'], plan['cluster'])
        log.say(f'TARGET {plan["cluster"]}; deployment config: {plan["config"]}')
        config_hash = hashlib.sha256(plan['config'].read_bytes()).hexdigest()
        code = execute(plan, before, log)
        if hashlib.sha256(plan['config'].read_bytes()).hexdigest() != config_hash:
            raise TeardownError('Deployment config changed during cleanup; inspect it before reinstalling')
    except KeyboardInterrupt:
        code = 130
        if log:
            log.say('FAIL  Teardown interrupted; inspect the log and remaining resources before retrying.')
    except (TeardownError, OSError, subprocess.SubprocessError, ET.ParseError) as error:
        message = f'FAIL  {error}'
        if log:
            log.say(message)
        else:
            print(message, file=sys.stderr)
        code = 1
    finally:
        if log:
            outcome = 'success' if code == 0 else 'failed'
            log.write_status(outcome, code)
            log.say(f'RESULT {outcome} (exit {code})\nLOG {log.path}\nSTATUS {log.status}')
            log.stream.close()
        if lock_fd is not None:
            os.close(lock_fd)
    return code


if __name__ == '__main__':
    sys.exit(main(sys.argv[2:], Path(sys.argv[1]).resolve().parent))
PY
