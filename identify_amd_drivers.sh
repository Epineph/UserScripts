#!/usr/bin/env bash
##############################################################################
# detect_gpu.sh
#
# A sample script that inspects your GPU (via lspci) and sets environment
# variables for Hyprland (or any Wayland session) depending on whether you
# have an AMD or NVIDIA GPU. It also distinguishes between the “amdgpu”
# module (GCN-based, uses radeonsi driver in Mesa) and older “radeon”
# module (TeraScale-based, uses r600 driver in Mesa).
#
# Usage:
#   1) Make the script executable:
#         chmod +x detect_gpu.sh
#   2) Source it in your shell or your Hyprland session startup:
#         source /path/to/detect_gpu.sh
#      or
#         . /path/to/detect_gpu.sh
#
#   3) Optionally, place it in your shell profile (~/.bash_profile, ~/.zshrc)
#      or as part of your Hyprland startup (like ~/.config/hypr/startup.sh).
##############################################################################

# 1. Retrieve GPU information.
GPU_INFO="$(lspci -k | grep -EA2 'VGA|3D|Display')"

echo "[INFO] Detected GPU Info:"
echo "$GPU_INFO"
echo

# 2. Detect NVIDIA vs. AMD vs. Others.
if echo "$GPU_INFO" | grep -qi "nvidia"; then
    echo "[INFO] NVIDIA GPU detected."
    # -------------------------------------------------
    # Export environment variables for NVIDIA
    # -------------------------------------------------
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __GL_GSYNC_ALLOWED=1
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __VK_LAYER_NV_optimus=NVIDIA_only
    # Example: forcing VAAPI to nvidia (with caution)
    # export LIBVA_DRIVER_NAME=nvidia
    # ...
    echo "[INFO] NVIDIA environment variables set."

elif echo "$GPU_INFO" | grep -qi "amdgpu"; then
    echo "[INFO] AMD GPU (amdgpu kernel module) detected (GCN or newer)."
    # -------------------------------------------------
    # Export environment variables for AMD GCN (radeonsi)
    # -------------------------------------------------
    export LIBVA_DRIVER_NAME=radeonsi    # VAAPI driver for GCN-based AMD
    export AMD_VULKAN_ICD=radv           # Use Mesa RADV driver
    # Example optional performance test flags:
    export RADV_PERFTEST=aco,ngg
    echo "[INFO] AMD environment variables (radeonsi, radv) set."

elif echo "$GPU_INFO" | grep -qi "radeon"; then
    echo "[INFO] AMD GPU (radeon kernel module) detected (older TeraScale)."
    # -------------------------------------------------
    # Export environment variables for older AMD TeraScale
    # -------------------------------------------------
    # Typically uses r600 Mesa driver for OpenGL:
    export LIBVA_DRIVER_NAME=r600
    # Vulkan support on older TeraScale is usually none or minimal,
    # so you may omit AMD_VULKAN_ICD or it may fail to load.
    echo "[INFO] TeraScale environment variables (r600) set."

elif echo "$GPU_INFO" | grep -qi "intel"; then
    echo "[INFO] Intel GPU detected."
    # -------------------------------------------------
    # Export environment variables for Intel
    # -------------------------------------------------
    export LIBVA_DRIVER_NAME=iHD   # Usually iHD or i965
    echo "[INFO] Intel environment variables set."

else
    echo "[WARN] Unrecognized or hybrid GPU. No specific environment variables set."
fi

# 3. Common Hyprland environment variables (Wayland). 
#    You might want to set these regardless of GPU.
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_DESKTOP=Hyprland
export XDG_SESSION_TYPE=wayland
export GDK_BACKEND=wayland,x11,*
export QT_QPA_PLATFORM="wayland;xcb"
export CLUTTER_BACKEND=wayland
export EDITOR=nvim
export MOZ_ENABLE_WAYLAND=1
export ELECTRON_OZONE_PLATFORM_HINT=auto

# Set scaling defaults (if you’re using fractional scaling or want consistent sizing)
export GDK_SCALE=1
export QT_SCALE_FACTOR=1

echo "[INFO] Common Hyprland environment variables exported."

