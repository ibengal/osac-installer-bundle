#!/usr/bin/env bash
# Remove an OSAC CI deployment from an existing, dedicated OpenShift cluster.
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

exec python3 - "$0" "$@" <<'PY'
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import signal
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import time


RELEASES = [('osac', None), ('osac-infra', 'osac-infra'), ('osac-deps', 'osac-deps')]
OWNED_NAMESPACES = {
    'ansible-aap': 'osac-deps', 'cert-manager': 'osac-deps',
    'cert-manager-operator': 'osac-deps', 'keycloak': 'osac-infra',
    'metallb-system': 'osac-deps', 'openshift-cnv': 'osac-deps',
    'openshift-storage': 'osac-deps', 'osac-csi': 'osac',
    'osac-kafka': 'osac-deps', 'multicluster-engine': 'osac-deps',
}
CR_ORDER = {
    name: index for index, name in enumerate((
        'computeinstances', 'baremetalinstances', 'clusterorders', 'volumes',
        'externalipattachments', 'externalips', 'natgateways', 'securitygroups',
        'subnets', 'virtualnetworks', 'fabricdomains', 'externalippools',
        'baremetalpools', 'tenants'))
}
SKIP_NAMESPACES = {'openshift', 'default', 'kube-system', 'kube-public', 'kube-node-lease'}
INFRA_RESOURCES = (
    ('kafkas.kafka.strimzi.io', 'osac-kafka', 'osac-kafka'),
    ('kafkanodepools.kafka.strimzi.io', 'osac-kafka', 'dual-role'),
    ('hyperconvergeds.hco.kubevirt.io', 'openshift-cnv', 'kubevirt-hyperconverged'),
    ('l2advertisements.metallb.io', 'metallb-system', 'caas-l2-advertisement'),
    ('ipaddresspools.metallb.io', 'metallb-system', 'caas-address-pool'),
    ('metallbs.metallb.io', 'metallb-system', 'metallb'),
    ('lvmclusters.lvm.topolvm.io', 'openshift-storage', 'lvms-cluster'),
)
OPERATOR_NAMESPACES = {
    'cert-manager', 'cert-manager-operator', 'metallb-system',
    'openshift-cnv', 'openshift-storage', 'osac-deps', 'multicluster-engine', 'ansible-aap', 'osac-csi',
}


class TeardownError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


class TeardownInterrupted(KeyboardInterrupt):
    def __init__(self, signum):
        self.signum = signum



def literal_settings(path):
    values = {}
    pattern = re.compile(r'^(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=\s*(.*)$')
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        match = pattern.fullmatch(line)
        if not match:
            raise TeardownError(f'Invalid assignment in {path}:{number}')
        try:
            words = shlex.split(match[2], comments=True)
        except ValueError:
            raise TeardownError(f'Invalid literal in {path}:{number}') from None
        if len(words) > 1 or (words and not re.fullmatch(r'[A-Za-z0-9_./-]*', words[0])):
            raise TeardownError(f'Unsafe value in {path}:{number}')
        values[match[1]] = words[0] if words else ''
    return values


def absolute_path(value, label):
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', value):
        raise TeardownError(f'{label} must be an absolute path without spaces or shell metacharacters')
    return Path(value)


def resolve(args, script_dir):
    config = absolute_path(args.config or str(script_dir / 'osac-install.conf'), 'config')
    if args.config and not config.is_file():
        raise TeardownError(f'Config not found: {config}')
    values = literal_settings(config) if config.is_file() else {}
    namespace = args.namespace or values.get('NAMESPACE') or 'osac'
    if not re.fullmatch(r'[a-z0-9](?:[-a-z0-9]*[a-z0-9])?', namespace) or len(namespace) > 63:
        raise TeardownError('Invalid OSAC namespace')
    if namespace in SKIP_NAMESPACES or namespace.startswith(('kube-', 'openshift-')) or namespace in OWNED_NAMESPACES or namespace in {'osac-deps', 'osac-infra'}:
        raise TeardownError('Protected or infrastructure namespace cannot be the OSAC target')
    profile = values.get('PROFILE') or 'vmaas-ci'
    if profile not in {'vmaas-ci', 'bmaas-ci', 'caas-ci', 'full-ci'}:
        raise TeardownError('Unsupported OSAC profile')
    kubeconfig = absolute_path(args.kubeconfig or values.get('KUBECONFIG', ''), 'KUBECONFIG')
    if not kubeconfig.is_file():
        raise TeardownError(f'Kubeconfig is missing: {kubeconfig}')
    log_root = absolute_path(args.log_dir or values.get('LOG_DIR') or '/tmp/astra-osac-install-logs', 'LOG_DIR')
    timeout = values.get('CLEANUP_TIMEOUT') or '600'
    if not re.fullmatch(r'[1-9][0-9]{0,4}', timeout):
        raise TeardownError('CLEANUP_TIMEOUT must be 1..99999 seconds')
    return dict(timeout=int(timeout), config=config, namespace=namespace, profile=profile,
                kubeconfig=kubeconfig, log_root=log_root)


