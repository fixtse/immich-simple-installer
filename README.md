# Immich Simple Installer

A really simple bash script for easy installation and configuration of [Immich](https://immich.app) with Docker Compose, including automatic hardware acceleration detection and setup

## 🚀 Features

### Core Installation
- **Automated Download**: Downloads latest `docker-compose.yml` and `.env` files from Immich releases
- **Interactive Configuration**: Guided setup for all environment variables
- **Docker Validation**: Checks Docker and Docker Compose installation and status
- **WSL Support**: Special handling for Windows Subsystem for Linux environments

### Hardware Acceleration
- **Video Transcoding**: Automatic detection and setup for NVENC, QSV, VAAPI, and RKMPP
- **Machine Learning**: Support for CUDA, ROCm, OpenVINO, ARM NN, and RKNN backends
- **Smart Detection**: Identifies available hardware and suggests optimal configurations
- **Disable Options**: Easy removal of existing hardware acceleration configurations

### Environment Setup
- **Password Generation**: Automatic secure database password generation
- **Timezone Configuration**: Interactive timezone selection with reference links
- **Volume Management**: WSL-specific database volume handling for compatibility
- **Version Control**: Option to pin specific Immich versions

## �️ Supported Platforms

This script has been officially tested and supports:
- **Ubuntu 20.04 LTS**
- **Ubuntu 24.04 LTS** 
- **Windows Subsystem for Linux (WSL2)**

While officially tested on Ubuntu and WSL(Ubuntu), the script may work on other Linux distributions as well, since it primarily relies on Docker and standard Linux utilities.

## �📋 Prerequisites

- **Operating System**: Linux or Windows with WSL2
- **Docker**: [Docker Engine and Docker Compose v2](https://fixtse.com/blog/open-webui#docker-installation-linuxwsl)
- **Network Access**: Internet connection for downloading files
- **Permissions**: Ability to create directories and modify files

### Hardware-Specific Requirements

#### NVIDIA (NVENC/CUDA)
- NVIDIA GPU with driver installed
- NVIDIA Container Toolkit (Linux only, not needed for WSL2)
- For ML: GPU with compute capability 5.2+ and driver ≥545

#### Intel (QSV/OpenVINO)
- Intel GPU with `/dev/dri` devices available
- For VP9: 9th gen CPU or newer
- Kernel support for hardware acceleration

#### AMD (VAAPI/ROCm)
- AMD GPU with appropriate drivers
- For ROCm: 35GB+ free disk space for ML images

#### ARM/Rockchip
- **ARM NN**: Mali GPU with `/dev/mali0` and `libmali.so`
- **RKNN**: Supported Rockchip SoC (RK3566/68/76/88) with NPU driver

## 🔧 Installation

### Quick Start

```bash
# Download the script
wget -O immich_installer.sh https://raw.githubusercontent.com/fixtse/immich-simple-installer/main/immich_installer.sh

# Make it executable
chmod +x immich_installer.sh

# Run the installer
./immich_installer.sh
```

### Custom Installation Directory

```bash
# Specify installation folder
./immich_installer.sh -f /path/to/immich
```

### Help and Usage

```bash
# Show help message
./immich_installer.sh -h
```

## 🎯 Usage

### Interactive Installation

The script will guide you through:

1. **Docker Verification**: Checks Docker installation and status
2. **Directory Setup**: Creates installation folder if needed
3. **File Download**: Downloads latest Immich files
4. **Environment Configuration**:
   - Upload location (default: `./library`)
   - Database location (default: `./postgres` or Docker volume for WSL)
   - Timezone selection
   - Immich version selection
   - Database password (auto-generated or custom)

5. **Hardware Transcoding Setup**:
   - Automatic API detection (NVENC, QSV, VAAPI, RKMPP)
   - Interactive selection from available options
   - Manual configuration option
   - Disable existing configurations

6. **ML Hardware Acceleration**:
   - Backend detection (CUDA, ROCm, OpenVINO, ARM NN, RKNN)
   - Performance optimization suggestions
   - Environment variable recommendations

7. **Container Startup**: Option to start Immich immediately

### Configuration Options

#### Hardware Transcoding Responses
- **Y/Enter**: Configure detected hardware acceleration
- **n**: Skip hardware transcoding setup
- **disable**: Remove existing hardware acceleration

#### ML Acceleration Responses
- **Y/Enter**: Configure detected ML acceleration
- **n**: Skip ML hardware acceleration
- **disable**: Remove existing ML acceleration

#### Manual Configuration
When auto-detection fails, you can manually specify:
- **Transcoding**: `nvenc`, `qsv`, `vaapi`, `vaapi-wsl`, `rkmpp`
- **ML**: `cuda`, `rocm`, `openvino`, `armnn`, `rknn`

## 📁 Generated Files

After successful installation:

```
your-installation-folder/
├── docker-compose.yml          # Main compose file
├── .env                        # Environment variables
├── hwaccel.transcoding.yml     # Hardware transcoding config (if enabled)
├── hwaccel.ml.yml             # ML acceleration config (if enabled)
└── volumes/
    ├── library/               # Photo/video storage
    └── postgres/              # Database files (or Docker volume)
```

## 🔍 Hardware Detection

### Video Transcoding APIs

| API | Detection Method | Requirements |
|-----|------------------|--------------|
| **NVENC** | `nvidia-smi` + Container Toolkit | NVIDIA GPU + drivers |
| **QSV** | Intel GPU + `/dev/dri` | Intel CPU with iGPU |
| **VAAPI** | `/dev/dri` render nodes | AMD/Intel/NVIDIA GPU |
| **RKMPP** | Rockchip SoC detection | RK35xx/RK33xx ARM SoC |

### ML Acceleration Backends

| Backend | Detection Method | Requirements |
|---------|------------------|--------------|
| **CUDA** | NVIDIA GPU + Compute 5.2+ | NVIDIA Container Toolkit |
| **ROCm** | AMD GPU detection | 35GB+ disk space |
| **OpenVINO** | Intel GPU detection | Iris Xe/Arc preferred |
| **ARM NN** | Mali GPU + `/dev/mali0` | `libmali.so` library |
| **RKNN** | Rockchip SoC + NPU driver | RK3566/68/76/88 |

## ⚙️ Advanced Configuration

### Environment Variables

The script configures these key variables in `.env`:

```bash
# Storage locations
UPLOAD_LOCATION=./library
DB_DATA_LOCATION=./postgres  # or 'pgdata' for WSL Docker volume

# Database configuration
DB_PASSWORD=<generated-secure-password>

# Version control
IMMICH_VERSION=release  # or specific version like 'v1.71.0'

# Timezone
TZ=America/New_York  # or your timezone
```

### Performance Optimization

#### ML Acceleration Environment Variables

Add these to `.env` for optimal performance:

```bash
# CUDA Multi-GPU
MACHINE_LEARNING_DEVICE_IDS=0,1
MACHINE_LEARNING_WORKERS=2

# ARM NN Performance
MACHINE_LEARNING_ANN_FP16_TURBO=true

# RKNN Threading (RK3576/RK3588)
MACHINE_LEARNING_RKNN_THREADS=3

# ROCm Compatibility
HSA_OVERRIDE_GFX_VERSION=10.3.0
```

### WSL-Specific Considerations

For Windows WSL users:

- **Database Volume**: Script automatically suggests Docker volumes over bind mounts
- **Filesystem Compatibility**: NTFS/FAT32 filesystems under `/mnt` won't work for database
- **NVIDIA Support**: Container Toolkit not required in WSL2
- **VAAPI**: Uses `vaapi-wsl` variant instead of standard `vaapi`

## 🐛 Troubleshooting

### Common Issues

#### Docker Problems
```bash
# Check Docker status
docker --version
docker compose version
docker info

# Start Docker daemon (if needed)
sudo systemctl start docker
```

#### Hardware Not Detected
```bash
# Check NVIDIA
nvidia-smi
docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi

# Check Intel/AMD GPUs
ls -la /dev/dri/
lspci | grep -i "vga\|display"

# Check Container Toolkit
which nvidia-container-runtime
```

#### Permission Issues
```bash
# Add user to docker group
sudo usermod -aG docker $USER
# Log out and back in
```

### Hardware-Specific Troubleshooting

#### NVIDIA CUDA
- Verify driver version: `nvidia-smi`
- Check compute capability: GPU must be 5.2+
- Install Container Toolkit: [NVIDIA Docs](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

#### Intel QSV
- Verify `/dev/dri` devices exist
- For older CPUs: May need low-power encoding mode
- Kernel 5.15 issues: Upgrade kernel for 11th gen CPUs

#### Rockchip RKNN
- Check NPU driver: `cat /sys/kernel/debug/rknpu/version`
- Verify SoC support: Only RK3566/68/76/88
- Thread optimization: Set `MACHINE_LEARNING_RKNN_THREADS=2-3`

## 📖 References

- [Immich Documentation](https://immich.app/docs/)
- [Hardware Transcoding Guide](https://immich.app/docs/features/hardware-transcoding)
- [ML Hardware Acceleration](https://immich.app/docs/features/ml-hardware-acceleration)
- [Docker Compose Installation](https://docs.docker.com/compose/install/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

## 📝 License

This installer script is licensed under the [MIT License](https://opensource.org/licenses/MIT).

```
MIT License

Copyright (c) 2025 Immich Simple Installer

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

**Note**: This installer script is licensed under MIT. Immich itself is licensed under [GNU AGPL v3](https://github.com/immich-app/immich/blob/main/LICENSE).

## 🤝 Contributing

Feel free to submit issues, suggestions, or improvements to enhance the installer script.

---

**Note**: This is an unofficial installer script. For official installation methods, please refer to the [Immich documentation](https://immich.app/docs/install/).

