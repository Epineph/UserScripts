#!/usr/bin/env bash

# Script: /usr/local/bin/detect_gpu_env
# Purpose: Detect GPU and configure Hyprland environment variables dynamically.
# Verbose explanations and structured clearly for pedagogical clarity.

CONFIG_FILE="$HOME/.config/hypr/UserConfigs/ENVariables.conf"

# Helper function to echo informative messages
vecho() {
  echo "[INFO] $*"
}

# Step 1: Retrieve GPU information
GPU_INFO=$(lspci -k | grep -EA2 'VGA|3D|Display')
vecho "Detected GPU Information:"
echo "$GPU_INFO"

# Backup existing configuration
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
vecho "Backup of configuration created at ${CONFIG_FILE}.bak"

# Step 2: Clear previous GPU-specific configurations
sed -i '/# GPU-SPECIFIC CONFIG START/,/# GPU-SPECIFIC CONFIG END/d' "$CONFIG_FILE"
vecho "Old GPU-specific configurations cleared."

# Step 3: Detect GPU vendor and prepare GPU-specific configurations
GPU_CONFIG="\n# GPU-SPECIFIC CONFIG START\n"

if echo "$GPU_INFO" | grep -qi 'nvidia'; then
  vecho "NVIDIA GPU detected."
  GPU_CONFIG+="env = __GLX_VENDOR_LIBRARY_NAME,nvidia\n"
  GPU_CONFIG+="env = __GL_GSYNC_ALLOWED,1\n"
  GPU_CONFIG+="env = __NV_PRIME_RENDER_OFFLOAD,1\n"
  GPU_CONFIG+="env = __VK_LAYER_NV_optimus,NVIDIA_only\n"
  GPU_CONFIG+="env = LIBVA_DRIVER_NAME,nvidia\n"
  GPU_CONFIG+="env = GBM_BACKEND,nvidia-drm\n"

elif echo "$GPU_INFO" | grep -qi 'amdgpu'; then
  vecho "AMD GPU (amdgpu) detected."
  GPU_CONFIG+="env = LIBVA_DRIVER_NAME,radeonsi\n"
  GPU_CONFIG+="env = AMD_VULKAN_ICD,radv\n"
  GPU_CONFIG+="env = RADV_PERFTEST,aco,ngg\n"

elif echo "$GPU_INFO" | grep -qi 'radeon'; then
  vecho "Older AMD GPU (radeon) detected."
  GPU_CONFIG+="env = LIBVA_DRIVER_NAME,r600\n"

elif echo "$GPU_INFO" | grep -qi 'intel'; then
  vecho "Intel GPU detected."
  GPU_CONFIG+="env = LIBVA_DRIVER_NAME,iHD\n"

else
  vecho "Unrecognized GPU or hybrid configuration. No GPU-specific environment variables set."
fi

GPU_CONFIG+="# GPU-SPECIFIC CONFIG END\n"

# Step 4: Append new GPU-specific configuration
printf "%b" "$GPU_CONFIG" >> "$CONFIG_FILE"
vecho "New GPU-specific configurations appended to $CONFIG_FILE"

# Step 5: Display the newly appended configuration
vecho "Final GPU-specific configuration:"
echo -e "$GPU_CONFIG"

vecho "Hyprland GPU environment configuration complete."

