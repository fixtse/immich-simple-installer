#!/bin/bash

# Immich Installation Script
# Based on: https://immich.app/docs/install/docker-compose

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to generate a random password
generate_password() {
    if command -v pwgen >/dev/null 2>&1; then
        pwgen -s 32 1
        elif command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
    else
        # Fallback method
        cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 32
    fi
}

# Function to check if running in WSL
is_wsl() {
    if [ -f /proc/version ] && grep -q "Microsoft\|WSL" /proc/version; then
        return 0
    fi
    return 1
}

# Function to add volume to docker-compose.yml volumes section
add_docker_volume() {
    local volume_name="$1"
    local compose_file="${2:-docker-compose.yml}"
    
    if [ -z "$volume_name" ]; then
        print_error "Volume name is required"
        return 1
    fi
    
    if [ ! -f "$compose_file" ]; then
        print_error "Docker compose file not found: $compose_file"
        return 1
    fi
    
    # Check if volume already exists
    if grep -q "^[[:space:]]*${volume_name}:" "$compose_file"; then
        print_info "Volume '$volume_name' already exists in $compose_file"
        return 0
    fi
    
    # Check if volumes section exists
    if grep -q "^volumes:" "$compose_file"; then
        # volumes: section exists, add the volume to it
        sed -i "/^volumes:/a\\  ${volume_name}:" "$compose_file"
        print_success "Added volume '$volume_name' to existing volumes section"
    else
        # No volumes section exists, create it
        echo "" >> "$compose_file"
        echo "volumes:" >> "$compose_file"
        echo "  ${volume_name}:" >> "$compose_file"
        print_success "Created volumes section and added volume '$volume_name'"
    fi
    
    return 0
}

# Function to check for NVIDIA GPU and Container Toolkit
check_nvidia() {
    local has_nvidia_gpu=false
    local has_nvidia_toolkit=false
    
    # Check for NVIDIA GPU
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        has_nvidia_gpu=true
    fi
    
    # Check for NVIDIA Container Toolkit (not needed in WSL2)
    if ! is_wsl && [ "$has_nvidia_gpu" = true ]; then
        # Check for nvidia-container-runtime or nvidia-docker2
        if command -v nvidia-container-runtime >/dev/null 2>&1 || [ -f /usr/bin/nvidia-container-runtime ]; then
            has_nvidia_toolkit=true
            elif docker info 2>/dev/null | grep -q "nvidia"; then
            has_nvidia_toolkit=true
            elif [ -f /etc/docker/daemon.json ] && grep -q "nvidia" /etc/docker/daemon.json 2>/dev/null; then
            has_nvidia_toolkit=true
        fi
        elif is_wsl && [ "$has_nvidia_gpu" = true ]; then
        # In WSL2, we don't need Container Toolkit
        has_nvidia_toolkit=true
    fi
    
    echo "${has_nvidia_gpu}:${has_nvidia_toolkit}"
}

# Function to check for Intel Quick Sync support
check_intel_qsv() {
    if [ -d "/dev/dri" ] && ls /dev/dri/render* >/dev/null 2>&1; then
        # Check if it's Intel GPU
        if lspci | grep -i "vga.*intel" >/dev/null 2>&1; then
            echo "true"
            return
        fi
    fi
    echo "false"
}

# Function to check for VAAPI support
check_vaapi() {
    if [ -d "/dev/dri" ] && ls /dev/dri/render* >/dev/null 2>&1; then
        echo "true"
    else
        echo "false"
    fi
}

# Function to check for Rockchip support
check_rockchip() {
    if lscpu | grep -i "rockchip\|rk35\|rk33" >/dev/null 2>&1; then
        echo "true"
    else
        echo "false"
    fi
}

# Function to detect available hardware transcoding APIs
detect_hardware_apis() {
    local apis=()
    
    # Check NVIDIA
    local nvidia_result=$(check_nvidia)
    local has_nvidia_gpu=$(echo "$nvidia_result" | cut -d: -f1)
    local has_nvidia_toolkit=$(echo "$nvidia_result" | cut -d: -f2)
    
    if [ "$has_nvidia_gpu" = "true" ] && [ "$has_nvidia_toolkit" = "true" ]; then
        apis+=("nvenc")
        elif [ "$has_nvidia_gpu" = "true" ] && [ "$has_nvidia_toolkit" = "false" ]; then
        print_warning "NVIDIA GPU detected but Container Toolkit not installed."
        print_info "Install NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
    fi
    
    # Check Intel QSV
    if [ "$(check_intel_qsv)" = "true" ] && ! is_wsl; then
        apis+=("qsv")
    fi
    
    # Check VAAPI
    if [ "$(check_vaapi)" = "true" ]; then
        if is_wsl; then
            apis+=("vaapi-wsl")
        else
            apis+=("vaapi")
        fi
    fi
    
    # Check Rockchip
    if [ "$(check_rockchip)" = "true" ]; then
        apis+=("rkmpp")
    fi
    
    echo "${apis[@]}"
}