def safe_environment():
    env = dict(os.environ)
    if env.get('HELM_DRIVER', '') not in ('', 'secret', 'secrets'):
        raise TeardownError('Unset HELM_DRIVER; teardown requires the standard Helm Secret store')
    for key in ('KUBECONFIG', 'OC_IMPERSONATE', 'HELM_KUBECONTEXT',
                'HELM_KUBEAPISERVER', 'HELM_KUBETOKEN', 'HELM_KUBEASUSER',
                'HELM_KUBEASGROUPS', 'HELM_KUBECAFILE', 'HELM_KUBETLS_SERVER_NAME',
                'HELM_KUBEINSECURE_SKIP_TLS_VERIFY'):
        env.pop(key, None)
    return env


def stop_process_group(child):
    # The parent can exit while descendants keep running with closed stdout.
    handlers = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        try:
            os.killpg(child.pid, signal.SIGTERM)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                child.poll()
                try:
                    os.killpg(child.pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.communicate()
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)


def run(args, plan, *, check=True, timeout=60, log=None):
    env = safe_environment()
    if args[0] == 'oc':
        args = ['oc', f'--kubeconfig={plan["kubeconfig"]}', '--request-timeout=30s', *args[1:]]
    elif args[0] == 'helm':
        args = ['helm', '--kubeconfig', str(plan['kubeconfig']), *args[1:]]
    if log:
        log.say('STEP  ' + shlex.join(args))
    try:
        with subprocess.Popen(args, env=env, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, start_new_session=True) as child:
            try:
                stdout, stderr = child.communicate(timeout=timeout)
                result = subprocess.CompletedProcess(args, child.returncode, stdout, stderr)
            finally:
                stop_process_group(child)
    except subprocess.TimeoutExpired as error:
        raise TeardownError(f'Command timed out: {shlex.join(args)}', 124) from error
    except OSError as error:
        raise TeardownError(f'Command failed to start: {shlex.join(args)}: {error}') from error
    if log:
        for line in (result.stdout + result.stderr).splitlines():
            log.say(line)
    if check and result.returncode:
        code = result.returncode if result.returncode > 0 else 128 - result.returncode
        detail = result.stderr.strip()[-2000:]
        raise TeardownError(f'Command exited {code}: {shlex.join(args)}' + (f': {detail}' if detail else ''), code)
    return result.stdout


def get_json(args, plan):
    try:
        return json.loads(run(args, plan))
    except json.JSONDecodeError as error:
        raise TeardownError(f'Invalid JSON from {args[0]}') from error


