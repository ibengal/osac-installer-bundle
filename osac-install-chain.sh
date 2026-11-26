#!/usr/bin/env bash
# Fresh OCP -> OSAC lab installation with rollback on either stage failure.
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
exec 3>&1
# END INSTALLER TERMINAL OUTPUT


exec python3 - "$0" "$@" <<'PY'
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time

class Failure(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code

class Chain:
    def __init__(self):
        self.log = None
        self.folder = None
        self.stage = 'preflight'
        self.started = datetime.now(timezone.utc).isoformat()
        self.cleanup = {'ocp': 'skipped', 'osac': 'skipped'}
        self.lock = None

    def say(self, text):
        print(text, flush=True)
        if self.log:
            self.log.write(text + '\n')

    def status(self, result, code):
        if self.folder:
            data = dict(result=result, stage=self.stage, exit_code=code,
                        started_at=self.started, updated_at=datetime.now(timezone.utc).isoformat(),
                        ocp_cleanup=self.cleanup['ocp'], osac_cleanup=self.cleanup['osac'])
            temporary = self.folder / 'status.tmp'
            temporary.write_text(''.join(f'{k}={v}\n' for k, v in data.items()))
            temporary.replace(self.folder / 'status')

    def command(self, args, seconds=60, capture=False):
        env = dict(os.environ)
        fds = ()
        if self.lock is not None:
            env['OCP_CHAIN_LOCK_FD'] = '7'
            fds = (7,)
        with subprocess.Popen([str(a) for a in args], env=env, pass_fds=fds,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              start_new_session=True) as child:
            output = bytearray()
            deadline = time.monotonic() + seconds
            selector = selectors.DefaultSelector()
            selector.register(child.stdout, selectors.EVENT_READ)
            try:
                while selector.get_map():
                    if time.monotonic() > deadline:
                        raise Failure('Command timed out', 124)
                    for key, _ in selector.select(0.5):
                        data = os.read(key.fd, 8192)
                        if not data:
                            selector.unregister(key.fd)
                            continue
                        if capture:
                            output.extend(data)
                        else:
                            message = data.decode(errors='replace')
                            print(message, end='', flush=True)
                            if self.log:
                                self.log.write(message)
                code = child.wait(timeout=max(1, deadline-time.monotonic()))
                if code:
                    if capture:
                        self.say(output.decode(errors='replace').strip())
                    raise Failure(f'{Path(args[0]).name} exited {code}', code if code > 0 else 128-code)
                return output.decode()
            finally:
                selector.close()
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()

def private_dir(path):
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    if path.is_symlink() or path.stat().st_uid != os.geteuid():
        raise Failure('Log directory must be a real directory owned by the current user')
    path.chmod(0o700)

def main(argv, folder):
    parser = argparse.ArgumentParser(
        prog='osac-install-chain.sh', add_help=False,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description='Install a fresh OpenShift cluster, then install OSAC on it.\n'
        'The chain passes the new OCP kubeconfig to OSAC and cleans up if\n'
        'either installation stage fails.',
        epilog='''WORKFLOW:
  1. Resolve the OCP and OSAC configurations and check their kubeconfigs agree.
  2. Check OSAC inputs, OCP prerequisites, and Helm 3 before creating a cluster.
  3. Install OCP, then install OSAC using the new cluster's kubeconfig.
  4. Record the result and, on failure, run the appropriate teardown scripts.

REQUIREMENTS:
  Run installations as root. Keep these executable scripts together in /root:
    osac-install-chain.sh  ocp-install.sh      ocp-teardown.sh
    osac-install.sh        osac-teardown.sh
  Python 3 and Helm 3 must be available. The child installers check their
  additional prerequisites. An existing OCP cluster at the target is refused;
  tear it down before starting a fresh installation.

CONFIGURATION AND INPUTS:
  Optional config files beside the scripts: /root/ocp-install.conf and
  /root/osac-install.conf. Use --ocp-config and --osac-config to select others.
  Keep these OSAC inputs in /root/osac-inputs/:
    ci-token.txt  license.zip  pull-secret.json
  Protect the input directory with mode 700 and each file with mode 600.

STATE TO PRESERVE:
  Keep /root/dev-scripts/ocp/<CLUSTER_NAME>/ (including auth/kubeconfig)
  and /root/.ocp-installer-state/ until OCP teardown completes. Preserve the
  dev-scripts checkout while the cluster exists. The kubeconfig grants
  cluster-admin access; keep it protected.
  Keep /root/.astra-osac-state/ while OSAC may be resumed or needs cluster
  identity checks. /root/osac-main is refreshed from upstream main and can
  be recreated.

LOGS AND FAILURE HANDLING:
  Chain runs write run.log and status under
  /tmp/osac-install-chain-logs/latest/ by default. OCP and OSAC installer
  logs default to /tmp/ocp-install-logs/ and /tmp/astra-osac-install-logs/.
  Logs are diagnostic only and /tmp may be cleared on reboot. Set --log-dir
  and each installer's LOG_DIR to persistent storage if needed.
  OCP failure triggers OCP teardown. OSAC failure triggers OSAC teardown,
  then OCP teardown. Cleanup failures are reported; the original failure
  exit status is preserved.

EXAMPLES:
  ./osac-install-chain.sh --check-config
  ./osac-install-chain.sh
  ./osac-install-chain.sh --ocp-config /root/custom-ocp.conf \\
      --osac-config /root/custom-osac.conf --log-dir /var/log/osac-chain

For installer-specific settings and checks, see ocp-install.sh --help and
osac-install.sh --help.''')
    options = parser.add_argument_group('OPTIONS')
    options.add_argument('-h', '--help', action='help',
                         help='show this help message and exit')
    options.add_argument('--ocp-config', metavar='FILE',
                         help='use a different OCP config file')
    options.add_argument('--osac-config', metavar='FILE',
                         help='use a different OSAC config file')
    options.add_argument('--log-dir', metavar='DIR',
                         help='chain logs (absolute path; overrides CHAIN_LOG_DIR)')
    options.add_argument('--check-config', action='store_true',
                         help='preview resolved settings without writes or cluster calls')
    for name in ('ocp-install', 'osac-install', 'ocp-teardown', 'osac-teardown'):
        parser.add_argument('--'+name, default=str(folder / (name+'.sh')), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    chain = Chain()
    code = 1
    scripts = {name: Path(getattr(args, name.replace('-', '_'))).absolute() for name in ('ocp-install','osac-install','ocp-teardown','osac-teardown')}
    ocp_flags = ['--config', str(Path(args.ocp_config).absolute())] if args.ocp_config else []
    osac_flags = ['--config', str(Path(args.osac_config).absolute())] if args.osac_config else []
    def interrupted(signum, frame):
        raise Failure('Interrupted', 128+signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        for script in scripts.values():
            if not script.is_file() or not os.access(script, os.X_OK):
                raise Failure(f'Missing executable: {script}')
        ocp = json.loads(chain.command([scripts['ocp-install'], *ocp_flags, '--config-json'], capture=True))
        osac = json.loads(chain.command([scripts['osac-install'], *osac_flags, '--config-json'], capture=True))
        expected = Path(ocp['KUBECONFIG'])
        if osac.get('KUBECONFIG') and Path(osac['KUBECONFIG']).resolve() != expected.resolve():
            raise Failure(f'OSAC KUBECONFIG conflicts with OCP target: {expected}')
        osac_flags += ['--kubeconfig', str(expected)]
        chain.say(f'TARGET OCP: {ocp["CLUSTER_NAME"]}; kubeconfig: {expected}')
        if args.check_config:
            chain.command([scripts['ocp-install'], *ocp_flags, '--check-config'])
            chain.command([scripts['osac-install'], *osac_flags, '--check-config'])
            return 0
        if os.geteuid() != 0:
            raise Failure('Run the OCP -> OSAC chain as root')
        lockpath = Path('/run/lock/osac-ocp.lock')
        fd = os.open(lockpath, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        if fd != 7:
            os.dup2(fd, 7)
            os.close(fd)
        chain.lock = 7
        try:
            fcntl.flock(7, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Failure('Another OCP operation or chain is active on this host') from None
        assets = expected.parent.parent
        if assets.exists() or assets.is_symlink():
            raise Failure(f'Existing OCP assets: {assets}; teardown the previous cluster first')
        logs = Path(args.log_dir or osac.get('CHAIN_LOG_DIR') or '/tmp/osac-install-chain-logs')
        if not logs.is_absolute():
            raise Failure('Log directory must be absolute')
        private_dir(logs)
        chain.folder = Path(tempfile.mkdtemp(prefix='run-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-'), dir=logs))
        chain.log = (chain.folder / 'run.log').open('w', buffering=1)
        latest = logs / 'latest'
        if latest.is_symlink(): latest.unlink()
        elif latest.exists(): raise Failure('latest must be a symlink')
        latest.symlink_to(chain.folder)
        chain.status('running', 0)
        # These checks never require the new OCP API or start an installation.
        chain.command([scripts['osac-install'], *osac_flags, '--check-inputs'])
        chain.command([scripts['ocp-install'], *ocp_flags, '--preflight'])
        for binary in ('helm',):
            import shutil
            if not shutil.which(binary):
                raise Failure(f'Missing OSAC prerequisite: {binary}; install it before starting OCP')
        version = chain.command(['helm', 'version', '--short'], capture=True).strip()
        if not version.startswith('v3.'):
            raise Failure('OSAC installation requires Helm 3')
        chain.stage = 'ocp'
        chain.status('running', 0)
        chain.say('STEP OCP installation')
        chain.command([scripts['ocp-install'], *ocp_flags], seconds=6*int(ocp.get('STEP_TIMEOUT', '7200')))
        if not expected.is_file() or expected.stat().st_size == 0:
            raise Failure(f'OCP did not produce its kubeconfig: {expected}')
        chain.stage = 'osac'
        chain.status('running', 0)
        chain.say('STEP OSAC installation')
        chain.command([scripts['osac-install'], *osac_flags], seconds=6*int(osac.get('STEP_TIMEOUT', '7200')))
        chain.stage = 'complete'
        code = 0
    except (Failure, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        code = error.code if isinstance(error, Failure) else 1
        chain.say(f'FAIL {error}')
        # Child process groups have stopped before cleanup begins. A second
        # signal does not interrupt cleanup or overwrite the original status.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if chain.stage in ('ocp', 'osac'):
            if chain.stage == 'osac':
                try:
                    chain.command(['oc', '--kubeconfig', str(expected), '--request-timeout=10s', 'get', 'pods,jobs,pvc', '-A', '-o', 'wide'], seconds=20)
                except (Failure, OSError):
                    chain.say('WARN Could not collect cluster diagnostics before cleanup')
            targets = ['osac', 'ocp'] if chain.stage == 'osac' else ['ocp']
            for target in targets:
                try:
                    flags = osac_flags if target == 'osac' else ocp_flags
                    # OCP teardown must use the resolved checkout, regardless of environment.
                    if target == 'ocp': flags = [*flags, '--repo', ocp['DEV_SCRIPTS_DIR']]
                    chain.say(f'STEP {target.upper()} cleanup')
                    chain.command([scripts[target+'-teardown'], *flags], seconds=3600)
                    chain.cleanup[target] = 'success'
                except (Failure, OSError, ValueError) as cleanup_error:
                    chain.cleanup[target] = 'failed'
                    chain.say(f'WARN {target.upper()} cleanup failed: {cleanup_error}')
    finally:
        result = 'success' if code == 0 else 'failed'
        chain.status(result, code)
        if chain.folder:
            chain.say(f'RESULT {result} (exit {code}); OCP cleanup: {chain.cleanup["ocp"]}; OSAC cleanup: {chain.cleanup["osac"]}\nLOG {chain.folder / "run.log"}')
        if chain.log: chain.log.close()
        if chain.lock is not None: os.close(chain.lock)
    return code

if __name__ == '__main__':
    os.umask(0o077)
    sys.exit(main(sys.argv[2:], Path(sys.argv[1]).resolve().parent))
PY
