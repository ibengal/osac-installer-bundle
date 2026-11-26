# OSAC Installer Bundle

This repository contains shell wrappers for provisioning a dedicated
OpenShift cluster with `dev-scripts`, deploying OSAC on that cluster, verifying
the installation, and safely removing it. The wrappers are designed for a
fresh lab host. They refuse to reuse an existing cluster at the configured
target.

The bundle contains no credentials. OpenShift pull secrets, the OpenShift CI
token, and the AAP subscription manifest are supplied separately at runtime.

## Contents

| File | Purpose |
| --- | --- |
| `ocp-install.sh` | Check prerequisites, clone/update `dev-scripts`, create the VM-based OpenShift cluster, and verify its health. |
| `ocp-teardown.sh` | Inspect and remove the OCP cluster and its VM data. |
| `osac-install.sh` | Deploy OSAC to an existing dedicated OpenShift cluster and verify the Helm releases and workloads. |
| `osac-teardown.sh` | Inspect and remove an OSAC deployment using its recorded ownership and cluster state. |
| `osac-install-chain.sh` | Run OCP installation followed by OSAC installation, with a check that both stages use the same kubeconfig. |
| `ocp-install.conf` | Generic, editable OCP settings. |
| `osac-install.conf` | Generic, editable OSAC settings. |

## How it fits together

The chain performs these steps:

1. Load both configuration files and verify that their kubeconfig targets agree.
2. Validate the private input files and local host requirements.
3. Install OpenShift through `dev-scripts` using `ocp-install.sh`.
4. Install OSAC with `osac-install.sh` and the kubeconfig produced by OCP.
5. Record status and logs. On failure, run the relevant teardown scripts.

The default configuration creates a three-node compact OpenShift cluster named
`ostest`, then deploys the `vmaas-ci` OSAC profile. That profile expects
virtualization support and unused block devices for LVMS. Do not use a CI
profile for production workloads.

The scripts intentionally use literal `KEY=value` configuration. They do not
source config files, expand variables, or run commands from values. Command-line
options take precedence over values in a configuration file.

## Host requirements

Use an x86_64 host running RHEL 9, CentOS Stream 9, AlmaLinux 9, or Rocky Linux
9. The OCP installer needs:

- Root access and preferably a dedicated physical host.
- `/dev/kvm` and hardware virtualization exposed to the cluster nodes.
- At least 80 GiB free for the dev-scripts working directory.
- At least 64 GiB RAM for the default three-node layout.
- Working package repositories.
- Outbound access to GitHub, `quay.io`, `registry.redhat.io`, and the other
  registries required by the selected OpenShift release and OSAC profile.

The OSAC installer additionally requires Bash 4+, `oc`, Helm 3, Git, Make, `jq`,
Python 3.9+, `flock`, `timeout`, and `tee`. The scripts check their remaining
prerequisites before making cluster changes.

## Configuration

The included configs use these generic locations:

| Setting | Default |
| --- | --- |
| dev-scripts checkout | `/opt/dev-scripts` |
| OCP working directory | `/opt/dev-scripts-work` |
| Private OSAC inputs | `/opt/osac-inputs` |
| OSAC source checkout | `/opt/osac-main` |
| OCP kubeconfig | `/opt/dev-scripts/ocp/ostest/auth/kubeconfig` |
| Cluster name | `ostest` |

Edit both files if you choose another layout. Keep these values aligned:

- `DEV_SCRIPTS_DIR` in `ocp-install.conf`.
- `WORKING_DIR` in `ocp-install.conf`; it must differ from
  `DEV_SCRIPTS_DIR`.
- `CLUSTER_NAME` in `ocp-install.conf`.
- `KUBECONFIG` in `osac-install.conf`.
- `INPUTS_DIR`, `CI_TOKEN_FILE`, and `PERSONAL_PULL_SECRET` in
  `ocp-install.conf`.
- `INPUTS_DIR` in `osac-install.conf`.

Some `--help` examples in `ocp-install.sh` still show `/root/...` paths. Those are
illustrative of the original root-host layout; use the configuration values
above.

The OCP kubeconfig path is derived as:

```text
<DEV_SCRIPTS_DIR>/ocp/<CLUSTER_NAME>/auth/kubeconfig
```

An exported `DEV_SCRIPTS_DIR` has command-line priority, so unset it before
running the chain when you want the configuration file to control the path:

```bash
unset DEV_SCRIPTS_DIR
```

To override the OSAC profile or use full infrastructure/instance values files,
set `PROFILE`, `INFRA_VALUES`, or `INSTANCE_VALUES` in `osac-install.conf`.
Values files replace the selected profile's corresponding file; they are not
layered on top of it.