def inventory(plan):
    if plan['namespace'] in SKIP_NAMESPACES or plan['namespace'].startswith(('kube-', 'openshift-')) or plan['namespace'] in OWNED_NAMESPACES or plan['namespace'] in {'osac-infra', 'osac-deps'}:
        raise TeardownError('Protected namespace cannot be the OSAC target')
    server = run(['oc', 'whoami', '--show-server'], plan).strip()
    if run(['oc', 'auth', 'can-i', '*', '*', '--all-namespaces'], plan).strip() != 'yes':
        raise TeardownError('Cluster-admin access is required')
    releases = get_json(['helm', 'list', '--all-namespaces', '--all', '-o', 'json'], plan)
    if not isinstance(releases, list):
        raise TeardownError('Unexpected Helm release inventory')
    expected = {'osac': plan['namespace'], 'osac-infra': 'osac-infra', 'osac-deps': 'osac-deps'}
    found = []
    for item in releases:
        if item.get('name') in expected:
            if item.get('namespace') != expected[item['name']]:
                raise TeardownError(f'Conflicting {item["name"]} release in {item.get("namespace")}')
            found.append(item['name'])
    namespaces = get_json(['oc', 'get', 'namespace', '-o', 'json'], plan)['items']
    namespace_plan = []
    skipped = []
    present_releases = set(found)
    for item in namespaces:
        metadata = item['metadata']
        name = metadata['name']
        annotations = metadata.get('annotations') or {}
        owner = annotations.get('meta.helm.sh/release-name', '')
        owner_namespace = annotations.get('meta.helm.sh/release-namespace', '')
        labels = metadata.get('labels') or {}
        marker = annotations.get('osac.openshift.io/installer-namespace')
        if name in {plan['namespace'], 'osac-infra', 'osac-deps'} and marker not in (None, plan['namespace']):
            raise TeardownError(f'Conflicting installer ownership on namespace {name}')
        if name == plan['namespace']:
            if (owner, owner_namespace) not in {('osac-infra', 'osac-infra'), ('osac', plan['namespace'])} and not (not owner and ('osac' in present_releases or marker == plan['namespace'])):
                raise TeardownError(f'OSAC namespace {name} belongs to another Helm release')
            namespace_plan.append(name)
        elif name in ('osac-deps', 'osac-infra'):
            if owner:
                raise TeardownError(f'Infrastructure namespace {name} belongs to another Helm release')
            if name in present_releases or annotations.get('osac.openshift.io/installer-namespace') == plan['namespace']:
                namespace_plan.append(name)
            else:
                skipped.append(name)
        elif name in OWNED_NAMESPACES:
            expected_owner = OWNED_NAMESPACES[name]
            expected_namespace = plan['namespace'] if expected_owner == 'osac' else expected_owner
            if (owner, owner_namespace) != (expected_owner, expected_namespace):
                raise TeardownError(f'Namespace {name} is not owned by the expected OSAC release')
            namespace_plan.append(name)
        elif name not in SKIP_NAMESPACES and not name.startswith(('kube-', 'openshift-')):
            if labels.get('osac.openshift.io/project') == plan['namespace'] and labels.get('osac.openshift.io/tenant-ref'):
                namespace_plan.append(name)
            elif annotations.get('osac.openshift.io/tenant'):
                skipped.append(name)
    if len(namespace_plan) > 30:
        raise TeardownError('Too many matching namespaces for automatic teardown')
    namespace_set = set(namespace_plan)
    foreign = [f'{item["name"]}@{item["namespace"]}' for item in releases
               if item.get('namespace') in namespace_set and item.get('name') not in expected]
    if foreign:
        raise TeardownError('Other Helm releases use cleanup namespaces: ' + ', '.join(foreign))
    all_crds = get_json(['oc', 'get', 'crd', '-o', 'json'], plan)['items']
    crds = []
    for item in all_crds:
        if item['spec'].get('group') != 'osac.openshift.io':
            continue
        metadata = item['metadata']
        annotations = metadata.get('annotations') or {}
        if (annotations.get('meta.helm.sh/release-name'), annotations.get('meta.helm.sh/release-namespace')) != ('osac', plan['namespace']):
            raise TeardownError(f'OSAC CRD has unexpected ownership: {metadata["name"]}')
        if item['spec'].get('scope') != 'Namespaced':
            raise TeardownError(f'Unexpected cluster-scoped OSAC CRD: {metadata["name"]}')
        plural = item['spec']['names']['plural']
        crds.append((plural, metadata['name']))
    crds.sort(key=lambda row: (CR_ORDER.get(row[0], 100), row[0]))
    cr_instances = []
    if crds:
        resources = ','.join(name for _, name in crds)
        objects = get_json(['oc', 'get', resources, '--all-namespaces', '-o', 'json'], plan)['items']
        by_kind = {item['spec']['names']['kind']: item['metadata']['name'] for item in all_crds
                   if item['spec'].get('group') == 'osac.openshift.io'}
        for item in objects:
            metadata = item['metadata']
            if metadata['namespace'] not in namespace_set:
                raise TeardownError(f'OSAC CR outside this deployment: {metadata["namespace"]}/{metadata["name"]}; refusing global CRD removal')
            cr_instances.append((by_kind[item['kind']], metadata['namespace'], metadata['name']))
    cr_instances.sort(key=lambda row: (CR_ORDER.get(row[0].split('.')[0], 100), row[0], row[1], row[2]))
    if len(cr_instances) > 1000:
        raise TeardownError('Too many OSAC custom resources for automatic teardown')
    available_crds = {item['metadata']['name'] for item in all_crds}
    infra_resources = []
    # Discover actual names rather than assuming the chart's default names.
    for resource, namespace in dict.fromkeys((r, n) for r, n, _ in INFRA_RESOURCES):
        if resource not in available_crds or namespace not in namespace_set:
            continue
        items = get_json(['oc', 'get', resource, '-n', namespace, '-o', 'json'], plan)['items']
        for item in items:
            metadata = item['metadata']
            infra_resources.append((resource, namespace, metadata['name']))
    # Cluster-scoped singletons must carry explicit installer ownership. Older
    # manually installed singletons are deliberately not inferred from names.
    for resource in ('agentserviceconfigs.agent-install.openshift.io',
                     'multiclusterengines.multicluster.openshift.io'):
        if resource not in available_crds:
            continue
        for item in get_json(['oc', 'get', resource, '-o', 'json'], plan)['items']:
            metadata = item['metadata']
            if (metadata.get('annotations') or {}).get('osac.openshift.io/installer-namespace') != plan['namespace']:
                if 'multicluster-engine' in namespace_set:
                    raise TeardownError(f'Unverified cluster resource ownership: {resource}/{metadata["name"]}; inspect before cleanup')
                continue
            infra_resources.append((resource, '', metadata['name']))
    # Remove consumers (AgentServiceConfig) before their MCE controller.
    infra_resources.sort(key=lambda row: (0 if row[0].startswith('agentserviceconfigs.') else
                                         1 if row[0].startswith('multiclusterengines.') else 2))

    if any(resource == 'hyperconvergeds.hco.kubevirt.io' for resource, _, _ in infra_resources):
        for resource in ('virtualmachines.kubevirt.io', 'virtualmachineinstances.kubevirt.io'):
            if resource not in available_crds:
                continue
            for item in get_json(['oc', 'get', resource, '--all-namespaces', '-o', 'json'], plan)['items']:
                if item['metadata']['namespace'] not in namespace_set:
                    raise TeardownError('Virtualization is used outside cleanup namespaces: ' + item['metadata']['namespace'] + '/' + item['metadata']['name'])

    cluster_rbac = []
    rbac = get_json(['oc', 'get', 'clusterroles,clusterrolebindings', '-o', 'json'], plan)['items']
    verified_hook_roles = set()
    for item in rbac:
        metadata = item['metadata']
        labels = metadata.get('labels') or {}
        annotations = metadata.get('annotations') or {}
        subjects = item.get('subjects') or []
        if (item['kind'] == 'ClusterRoleBinding' and annotations.get('helm.sh/hook')
                and labels.get('app.kubernetes.io/managed-by') == 'Helm'
                and labels.get('app.kubernetes.io/instance') in expected
                and annotations.get('meta.helm.sh/release-name', labels.get('app.kubernetes.io/instance')) in expected
                and subjects and all(x.get('kind') == 'ServiceAccount' and x.get('namespace') in namespace_set for x in subjects)
                and item.get('roleRef', {}).get('kind') == 'ClusterRole'):
            verified_hook_roles.add(item['roleRef']['name'])
    for item in rbac:
        metadata = item['metadata']
        labels = metadata.get('labels') or {}
        annotations = metadata.get('annotations') or {}
        release = annotations.get('meta.helm.sh/release-name') or labels.get('app.kubernetes.io/instance')
        if release not in expected or labels.get('app.kubernetes.io/managed-by') != 'Helm':
            continue
        marker = annotations.get('osac.openshift.io/installer-namespace')
        if marker not in (None, plan['namespace']):
            raise TeardownError(f'Conflicting installer ownership on cluster RBAC: {metadata["name"]}')
        release_namespace = annotations.get('meta.helm.sh/release-namespace')
        if release_namespace and release_namespace != expected[release]:
            raise TeardownError(f'Conflicting cluster RBAC owner: {metadata["name"]}')
        if not release_namespace:
            subjects = item.get('subjects') or []
            verified = marker == plan['namespace'] or annotations.get('helm.sh/hook') and (
                (item['kind'] == 'ClusterRole' and metadata['name'] in verified_hook_roles) or
                (item['kind'] == 'ClusterRoleBinding' and subjects and all(
                    x.get('kind') == 'ServiceAccount' and x.get('namespace') in namespace_set for x in subjects)))
            if not verified:
                skipped.append('cluster RBAC ' + metadata['name'])
                continue
        resource = {'ClusterRole': 'clusterrole', 'ClusterRoleBinding': 'clusterrolebinding'}.get(item['kind'])
        if resource:
            cluster_rbac.append((resource, metadata['name']))
    volumes = get_json(['oc', 'get', 'pv', '-o', 'json'], plan)['items']
    owned_volumes = selected_volumes(volumes, namespace_set, plan)
    reject_retained(owned_volumes)
    if any(r == 'lvmclusters.lvm.topolvm.io' for r, _, _ in infra_resources):
        for item in volumes:
            if item.get('spec', {}).get('csi', {}).get('driver') == 'topolvm.io' and item not in owned_volumes:
                raise TeardownError('LVMS still serves a volume outside this teardown: ' + item['metadata']['name'])
    return dict(volumes=[x['metadata']['name'] for x in owned_volumes], cluster_rbac=cluster_rbac, server=server, releases=found, namespaces=sorted(namespace_plan), skipped=skipped,
                crds=[name for _, name in crds], custom_resources=cr_instances,
                infra_resources=infra_resources)