# Function to disable hardware acceleration
disable_hardware_acceleration() {
    local type="$1"  # "transcoding" or "ml"
    local found_config=false
    
    if [ "$type" = "transcoding" ]; then
        print_info "Disabling hardware transcoding acceleration..."
        
        # Check if configuration exists
        if grep -A 10 "immich-server:" docker-compose.yml | grep -q "extends:" || [ -f "hwaccel.transcoding.yml" ]; then
            found_config=true
        fi
        
        if [ "$found_config" = true ]; then
            print_warning "Found existing hardware transcoding configuration."
            read -p "Are you sure you want to disable hardware transcoding? (y/N): " confirm_disable
            if [[ ! "$confirm_disable" =~ ^[Yy]$ ]]; then
                print_info "Hardware transcoding disable cancelled."
                return 0
            fi
        fi
        
        # Remove extends section from immich-server
        if grep -A 10 "immich-server:" docker-compose.yml | grep -q "extends:"; then
            sed -i '/immich-server:/,/^[[:space:]]*[^[:space:]]/ {
                /extends:/,+2d
            }' docker-compose.yml
            print_success "Hardware transcoding configuration removed from docker-compose.yml"
        fi
        
        # Remove hwaccel.transcoding.yml if it exists
        if [ -f "hwaccel.transcoding.yml" ]; then
            rm -f hwaccel.transcoding.yml
            print_success "hwaccel.transcoding.yml file removed"
        fi
        
        if [ "$found_config" = true ]; then
            print_success "Hardware transcoding has been disabled."
            print_info "You will need to restart containers for changes to take effect."
        else
            print_info "No hardware transcoding configuration found to disable."
        fi
        
        elif [ "$type" = "ml" ]; then
        print_info "Disabling ML hardware acceleration..."
        
        # Check if configuration exists
        if grep -A 10 "immich-machine-learning:" docker-compose.yml | grep -q "extends:" || [ -f "hwaccel.ml.yml" ] || grep -q "immich-machine-learning.*-[a-z]*" docker-compose.yml; then
            found_config=true
        fi
        
        if [ "$found_config" = true ]; then
            print_warning "Found existing ML hardware acceleration configuration."
            read -p "Are you sure you want to disable ML hardware acceleration? (y/N): " confirm_disable_ml
            if [[ ! "$confirm_disable_ml" =~ ^[Yy]$ ]]; then
                print_info "ML hardware acceleration disable cancelled."
                return 0
            fi
        fi
        
        # Remove extends section from immich-machine-learning
        if grep -A 10 "immich-machine-learning:" docker-compose.yml | grep -q "extends:"; then
            sed -i '/immich-machine-learning:/,/^[[:space:]]*[^[:space:]]/ {
                /extends:/,+2d
            }' docker-compose.yml
            print_success "ML hardware acceleration configuration removed from docker-compose.yml"
        fi
        
        # Restore original image tag (remove backend suffix)
        if grep -q "immich-machine-learning.*-[a-z]*" docker-compose.yml; then
            sed -i 's|immich-machine-learning:\${IMMICH_VERSION:-release}-[a-z]*|immich-machine-learning:\${IMMICH_VERSION:-release}|' docker-compose.yml
            print_success "ML service image tag restored to CPU-only version"
        fi
        
        # Remove hwaccel.ml.yml if it exists
        if [ -f "hwaccel.ml.yml" ]; then
            rm -f hwaccel.ml.yml
            print_success "hwaccel.ml.yml file removed"
        fi
        
        if [ "$found_config" = true ]; then
            print_success "ML hardware acceleration has been disabled."
            print_info "You will need to restart containers for changes to take effect."
        else
            print_info "No ML hardware acceleration configuration found to disable."
        fi
    fi
}

