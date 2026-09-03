# GB10-AI — Distributed LLM inference on dual NVIDIA GB10 sparks

An Omni cluster template + Talos machine-config for a **3-node cluster (1 control-plane
+ 2 GB10 (DGX Spark) workers) running distributed inference across the two GPU nodes**,
wired for NCCL over RoCE across a direct ConnectX-7 QSFP cable. The bundled `vllm-lws-example.yaml` runs DeepSeek-V4-Flash-0731 at
`tensor-parallel-size=2` across the pair using [LeaderWorkerSet](https://lws.sigs.k8s.io/).

## Requirements

- **Talos v1.14+** — this example uses typed multi-doc config kinds (`KubeNodeConfig`, `LinkConfig`, `SysctlConfig`, `VolumeConfig`, `UserVolumeConfig`, `WatchdogTimerConfig`, `HostnameConfig`) that don't exist in the v1alpha1 nested-map form used by Talos ≤1.13.
- **Omni** with your machines registered.
- **omnictl**, **helm**, **curl**.
- 3 machines registered to Omni:
  - **1 control-plane**
  - **2 GB10 computers** — NVIDIA DGX Spark or equivalent Grace/Blackwell hardware, each with a ConnectX-7 QSFP port cabled directly to the other.

## Deploy

```bash
# 1. Render the upstream charts + fetch dranet install.yaml.
make charts

# 2. Edit cluster.yaml:
#      - replace <CONTROL_PLANE_UUID>, <SPARK_A_UUID>, <SPARK_B_UUID> with your
#        actual machine UUIDs (omnictl get machinestatuses)
#      - swap systemExtensions for your CP hardware if not AMD (e.g.
#        siderolabs/intel-ucode on Intel)
#
# 3. Edit patches/gpu-labels.yaml:
#      - replace 10.0.0.0/8 with your LAN CIDR
#
# 4. Create the HuggingFace token secret in the workload namespace (or
#    convert the workload manifest to use a literal value):
#      kubectl -n inference create secret generic huggingface-token \
#        --from-literal=token=hf_YOUR_TOKEN
#
# 5. Sync — this applies the Talos machine config AND syncs all Kubernetes
#    manifests in one go.

omnictl cluster template sync --file cluster.yaml
```

## Design notes

### The `models` UserVolume

Each spark carves a ~2–3.5 TiB partition (2000–3500 GiB) out of NVMe as a Talos user volume named `models`.
Talos exposes it at `/var/mnt/models`; the vLLM pod hostPath mounts it as `HF_HOME`. First cold start pulls the model weights; every subsequent start loads from local NVMe.

### RoCE + NCCL

The vLLM LWS uses `NCCL_IB_HCA==mlx5_0:1` (the leading `=` is NCCL's exact-match syntax — the manifest value is literally `"=mlx5_0:1"`, not a typo) with `NCCL_IB_GID_INDEX=1` (RoCEv2 over link-local IPv6 GID). No IPv4 addresses are assigned to the CX-7 interfaces — NCCL peers reach each other over the direct cable using link-local IPv6 GIDs.
The bootstrap/rendezvous socket goes over `eth0` (the pod CNI interface, typically flannel); collectives go over the IBHCA.

`NCCL_IB_TIMEOUT=22` gives ~17 s of QP retransmit budget — generous, but transient stalls on a direct cable shouldn't escalate to `RETRY_EXC_ERR`.

The `gpu-rdma` ResourceClaimTemplate pins RDMA claims to the pci0000 CX-7 card so device naming inside the pod is deterministic (mlx5_0 = f0np0, mlx5_1 = f1np1).
If you scale to a different card layout, edit the CEL selector.

## Adapting to your hardware

- **Different CP hardware** — edit `systemExtensions` in the Machine block for `<CONTROL_PLANE_UUID>` in `cluster.yaml`.
- **Different hostnames** — edit `hostname:` in `patches/{control-plane,spark-a,spark-b}.yaml` AND the `nodeSelector.kubernetes.io/hostname` in `manifests/vllm-lws-example.yaml`.
- **Different LAN CIDR** — edit `nodeIP.validSubnets` in `patches/gpu-labels.yaml`.
- **Different disk layout** — edit `diskSelector` and size fields in the `VolumeConfig` and `UserVolumeConfig` docs in `patches/spark-{a,b}.yaml`.
  The `disk.transport == "nvme"` selector picks the first NVMe drive; if
  you want a specific device, use `disk.dev_path == "/dev/nvme0n1"`.
- **Different vLLM model** — edit `vllm serve <model>` and the associated `--tokenizer-mode` / `--tool-call-parser` / `--reasoning-parser` / `--*-backend` flags in `manifests/vllm-lws-example.yaml`.
  If you don't need Blackwell 12x kernels, swap the image for a stock vLLM build and drop the `B12X_*` / `VLLM_USE_B12X_*` / `CUTE_DSL_ARCH` env vars.

## Regenerating rendered charts

Omni's manifest sync doesn't run Helm or Kustomize — only raw YAML.
Version bumps happen in the `Makefile` at the top (`DRA_DRIVER_VERSION`, `LWS_VERSION`, `DRANET_VERSION`). Run `make charts` to refresh.