def selected_volumes(volumes, namespaces, plan):
    selected = []
    for item in volumes:
        claim = item.get('spec', {}).get('claimRef') or {}
        annotations = item['metadata'].get('annotations') or {}
        recorded = annotations.get('osac.openshift.io/teardown-namespace')
        if recorded == plan['namespace']:
            if not claim.get('uid') or annotations.get('osac.openshift.io/teardown-claim-uid') != claim['uid']:
                raise TeardownError('Previously marked PV changed its claim; inspect before cleanup: ' + item['metadata']['name'])
            selected.append(item)
        elif claim.get('namespace') in namespaces:
            if recorded:
                raise TeardownError('PV belongs to another teardown: ' + item['metadata']['name'])
            if not claim.get('uid'):
                raise TeardownError('PV has no claim UID; cannot safely track cleanup: ' + item['metadata']['name'])
            selected.append(item)
    return selected


def reject_retained(volumes):
    retained = [x['metadata']['name'] for x in volumes if x.get('spec', {}).get('persistentVolumeReclaimPolicy') != 'Delete']
    if retained:
        raise TeardownError('Retain/unknown-policy PVs require explicit storage cleanup before teardown: ' + ', '.join(retained))


def mark_volumes(plan, contents, log, only_namespaces=None):
    volumes = selected_volumes(get_json(['oc', 'get', 'pv', '-o', 'json'], plan)['items'], set(contents['namespaces']), plan)
    if only_namespaces is not None:
        volumes = [x for x in volumes if x['spec']['claimRef'].get('namespace') in only_namespaces]
    reject_retained(volumes)
    for item in volumes:
        # Persist enough identity to recognize a leftover after its namespace is
        # gone. Never infer ownership from a namespace name on a later rerun.
        run(['oc', 'annotate', 'pv', item['metadata']['name'],
             'osac.openshift.io/teardown-namespace=' + plan['namespace'],
             'osac.openshift.io/teardown-claim-uid=' + item['spec']['claimRef']['uid'], '--overwrite'], plan, log=log)
    return volumes


