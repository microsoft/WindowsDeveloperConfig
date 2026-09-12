@{
    SchemaVersion = 1
    Components = @{
        CudaX64 = @{
            Component = 'NVIDIA CUDA Toolkit'
            Vendor = 'NVIDIA'
            Architectures = @('X64')
            Maturity = 'stable'
            SourceType = 'winget'
            PackageId = 'Nvidia.CUDA'
            VersionPolicy = 'latest applicable stable package'
            Integrity = 'WinGet manifest SHA-256 and installer signature'
            CachePath = 'WinGet managed'
            InstallPath = '%ProgramFiles%\NVIDIA GPU Computing Toolkit\CUDA\v*'
            NormalChannelLimitation = 'None'
            ExpectedStableSource = 'Nvidia.CUDA'
            MigrationTrigger = 'WinGet reports a newer applicable stable package'
            CleanupUpgrade = 'WinGet upgrade; vendor uninstaller for removal'
        }
        CudaArm64 = @{
            Component = 'NVIDIA CUDA Toolkit'
            Vendor = 'NVIDIA'
            Architectures = @('Arm64')
            Maturity = 'developer-preview'
            SourceType = 'direct'
            Version = '13.4.0'
            Artifact = 'cuda_13.4.0_windows_arm64.exe'
            Uri = 'https://packages.nvidia.com/prerelease/cuda/13.4.0/local_installers/cuda_13.4.0_windows_arm64.exe'
            Sha256 = 'a1f68c81160b16d519c4087788b9c07de41306c3f1b872471ceee0996621374d'
            VersionPolicy = 'exact qualified preview'
            Integrity = 'Pinned SHA-256 plus exact Microsoft-trusted NVIDIA Authenticode signer'
            CachePath = '%ProgramData%\WindowsDeveloperConfig\cache\nvidia-cuda\13.4.0'
            InstallPath = '%ProgramFiles%\NVIDIA GPU Computing Toolkit\CUDA\v13.4'
            NormalChannelLimitation = 'Nvidia.CUDA does not currently publish a Windows ARM64 installer'
            ExpectedStableSource = 'Nvidia.CUDA (ARM64 architecture support unconfirmed)'
            MigrationTrigger = 'WinGet manifest for Nvidia.CUDA publishes ARM64 and passes the N1X kernel acceptance'
            CleanupUpgrade = 'Install newer qualified version side-by-side, validate, then use NVIDIA uninstaller for old preview'
        }
        FoundryLocal = @{
            Component = 'Foundry Local'
            Vendor = 'Microsoft'
            Architectures = @('X64', 'Arm64')
            Maturity = 'preview'
            SourceType = 'winget'
            PackageId = 'Microsoft.FoundryLocal'
            VersionPolicy = 'latest applicable preview package'
            Integrity = 'WinGet manifest SHA-256 and MSIX signature'
            CachePath = 'Foundry cache reported by foundry cache location'
            InstallPath = 'Per-user MSIX'
            NormalChannelLimitation = 'The product is still public preview'
            ExpectedStableSource = 'Microsoft.FoundryLocal'
            MigrationTrigger = 'Microsoft marks the CLI/package GA and real inference acceptance passes'
            CleanupUpgrade = 'WinGet upgrade; foundry cache remove for model cleanup'
        }
        NvidiaPyTorchArm64 = @{
            Component = 'PyTorch CUDA for Windows ARM64'
            Vendor = 'NVIDIA/PyTorch'
            Architectures = @('Arm64')
            Maturity = 'nightly-developer-preview'
            SourceType = 'direct-python-wheel'
            Version = '2.15.0.dev20260904+cu134'
            Uri = 'https://pypi.nvidia.com/nvtorch_oot_nightly/torch/torch-2.15.0.dev20260904%2Bcu134-cp313-cp313-win_arm64.whl'
            Sha256 = 'af0872854d183cb6894dbd5b1e5e9291875ce139d138b5fc0b501498828265d3'
            VersionPolicy = 'exact hardware-qualified nightly'
            Integrity = 'Pinned SHA-256; dependencies resolve from the configured primary Python index'
            CachePath = '%LOCALAPPDATA%\DevConfig\pytorch\wheel-cache'
            InstallPath = '%LOCALAPPDATA%\DevConfig\pytorch\.venv'
            NormalChannelLimitation = 'Official stable PyTorch indexes do not publish win_arm64 CUDA wheels'
            ExpectedStableSource = 'https://download.pytorch.org/whl/cu* (Windows ARM64 channel unconfirmed)'
            MigrationTrigger = 'Stable PyTorch index publishes a win_arm64 CUDA wheel and N1X tensor/Triton acceptance passes'
            CleanupUpgrade = 'Replace contained venv; retain only qualified wheel cache entries'
            NativeToolkitRequired = $false
            NativeToolkitRelationship = 'The wheel carries the CUDA runtime. The standalone cuda flow is for native CUDA development; this setup acquires compiler/toolkit components only for supported Triton JIT.'
        }
        PyTorchCpu = @{
            Component = 'PyTorch CPU'
            Vendor = 'PyTorch'
            Architectures = @('X64', 'Arm64')
            Maturity = 'stable'
            SourceType = 'pytorch-index'
            IndexUrl = 'https://download.pytorch.org/whl/cpu'
            Version = '2.14.0'
            VersionPolicy = 'exact stable backend-qualified wheel'
            Integrity = 'Official PyTorch package index hashes and wheel RECORD'
            CachePath = 'Python package cache'
            InstallPath = '%LOCALAPPDATA%\DevConfig\pytorch\.venv'
            NormalChannelLimitation = 'None'
            ExpectedStableSource = 'https://download.pytorch.org/whl/cpu'
            MigrationTrigger = 'New stable tuple passes CPU tensor acceptance'
            CleanupUpgrade = 'Replace contained venv'
            NativeToolkitRequired = $false
            NativeToolkitRelationship = 'No vendor toolkit is required.'
        }
        PyTorchCudaX64 = @{
            Component = 'PyTorch CUDA'
            Vendor = 'NVIDIA/PyTorch'
            Architectures = @('X64')
            Maturity = 'stable'
            SourceType = 'pytorch-index'
            IndexUrl = 'https://download.pytorch.org/whl/cu126 or cu130'
            Version = '2.14.0'
            VersionPolicy = 'exact stable wheel selected by GPU capability and driver branch'
            Integrity = 'Official PyTorch package index hashes and wheel RECORD'
            CachePath = 'Python package cache'
            InstallPath = '%LOCALAPPDATA%\DevConfig\pytorch\.venv'
            NormalChannelLimitation = 'None'
            ExpectedStableSource = 'Official PyTorch CUDA index'
            MigrationTrigger = 'New stable runtime tuple passes CUDA tensor and Triton acceptance'
            CleanupUpgrade = 'Replace contained venv'
            NativeToolkitRequired = $false
            NativeToolkitRelationship = 'The wheel carries the CUDA runtime. The standalone cuda flow is for nvcc/native development; this setup acquires CUDA/MSVC only when Triton JIT requires toolchain components.'
        }
        PyTorchRocm = @{
            Component = 'PyTorch ROCm'
            Vendor = 'AMD/PyTorch'
            Architectures = @('X64')
            Maturity = 'stable'
            SourceType = 'amd-python-index'
            IndexUrl = 'https://stable.repo.amd.com/rocm/whl-next/'
            Version = '2.13.0+rocm10.0.0'
            VersionPolicy = 'exact production tuple and exact supported gfx target'
            Integrity = 'Official AMD HTTPS feed allowlist and wheel RECORD'
            CachePath = 'Python package cache'
            InstallPath = '%LOCALAPPDATA%\DevConfig\pytorch\.venv'
            NormalChannelLimitation = 'Default PyPI does not publish the AMD ROCm Windows build'
            ExpectedStableSource = 'AMD stable ROCm package feed'
            MigrationTrigger = 'New production tuple lists the GPU and tensor acceptance passes'
            CleanupUpgrade = 'Replace contained venv'
            NativeToolkitRequired = $false
            NativeToolkitRelationship = 'The AMD device-specific PyTorch tuple carries its ROCm runtime dependencies. The standalone rocm flow is not a prerequisite; it is for hipcc/native HIP kernel development.'
        }
        PyTorchXpu = @{
            Component = 'PyTorch XPU'
            Vendor = 'Intel/PyTorch'
            Architectures = @('X64')
            Maturity = 'stable'
            SourceType = 'pytorch-index'
            IndexUrl = 'https://download.pytorch.org/whl/xpu'
            Version = '2.14.0+xpu'
            VersionPolicy = 'exact stable XPU tuple'
            Integrity = 'Official PyTorch package index hashes and wheel RECORD'
            CachePath = 'Python package cache'
            InstallPath = '%LOCALAPPDATA%\DevConfig\pytorch\.venv'
            NormalChannelLimitation = 'Default PyPI does not publish the Intel XPU build'
            ExpectedStableSource = 'https://download.pytorch.org/whl/xpu'
            MigrationTrigger = 'New stable tuple passes XPU tensor and torch.compile acceptance'
            CleanupUpgrade = 'Replace contained venv'
            NativeToolkitRequired = $false
            NativeToolkitRelationship = 'The official XPU wheel tuple carries the PyTorch runtime and does not install full oneAPI. The standalone intel-ai SYCL/Full profiles install oneAPI only for native SYCL development.'
        }
        TritonWindows = @{
            Component = 'Triton Windows'
            Vendor = 'Triton project'
            Architectures = @('X64', 'Arm64')
            Maturity = 'community'
            SourceType = 'pypi'
            Package = 'triton-windows==3.8.0.post28'
            VersionPolicy = 'exact qualified build matched to PyTorch'
            Integrity = 'Python package index TLS and wheel RECORD'
            CachePath = 'Python package cache'
            InstallPath = 'PyTorch contained venv'
            NormalChannelLimitation = 'Upstream Triton does not publish a general stable Windows package'
            ExpectedStableSource = 'Official PyTorch/Triton Windows package feed (unconfirmed)'
            MigrationTrigger = 'Official Windows package is published and vector-add acceptance passes'
            CleanupUpgrade = 'Replace contained venv when PyTorch/Triton tuple changes'
        }
        TritonXpu = @{
            Component = 'Triton XPU'
            Vendor = 'Intel/PyTorch'
            Architectures = @('X64')
            Maturity = 'stable-integrated'
            SourceType = 'pytorch-index'
            Package = 'triton-xpu==3.8.0'
            VersionPolicy = 'exact PyTorch XPU-compatible tuple'
            Integrity = 'Official PyTorch XPU index hash and wheel RECORD'
            CachePath = 'Python package cache'
            InstallPath = 'PyTorch contained venv'
            NormalChannelLimitation = 'Standalone Intel Triton still documents Linux; Windows support is through PyTorch torch.compile'
            ExpectedStableSource = 'Official PyTorch XPU index'
            MigrationTrigger = 'New PyTorch XPU tuple passes cold torch.compile acceptance'
            CleanupUpgrade = 'Replace contained venv'
        }
        LlamaCppRolling = @{
            Component = 'llama.cpp Windows binaries'
            Vendor = 'ggml-org'
            Architectures = @('X64', 'Arm64')
            Maturity = 'rolling'
            SourceType = 'github-release'
            Repository = 'ggml-org/llama.cpp'
            BackendAssets = @{
                CpuX64 = @{
                    Backend = 'CPU'
                    Vendor = 'CPU'
                    Architecture = 'X64'
                    Runtime = 'CPU x64'
                    Patterns = @('^llama-b[0-9]+-bin-win-cpu-x64\.zip$')
                }
                CpuArm64 = @{
                    Backend = 'CPU'
                    Vendor = 'CPU'
                    Architecture = 'Arm64'
                    Runtime = 'CPU ARM64'
                    Patterns = @('^llama-b[0-9]+-bin-win-cpu-arm64\.zip$')
                }
                Cuda124X64 = @{
                    Backend = 'CUDA'
                    Vendor = 'NVIDIA'
                    Architecture = 'X64'
                    Runtime = 'CUDA 12.4'
                    Patterns = @(
                        '^llama-b[0-9]+-bin-win-cuda-12\.4-x64\.zip$',
                        '^cudart-llama-bin-win-cuda-12\.4-x64\.zip$'
                    )
                }
                Cuda133X64 = @{
                    Backend = 'CUDA'
                    Vendor = 'NVIDIA'
                    Architecture = 'X64'
                    Runtime = 'CUDA 13.3'
                    Patterns = @(
                        '^llama-b[0-9]+-bin-win-cuda-13\.3-x64\.zip$',
                        '^cudart-llama-bin-win-cuda-13\.3-x64\.zip$'
                    )
                }
                Cuda134Arm64 = @{
                    Backend = 'CUDA'
                    Vendor = 'NVIDIA'
                    Architecture = 'Arm64'
                    Runtime = 'CUDA 13.4 Developer Preview'
                    Maturity = 'rolling-developer-preview'
                    Patterns = @(
                        '^llama-b[0-9]+-bin-win-cuda-13\.4-arm64\.zip$',
                        '^cudart-llama-bin-win-cuda-13\.4-arm64\.zip$'
                    )
                }
                Rocm10X64 = @{
                    Backend = 'ROCm'
                    Vendor = 'AMD'
                    Architecture = 'X64'
                    Runtime = 'ROCm 10.0'
                    Patterns = @('^llama-b[0-9]+-bin-win-rocm-10\.0-x64\.zip$')
                }
                SyclX64 = @{
                    Backend = 'SYCL'
                    Vendor = 'Intel'
                    Architecture = 'X64'
                    Runtime = 'SYCL'
                    Patterns = @('^llama-b[0-9]+-bin-win-sycl-x64\.zip$')
                }
                OpenVinoX64 = @{
                    Backend = 'OpenVINO'
                    Vendor = 'Intel/general'
                    Architecture = 'X64'
                    Runtime = 'OpenVINO 2026.3.1'
                    Patterns = @('^llama-b[0-9]+-bin-win-openvino-2026\.3\.1-x64\.zip$')
                }
                VulkanX64 = @{
                    Backend = 'Vulkan'
                    Vendor = 'Cross-vendor'
                    Architecture = 'X64'
                    Runtime = 'Vulkan'
                    Patterns = @('^llama-b[0-9]+-bin-win-vulkan-x64\.zip$')
                }
                OpenClAdrenoArm64 = @{
                    Backend = 'OpenCL'
                    Vendor = 'Qualcomm'
                    Architecture = 'Arm64'
                    Runtime = 'OpenCL Adreno'
                    Patterns = @('^llama-b10917-bin-win-opencl-adreno-arm64\.zip$')
                    VersionPolicy = 'pinned b10917 qualified on Qualcomm ARM64; b10919 is blocked by managed Defender ransomware protection'
                }
            }
            VersionPolicy = 'newest bNNNNN release containing a complete backend asset set'
            Integrity = 'GitHub release asset SHA-256 digest'
            CachePath = '%LOCALAPPDATA%\DevConfig\llama.cpp\asset-cache'
            InstallPath = '%LOCALAPPDATA%\DevConfig\llama.cpp\runtime'
            NormalChannelLimitation = 'WinGet ggml.llamacpp currently maps only to the x64 Vulkan variant and does not expose backend-specific package choices'
            ExpectedStableSource = 'ggml.llamacpp backend-specific package variants when published; otherwise unconfirmed'
            MigrationTrigger = 'WinGet publishes the required backend for the host and inference/benchmark acceptance passes'
            CleanupUpgrade = 'Reuse digest-verified asset cache and atomically replace resolver-owned runtime directory'
        }
        OllamaX64 = @{
            Component = 'Ollama'
            Vendor = 'Ollama'
            Architectures = @('X64')
            Maturity = 'stable'
            SourceType = 'winget'
            PackageId = 'Ollama.Ollama'
            VersionPolicy = 'latest applicable stable package'
            Integrity = 'WinGet manifest SHA-256 and installer signature'
            CachePath = '%USERPROFILE%\.ollama\models or OLLAMA_MODELS'
            InstallPath = 'Per-user application'
            NormalChannelLimitation = 'None'
            ExpectedStableSource = 'Ollama.Ollama'
            MigrationTrigger = 'WinGet reports a newer applicable stable package'
            CleanupUpgrade = 'WinGet upgrade; ollama rm for models'
        }
        OllamaArm64 = @{
            Component = 'Ollama portable'
            Vendor = 'Ollama'
            Architectures = @('Arm64')
            Maturity = 'stable-direct'
            SourceType = 'github-latest-release'
            Repository = 'ollama/ollama'
            AssetPattern = '^ollama-windows-arm64\.zip$'
            VersionPolicy = 'latest non-prerelease release'
            Integrity = 'GitHub release asset SHA-256 digest'
            CachePath = '%LOCALAPPDATA%\DevConfig\ollama\runtime'
            InstallPath = '%LOCALAPPDATA%\DevConfig\ollama\runtime'
            NormalChannelLimitation = 'Ollama.Ollama is x64-only and Ollama.Ollama.Portable lags the official release'
            ExpectedStableSource = 'Ollama.Ollama or Ollama.Ollama.Portable with current ARM64 payload'
            MigrationTrigger = 'WinGet publishes current ARM64 payload and API/model acceptance passes'
            CleanupUpgrade = 'Atomically replace resolver-owned runtime directory'
        }
        AmdRocm = @{
            Component = 'AMD ROCm Core SDK'
            Vendor = 'AMD'
            Architectures = @('X64')
            Maturity = 'stable'
            SourceType = 'amd-python-index'
            IndexUrl = 'https://stable.repo.amd.com/rocm/whl-next/'
            Version = '10.0.0'
            PackageTemplate = 'rocm[libraries,devel,device-{0}]==10.0.0'
            VersionPolicy = 'exact production tuple and exact supported gfx target'
            Integrity = 'Exact AMD HTTPS feed allowlist and wheel RECORD; AMD feed does not publish SHA-256 fragments'
            CachePath = 'Python package cache'
            InstallPath = '%LOCALAPPDATA%\DevConfig\rocm\.venv'
            NormalChannelLimitation = 'No WinGet package and not published on the default PyPI channel'
            ExpectedStableSource = 'AMD stable ROCm package feed; WinGet package unconfirmed'
            MigrationTrigger = 'New AMD production tuple lists the exact GPU in Windows compatibility data and HIP kernel acceptance passes'
            CleanupUpgrade = 'Replace versioned contained environment after HIP kernel validation'
        }
        IntelOpenVino = @{
            Component = 'Intel OpenVINO Runtime/GenAI'
            Vendor = 'Intel'
            Architectures = @('X64')
            Maturity = 'stable'
            SourceType = 'pypi'
            Packages = @('openvino==2026.3.1', 'openvino-tokenizers==2026.3.1.0', 'openvino-genai==2026.3.1.0')
            VersionPolicy = 'exact matched regular release tuple'
            Integrity = 'Official PyPI wheel hashes/RECORD; contained environment'
            CachePath = 'Python package cache'
            InstallPath = '%LOCALAPPDATA%\DevConfig\intel-ai\openvino\.venv'
            NormalChannelLimitation = 'WinGet C++ package is community-maintained and can lag the Python runtime'
            ExpectedStableSource = 'Official PyPI OpenVINO packages'
            MigrationTrigger = 'Matched newer regular/LTS tuple passes selected-device inference'
            CleanupUpgrade = 'Replace contained environment'
        }
        IntelOneApi = @{
            Component = 'Intel oneAPI Toolkit'
            Vendor = 'Intel'
            Architectures = @('X64')
            Maturity = 'stable'
            SourceType = 'winget'
            PackageId = 'Intel.OneAPI.Toolkit'
            Version = '2026.0.0.193'
            VersionPolicy = 'latest qualified stable WinGet package'
            Integrity = 'WinGet manifest SHA-256 and Intel installer signature'
            CachePath = 'WinGet managed'
            InstallPath = '%ProgramFiles(x86)%\Intel\oneAPI'
            NormalChannelLimitation = 'None'
            ExpectedStableSource = 'Intel.OneAPI.Toolkit'
            MigrationTrigger = 'New stable WinGet version passes SYCL kernel acceptance'
            CleanupUpgrade = 'WinGet upgrade; Intel installer for removal'
        }
    }
    CapabilityMatrix = @(
        @{
            Id = 'cuda-nvidia-x64'
            Workload = 'cuda'; Architecture = 'X64'; Vendor = 'NVIDIA'; DeviceFamily = 'CUDA 13-supported CC7.5+ GPU'; Backend = 'CUDA'
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('component:CudaX64', 'winget:Microsoft.VisualStudio.2022.BuildTools')
            Prerequisites = 'NVIDIA driver 580+ and compute capability 7.5+ for current stable GPU readiness; toolkit-only mode is explicit'
            Resolver = 'Resolve-CudaInstallPlan'; ResolverArguments = @{ Architecture = 'X64' }; Expected = @{ Method = 'WinGet' }
            ProbePath = 'src/Workloads/cuda/smoke.cu'; ReportEvidence = 'nvcc, compiler path, driver/device/compute capability, compiled and executed kernel'
            PartnerCommand = '.\src\Workloads\cuda\install.ps1 -ReportPath "$env:TEMP\cuda-x64-report.json"'
        }
        @{
            Id = 'cuda-nvidia-arm64'
            Workload = 'cuda'; Architecture = 'Arm64'; Vendor = 'NVIDIA'; DeviceFamily = 'RTX Spark-class CC12.x'; Backend = 'CUDA'
            Status = 'implemented-supported'; Maturity = 'developer-preview'; Acquisition = @('component:CudaArm64', 'winget:Microsoft.VisualStudio.2022.BuildTools')
            Prerequisites = 'Windows 11, driver 616+, RTX Spark-class NVIDIA GPU'
            Resolver = 'Resolve-CudaInstallPlan'; ResolverArguments = @{ Architecture = 'Arm64'; WindowsBuild = 28120 }; Expected = @{ Method = 'NvidiaInstaller'; ToolkitVersion = '13.4' }
            ProbePath = 'src/Workloads/cuda/smoke.cu'; ReportEvidence = 'pinned installer hash/signature, ARM64 compiler, nvcc, N1X driver/device, executed kernel'
            PartnerCommand = '.\src\Workloads\cuda\install.ps1 -ReportPath "$env:TEMP\cuda-arm64-report.json"'
        }
        @{
            Id = 'rocm-amd-x64'
            Workload = 'rocm'; Architecture = 'X64'; Vendor = 'AMD'; DeviceFamily = 'ROCm 10 Windows gfx matrix'; Backend = 'HIP'
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('component:AmdRocm')
            Prerequisites = 'AMD GPU marketing name must map to a published gfx target'
            Resolver = 'Resolve-RocmInstallPlan'; ResolverArguments = @{ Architecture = 'X64'; GpuName = 'AMD Radeon RX 9070 XT' }; Expected = @{ GfxTarget = 'gfx1201' }
            ProbePath = 'src/Workloads/rocm/hip-smoke.cpp'; ReportEvidence = 'AMD device, gfx target, hipcc/runtime tuple, compiled and executed HIP kernel'
            PartnerCommand = '.\src\Workloads\rocm\install.ps1 -ReportPath "$env:TEMP\rocm-hip-report.json"'
        }
        @{
            Id = 'intel-openvino-cpu-x64'
            Workload = 'intel-ai'; Architecture = 'X64'; Vendor = 'Intel/general'; DeviceFamily = 'CPU'; Backend = 'OpenVINO'
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('component:IntelOpenVino')
            Prerequisites = 'Windows x64 and CPython 3.13'
            Resolver = 'Resolve-IntelAiPlan'; ResolverArguments = @{ Architecture = 'X64'; Device = 'CPU'; Profile = 'OpenVINO' }; Expected = @{ Device = 'CPU'; InstallOpenVino = $true }
            ProbePath = 'src/Workloads/intel-ai/openvino-smoke.py'; ReportEvidence = 'requested and actual OpenVINO device, full device name, generated-model inference'
            PartnerCommand = '.\src\Workloads\intel-ai\install.ps1 -Device CPU -Profile OpenVINO -ReportPath "$env:TEMP\intel-openvino-cpu-report.json"'
        }
        @{
            Id = 'intel-openvino-gpu-x64'
            Workload = 'intel-ai'; Architecture = 'X64'; Vendor = 'Intel'; DeviceFamily = 'OpenVINO-supported Intel GPU'; Backend = 'OpenVINO'
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('component:IntelOpenVino')
            Prerequisites = 'Detected Intel display adapter and installed compatible driver'
            Resolver = 'Resolve-IntelAiPlan'; ResolverArguments = @{ Architecture = 'X64'; Device = 'GPU'; Profile = 'OpenVINO'; IntelGpuPresent = $true }; Expected = @{ Device = 'GPU'; InstallOpenVino = $true }
            ProbePath = 'src/Workloads/intel-ai/openvino-smoke.py'; ReportEvidence = 'actual OpenVINO GPU and full device name, generated-model inference'
            PartnerCommand = '.\src\Workloads\intel-ai\install.ps1 -Device GPU -Profile OpenVINO -ReportPath "$env:TEMP\intel-openvino-gpu-report.json"'
        }
        @{
            Id = 'intel-openvino-npu-x64'
            Workload = 'intel-ai'; Architecture = 'X64'; Vendor = 'Intel'; DeviceFamily = 'Intel AI Boost/OpenVINO NPU'; Backend = 'OpenVINO'
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('component:IntelOpenVino')
            Prerequisites = 'Detected Intel NPU and compatible installed driver'
            Resolver = 'Resolve-IntelAiPlan'; ResolverArguments = @{ Architecture = 'X64'; Device = 'NPU'; Profile = 'OpenVINO'; IntelNpuPresent = $true }; Expected = @{ Device = 'NPU'; InstallOpenVino = $true }
            ProbePath = 'src/Workloads/intel-ai/openvino-smoke.py'; ReportEvidence = 'actual OpenVINO NPU and full device name, generated-model inference'
            PartnerCommand = '.\src\Workloads\intel-ai\install.ps1 -Device NPU -Profile OpenVINO -ReportPath "$env:TEMP\intel-openvino-npu-report.json"'
        }
        @{
            Id = 'intel-sycl-gpu-x64'
            Workload = 'intel-ai'; Architecture = 'X64'; Vendor = 'Intel'; DeviceFamily = 'oneAPI-supported Intel GPU'; Backend = 'SYCL'
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('component:IntelOneApi')
            Prerequisites = 'Detected Intel GPU and compatible installed driver'
            Resolver = 'Resolve-IntelAiPlan'; ResolverArguments = @{ Architecture = 'X64'; Device = 'GPU'; Profile = 'SYCL'; IntelGpuPresent = $true }; Expected = @{ Device = 'GPU'; InstallOneApi = $true }
            ProbePath = 'src/Workloads/intel-ai/sycl-smoke.cpp'; ReportEvidence = 'oneAPI compiler/runtime, selected Intel GPU, compiled and executed SYCL kernel'
            PartnerCommand = '.\src\Workloads\intel-ai\install.ps1 -Device GPU -Profile SYCL -ReportPath "$env:TEMP\intel-sycl-report.json"'
        }
        @{
            Id = 'intel-full-gpu-x64'
            Workload = 'intel-ai'; Architecture = 'X64'; Vendor = 'Intel'; DeviceFamily = 'OpenVINO/oneAPI-supported Intel GPU'; Backend = 'OpenVINO+SYCL'
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('component:IntelOpenVino', 'component:IntelOneApi')
            Prerequisites = 'Detected Intel GPU and compatible installed driver'
            Resolver = 'Resolve-IntelAiPlan'; ResolverArguments = @{ Architecture = 'X64'; Device = 'GPU'; Profile = 'Full'; IntelGpuPresent = $true }; Expected = @{ Device = 'GPU'; InstallOpenVino = $true; InstallOneApi = $true }
            ProbePath = 'src/Workloads/intel-ai/install.ps1'; ReportEvidence = 'actual OpenVINO GPU inference plus compiled and executed oneAPI SYCL kernel'
            PartnerCommand = '.\src\Workloads\intel-ai\install.ps1 -Device GPU -Profile Full -ReportPath "$env:TEMP\intel-full-report.json"'
        }
        @{
            Id = 'pytorch-cpu-x64'
            Workload = 'pytorch'; Architecture = 'X64'; Vendor = 'CPU'; DeviceFamily = 'x64 CPU'; Backend = 'CPU'
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('component:PyTorchCpu', 'winget:Python.Python.3.13')
            Prerequisites = 'Windows x64'
            Resolver = 'Resolve-PyTorchPlan'; ResolverArguments = @{ Architecture = 'X64'; Backend = 'CPU'; PythonVersion = '3.13' }; Expected = @{ Backend = 'CPU'; Runtime = 'cpu' }
            ProbePath = 'src/Workloads/pytorch/smoke.py'; ReportEvidence = 'exact wheel tuple, CPU device, tensor and NumPy bridge'
            PartnerCommand = '.\src\Workloads\pytorch\install.ps1 -Backend CPU -ReportPath "$env:TEMP\pytorch-cpu-x64-report.json"'
        }
        @{
            Id = 'pytorch-cpu-arm64'
            Workload = 'pytorch'; Architecture = 'Arm64'; Vendor = 'CPU'; DeviceFamily = 'ARM64 CPU'; Backend = 'CPU'
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('component:PyTorchCpu', 'winget:Python.Python.3.13')
            Prerequisites = 'Windows ARM64'
            Resolver = 'Resolve-PyTorchPlan'; ResolverArguments = @{ Architecture = 'Arm64'; Backend = 'CPU'; PythonVersion = '3.13' }; Expected = @{ Backend = 'CPU'; Runtime = 'cpu' }
            ProbePath = 'src/Workloads/pytorch/smoke.py'; ReportEvidence = 'native ARM64 CPU wheel, CPU tensor and NumPy bridge'
            PartnerCommand = '.\src\Workloads\pytorch\install.ps1 -Backend CPU -ReportPath "$env:TEMP\pytorch-cpu-arm64-report.json"'
        }
        @{
            Id = 'pytorch-cuda-x64'
            Workload = 'pytorch'; Architecture = 'X64'; Vendor = 'NVIDIA'; DeviceFamily = 'CUDA-capable GPU'; Backend = 'CUDA'
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('component:PyTorchCudaX64', 'winget:Python.Python.3.13')
            Prerequisites = 'Compute capability 5.0+, driver 525+; CUDA 13-class GPUs require driver 580+'
            Resolver = 'Resolve-PyTorchPlan'; ResolverArguments = @{ Architecture = 'X64'; Backend = 'CUDA'; PythonVersion = '3.13'; HasNvidia = $true; DriverMajor = 580; ComputeCapability = '8.9'; GpuName = 'NVIDIA GeForce RTX 4090' }; Expected = @{ Backend = 'CUDA'; Runtime = 'cu130' }
            ProbePath = 'src/Workloads/pytorch/smoke.py'; ReportEvidence = 'NVIDIA device, torch CUDA runtime, exact wheel tuple, executed tensor'
            PartnerCommand = '.\src\Workloads\pytorch\install.ps1 -Backend CUDA -ReportPath "$env:TEMP\pytorch-cuda-x64-report.json"'
        }
        @{
            Id = 'pytorch-cuda-arm64'
            Workload = 'pytorch'; Architecture = 'Arm64'; Vendor = 'NVIDIA'; DeviceFamily = 'RTX Spark-class CC12.x'; Backend = 'CUDA'
            Status = 'implemented-supported'; Maturity = 'nightly-developer-preview'; Acquisition = @('component:NvidiaPyTorchArm64', 'winget:Python.Python.3.13')
            Prerequisites = 'CPython 3.13, driver 616+, compute capability 12.x'
            Resolver = 'Resolve-PyTorchPlan'; ResolverArguments = @{ Architecture = 'Arm64'; Backend = 'CUDA'; PythonVersion = '3.13'; HasNvidia = $true; DriverMajor = 616; ComputeCapability = '12.1'; GpuName = 'NVIDIA RTX Spark N1X' }; Expected = @{ Backend = 'CUDA'; Runtime = 'cu134' }
            ProbePath = 'src/Workloads/pytorch/smoke.py'; ReportEvidence = 'pinned wheel hash, N1X device, torch CUDA 13.4 tensor'
            PartnerCommand = '.\src\Workloads\pytorch\install.ps1 -Backend CUDA -ReportPath "$env:TEMP\pytorch-cuda-arm64-report.json"'
        }
        @{
            Id = 'pytorch-rocm-x64'
            Workload = 'pytorch'; Architecture = 'X64'; Vendor = 'AMD'; DeviceFamily = 'ROCm 10 Windows gfx matrix'; Backend = 'ROCm'
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('component:PyTorchRocm', 'winget:Python.Python.3.13')
            Prerequisites = 'Exact supported AMD GPU/gfx target'
            Resolver = 'Resolve-PyTorchPlan'; ResolverArguments = @{ Architecture = 'X64'; Backend = 'ROCm'; PythonVersion = '3.13'; HasAmd = $true; AmdGpuName = 'AMD Radeon RX 9070 XT'; AmdGfxTarget = 'gfx1201' }; Expected = @{ Backend = 'ROCm'; AmdGfxTarget = 'gfx1201' }
            ProbePath = 'src/Workloads/pytorch/smoke.py'; ReportEvidence = 'exact AMD package tuple, non-null torch.version.hip, AMD device/gfx, tensor'
            PartnerCommand = '.\src\Workloads\pytorch\install.ps1 -Backend ROCm -ReportPath "$env:TEMP\pytorch-rocm-report.json"'
        }
        @{
            Id = 'pytorch-xpu-x64'
            Workload = 'pytorch'; Architecture = 'X64'; Vendor = 'Intel'; DeviceFamily = 'validated Intel XPU GPU families'; Backend = 'XPU'
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('component:PyTorchXpu', 'winget:Python.Python.3.13')
            Prerequisites = 'Supported Intel GPU and compatible driver'
            Resolver = 'Resolve-PyTorchPlan'; ResolverArguments = @{ Architecture = 'X64'; Backend = 'XPU'; PythonVersion = '3.13'; HasIntel = $true; IntelGpuName = 'Intel Arc B580 Graphics' }; Expected = @{ Backend = 'XPU'; Runtime = 'xpu' }
            ProbePath = 'src/Workloads/pytorch/smoke.py'; ReportEvidence = 'Intel XPU device, exact wheel tuple, executed tensor'
            PartnerCommand = '.\src\Workloads\pytorch\install.ps1 -Backend XPU -ReportPath "$env:TEMP\pytorch-xpu-report.json"'
        }
        @{
            Id = 'triton-cuda-x64'
            Workload = 'pytorch-triton'; Architecture = 'X64'; Vendor = 'NVIDIA'; DeviceFamily = 'CUDA CC8.0+'; Backend = 'CUDA'
            Status = 'implemented-supported'; Maturity = 'community'; Acquisition = @('component:PyTorchCudaX64', 'component:TritonWindows')
            Prerequisites = 'Compatible PyTorch CUDA tuple, CC8.0+, MSVC/CUDA JIT toolchain'
            Resolver = 'Resolve-PyTorchPlan'; ResolverArguments = @{ Architecture = 'X64'; Backend = 'CUDA'; PythonVersion = '3.13'; HasNvidia = $true; DriverMajor = 580; ComputeCapability = '8.9'; GpuName = 'NVIDIA GeForce RTX 4090' }; Expected = @{ InstallTriton = $true }
            ProbePath = 'src/Workloads/pytorch/triton-smoke.py'; ReportEvidence = 'triton-windows version and executed vector-add kernel'
            PartnerCommand = '.\src\Workloads\pytorch\install.ps1 -Backend CUDA -RequireTriton -ReportPath "$env:TEMP\triton-cuda-x64-report.json"'
        }
        @{
            Id = 'triton-cuda-arm64'
            Workload = 'pytorch-triton'; Architecture = 'Arm64'; Vendor = 'NVIDIA'; DeviceFamily = 'RTX Spark CC12.x'; Backend = 'CUDA'
            Status = 'implemented-supported'; Maturity = 'community-on-preview'; Acquisition = @('component:NvidiaPyTorchArm64', 'component:TritonWindows')
            Prerequisites = 'Qualified ARM64 PyTorch CUDA preview, MSVC ARM64, CUDA 13.4'
            Resolver = 'Resolve-PyTorchPlan'; ResolverArguments = @{ Architecture = 'Arm64'; Backend = 'CUDA'; PythonVersion = '3.13'; HasNvidia = $true; DriverMajor = 616; ComputeCapability = '12.1'; GpuName = 'NVIDIA RTX Spark N1X' }; Expected = @{ InstallTriton = $true }
            ProbePath = 'src/Workloads/pytorch/triton-smoke.py'; ReportEvidence = 'triton-windows version and N1X vector-add JIT kernel'
            PartnerCommand = '.\src\Workloads\pytorch\install.ps1 -Backend CUDA -RequireTriton -ReportPath "$env:TEMP\triton-cuda-arm64-report.json"'
        }
        @{
            Id = 'triton-xpu-x64'
            Workload = 'pytorch-triton'; Architecture = 'X64'; Vendor = 'Intel'; DeviceFamily = 'validated Intel XPU GPU families'; Backend = 'XPU'
            Status = 'implemented-supported'; Maturity = 'stable-integrated'; Acquisition = @('component:PyTorchXpu', 'component:TritonXpu')
            Prerequisites = 'Supported Intel XPU GPU and official XPU tuple'
            Resolver = 'Resolve-PyTorchPlan'; ResolverArguments = @{ Architecture = 'X64'; Backend = 'XPU'; PythonVersion = '3.13'; HasIntel = $true; IntelGpuName = 'Intel Arc B580 Graphics' }; Expected = @{ InstallTriton = $true }
            ProbePath = 'src/Workloads/pytorch/xpu-smoke.py'; ReportEvidence = 'triton-xpu version, Intel device and successful cold torch.compile'
            PartnerCommand = '.\src\Workloads\pytorch\install.ps1 -Backend XPU -RequireTriton -ReportPath "$env:TEMP\triton-xpu-report.json"'
        }
        @{
            Id = 'llama-cpu-x64'
            Workload = 'llama.cpp'; Architecture = 'X64'; Vendor = 'CPU'; DeviceFamily = 'x64 CPU'; Backend = 'CPU'
            Status = 'implemented-supported'; Maturity = 'rolling'; Acquisition = @('component:LlamaCppRolling')
            Prerequisites = 'Windows x64'
            Resolver = 'Resolve-LlamaCppInstallPlan'; ResolverArguments = @{ Architecture = 'X64'; Backend = 'CPU' }; Expected = @{ Backend = 'CPU'; Runtime = 'CPU x64' }
            ProbePath = 'src/tests/llama.cpp/probe.ps1'; ReportEvidence = 'official asset tag/digest, zero GPU layers, pinned model inference'
            PartnerCommand = '.\src\Workloads\llama.cpp\install.ps1 -Backend CPU -ReportPath "$env:TEMP\llama-cpu-x64-report.json"'
        }
        @{
            Id = 'llama-cpu-arm64'
            Workload = 'llama.cpp'; Architecture = 'Arm64'; Vendor = 'CPU'; DeviceFamily = 'ARM64 CPU'; Backend = 'CPU'
            Status = 'implemented-supported'; Maturity = 'rolling'; Acquisition = @('component:LlamaCppRolling')
            Prerequisites = 'Windows ARM64'
            Resolver = 'Resolve-LlamaCppInstallPlan'; ResolverArguments = @{ Architecture = 'Arm64'; Backend = 'CPU' }; Expected = @{ Backend = 'CPU'; Runtime = 'CPU ARM64' }
            ProbePath = 'src/tests/llama.cpp/probe.ps1'; ReportEvidence = 'official asset tag/digest, zero GPU layers, pinned model inference'
            PartnerCommand = '.\src\Workloads\llama.cpp\install.ps1 -Backend CPU -ReportPath "$env:TEMP\llama-cpu-arm64-report.json"'
        }
        @{
            Id = 'llama-cuda-x64'
            Workload = 'llama.cpp'; Architecture = 'X64'; Vendor = 'NVIDIA'; DeviceFamily = 'CUDA-capable GPU'; Backend = 'CUDA'
            Status = 'implemented-supported'; Maturity = 'rolling'; Acquisition = @('component:LlamaCppRolling')
            Prerequisites = 'CC5.x-9.x with driver 551.61+ or CC7.5+ with driver 580+ for CUDA 13.3'
            Resolver = 'Resolve-LlamaCppInstallPlan'; ResolverArguments = @{ Architecture = 'X64'; Backend = 'CUDA'; HasNvidia = $true; DriverVersion = '581.10'; ComputeCapability = '8.9'; NvidiaGpuName = 'NVIDIA GeForce RTX 4090' }; Expected = @{ Backend = 'CUDA'; Runtime = 'CUDA 13.3' }
            ProbePath = 'src/tests/llama.cpp/probe.ps1'; ReportEvidence = 'paired app/cudart tag/digests, NVIDIA device, CUDA backend, GPU layers, inference'
            PartnerCommand = '.\src\Workloads\llama.cpp\install.ps1 -Backend CUDA -ReportPath "$env:TEMP\llama-cuda-x64-report.json"'
        }
        @{
            Id = 'llama-cuda-arm64'
            Workload = 'llama.cpp'; Architecture = 'Arm64'; Vendor = 'NVIDIA'; DeviceFamily = 'RTX Spark CC12.x'; Backend = 'CUDA'
            Status = 'implemented-supported'; Maturity = 'rolling-developer-preview'; Acquisition = @('component:LlamaCppRolling')
            Prerequisites = 'Driver 616+, compute capability 12.x'
            Resolver = 'Resolve-LlamaCppInstallPlan'; ResolverArguments = @{ Architecture = 'Arm64'; Backend = 'CUDA'; HasNvidia = $true; DriverVersion = '616.62'; ComputeCapability = '12.1'; NvidiaGpuName = 'NVIDIA RTX Spark N1X' }; Expected = @{ Backend = 'CUDA'; Runtime = 'CUDA 13.4 Developer Preview' }
            ProbePath = 'src/tests/llama.cpp/probe.ps1'; ReportEvidence = 'paired app/cudart tag/digests, N1X device, CUDA backend, GPU layers, inference'
            PartnerCommand = '.\src\Workloads\llama.cpp\install.ps1 -Backend CUDA -ReportPath "$env:TEMP\llama-cuda-arm64-report.json"'
        }
        @{
            Id = 'llama-rocm-x64'
            Workload = 'llama.cpp'; Architecture = 'X64'; Vendor = 'AMD'; DeviceFamily = 'ROCm 10 Windows gfx matrix'; Backend = 'ROCm'
            Status = 'implemented-supported'; Maturity = 'rolling'; Acquisition = @('component:LlamaCppRolling')
            Prerequisites = 'Supported AMD GPU/gfx target'
            Resolver = 'Resolve-LlamaCppInstallPlan'; ResolverArguments = @{ Architecture = 'X64'; Backend = 'ROCm'; AmdGpuName = 'AMD Radeon RX 9070 XT'; AmdGfxTarget = 'gfx1201' }; Expected = @{ Backend = 'ROCm'; Runtime = 'ROCm 10.0' }
            ProbePath = 'src/tests/llama.cpp/probe.ps1'; ReportEvidence = 'official asset tag/digest, AMD device/gfx, ROCm backend, GPU layers, inference'
            PartnerCommand = '.\src\Workloads\llama.cpp\install.ps1 -Backend ROCm -ReportPath "$env:TEMP\llama-rocm-report.json"'
        }
        @{
            Id = 'llama-sycl-x64'
            Workload = 'llama.cpp'; Architecture = 'X64'; Vendor = 'Intel'; DeviceFamily = 'validated Intel GPU families'; Backend = 'SYCL'
            Status = 'implemented-supported'; Maturity = 'rolling'; Acquisition = @('component:LlamaCppRolling')
            Prerequisites = 'Supported Intel GPU and installed compatible driver'
            Resolver = 'Resolve-LlamaCppInstallPlan'; ResolverArguments = @{ Architecture = 'X64'; Backend = 'SYCL'; IntelGpuName = 'Intel Arc B580 Graphics' }; Expected = @{ Backend = 'SYCL'; Runtime = 'SYCL' }
            ProbePath = 'src/tests/llama.cpp/probe.ps1'; ReportEvidence = 'official asset tag/digest, Intel device, SYCL backend, GPU layers, inference'
            PartnerCommand = '.\src\Workloads\llama.cpp\install.ps1 -Backend SYCL -ReportPath "$env:TEMP\llama-sycl-report.json"'
        }
        @{
            Id = 'llama-openvino-x64'
            Workload = 'llama.cpp'; Architecture = 'X64'; Vendor = 'Intel/general'; DeviceFamily = 'OpenVINO backend device'; Backend = 'OpenVINO'
            Status = 'implemented-supported'; Maturity = 'rolling'; Acquisition = @('component:LlamaCppRolling')
            Prerequisites = 'Windows x64 and backend-visible device'
            Resolver = 'Resolve-LlamaCppInstallPlan'; ResolverArguments = @{ Architecture = 'X64'; Backend = 'OpenVINO'; IntelGpuName = 'Intel Arc B580 Graphics' }; Expected = @{ Backend = 'OpenVINO'; Runtime = 'OpenVINO 2026.3.1' }
            ProbePath = 'src/tests/llama.cpp/probe.ps1'; ReportEvidence = 'official asset tag/digest, actual OpenVINO device/backend, GPU layers, inference; no NPU claim'
            PartnerCommand = '.\src\Workloads\llama.cpp\install.ps1 -Backend OpenVINO -ReportPath "$env:TEMP\llama-openvino-report.json"'
        }
        @{
            Id = 'llama-vulkan-x64'
            Workload = 'llama.cpp'; Architecture = 'X64'; Vendor = 'Cross-vendor'; DeviceFamily = 'Vulkan-capable GPU'; Backend = 'Vulkan'
            Status = 'implemented-supported'; Maturity = 'rolling-fallback'; Acquisition = @('component:LlamaCppRolling')
            Prerequisites = 'Vulkan loader and usable display adapter'
            Resolver = 'Resolve-LlamaCppInstallPlan'; ResolverArguments = @{ Architecture = 'X64'; Backend = 'Vulkan'; HasVulkan = $true; VulkanGpuName = 'Generic Vulkan GPU' }; Expected = @{ Backend = 'Vulkan'; Runtime = 'Vulkan' }
            ProbePath = 'src/tests/llama.cpp/probe.ps1'; ReportEvidence = 'official asset tag/digest, Vulkan backend/device, GPU layers, fallback status, inference'
            PartnerCommand = '.\src\Workloads\llama.cpp\install.ps1 -Backend Vulkan -ReportPath "$env:TEMP\llama-vulkan-report.json"'
        }
        @{
            Id = 'llama-opencl-adreno-arm64'
            Workload = 'llama.cpp'; Architecture = 'Arm64'; Vendor = 'Qualcomm'; DeviceFamily = 'Adreno'; Backend = 'OpenCL'
            Status = 'implemented-supported'; Maturity = 'rolling'; Acquisition = @('component:LlamaCppRolling')
            Prerequisites = 'Qualcomm/Adreno adapter and Windows OpenCL loader'
            Resolver = 'Resolve-LlamaCppInstallPlan'; ResolverArguments = @{ Architecture = 'Arm64'; Backend = 'OpenCL'; QualcommGpuName = 'Qualcomm Adreno X1-85 GPU'; HasOpenCl = $true }; Expected = @{ Backend = 'OpenCL'; Runtime = 'OpenCL Adreno' }
            ProbePath = 'src/tests/llama.cpp/probe.ps1'; ReportEvidence = 'official asset tag/digest, Adreno device, OpenCL backend, GPU layers, inference'
            PartnerCommand = '.\src\Workloads\llama.cpp\install.ps1 -Backend OpenCL -ReportPath "$env:TEMP\llama-adreno-report.json"'
        }
        @{
            Id = 'foundry-source-managed-x64'
            Workload = 'foundry'; Architecture = 'X64'; Vendor = 'Source-managed'; DeviceFamily = 'WinML provider selected by Foundry'; Backend = 'WinML'
            Status = 'source-managed'; Maturity = 'preview'; Acquisition = @('component:FoundryLocal')
            Prerequisites = 'Windows 11 build 26100+'
            Resolver = 'Resolve-FoundryInstallPlan'; ResolverArguments = @{ Architecture = 'X64'; WindowsBuild = 26100 }; Expected = @{ PackageId = 'Microsoft.FoundryLocal'; RequiresCuda = $false }
            ProbePath = 'src/Workloads/foundry/install.ps1'; ReportEvidence = 'resolved package variant, model inference, actual execution provider/device, truthful CPU fallback'
            PartnerCommand = '.\src\Workloads\foundry\install.ps1 -ReportPath "$env:TEMP\foundry-x64-report.json"'
        }
        @{
            Id = 'foundry-source-managed-arm64'
            Workload = 'foundry'; Architecture = 'Arm64'; Vendor = 'Source-managed'; DeviceFamily = 'WinML provider selected by Foundry'; Backend = 'WinML'
            Status = 'source-managed'; Maturity = 'preview'; Acquisition = @('component:FoundryLocal')
            Prerequisites = 'Windows 11 build 26100+'
            Resolver = 'Resolve-FoundryInstallPlan'; ResolverArguments = @{ Architecture = 'Arm64'; WindowsBuild = 26100 }; Expected = @{ PackageId = 'Microsoft.FoundryLocal'; RequiresCuda = $false }
            ProbePath = 'src/Workloads/foundry/install.ps1'; ReportEvidence = 'resolved package variant, model inference, actual execution provider/device, truthful CPU fallback'
            PartnerCommand = '.\src\Workloads\foundry\install.ps1 -ReportPath "$env:TEMP\foundry-arm64-report.json"'
        }
        @{
            Id = 'ollama-source-managed-x64'
            Workload = 'ollama'; Architecture = 'X64'; Vendor = 'Source-managed'; DeviceFamily = 'Ollama-selected CPU/GPU'; Backend = 'Ollama'
            Status = 'source-managed'; Maturity = 'stable'; Acquisition = @('component:OllamaX64')
            Prerequisites = 'Windows x64'
            Resolver = 'Resolve-OllamaInstallPlan'; ResolverArguments = @{ Architecture = 'X64' }; Expected = @{ Method = 'WinGet'; PackageId = 'Ollama.Ollama' }
            ProbePath = 'src/Workloads/ollama/install.ps1'; ReportEvidence = 'model digest/inference, actual process backend and CPU/GPU VRAM allocation; no forced vendor selector'
            PartnerCommand = '.\src\Workloads\ollama\install.ps1 -ReportPath "$env:TEMP\ollama-x64-report.json"'
        }
        @{
            Id = 'ollama-source-managed-arm64'
            Workload = 'ollama'; Architecture = 'Arm64'; Vendor = 'Source-managed'; DeviceFamily = 'Ollama-selected CPU/NVIDIA'; Backend = 'Ollama'
            Status = 'source-managed'; Maturity = 'stable-direct'; Acquisition = @('component:OllamaArm64')
            Prerequisites = 'Windows ARM64'
            Resolver = 'Resolve-OllamaInstallPlan'; ResolverArguments = @{ Architecture = 'Arm64' }; Expected = @{ Method = 'GitHubRelease'; LaunchMode = 'Serve' }
            ProbePath = 'src/Workloads/ollama/install.ps1'; ReportEvidence = 'model digest/inference, actual process backend and CPU/GPU VRAM allocation; no Adreno claim'
            PartnerCommand = '.\src\Workloads\ollama\install.ps1 -ReportPath "$env:TEMP\ollama-arm64-report.json"'
        }
        @{
            Id = 'rocm-arm64-unavailable'; Workload = 'rocm'; Architecture = 'Arm64'; Vendor = 'AMD'; DeviceFamily = 'GPU'; Backend = 'HIP'
            Status = 'upstream-unavailable'; Blocker = 'AMD does not publish the ROCm Core SDK or PyTorch ROCm runtime for native Windows ARM64.'
        }
        @{
            Id = 'pytorch-rocm-arm64-unavailable'; Workload = 'pytorch'; Architecture = 'Arm64'; Vendor = 'AMD'; DeviceFamily = 'GPU'; Backend = 'ROCm'
            Status = 'upstream-unavailable'; Blocker = 'AMD does not publish the PyTorch ROCm runtime tuple for native Windows ARM64.'
        }
        @{
            Id = 'intel-ai-arm64-unavailable'; Workload = 'intel-ai'; Architecture = 'Arm64'; Vendor = 'Intel'; DeviceFamily = 'GPU/NPU'; Backend = 'OpenVINO/SYCL'
            Status = 'upstream-unavailable'; Blocker = 'Intel OpenVINO/oneAPI Windows artifacts used by this flow are native x64; no equivalent native Windows ARM64 tuple is published.'
        }
        @{
            Id = 'pytorch-xpu-arm64-unavailable'; Workload = 'pytorch'; Architecture = 'Arm64'; Vendor = 'Intel'; DeviceFamily = 'GPU'; Backend = 'XPU'
            Status = 'upstream-unavailable'; Blocker = 'PyTorch does not publish native Windows ARM64 XPU wheels.'
        }
        @{
            Id = 'pytorch-qualcomm-arm64-unavailable'; Workload = 'pytorch'; Architecture = 'Arm64'; Vendor = 'Qualcomm'; DeviceFamily = 'Adreno'; Backend = 'Qualcomm accelerator'
            Status = 'upstream-unavailable'; Blocker = 'PyTorch does not publish a native Windows Qualcomm/Adreno accelerator backend.'
        }
        @{
            Id = 'triton-amd-windows-unavailable'; Workload = 'pytorch-triton'; Architecture = 'X64'; Vendor = 'AMD'; DeviceFamily = 'ROCm GPU'; Backend = 'ROCm'
            Status = 'upstream-unavailable'; Blocker = 'No supported native Windows AMD Triton package is published.'
        }
        @{
            Id = 'generic-arm-gpu-toolkit-unavailable'; Workload = 'vendor-toolkit'; Architecture = 'Arm64'; Vendor = 'Generic'; DeviceFamily = 'ARM GPU'; Backend = 'Generic'
            Status = 'upstream-unavailable'; Blocker = 'There is no standalone generic ARM GPU toolkit with authoritative Windows artifacts; use a published vendor backend or source-managed WinML provider.'
        }
        @{
            Id = 'amd-ryzen-ai-npu-unavailable'; Workload = 'vendor-toolkit'; Architecture = 'X64'; Vendor = 'AMD'; DeviceFamily = 'Ryzen AI NPU'; Backend = 'NPU'
            Status = 'upstream-unavailable'; Blocker = 'ROCm is the AMD GPU/HIP stack. This repository does not implement or claim an authoritative AMD Ryzen AI NPU runtime.'
        }
        @{
            Id = 'other-windows-gpu-unavailable'; Workload = 'vendor-toolkit'; Architecture = 'X64/Arm64'; Vendor = 'Other'; DeviceFamily = 'Mali or unlisted GPU'; Backend = 'Unpublished'
            Status = 'upstream-unavailable'; Blocker = 'No authoritative supported Windows artifact is implemented for this vendor/backend combination.'
        }
    )
}
