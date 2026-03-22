# Purpose

Clean up **Nutanix Kubernetes Platform (NKP)**–related **PVC volume groups** and optionally **delete powered-off worker VMs**. This tool includes an infrastructure report of NKP clusters (via **`--discover`**).

**Safety:** Storage cleanup paths only consider VMs that are **powered OFF** and match the given **`--cluster`** label (`KubernetesClusterName` / `kubernetes_cluster_name` on metadata or spec). Destructive steps prompt for **`yes`** before running.

---

## Requirements

| Component | Version / notes |
|-----------|-----------------|
| **Prism Central** | Recent PC with **v3** VM / volume_group list APIs and **volumes v4.1** config APIs used for detach/delete volume groups. |
| **Client host** | `bash`, `curl`, `jq`; `uuidgen` optional (fallback exists). |
| **Network** | Outbound HTTPS access to Prism Central (typically port **9440**). |

**Prism Central account** needs permissions sufficient to:

- List VMs and volume groups, run volume-group **detach** and **delete** actions.
- Delete VMs (when using **`--vms`**).

---

## Usage

```bash
./nkp-cleanup.sh --discover [--debug]

./nkp-cleanup.sh --cluster <name> [--detach-only | --vms] [--debug]

./nkp-cleanup.sh --volumes <file> [--debug]
```

| Option | Description |
|--------|-------------|
| `--discover` | **Read-only.** Print inventory by Kubernetes cluster: controllers, workers, and **pvc-** volume groups attached via VM **disk_list**. No `--cluster` / `--volumes` / `--detach-only` / `--vms`. |
| `--cluster <name>` | Kubernetes cluster name to filter on **powered-off** VMs. |
| `--detach-only` | Detach PVC volume groups from those VMs only; writes **`volumes.list.tmp`** for a later **`--volumes`** run. Requires `--cluster` |
| `--vms` | Delete **powered-off** VMs matching **`--cluster`** (after storage is gone). |
| `--volumes <file>` | Delete volume groups listed in the JSON-lines file (e.g. from **`--detach-only`**). |
| `--debug` | Shows **Step N:** progress information and API details. |
| `--pc`, `--user`, `--password` | Prism Central URL and credentials. Optional flags (see below). |
| `-h`, `--help` | Show embedded help and exit. |

**Default cluster workflow (no flags beyond `--cluster`):** detach PVC volume groups from matching **powered-off** VMs, wait, then **delete** those volume groups in one run.

Prism Central Credentials can be passed in via 3 methods, listed in order of prescendence:
1. **Export** before running: `NUTANIX_ENDPOINT`, `NUTANIX_USER`, `NUTANIX_PASSWORD`  
2. **`env.vars`** in the **same directory as the script** (automatically sourced if present).
3. **CLI** (applied last): `--pc <url>`, `--user <name>`, `--password '<secret>'`  
   - `--pc` may be `https://fqdn_or_IP:9440` or `fqdn_or_IP:9440`.  

**Optional tuning (environment variables):**

| Variable | Default | Role |
|----------|---------|------|
| `CURL_TIMEOUT` | `90` | Per-request curl timeout (seconds). |
| `DELETE_RETRIES` | `3` | Retries on transient VG delete errors. |
| `DELAY_BETWEEN_VGS` | `3` | Sleep between VG operations (seconds). |
| `DETACH_WAIT_SECONDS` | `30` | Wait after detach before delete (seconds). |
| `LIST_PAGE_SIZE` | `500` | Page size for **v3** VM and volume_group **list** APIs (capped at **500** per request). The script follows **`offset`** until all entities are merged. |

**Examples:**

```bash
export NUTANIX_ENDPOINT='https://pc.example.com:9440'
export NUTANIX_USER='admin'
export NUTANIX_PASSWORD='secret'

# Inventory only:
./nkp-cleanup.sh --discover

# One-shot: detach + delete PVC VGs for powered-off VMs in cluster "nkp"
./nkp-cleanup.sh --cluster nkp

# Two-step storage: detach → file → delete VGs
./nkp-cleanup.sh --cluster nkp --detach-only
./nkp-cleanup.sh --volumes volumes.list.tmp

# After VGs are gone, delete the powered-off VMs
./nkp-cleanup.sh --cluster nkp --vms
```

---

## Example output

**`--discover`** (cluster tree and summary — exact names/counts depend on your environment):

```text
Connecting to Prism Central: https://pc.example.com:9440
User: admin
Mode: Infrastructure report (--discover, read-only)

my-cluster
|_Controller Nodes
|  |_nkp-pro-mlgk8-t8nhv (vCPU: 4 | Memory: 16.00 GB)
|  |  |_pvc-abc123...
|_Worker Nodes
   |_nkp-pro-md-0-k558f-zdz9z-bl6ng (vCPU: 16 | Memory: 64.00 GB)
      |_pvc-def456...

==========================================
Summary:
  Clusters: 1
  Total VMs: 2
  Controller nodes: 1
  Worker nodes: 1
  PVCs attached to these VMs: 2
==========================================
```

---

## License / Support

Use at your own risk. Not an officially supported script. Test against your Prism Central version and permissions in **non-production** first.