def drain_volumes(plan, contents, log, only_namespaces=None):
    for item in mark_volumes(plan, contents, log, only_namespaces):
        run(['oc', 'wait', '--for=delete', 'pv/' + item['metadata']['name'],
             f'--timeout={plan["timeout"]}s'], plan, log=log, timeout=plan['timeout'] + 60)


def delete_namespace(name, plan, log):
    run(['oc', 'delete', 'namespace', name, '--ignore-not-found', '--wait=true',
         f'--timeout={plan["timeout"]}s'], plan, log=log, timeout=plan['timeout'] + 60)


def private_directory(path):
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise TeardownError(f'Log directory must be owner-only: {path}')


class Log:
    def __init__(self, root):
        private_directory(root)
        self.folder = root / 'teardown'
        private_directory(self.folder)
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        self.path = Path(tempfile.mkdtemp(prefix=f'run-{stamp}-', dir=self.folder))
        self.file = (self.path / 'run.log').open('w', buffering=1)
        self.status = self.path / 'status'
        self.stage = 'preparation'
        self.started = stamp
        self.write_status('running', 0)
        latest = self.folder / 'latest'
        if latest.is_symlink():
            latest.unlink()
        elif latest.exists():
            raise TeardownError('Teardown latest path is not a symlink')
        latest.symlink_to(self.path.name)

    def say(self, value):
        print(value, flush=True)
        self.file.write(value + '\n')

    def write_status(self, result, code):
        self.status.write_text(f'result={result}\nstage={self.stage}\nexit_code={code}\nstarted_at={self.started}\nupdated_at={datetime.now(timezone.utc).isoformat()}\n')

    def close(self):
        self.file.close()


