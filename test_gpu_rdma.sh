#!/usr/bin/env bash
#
# test_gpu_rdma.sh — Verify NVIDIA GPUDirect RDMA connectivity
#
# Usage:
#   ./test_gpu_rdma.sh [-d <ib_device>] [-p <port>] [-h]
#
# Options:
#   -d <ib_device>   InfiniBand device name (default: mlx5_0)
#   -p <port>        IB port number (default: 1)
#   -h               Show this help and exit
#
# Prerequisites:
#   • rdma-core and perftest installed (e.g. ibv-devinfo, ib_write_lat)
#   • NVIDIA drivers + CUDA (for nvidia-smi and CUDA samples)
#   • NVIDIA peer memory module (nv_peer_mem) or nvidia-peermem DKMS
#
# What it does:
#   1. Checks for HCA and nv_peer_mem
#   2. Shows GPU↔NIC topology (nvidia-smi topo -m)
#   3. Builds and runs gpu_direct_rdma_bandwidth sample


set -euo pipefail

IB_DEV="mlx5_0"
IB_PORT=1

usage(){
  sed -n '1,20p' "$0"
  exit 1
}

while getopts "d:p:h" opt; do
  case $opt in
    d) IB_DEV="$OPTARG" ;;
    p) IB_PORT="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

echo "=== 1. Checking for RDMA HCA and NVIDIA peer memory module ==="
if ! command -v ibv_devinfo &>/dev/null; then
  echo "ERROR: rdma-core suite not found. Install it (e.g. 'apt install rdma-core perftest')." >&2
  exit 1
fi

echo "- Listing InfiniBand HCAs:"
ibv_devinfo -v | grep -E 'hca_id|device_cap_flags'
echo

echo "- Checking for nv_peer_mem or nvidia_peermem:"
if lsmod | grep -E 'nv_peer_mem|nvidia_peermem' &>/dev/null; then
  echo "OK: peer-memory module is loaded."
else
  echo "WARNING: peer-memory module not loaded."
  echo "→ Try: sudo modprobe nv_peer_mem  (or install nvidia-peermem DKMS)" 
fi
echo

echo "=== 2. PCIe / NVLink topology ==="
if command -v nvidia-smi &>/dev/null; then
  nvidia-smi topo -m
else
  echo "nvidia-smi not found; ensure NVIDIA drivers are installed."
fi
echo

echo "=== 3. Building GPUDirect RDMA sample ==="
# Adjust SAMPLE_DIR if your CUDA samples are elsewhere
SAMPLE_DIR="${CUDA_SAMPLES_ROOT:-/usr/local/cuda}/samples/7_CUDALibraries/gpudirect_rdma_bandwidth"
if [ ! -d "$SAMPLE_DIR" ]; then
  echo "ERROR: Sample directory not found: $SAMPLE_DIR" >&2
  echo "Install CUDA samples or point CUDA_SAMPLES_ROOT correctly."
  exit 1
fi
pushd "$SAMPLE_DIR" >/dev/null
make clean && make
popd >/dev/null
echo "Built gpu_direct_rdma_bandwidth in $SAMPLE_DIR"
echo

echo "=== 4. Running RDMA latency test between GPU buffers ==="
echo "→ You need two hosts, each running this script, pointing to each other via IB."
echo "Example (HOST1):"
echo "  $ SAMPLE_DIR/gpu_direct_rdma_bandwidth $IB_DEV $IB_PORT <remote_hostname>"
echo
echo "Example (HOST2):"
echo "  $ SAMPLE_DIR/gpu_direct_rdma_bandwidth $IB_DEV $IB_PORT <host1_hostname>"
echo
echo "If you only have one host, you can try loopback (may or may not be supported):"
echo "  $ SAMPLE_DIR/gpu_direct_rdma_bandwidth $IB_DEV $IB_PORT localhost"
echo

echo "---- Done. Interpret the reported bandwidth/latency:"
echo "- If you see bandwidth numbers comparable to your IB link (e.g. 50–100 GB/s on HDR) using GPU buffers,"
echo "  you have working GPUDirect RDMA."
echo "- If it falls back to host memory speeds (~15–20 GB/s), then RDMA cannot access GPU memory directly."