## Private inputs

Create the input directory with restrictive permissions:

```bash
sudo install -d -m 700 /opt/osac-inputs
```

Place these files in it:

| File | Contents |
| --- | --- |
| `ci-token.txt` | Only the token value from the OpenShift CI login command. |
| `license.zip` | AAP subscription manifest exported from the Red Hat Customer Portal. |
| `pull-secret.json` | Red Hat OpenShift pull-secret JSON with a nonempty `auths` object. |

Restrict the files:

```bash
sudo chmod 600 \
  /opt/osac-inputs/ci-token.txt \
  /opt/osac-inputs/license.zip \
  /opt/osac-inputs/pull-secret.json
```

Never commit these files or place their values in the configuration files.
The repository's `.gitignore` excludes common credential and runtime filenames
as a guardrail, not as a replacement for checking what you publish.

## Install

Clone the repository onto the target host and make the scripts executable. This
repository is private, so use an authenticated clone method such as `gh repo
clone` or SSH:

```bash
gh repo clone ibengal/osac-installer-bundle
cd osac-installer-bundle
sudo chmod 700 ./*.sh
sudo chmod 600 ./*.conf
```

Preview both resolved configurations without contacting a cluster:

```bash
unset DEV_SCRIPTS_DIR
sudo ./osac-install-chain.sh --check-config
```

The preview should show the same OCP kubeconfig path used by OSAC. It validates
syntax and path consistency, but it does not validate credential contents,
registry access, release availability, or host capacity.

Run the full installation inside `tmux` so it survives an SSH disconnect:

```bash
tmux new -s osac-install
```

Inside that session:

```bash
sudo env -u DEV_SCRIPTS_DIR ./osac-install-chain.sh
```

The OCP stage clones or updates `dev-scripts`, prepares the host, creates the
cluster, and waits for OpenShift health. The OSAC stage validates and stages the
private inputs, checks cluster readiness, installs infrastructure and OSAC,
configures the Keycloak UI client, and verifies the deployment.

## Verify

Verify an existing OSAC deployment without reinstalling it:

```bash
sudo ./osac-install.sh --verify-only
```

The verification stage checks Helm release status, rollouts, pod readiness, and
admitted routes. It writes a private run directory beneath
`/tmp/astra-osac-install-logs/latest/` by default, including `run.log`,
`status`, and `images.tsv`.

## Teardown

Remove OSAC before removing OCP. Review both dry-run plans first:

```bash
sudo ./osac-teardown.sh --dry-run
sudo ./ocp-teardown.sh --dry-run
```

Then perform the deletion:

```bash
sudo ./osac-teardown.sh
sudo ./ocp-teardown.sh
```

`ocp-teardown.sh` deletes the VM cluster and its data. Keep the bundle,
`dev-scripts`, `/opt/dev-scripts`, and the installer state directories until
teardown completes.

## State and logs

The installers retain state beside the scripts:

- `.ocp-installer-state/` contains the effective OCP wrapper configuration.
- `.astra-osac-state/` contains OSAC deployment identity and resume information.
- `/opt/dev-scripts/ocp/<CLUSTER_NAME>/` contains cluster assets and the
  kubeconfig.

These directories are runtime state and are ignored by Git. The kubeconfig
provides cluster-admin access; protect it like a credential.

Logs may include sensitive output from upstream tools. Keep log directories
private, and copy logs to persistent storage if you need them after reboot.
`/tmp` may be cleared automatically.

## Security notes

- Run the OCP and chain installers as root on a dedicated lab host.
- Do not run multiple installations concurrently against one host or cluster.
- Do not commit kubeconfigs, pull secrets, CI tokens, license manifests,
  activation keys, private keys, or raw installer logs.
- CI profiles use test credentials and ephemeral services. They are not
  production profiles.
- Review prompt output and Git status before every push or repository creation.

## Troubleshooting

Start with the latest chain status and log:

```bash
sudo cat /tmp/osac-install-chain-logs/latest/status
sudo less /tmp/osac-install-chain-logs/latest/run.log
```

For a configuration mismatch, rerun:

```bash
unset DEV_SCRIPTS_DIR
sudo ./osac-install-chain.sh --check-config
```

If a fresh installation is refused because OCP assets already exist, inspect the
reported assets and use `ocp-teardown.sh --dry-run` to determine whether an old
deployment must be removed. Do not create a second installation at the same
target.

For installer-specific options:

```bash
./ocp-install.sh --help
./osac-install.sh --help
./ocp-teardown.sh --help
./osac-teardown.sh --help
./osac-install-chain.sh --help
```