def acquire_lock(plan):
    server = run(['oc', 'whoami', '--show-server'], plan).strip().rstrip('/')
    root = Path('/tmp') / f'osac-operation-locks-{os.geteuid()}'
    private_directory(root)
    path = root / ('cluster-' + hashlib.sha256(server.encode()).hexdigest() + '.lock')
    if path.is_symlink():
        raise TeardownError('Installer lock must not be a symlink')
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise TeardownError('Another OSAC install or teardown targets this cluster from this host') from None
    return fd


def execute(plan, contents, log):
    (log.path / 'inventory.json').write_text(json.dumps(contents, indent=2) + '\n')
    log.say(f'TARGET {contents["server"]} namespace={plan["namespace"]}')
    for name in contents['namespaces']:
        if name in (plan['namespace'], 'osac-deps', 'osac-infra'):
            run(['oc', 'annotate', 'namespace', name, f'osac.openshift.io/installer-namespace={plan["namespace"]}', '--overwrite'], plan, log=log)
    for resource, name in contents['cluster_rbac']:
        run(['oc', 'annotate', resource, name, f'osac.openshift.io/installer-namespace={plan["namespace"]}', '--overwrite'], plan, log=log)
    # Stop fulfillment reconciliation while operators perform finalizer cleanup.
    tracked_volumes = mark_volumes(plan, contents, log)
    if plan['namespace'] in contents['namespaces']:
        deployments = get_json(['oc', 'get', 'deployment', '-n', plan['namespace'], '-o', 'json'], plan)['items']
        for item in deployments:
            if item['metadata']['name'] == 'fulfillment-controller':
                run(['oc', 'scale', 'deployment/fulfillment-controller', '-n', plan['namespace'], '--replicas=0'], plan, log=log)
                run(['oc', 'rollout', 'status', 'deployment/fulfillment-controller', '-n', plan['namespace'], f'--timeout={plan.get("timeout", 600)}s'], plan, log=log, timeout=plan.get('timeout', 600) + 30)
    for resource, namespace, name in contents['custom_resources']:
        log.stage = 'custom_resources'
        log.write_status('running', 0)
        run(['oc', 'delete', resource, name, '-n', namespace, '--ignore-not-found', '--wait=true', f'--timeout={plan.get("timeout", 600)}s'], plan, log=log, timeout=plan.get('timeout', 600) + 60)
    # Remove tenant test VMs/PVCs before uninstalling their OSAC/CSI/KubeVirt
    # controllers. OSAC CR finalizers above still had AAP and operators alive.
    tenant_namespaces = [n for n in contents['namespaces'] if n != plan['namespace'] and n not in OWNED_NAMESPACES and n not in {'osac-deps', 'osac-infra'}]
    log.stage = 'tenant_namespaces'
    log.write_status('running', 0)
    for name in tenant_namespaces:
        delete_namespace(name, plan, log)
    orphaned_claim_namespaces = {x['spec']['claimRef']['namespace'] for x in tracked_volumes
                                if x['spec']['claimRef']['namespace'] not in contents['namespaces']}
    drain_volumes(plan, contents, log, set(tenant_namespaces) | orphaned_claim_namespaces)
    if contents['crds']:
        remaining = get_json(['oc', 'get', ','.join(contents['crds']), '--all-namespaces', '-o', 'json'], plan)['items']
        if remaining:
            raise TeardownError('OSAC custom resources still exist or were recreated; controllers kept for cleanup')
    for release, fixed_namespace in RELEASES[:2]:
        log.stage = 'helm_' + release
        log.write_status('running', 0)
        run(['helm', 'uninstall', release, '--namespace', fixed_namespace or plan['namespace'],
             '--ignore-not-found', '--wait', '--timeout', f'{plan.get("timeout", 600)}s'], plan, log=log, timeout=plan.get('timeout', 600) + 60)
    log.stage = 'infra_resources'
    log.write_status('running', 0)
    for resource, namespace, name in contents['infra_resources']:
        if resource in {'lvmclusters.lvm.topolvm.io', 'hyperconvergeds.hco.kubevirt.io'}:
            continue
        run(['oc', 'delete', resource, name, *(['-n', namespace] if namespace else []),
             '--ignore-not-found', '--wait=true', f'--timeout={plan.get("timeout", 600)}s'], plan,
            log=log, timeout=plan.get('timeout', 600) + 60)
    # Remove workloads and their PVCs while the storage operator is still alive.
    log.stage = 'workload_namespaces'
    log.write_status('running', 0)
    workload_namespaces = [name for name in contents['namespaces']
                           if name not in OPERATOR_NAMESPACES]
    for name in workload_namespaces:
        delete_namespace(name, plan, log)
    log.stage = 'volume_cleanup'
    log.write_status('running', 0)
    drain_volumes(plan, contents, log)
    # All tenant VMs and consumer PVCs are now gone. Keep their operators until
    # this point so finalizers and Delete-policy storage can finish normally.
    log.stage = 'storage_resources'
    log.write_status('running', 0)
    for resource, namespace, name in contents['infra_resources']:
        if resource not in {'hyperconvergeds.hco.kubevirt.io', 'lvmclusters.lvm.topolvm.io'}:
            continue
        run(['oc', 'delete', resource, name, *(['-n', namespace] if namespace else []),
             '--ignore-not-found', '--wait=true', f'--timeout={plan["timeout"]}s'], plan,
            log=log, timeout=plan['timeout'] + 60)
    log.stage = 'helm_osac-deps'
    log.write_status('running', 0)
    run(['helm', 'uninstall', 'osac-deps', '--namespace', 'osac-deps',
         '--ignore-not-found', '--wait', '--timeout', f'{plan.get("timeout", 600)}s'], plan, log=log, timeout=plan.get('timeout', 600) + 60)
    log.stage = 'namespaces'
    log.write_status('running', 0)
    for name in contents['namespaces']:
        delete_namespace(name, plan, log)
    log.stage = 'crds'
    log.write_status('running', 0)
    if contents['crds']:
        run(['oc', 'delete', 'crd', *contents['crds'], '--ignore-not-found', '--wait=true', f'--timeout={plan.get("timeout", 600)}s'],
            plan, log=log, timeout=plan.get('timeout', 600) + 60)
    for resource, name in contents.get('cluster_rbac', []):
        run(['oc', 'delete', resource, name, '--ignore-not-found', '--wait=true', f'--timeout={plan.get("timeout", 600)}s'], plan, log=log, timeout=plan.get('timeout', 600)+60)
    log.stage = 'verification'
    log.write_status('running', 0)
    remaining = get_json(['helm', 'list', '--all-namespaces', '--all', '-o', 'json'], plan)
    if any(item.get('name') in {'osac', 'osac-infra', 'osac-deps'} for item in remaining):
        raise TeardownError('OSAC Helm releases remain')
    remaining_namespaces = {item['metadata']['name'] for item in get_json(['oc', 'get', 'namespace', '-o', 'json'], plan)['items']}
    if remaining_namespaces.intersection(contents['namespaces']):
        raise TeardownError('OSAC or test namespaces remain')
    remaining_crds = {item['metadata']['name'] for item in get_json(['oc', 'get', 'crd', '-o', 'json'], plan)['items']}
    if remaining_crds.intersection(contents['crds']):
        raise TeardownError('OSAC CRDs remain')
    volumes = selected_volumes(get_json(['oc', 'get', 'pv', '-o', 'json'], plan)['items'], set(contents['namespaces']), plan)
    if volumes:
        raise TeardownError('PV cleanup incomplete: ' + ', '.join(x['metadata']['name'] for x in volumes))
    remaining_rbac = {(x['kind'].lower(), x['metadata']['name']) for x in get_json(['oc', 'get', 'clusterroles,clusterrolebindings', '-o', 'json'], plan)['items']}
    if remaining_rbac.intersection(map(tuple, contents['cluster_rbac'])):
        raise TeardownError('Owned cluster RBAC remains')
    log.say('PASS  OSAC releases, owned namespaces, test leftovers, and retained CRDs removed')
    log.say('INFO  Kept OCP, installation config, credentials, checkout, and private logs')