# Function to configure hardware transcoding
configure_hardware_transcoding() {
    echo
    print_info "=== Hardware Transcoding Configuration ==="
    
    # Check if user wants to disable hardware acceleration
    read -p "Do you want to configure hardware transcoding? (Y/n/disable): " hw_transcoding_choice
    
    if [[ "$hw_transcoding_choice" =~ ^[Dd]isable$ ]]; then
        disable_hardware_acceleration "transcoding"
        return 0
        elif [[ "$hw_transcoding_choice" =~ ^[Nn]$ ]]; then
        print_info "Skipping hardware transcoding configuration."
        return 0
    fi
    
    print_info "Detecting available hardware acceleration APIs..."
    
    local available_apis=($(detect_hardware_apis))
    
    if [ ${#available_apis[@]} -eq 0 ]; then
        print_warning "No compatible hardware acceleration APIs detected."
        read -p "Do you want to configure hardware transcoding manually? (y/N): " manual_config
        if [[ "$manual_config" =~ ^[Yy]$ ]]; then
            configure_manual_hwaccel
        else
            return 0
        fi
    else
        print_success "Detected APIs: ${available_apis[*]}"
        
        if [ ${#available_apis[@]} -eq 1 ]; then
            print_info "Only one API available: ${available_apis[0]}"
            read -p "Configure ${available_apis[0]} hardware acceleration? (Y/n): " use_hwaccel
            if [[ ! "$use_hwaccel" =~ ^[Nn]$ ]]; then
                setup_hardware_transcoding "${available_apis[0]}"
            fi
        else
            echo
            print_info "Multiple APIs available. Please choose one:"
            for i in "${!available_apis[@]}"; do
                echo "$((i+1)). ${available_apis[i]}"
            done
            echo "$((${#available_apis[@]}+1)). Manual configuration"
            echo "$((${#available_apis[@]}+2)). Disable hardware acceleration"
            echo "$((${#available_apis[@]}+3)). Skip hardware acceleration"
            
            while true; do
                read -p "Enter your choice (1-$((${#available_apis[@]}+3))): " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $((${#available_apis[@]}+3)) ]; then
                    if [ "$choice" -eq $((${#available_apis[@]}+1)) ]; then
                        configure_manual_hwaccel
                        break
                        elif [ "$choice" -eq $((${#available_apis[@]}+2)) ]; then
                        disable_hardware_acceleration "transcoding"
                        break
                        elif [ "$choice" -eq $((${#available_apis[@]}+3)) ]; then
                        print_info "Skipping hardware acceleration configuration."
                        break
                    else
                        local selected_api="${available_apis[$((choice-1))]}"
                        setup_hardware_transcoding "$selected_api"
                        break
                    fi
                else
                    print_error "Invalid choice. Please try again."
                fi
            done
        fi
    fi
}

# Function for manual hardware acceleration configuration
configure_manual_hwaccel() {
    echo
    print_info "Manual hardware acceleration configuration:"
    print_info "Available APIs: nvenc, qsv, vaapi, vaapi-wsl, rkmpp"
    read -p "Enter the API you want to use (or 'disable' to remove, or press Enter to skip): " manual_api
    
    if [ -n "$manual_api" ]; then
        case "$manual_api" in
            nvenc|qsv|vaapi|vaapi-wsl|rkmpp)
                setup_hardware_transcoding "$manual_api"
            ;;
            disable)
                disable_hardware_acceleration "transcoding"
            ;;
            *)
                print_error "Invalid API: $manual_api"
                print_info "Valid options: nvenc, qsv, vaapi, vaapi-wsl, rkmpp, disable"
            ;;
        esac
    else
        print_info "Skipping hardware acceleration configuration."
    fi
}

# Function to setup hardware transcoding
setup_hardware_transcoding() {
    local api="$1"
    
    print_info "Setting up hardware transcoding with $api..."
    
    # Download hwaccel.transcoding.yml
    print_info "Downloading hwaccel.transcoding.yml..."
    if wget -O hwaccel.transcoding.yml https://github.com/immich-app/immich/releases/latest/download/hwaccel.transcoding.yml; then
        print_success "hwaccel.transcoding.yml downloaded successfully."
    else
        print_error "Failed to download hwaccel.transcoding.yml"
        print_warning "Hardware transcoding setup incomplete. You can manually download the file later."
        return 1
    fi
    
    # Modify docker-compose.yml to add extends section
    # Check for uncommented extends sections in immich-server (exclude commented lines)
    if grep -A 10 "immich-server:" docker-compose.yml | grep -q "^[[:space:]]*extends:"; then
        print_warning "Found active hardware acceleration in immich-server"
        read -p "Replace existing hardware acceleration config? (y/N): " replace_config
        if [[ "$replace_config" =~ ^[Yy]$ ]]; then
            # Remove existing active extends section and add new one
            sed -i '/immich-server:/,/^[[:space:]]*[^[:space:]]/ {
                /extends:/,+2d
            }' docker-compose.yml
            sed -i '/immich-server:/,/^[[:space:]]*[^[:space:]]/ {
                /container_name: immich_server/a\
    extends:\
      file: hwaccel.transcoding.yml\
      service: '"$api"'
            }' docker-compose.yml
            print_success "Hardware acceleration configuration updated in docker-compose.yml"
        fi
    else
        # No active extends found, add new configuration (remove commented sections first if they exist)
        print_info "Adding hardware acceleration configuration to docker-compose.yml..."
        
        # Remove any commented extends sections
        sed -i '/immich-server:/,/^[[:space:]]*[^[:space:]]/ {
            /# extends:/,+2d
        }' docker-compose.yml
        
        # Add new extends section
        sed -i '/immich-server:/,/^[[:space:]]*[^[:space:]]/ {
            /container_name: immich_server/a\
    extends:\
      file: hwaccel.transcoding.yml\
      service: '"$api"'
        }' docker-compose.yml
        
        print_success "Hardware acceleration configuration added to docker-compose.yml"
    fi
    
    # Special handling for RKMPP with tonemapping
    if [ "$api" = "rkmpp" ]; then
        if [ -f "/usr/lib/aarch64-linux-gnu/libmali.so.1" ]; then
            print_info "libmali detected. Enabling OpenCL tonemapping for RKMPP..."
            # Uncomment the OpenCL lines in hwaccel.transcoding.yml
            sed -i '/rkmpp:/,/^[[:space:]]*[^[:space:]]/ {
                s/^[[:space:]]*#[[:space:]]*- \/dev\/mali0:\/dev\/mali0/      - \/dev\/mali0:\/dev\/mali0/
                s/^[[:space:]]*#[[:space:]]*- \/etc\/OpenCL:\/etc\/OpenCL:ro/      - \/etc\/OpenCL:\/etc\/OpenCL:ro/
                s/^[[:space:]]*#[[:space:]]*- \/usr\/lib\/aarch64-linux-gnu\/libmali\.so\.1:\/usr\/lib\/aarch64-linux-gnu\/libmali\.so\.1:ro/      - \/usr\/lib\/aarch64-linux-gnu\/libmali.so.1:\/usr\/lib\/aarch64-linux-gnu\/libmali.so.1:ro/
            }' hwaccel.transcoding.yml
            print_success "OpenCL tonemapping enabled for RKMPP."
        else
            print_warning "libmali.so.1 not found. Hardware tonemapping will not be available."
            print_info "Install libmali from: https://github.com/tsukumijima/libmali-rockchip/releases"
        fi
    fi
    
    print_success "Hardware transcoding configured with $api"
    print_info "Remember to:"
    print_info "1. Enable hardware acceleration in Admin > Video transcoding settings"
    print_info "2. Choose the appropriate hardware acceleration option: $api"
    
    if [ "$api" = "nvenc" ]; then
        print_info "3. Consider enabling hardware decoding in the video transcoding settings"
    fi
}

# Function to check for NVIDIA CUDA support for ML
check_nvidia_cuda_ml() {
    local has_nvidia_gpu=false
    local has_nvidia_toolkit=false
    local cuda_compute_capability=""
    
    # Check for NVIDIA GPU
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        has_nvidia_gpu=true
        # Get compute capability (simplified check)
        local gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits | head -1)
        # Basic compute capability check - most modern GPUs are 5.2+
        if [[ "$gpu_name" =~ RTX|GTX\ 10|GTX\ 16|Tesla|Quadro ]]; then
            cuda_compute_capability="5.2+"
        fi
    fi
    
    # Check for NVIDIA Container Toolkit (not needed in WSL2)
    if ! is_wsl && [ "$has_nvidia_gpu" = true ]; then
        if command -v nvidia-container-runtime >/dev/null 2>&1 || [ -f /usr/bin/nvidia-container-runtime ]; then
            has_nvidia_toolkit=true
            elif docker info 2>/dev/null | grep -q "nvidia"; then
            has_nvidia_toolkit=true
            elif [ -f /etc/docker/daemon.json ] && grep -q "nvidia" /etc/docker/daemon.json 2>/dev/null; then
            has_nvidia_toolkit=true
        fi
        elif is_wsl && [ "$has_nvidia_gpu" = true ]; then
        has_nvidia_toolkit=true
    fi
    
    echo "${has_nvidia_gpu}:${has_nvidia_toolkit}:${cuda_compute_capability}"
}

# Function to check for AMD ROCm support
check_amd_rocm() {
    if lspci | grep -i "amd.*radeon\|amd.*rx\|amd.*vega" >/dev/null 2>&1; then
        echo "true"
    else
        echo "false"
    fi
}

# Function to check for Intel OpenVINO support
check_intel_openvino() {
    if lspci | grep -i "vga.*intel\|display.*intel" >/dev/null 2>&1; then
        # Check for Iris Xe or Arc GPUs specifically
        if lspci | grep -i "intel.*iris\|intel.*arc\|intel.*xe" >/dev/null 2>&1; then
            echo "discrete"
            elif lspci | grep -i "vga.*intel" >/dev/null 2>&1; then
            echo "integrated"
        fi
    else
        echo "false"
    fi
}

# Function to check for ARM NN (Mali GPU) support
check_arm_nn() {
    local has_mali=false
    local has_mali_dev=false
    local has_libmali=false
    
    # Check for Mali GPU
    if lscpu | grep -i "arm\|aarch64" >/dev/null 2>&1 && lspci | grep -i "mali" >/dev/null 2>&1; then
        has_mali=true
    fi
    
    # Check for /dev/mali0
    if [ -c "/dev/mali0" ]; then
        has_mali_dev=true
        has_mali=true  # If we have the device, we likely have Mali
    fi
    
    # Check for libmali.so
    if [ -f "/usr/lib/libmali.so" ] || [ -f "/usr/lib/aarch64-linux-gnu/libmali.so" ]; then
        has_libmali=true
    fi
    
    echo "${has_mali}:${has_mali_dev}:${has_libmali}"
}

# Function to check for RKNN support
check_rknn() {
    local has_rockchip=false
    local rknn_version=""
    
    # Check for supported Rockchip SoCs
    if lscpu | grep -i "rk35\|rk36" >/dev/null 2>&1; then
        local soc_info=$(lscpu | grep -i "rk35\|rk36" | head -1)
        if [[ "$soc_info" =~ RK3566|RK3568|RK3576|RK3588 ]]; then
            has_rockchip=true
        fi
    fi
    
    # Check RKNPU driver version
    if [ -f "/sys/kernel/debug/rknpu/version" ]; then
        rknn_version=$(cat /sys/kernel/debug/rknpu/version 2>/dev/null || echo "unknown")
    fi
    
    echo "${has_rockchip}:${rknn_version}"
}

# Function to detect available ML hardware acceleration backends
detect_ml_backends() {
    local backends=()
    
    # Check NVIDIA CUDA
    local cuda_result=$(check_nvidia_cuda_ml)
    local has_nvidia_gpu=$(echo "$cuda_result" | cut -d: -f1)
    local has_nvidia_toolkit=$(echo "$cuda_result" | cut -d: -f2)
    local cuda_capability=$(echo "$cuda_result" | cut -d: -f3)
    
    if [ "$has_nvidia_gpu" = "true" ] && [ "$has_nvidia_toolkit" = "true" ] && [ -n "$cuda_capability" ]; then
        backends+=("cuda")
        elif [ "$has_nvidia_gpu" = "true" ] && [ -n "$cuda_capability" ]; then
        if [ "$has_nvidia_toolkit" = "false" ] && ! is_wsl; then
            print_warning "NVIDIA GPU detected but Container Toolkit not installed (required for ML)."
        fi
    fi
    
    # Check AMD ROCm
    if [ "$(check_amd_rocm)" = "true" ]; then
        backends+=("rocm")
    fi
    
    # Check Intel OpenVINO
    local intel_result=$(check_intel_openvino)
    if [ "$intel_result" != "false" ]; then
        backends+=("openvino")
    fi
    
    # Check ARM NN
    local armnn_result=$(check_arm_nn)
    local has_mali=$(echo "$armnn_result" | cut -d: -f1)
    local has_mali_dev=$(echo "$armnn_result" | cut -d: -f2)
    local has_libmali=$(echo "$armnn_result" | cut -d: -f3)
    
    if [ "$has_mali" = "true" ] && [ "$has_mali_dev" = "true" ] && [ "$has_libmali" = "true" ]; then
        backends+=("armnn")
        elif [ "$has_mali" = "true" ]; then
        print_warning "Mali GPU detected but missing requirements for ARM NN."
        if [ "$has_mali_dev" = "false" ]; then
            print_info "Missing: /dev/mali0 device"
        fi
        if [ "$has_libmali" = "false" ]; then
            print_info "Missing: libmali.so library"
        fi
    fi
    
    # Check RKNN
    local rknn_result=$(check_rknn)
    local has_rockchip=$(echo "$rknn_result" | cut -d: -f1)
    local rknn_version=$(echo "$rknn_result" | cut -d: -f2)
    
    if [ "$has_rockchip" = "true" ] && [ "$rknn_version" != "" ]; then
        backends+=("rknn")
        elif [ "$has_rockchip" = "true" ]; then
        print_warning "Supported Rockchip SoC detected but RKNPU driver not found."
        print_info "Check: cat /sys/kernel/debug/rknpu/version"
    fi
    
    echo "${backends[@]}"
}

# Function to configure ML hardware acceleration
configure_ml_hardware_acceleration() {
    echo
    print_info "=== Machine Learning Hardware Acceleration Configuration ==="
    
    # Check if user wants to disable ML hardware acceleration
    read -p "Do you want to configure ML hardware acceleration? (Y/n/disable): " ml_hw_choice
    
    if [[ "$ml_hw_choice" =~ ^[Dd]isable$ ]]; then
        disable_hardware_acceleration "ml"
        return 0
        elif [[ "$ml_hw_choice" =~ ^[Nn]$ ]]; then
        print_info "Skipping ML hardware acceleration configuration."
        return 0
    fi
    
    print_info "Detecting available ML acceleration backends..."
    
    local available_backends=($(detect_ml_backends))
    
    if [ ${#available_backends[@]} -eq 0 ]; then
        print_warning "No compatible ML hardware acceleration backends detected."
        read -p "Do you want to configure ML hardware acceleration manually? (y/N): " manual_ml_config
        if [[ "$manual_ml_config" =~ ^[Yy]$ ]]; then
            configure_manual_ml_hwaccel
        else
            return 0
        fi
    else
        print_success "Detected ML backends: ${available_backends[*]}"
        
        if [ ${#available_backends[@]} -eq 1 ]; then
            print_info "Only one ML backend available: ${available_backends[0]}"
            read -p "Configure ${available_backends[0]} ML hardware acceleration? (Y/n): " use_ml_hwaccel
            if [[ ! "$use_ml_hwaccel" =~ ^[Nn]$ ]]; then
                setup_ml_hardware_acceleration "${available_backends[0]}"
            fi
        else
            echo
            print_info "Multiple ML backends available. Please choose one:"
            for i in "${!available_backends[@]}"; do
                echo "$((i+1)). ${available_backends[i]}"
            done
            echo "$((${#available_backends[@]}+1)). Manual configuration"
            echo "$((${#available_backends[@]}+2)). Disable ML hardware acceleration"
            echo "$((${#available_backends[@]}+3)). Skip ML hardware acceleration"
            
            while true; do
                read -p "Enter your choice (1-$((${#available_backends[@]}+3))): " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $((${#available_backends[@]}+3)) ]; then
                    if [ "$choice" -eq $((${#available_backends[@]}+1)) ]; then
                        configure_manual_ml_hwaccel
                        break
                        elif [ "$choice" -eq $((${#available_backends[@]}+2)) ]; then
                        disable_hardware_acceleration "ml"
                        break
                        elif [ "$choice" -eq $((${#available_backends[@]}+3)) ]; then
                        print_info "Skipping ML hardware acceleration configuration."
                        break
                    else
                        local selected_backend="${available_backends[$((choice-1))]}"
                        setup_ml_hardware_acceleration "$selected_backend"
                        break
                    fi
                else
                    print_error "Invalid choice. Please try again."
                fi
            done
        fi
    fi
}

# Function for manual ML hardware acceleration configuration
configure_manual_ml_hwaccel() {
    echo
    print_info "Manual ML hardware acceleration configuration:"
    print_info "Available backends: cuda, rocm, openvino, armnn, rknn"
    read -p "Enter the backend you want to use (or 'disable' to remove, or press Enter to skip): " manual_backend
    
    if [ -n "$manual_backend" ]; then
        case "$manual_backend" in
            cuda|rocm|openvino|armnn|rknn)
                setup_ml_hardware_acceleration "$manual_backend"
            ;;
            disable)
                disable_hardware_acceleration "ml"
            ;;
            *)
                print_error "Invalid backend: $manual_backend"
                print_info "Valid options: cuda, rocm, openvino, armnn, rknn, disable"
            ;;
        esac
    else
        print_info "Skipping ML hardware acceleration configuration."
    fi
}

# Function to setup ML hardware acceleration
setup_ml_hardware_acceleration() {
    local backend="$1"
    
    print_info "Setting up ML hardware acceleration with $backend..."
    
    # Download hwaccel.ml.yml
    print_info "Downloading hwaccel.ml.yml..."
    if wget -O hwaccel.ml.yml https://github.com/immich-app/immich/releases/latest/download/hwaccel.ml.yml; then
        print_success "hwaccel.ml.yml downloaded successfully."
    else
        print_error "Failed to download hwaccel.ml.yml"
        print_warning "ML hardware acceleration setup incomplete. You can manually download the file later."
        return 1
    fi
    
    # Modify docker-compose.yml to add extends section for ML service
    # Check for uncommented extends sections in immich-machine-learning (exclude commented lines)
    if grep -A 10 "immich-machine-learning:" docker-compose.yml | grep -q "^[[:space:]]*extends:"; then
        print_warning "Found active ML hardware acceleration in immich-machine-learning"
        read -p "Replace existing ML hardware acceleration config? (y/N): " replace_ml_config
        if [[ "$replace_ml_config" =~ ^[Yy]$ ]]; then
            # Remove existing active extends section and add new one
            sed -i '/immich-machine-learning:/,/^[[:space:]]*[^[:space:]]/ {
                /extends:/,+2d
            }' docker-compose.yml
            sed -i '/immich-machine-learning:/,/^[[:space:]]*[^[:space:]]/ {
                /container_name: immich_machine_learning/a\
    extends:\
      file: hwaccel.ml.yml\
      service: '"$backend"'
            }' docker-compose.yml
            print_success "ML hardware acceleration configuration updated in docker-compose.yml"
        fi
    else
        # No active extends found, add new configuration (remove commented sections first if they exist)
        print_info "Adding ML hardware acceleration configuration to docker-compose.yml..."
        
        # Remove any commented extends sections
        sed -i '/immich-machine-learning:/,/^[[:space:]]*[^[:space:]]/ {
            /# extends:/,+2d
        }' docker-compose.yml
        
        # Add new extends section
        sed -i '/immich-machine-learning:/,/^[[:space:]]*[^[:space:]]/ {
            /container_name: immich_machine_learning/a\
    extends:\
      file: hwaccel.ml.yml\
      service: '"$backend"'
        }' docker-compose.yml
        
        print_success "ML hardware acceleration configuration added to docker-compose.yml"
    fi
    
    # Modify the image tag to include the backend
    print_info "Updating ML service image tag for $backend backend..."
    if grep -q "immich-machine-learning.*release.*-$backend" docker-compose.yml; then
        print_info "Image tag already includes $backend backend."
    else
        # Update the image tag
        sed -i "s|immich-machine-learning:\${IMMICH_VERSION:-release}|immich-machine-learning:\${IMMICH_VERSION:-release}-$backend|" docker-compose.yml
        print_success "Updated ML service image to include $backend backend."
    fi
    
    # Backend-specific configuration and advice
    case "$backend" in
        "cuda")
            print_info "CUDA backend selected. Ensure your GPU has compute capability 5.2 or higher."
            print_info "Driver version must be >= 545 (CUDA 12.3 support)."
            print_info "Optional: Set MACHINE_LEARNING_DEVICE_IDS=0,1 for multi-GPU setups."
            print_info "Optional: Increase MACHINE_LEARNING_WORKERS for better utilization."
        ;;
        "rocm")
            print_warning "ROCm image is quite large (35GB+ disk space required)."
            print_info "If your GPU isn't officially supported, you may need to set:"
            print_info "HSA_OVERRIDE_GFX_VERSION=<supported_version> (e.g., 10.3.0)"
            print_info "If that doesn't work, also try: HSA_USE_SVM=0"
        ;;
        "openvino")
            print_info "OpenVINO backend selected for Intel GPUs."
            print_warning "Expect higher RAM usage compared to CPU processing."
            print_info "Discrete GPUs generally work better than integrated ones."
            print_info "For multi-GPU: Set MACHINE_LEARNING_DEVICE_IDS=0,1"
        ;;
        "armnn")
            print_info "ARM NN backend selected for Mali GPUs."
            if [ ! -f "/lib/firmware/mali_csffw.bin" ]; then
                print_warning "Optional firmware file /lib/firmware/mali_csffw.bin not found."
                print_info "Update hwaccel.ml.yml if your device doesn't require this file."
            fi
            print_info "Recommended: Add MACHINE_LEARNING_ANN_FP16_TURBO=true to .env for better performance."
        ;;
        "rknn")
            print_info "RKNN backend selected for Rockchip NPU."
            local rknn_info=$(check_rknn)
            local rknn_version=$(echo "$rknn_info" | cut -d: -f2)
            if [ "$rknn_version" != "unknown" ] && [ -n "$rknn_version" ]; then
                print_success "RKNPU driver version: $rknn_version"
            fi
            print_info "Recommended for RK3576/RK3588: Add MACHINE_LEARNING_RKNN_THREADS=2 to .env"
            print_info "For RK3588: MACHINE_LEARNING_RKNN_THREADS=3 for maximum performance"
            print_warning "Higher thread count increases RAM usage proportionally."
        ;;
    esac
    
    print_success "ML hardware acceleration configured with $backend"
    print_info "The ML service will use hardware acceleration for Smart Search and Face Detection."
    print_info "No additional configuration needed in the web interface."
}

# Function to check if Docker is installed and running
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        print_error "Docker is not installed. Please install Docker first."
        print_info "Visit: https://fixtse.com/blog/open-webui#docker-installation-linuxwsl"
        exit 1
    fi
    
    if ! docker compose version >/dev/null 2>&1; then
        print_error "Docker Compose is not available or not the correct version."
        print_info "Please ensure you have Docker Compose v2 installed."
        print_info "Visit: https://fixtse.com/blog/open-webui#docker-installation-linuxwsl"
        exit 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        print_error "Docker daemon is not running. Please start Docker."
        exit 1
    fi
    
    print_success "Docker and Docker Compose are available."
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [-f folder_path] [-h]"
    echo "  -f folder_path  : Specify the installation folder (optional)"
    echo "  -h              : Show this help message"
    echo ""
    echo "This script will:"
    echo "  - Download and configure Immich with Docker Compose"
    echo "  - Set up environment variables interactively"
    echo "  - Detect and configure hardware transcoding (NVENC, QSV, VAAPI, RKMPP)"
    echo "  - Detect and configure ML hardware acceleration (CUDA, ROCm, OpenVINO, ARM NN, RKNN)"
    echo "  - Option to disable hardware acceleration if already configured"
    echo "  - Handle WSL-specific requirements"
}

# Parse command line arguments
INSTALL_FOLDER=""
while getopts "f:h" opt; do
    case $opt in
        f)
            INSTALL_FOLDER="$OPTARG"
        ;;
        h)
            show_usage
            exit 0
        ;;
        \?)
            print_error "Invalid option: -$OPTARG"
            show_usage
            exit 1
        ;;
    esac
done

# Main installation function
main() {
    print_info "Starting Immich installation..."
    
    # Check Docker installation
    check_docker
    
    # Get installation folder
    if [ -z "$INSTALL_FOLDER" ]; then
        echo
        read -p "Enter the installation folder path (default: ./immich-app): " INSTALL_FOLDER
        if [ -z "$INSTALL_FOLDER" ]; then
            INSTALL_FOLDER="./immich-app"
        fi
    fi
    
    # Convert to absolute path
    INSTALL_FOLDER=$(realpath "$INSTALL_FOLDER")
    
    print_info "Installation folder: $INSTALL_FOLDER"
    
    # Create the directory if it doesn't exist
    if [ ! -d "$INSTALL_FOLDER" ]; then
        print_info "Creating directory: $INSTALL_FOLDER"
        mkdir -p "$INSTALL_FOLDER"
        print_success "Directory created successfully."
    else
        print_warning "Directory already exists: $INSTALL_FOLDER"
        if [ -f "$INSTALL_FOLDER/docker-compose.yml" ] || [ -f "$INSTALL_FOLDER/.env" ]; then
            echo
            read -p "Existing Immich files found. Continue anyway? (y/N): " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                print_info "Installation cancelled."
                exit 0
            fi
        fi
    fi
    
    # Change to installation directory
    cd "$INSTALL_FOLDER"
    
    # Download docker-compose.yml
    print_info "Downloading docker-compose.yml..."
    if wget -O docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml; then
        print_success "docker-compose.yml downloaded successfully."
    else
        print_error "Failed to download docker-compose.yml"
        exit 1
    fi
    
    # Download .env file
    print_info "Downloading .env file..."
    if wget -O .env https://github.com/immich-app/immich/releases/latest/download/example.env; then
        print_success ".env file downloaded successfully."
    else
        print_error "Failed to download .env file"
        exit 1
    fi
    
    echo
    print_info "Starting environment configuration..."
    
    # Configure UPLOAD_LOCATION
    echo
    echo "Current UPLOAD_LOCATION: ./library"
    read -p "Enter upload location (press Enter to keep default './library'): " upload_location
    if [ -n "$upload_location" ]; then
        sed -i "s|UPLOAD_LOCATION=./library|UPLOAD_LOCATION=$upload_location|" .env
        print_info "Upload location set to: $upload_location"
    else
        print_info "Using default upload location: ./library"
    fi
    
    # Configure DB_DATA_LOCATION (WSL check)
    echo
    if is_wsl; then
        print_warning "WSL detected!"
        print_warning "The Postgres database must be on a filesystem that supports user/group ownership."
        print_warning "NTFS/FAT32 filesystems (commonly under /mnt) will NOT work."
        echo
        read -p "Do you want to use a Docker volume instead of a bind mount? (recommended for WSL) (Y/n): " use_volume
        if [[ ! "$use_volume" =~ ^[Nn]$ ]]; then
            # Use Docker volume
            sed -i "s|DB_DATA_LOCATION=./postgres|DB_DATA_LOCATION=pgdata|" .env
            
            # Add pgdata volume to docker-compose.yml
            if add_docker_volume "pgdata"; then
                print_success "Docker volume configuration applied."
            else
                print_error "Failed to configure Docker volume"
            fi
        else
            echo "Current DB_DATA_LOCATION: ./postgres"
            read -p "Enter database data location (press Enter to keep default './postgres'): " db_location
            if [ -n "$db_location" ]; then
                sed -i "s|DB_DATA_LOCATION=./postgres|DB_DATA_LOCATION=$db_location|" .env
                print_info "Database location set to: $db_location"
            else
                print_info "Using default database location: ./postgres"
            fi
        fi
    else
        echo "Current DB_DATA_LOCATION: ./postgres"
        read -p "Enter database data location (press Enter to keep default './postgres'): " db_location
        if [ -n "$db_location" ]; then
            sed -i "s|DB_DATA_LOCATION=./postgres|DB_DATA_LOCATION=$db_location|" .env
            print_info "Database location set to: $db_location"
        else
            print_info "Using default database location: ./postgres"
        fi
    fi
    
    # Configure timezone
    echo
    print_info "Timezone configuration:"
    print_info "Check available timezones at: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones#List"
    echo "Current timezone: Etc/UTC (commented out)"
    read -p "Enter timezone (e.g., America/New_York, Europe/London, or press Enter to skip): " timezone
    if [ -n "$timezone" ]; then
        sed -i "s|# TZ=Etc/UTC|TZ=$timezone|" .env
        print_info "Timezone set to: $timezone"
    else
        print_info "Timezone configuration skipped (will use Etc/UTC)"
    fi
    
    # Configure IMMICH_VERSION
    echo
    echo "Current IMMICH_VERSION: release"
    read -p "Enter Immich version (press Enter to keep 'release' for latest): " immich_version
    if [ -n "$immich_version" ]; then
        sed -i "s|IMMICH_VERSION=release|IMMICH_VERSION=$immich_version|" .env
        print_info "Immich version set to: $immich_version"
    else
        print_info "Using default version: release (latest)"
    fi
    
    # Configure DB_PASSWORD
    echo
    echo "Current DB_PASSWORD: postgres"
    read -p "Enter database password (press Enter to generate a random password): " db_password
    if [ -z "$db_password" ]; then
        db_password=$(generate_password)
        print_info "Generated random password for database."
    fi
    sed -i "s|DB_PASSWORD=postgres|DB_PASSWORD=$db_password|" .env
    print_success "Database password configured."
    
    # Configure hardware transcoding
    configure_hardware_transcoding
    
    # Configure ML hardware acceleration
    configure_ml_hardware_acceleration
    
    echo
    print_success "Configuration completed!"
    print_info "Installation folder: $INSTALL_FOLDER"
    print_info "Files created:"
    print_info "  - docker-compose.yml"
    print_info "  - .env"
    if [ -f "hwaccel.transcoding.yml" ]; then
        print_info "  - hwaccel.transcoding.yml"
    fi
    if [ -f "hwaccel.ml.yml" ]; then
        print_info "  - hwaccel.ml.yml"
    fi
    
    echo
    read -p "Do you want to start Immich now? (Y/n): " start_now
    if [[ ! "$start_now" =~ ^[Nn]$ ]]; then
        print_info "Starting Immich containers..."
        if docker compose up -d; then
            echo
            print_success "Immich started successfully!"
            print_info "You can access Immich at: http://localhost:2283"
            print_info "To check status: docker compose ps"
            print_info "To view logs: docker compose logs -f"
            print_info "To stop: docker compose down"
        else
            print_error "Failed to start Immich containers."
            print_info "Check the logs with: docker compose logs"
            exit 1
        fi
    else
        echo
        print_info "Immich is ready to start. To start it manually, run:"
        print_info "cd '$INSTALL_FOLDER' && docker compose up -d"
    fi
    
    echo
    print_success "Installation completed successfully!"
    print_info "Next steps:"
    print_info "1. Access Immich at http://localhost:2283"
    print_info "2. Create your admin account"
    if [ -f "hwaccel.transcoding.yml" ]; then
        print_info "3. Enable hardware acceleration:"
        print_info "   - Go to Admin > Settings > Video transcoding settings"
        print_info "   - Set 'Hardware acceleration' to the configured API"
        print_info "   - Optionally enable 'Hardware decoding' for better performance"
        if [ -f "hwaccel.ml.yml" ]; then
            print_info "4. ML hardware acceleration is automatically enabled"
            print_info "5. Read the post-installation guide: https://immich.app/docs/install/post-install"
        else
            print_info "4. Read the post-installation guide: https://immich.app/docs/install/post-install"
        fi
        elif [ -f "hwaccel.ml.yml" ]; then
        print_info "3. ML hardware acceleration is automatically enabled"
        print_info "4. Read the post-installation guide: https://immich.app/docs/install/post-install"
    else
        print_info "3. Read the post-installation guide: https://immich.app/docs/install/post-install"
    fi
}

# Run main function
main "$@"