def main(argv, script_dir):
    parser = argparse.ArgumentParser(prog='osac-teardown.sh', description='Remove OSAC from a dedicated OpenShift lab cluster, including failed-install and test leftovers.',
        epilog='This is destructive: --dry-run lists targets without changes. Requires Python 3.9+, oc and Helm, plus cluster-admin kubeconfig. Config is optional; namespace defaults to osac. CLEANUP_TIMEOUT defaults to 600 seconds per deletion. License, pull-secret inputs and Git checkout are not required. Only verified deployment/tenant ownership is cleaned; ambiguous resources stop cleanup or are reported untouched. Use one automation host per cluster. Retain-policy PVs block teardown before deletion. Delete-policy PVs are tracked by claim UID and awaited before removing storage operators. Tenant namespaces are removed while VM/CSI operators remain. No finalizers or Helm release records are force-removed. Exit codes preserve command failures, timeout 124, SIGINT 130 and SIGTERM 143. Logs: /tmp/astra-osac-install-logs/teardown/latest/.')
    parser.add_argument('--config', help='optional OSAC installer config; uses osac-install.conf beside this script when present')
    parser.add_argument('--kubeconfig', help='explicit cluster-admin kubeconfig, overrides config')
    parser.add_argument('--namespace', help='OSAC namespace, overrides config')
    parser.add_argument('--log-dir', help='OSAC installer log directory, overrides config')
    parser.add_argument('--dry-run', action='store_true', help='show exact release, custom-resource, namespace and CRD cleanup plan without writes')
    args = parser.parse_args(argv)
    def interrupted(signum, frame):
        raise TeardownInterrupted(signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    os.umask(0o077)
    log = None
    lock_fd = None
    code = 1
    try:
        plan = resolve(args, script_dir)
        if not args.dry_run:
            lock_fd = acquire_lock(plan)
        if not args.dry_run:
            log = Log(plan['log_root'])
        contents = inventory(plan)
        print(f'TARGET {contents["server"]} namespace={plan["namespace"]}', flush=True)
        for name in contents.get('skipped', []):
            print(f'WARN  Unverified resource left untouched: {name}', flush=True)
        for key in ('releases', 'custom_resources', 'infra_resources', 'namespaces', 'crds', 'cluster_rbac', 'volumes'):
            print(f'{key.upper()} {json.dumps(contents[key])}', flush=True)
        if args.dry_run:
            print('DRY RUN: no resources or files changed', flush=True)
            return 0
        execute(plan, contents, log)
        code = 0
    except KeyboardInterrupt as error:
        code = 128 + error.signum if isinstance(error, TeardownInterrupted) else 130
        if log:
            log.say('FAIL  Teardown interrupted; inspect remaining resources before retrying')
    except (TeardownError, OSError, KeyError, ValueError) as error:
        message = f'FAIL  {error}'
        if log:
            log.say(message)
        else:
            print(message, file=sys.stderr)
        code = error.code if isinstance(error, TeardownError) else 1
    finally:
        if log:
            outcome = 'success' if code == 0 else 'failed'
            log.write_status(outcome, code)
            log.say(f'RESULT {outcome} (exit {code})\nLOG {log.path / "run.log"}\nSTATUS {log.status}')
            log.close()
        if lock_fd is not None:
            os.close(lock_fd)
    return code


if __name__ == '__main__':
    sys.exit(main(sys.argv[2:], Path(sys.argv[1]).resolve().parent))
PY
