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
            Maturity = 'qualified-interim-developer-preview'
            SourceType = 'direct'
            Version = '13.4.0'
            Artifact = 'cuda_13.4.0_windows_arm64.exe'
            Uri = 'https://packages.nvidia.com/prerelease/cuda/13.4.0/local_installers/cuda_13.4.0_windows_arm64.exe'
            Sha256 = 'a1f68c81160b16d519c4087788b9c07de41306c3f1b872471ceee0996621374d'
            VersionPolicy = 'exact qualified Windows ARM64 NVIDIA interim release'
            Integrity = 'Pinned SHA-256 plus valid NVIDIA Corporation Authenticode signature'
            CachePath = '%ProgramData%\WindowsDeveloperConfig\cache\nvidia-cuda\13.4.0'
            InstallPath = '%ProgramFiles%\NVIDIA GPU Computing Toolkit\CUDA\v13.4'
            NormalChannelLimitation = 'Nvidia.CUDA WinGet has no ARM64 payload; stable 13.4.1 direct installer is discovered but not yet qualified on supported Windows ARM64 NVIDIA hardware'
            ExpectedStableSource = 'NVIDIA stable CUDA direct download, then Nvidia.CUDA ARM64 if published'
            MigrationTrigger = 'CUDA 13.4.1 passes Windows ARM64 NVIDIA nvcc compile/kernel and PyTorch Triton JIT acceptance'
            CleanupUpgrade = 'Qualify newer version side-by-side, then use NVIDIA uninstaller for the old interim release'
            PromotionCandidate = @{
                Version = '13.4.1'
                Maturity = 'official-stable-direct-candidate'
                Artifact = 'cuda_13.4.1_windows_arm64.exe'
                Uri = 'https://developer.download.nvidia.com/compute/cuda/13.4.1/local_installers/cuda_13.4.1_windows_arm64.exe'
                Sha256 = '39af79e5e136c4e0de03bba816bda60fd7b70aad033e37ecaacf9f2e2c982442'
                Size = 3711598920
                Authenticity = 'Valid NVIDIA Corporation Authenticode signature verified'
                TrackingStatus = 'awaiting Windows ARM64 NVIDIA kernel and Triton qualification'
            }
        }
        FoundryLocal = @{
            Component = 'Foundry Local'
            Vendor = 'Microsoft'
            Architectures = @('X64', 'Arm64')
            Maturity = 'qualified-preview'
            SourceType = 'winget'
            PackageId = 'Microsoft.FoundryLocal'
            VersionPolicy = 'latest applicable qualified preview package'
            Integrity = 'WinGet manifest SHA-256 and MSIX signature'
            CachePath = 'Foundry cache reported by foundry cache location'
            InstallPath = 'Per-user MSIX'
            NormalChannelLimitation = 'WinGet remains 0.10.3 preview; official v2.0.1 is a candidate with a new SDK/API and is not yet workload-qualified'
            ExpectedStableSource = 'Official Foundry Local v2 release or a current stable Microsoft.FoundryLocal package'
            MigrationTrigger = 'v2.0.1 passes x64/ARM64 installation, provider registration, cached rerun, and real model inference'
            CleanupUpgrade = 'Preserve model cache while replacing the qualified runtime'
            PromotionCandidate = @{
                Version = '2.0.1'
                Maturity = 'official-non-prerelease-candidate; Python package metadata remains alpha'
                Repository = 'microsoft/Foundry-Local'
                PythonRequirement = 'foundry-local-sdk==2.0.1'
                X64Asset = 'foundry-local-win-x64.zip'
                X64Sha256 = '0551db07d5cba6a523e4c1832f0d38e023301ab67b946378239f8cee156ba5a4'
                Arm64Asset = 'foundry-local-win-arm64.zip'
                Arm64Sha256 = '2fa8510281cfaa554e21ffae8de41366a08051bce92fd592b919bc4413b57b09'
                TrackingStatus = 'awaiting v2 CLI/SDK migration and x64/ARM64 real inference qualification'
            }
        }
        NvidiaPyTorchArm64 = @{
            Component = 'PyTorch CUDA for Windows ARM64'
            Vendor = 'NVIDIA/PyTorch'
            Architectures = @('Arm64')
            Maturity = 'qualified-interim-nightly'
            SourceType = 'direct-python-wheel'
            Version = '2.15.0.dev20260904+cu134'
            Uri = 'https://pypi.nvidia.com/nvtorch_oot_nightly/torch/torch-2.15.0.dev20260904%2Bcu134-cp313-cp313-win_arm64.whl'
            Sha256 = 'af0872854d183cb6894dbd5b1e5e9291875ce139d138b5fc0b501498828265d3'
            VersionPolicy = 'exact qualified Windows ARM64 NVIDIA interim nightly'
            Integrity = 'Pinned SHA-256; dependencies resolve from the configured primary Python index'
            CachePath = '%LOCALAPPDATA%\DevConfig\pytorch\wheel-cache'
            InstallPath = '%LOCALAPPDATA%\DevConfig\pytorch\.venv'
            NormalChannelLimitation = 'Stable NVIDIA nvtorch_oot tuple is published but has not yet passed Windows ARM64 NVIDIA tensor/Triton qualification'
            ExpectedStableSource = 'NVIDIA stable nvtorch_oot index'
            MigrationTrigger = 'Stable 2.14.0 cu134 trio passes imports, Windows ARM64 NVIDIA CUDA tensor, and Triton vector-add'
            CleanupUpgrade = 'Replace contained venv; retain only qualified wheel cache entries'
            NativeToolkitRequired = $false
            NativeToolkitRelationship = 'The wheel carries the CUDA runtime. The standalone cuda flow is for native CUDA development; this setup acquires compiler/toolkit components only for supported Triton JIT.'
            PromotionCandidate = @{
                Maturity = 'official-out-of-tree-stable-candidate'
                IndexUrl = 'https://pypi.nvidia.com/nvtorch_oot/'
                Torch = 'torch==2.14.0+cu134'
                TorchSha256 = '4f781babc0e0e0722cc48d0b15107a28e6003fc2b6544f1578b6eb6f5177dcb5'
                Torchvision = 'torchvision==0.29.0+cu134'
                TorchvisionSha256 = 'e935037b6a97c32642d47f73da8cf62acf6453bfe15825314f774f62ec395d26'
                Torchaudio = 'torchaudio==2.11.0+cu134'
                TorchaudioSha256 = 'e4f18fa7359528416964d525ba620a0ca95ad231d6ab573b26c8b09c6ea8bf6b'
                TrackingStatus = 'awaiting Windows ARM64 NVIDIA trio import, tensor, and Triton qualification'
            }
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
                    VersionPolicy = 'pinned b10917 qualified on Qualcomm ARM64; newer releases require functional requalification'
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
            VersionPolicy = 'latest applicable stable package for x64'
            Integrity = 'WinGet manifest SHA-256 and installer signature'
            CachePath = '%USERPROFILE%\.ollama\models or OLLAMA_MODELS'
            InstallPath = 'Per-user application'
            NormalChannelLimitation = 'None'
            ExpectedStableSource = 'Ollama.Ollama'
            MigrationTrigger = 'WinGet reports a newer applicable stable package'
            CleanupUpgrade = 'WinGet upgrade; ollama rm for models'
        }
        OllamaArm64 = @{
            Component = 'Ollama'
            Vendor = 'Ollama'
            Architectures = @('Arm64')
            Maturity = 'stable'
            SourceType = 'winget'
            PackageId = 'Ollama.Ollama'
            VersionPolicy = 'latest applicable stable package for arm64'
            Integrity = 'WinGet manifest SHA-256 and installer signature'
            CachePath = '%USERPROFILE%\.ollama\models or OLLAMA_MODELS'
            InstallPath = 'Per-user application'
            NormalChannelLimitation = 'None as of Ollama.Ollama 0.40.0; the shared setup EXE is applicable to arm64 and x64'
            ExpectedStableSource = 'Ollama.Ollama'
            MigrationTrigger = 'Achieved at Ollama.Ollama 0.40.0 after native ARM64 install, API, model, and GPU-allocation acceptance'
            CleanupUpgrade = 'One-time removal of the Dev Config-managed archive while preserving models, then WinGet install/upgrade'
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
            Status = 'implemented-supported'; Maturity = 'qualified-interim-developer-preview'; Acquisition = @('component:CudaArm64', 'winget:Microsoft.VisualStudio.2022.BuildTools')
            Prerequisites = 'Windows 11 and an NVIDIA RTX Spark-class GPU with compute capability 12.x; runtime compatibility is proven by the kernel workload'
            Resolver = 'Resolve-CudaInstallPlan'; ResolverArguments = @{ Architecture = 'Arm64'; WindowsBuild = 26100 }; Expected = @{ Method = 'NvidiaInstaller'; ToolkitVersion = '13.4' }
            ProbePath = 'src/Workloads/cuda/smoke.cu'; ReportEvidence = 'pinned installer hash/signature, ARM64 compiler, nvcc, qualified NVIDIA driver/device, executed kernel'
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
            Status = 'implemented-supported'; Maturity = 'qualified-interim-nightly'; Acquisition = @('component:NvidiaPyTorchArm64', 'winget:Python.Python.3.13')
            Prerequisites = 'CPython 3.13 and an NVIDIA RTX Spark-class GPU with compute capability 12.x; runtime compatibility is proven by tensor execution'
            Resolver = 'Resolve-PyTorchPlan'; ResolverArguments = @{ Architecture = 'Arm64'; Backend = 'CUDA'; PythonVersion = '3.13'; HasNvidia = $true; DriverMajor = 0; ComputeCapability = '12.1'; GpuName = 'NVIDIA RTX Spark' }; Expected = @{ Backend = 'CUDA'; Runtime = 'cu134' }
            ProbePath = 'src/Workloads/pytorch/smoke.py'; ReportEvidence = 'pinned wheel hash, qualified Windows ARM64 NVIDIA device, torch CUDA 13.4 tensor'
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
            Status = 'implemented-supported'; Maturity = 'community-stable-on-qualified-interim'; Acquisition = @('component:NvidiaPyTorchArm64', 'component:TritonWindows')
            Prerequisites = 'Qualified ARM64 PyTorch CUDA preview, MSVC ARM64, CUDA 13.4'
            Resolver = 'Resolve-PyTorchPlan'; ResolverArguments = @{ Architecture = 'Arm64'; Backend = 'CUDA'; PythonVersion = '3.13'; HasNvidia = $true; DriverMajor = 0; ComputeCapability = '12.1'; GpuName = 'NVIDIA RTX Spark' }; Expected = @{ InstallTriton = $true }
            ProbePath = 'src/Workloads/pytorch/triton-smoke.py'; ReportEvidence = 'triton-windows version and Windows ARM64 NVIDIA vector-add JIT kernel'
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
            Prerequisites = 'NVIDIA RTX Spark-class GPU with compute capability 12.x; runtime compatibility is proven by benchmark and inference'
            Resolver = 'Resolve-LlamaCppInstallPlan'; ResolverArguments = @{ Architecture = 'Arm64'; Backend = 'CUDA'; HasNvidia = $true; DriverVersion = '0.0'; ComputeCapability = '12.1'; NvidiaGpuName = 'NVIDIA RTX Spark' }; Expected = @{ Backend = 'CUDA'; Runtime = 'CUDA 13.4 Developer Preview' }
            ProbePath = 'src/tests/llama.cpp/probe.ps1'; ReportEvidence = 'paired app/cudart tag/digests, qualified Windows ARM64 NVIDIA device, CUDA backend, GPU layers, inference'
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
            Status = 'source-managed'; Maturity = 'qualified-preview'; Acquisition = @('component:FoundryLocal')
            Prerequisites = 'Windows 11 build 26100+'
            Resolver = 'Resolve-FoundryInstallPlan'; ResolverArguments = @{ Architecture = 'X64'; WindowsBuild = 26100 }; Expected = @{ PackageId = 'Microsoft.FoundryLocal'; RequiresCuda = $false }
            ProbePath = 'src/Workloads/foundry/install.ps1'; ReportEvidence = 'resolved package variant, model inference, actual execution provider/device, truthful CPU fallback'
            PartnerCommand = '.\src\Workloads\foundry\install.ps1 -ReportPath "$env:TEMP\foundry-x64-report.json"'
        }
        @{
            Id = 'foundry-source-managed-arm64'
            Workload = 'foundry'; Architecture = 'Arm64'; Vendor = 'Source-managed'; DeviceFamily = 'WinML provider selected by Foundry'; Backend = 'WinML'
            Status = 'source-managed'; Maturity = 'qualified-preview'; Acquisition = @('component:FoundryLocal')
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
            Status = 'implemented-supported'; Maturity = 'stable'; Acquisition = @('winget:Ollama.Ollama')
            Prerequisites = 'Windows ARM64'
            Resolver = 'Resolve-OllamaInstallPlan'; ResolverArguments = @{ Architecture = 'Arm64' }; Expected = @{ Method = 'WinGet'; PackageId = 'Ollama.Ollama'; LaunchMode = 'InstalledApplication' }
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

# SIG # Begin signature block
# MIInNwYJKoZIhvcNAQcCoIInKDCCJyQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB+ovywHXVDBv/e
# Xmg6LWX5MmLr2HEaYmdXTE+jsj2WM6CCDMkwggYEMIID7KADAgECAhMzAAACHPrN
# xZvoL37EAAAAAAIcMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQxWhcNMjcwNDE1MTg1
# OTQxWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDVsZfgOKmM31HPfoWOoNEiw0SlCiIxUMC0I9NMWbucKOw/e9lP
# oAoehQVu6SG65V4EPzrYsnBnFPNoi4/HoOdjhz1qkrEt4I6tEcxXU6oOeY9zGveC
# /3iBeuhLYxM3M/PkcUoebF+Nednm8OkdSPoDu8imViHPQq/8CQUu0WRR4rE+dMRf
# rpVqfmNi2qWCX94T4MsepijGVkwE//tJg0ryAiYdHT34LSnlG/RSBZmQRGWZ5g8j
# qnKjRParSqMft1gvjuUTVgtWNZfgcLFSK5Wa0myrq8OPcgTGGsRgun+tnSS+IxDT
# xVsAPH1OzvPjwomguByhUe/OcvUN0D5Wmp7xAgMBAAGjggGqMIIBpjAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFNoH7a2YDjOSwpkp6DHcmUS7J+0yMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUT
# DTIzMDAxMis1MDc1NjkwHwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEw
# YAYDVR0fBFkwVzBVoFOgUYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# bDBtBggrBgEFBQcBAQRhMF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmcl
# MjBQQ0ElMjAyMDI0LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAUnEqhaRXe0T3hIJjvdQErEkrA/7bByjn6t5IArODkkRjzkYwtKMc2yYj2quaN
# rLutWw2YZcngKPy1b71YyDJQTy4NDRwaSh9Tw5thrk3NmcPrAHia5vtcBJ1CgtKK
# 7mQbIcQ22d/N3813ayCDDFewu1+jsZmX+r/aTEqaOM4TVxVtRSkuCy8nAXKuChOK
# Li/zA4XuH8iEYqIsj2YoNaeSxVmeGiERXpKdo3dDmYi0kO5w2D8VS4c3+9h6gElY
# BaAAg/dYErBg27qT3vv0zRDJhJufvCNylA8S7/+8H5E/PV5cng6na9VV/w9OV3qu
# uND6zdGa2EX38Glp50F9AIQk3p2xXmcvorDeM4XJ7UlWYBi6g80J1SSOQnInCYFE
# msfUNn3+1AaTJKSJL83quKArTac2pKhu0Yzzzrzo6HrsRiQKzpnRBb1/dMa6P3hz
# 75XbMRBctNsFhZC07WCmjExdLg2eHW5uV0TY8D5+6wozJf7vF3+WHkYPO85Z+BC6
# U4FkNbYNycZ9cE4j1tXRdyDCfml6c0HWPHjNVDObrv9lKt3qUqFpX38VCqVCyNOO
# 1UcXfQiVjJw32U2WUKZjt/neJKHEBsm9kFsLuWzkQ53+qcaSaytmsCnk2gOglrlD
# 5d3kKyvvAw+rzm0lT8K38P6PLxfZQHhu4W8dV7Av8N2ZmDCCBr0wggSloAMCAQIC
# EzMAAAA5O7Y3Gb8GHWcAAAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoX
# DTM2MDMyMjIyMTMwNFowVzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeq
# lRYHNa265v4IY9fH8TKhemHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo
# 0dtS/EW6I/yEL/bLSY8hKpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATv
# QVL4tcf03aTycsz8QeCdM0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a
# 1uv1zerOYMnsneRRwCbpyW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1
# FyQfK0fVkaya8SmVHQ/tOf23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfO
# GSWHIIV4YrTJTT6PNty5REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7
# ttOu1bVnXfHaqPYl2rPs20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJ
# uz2MXMCt7iw7lFPG9LXKGjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxS
# CwyoGIq0PhaA7Y+VPct5pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOm
# VQop36wUVUYklUy++vDWeEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3
# SkE/xIkgpfl22MM1itkZ35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPX
# LQaUEggxMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAw
# TgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOC
# AgEAFJQfOChP7onn6fLIMKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D
# 5W4wMwYeLystcEqfkjz4NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBY
# nbu0+THSuVHTe0VTTPVhily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSI
# vgn0JksVBVMYVI5QFu/qhnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6
# aR9y34aiM1qmxaxBi6OUnyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4w
# PKC5OmHm1DQIt/MNokbbH3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7
# RTX8AdBPo0I6OEojf39zuFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK
# /fg8B2qjW88MT/WF5V5uvZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSK
# YBv0VisCzfxgeU+dquXW9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkw
# YTu/9dLeH2pDqeJZAABVDWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVT
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEIKFDjCXVmZ+2LkoaLdk0gESdWsr5
# 2GkdrEuAvidGbQ67MEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAeqY3CtrXOppRmq8cM35YLdeSI9Svi0q2HPmndQftNYJXeDnJEQGOMWIjue0q
# 4gehxL7krf+H2JEsZDuSA4flmwLk65JJm1DWyVbZ7OJnkECwteP5D2kiq0o8+5rL
# x8ZaW7u1YY7PVsaRRWT2dDbc7ifV/o6NbeIsG0yjH62t/xbEUmtcuJyk+89xZq+m
# AonKT1Yrdc3xH9KInkpCKoVlB6/h9Gfv2Lk3IMYzLNuo+23mA/VU8FSn6PbqUM4i
# 1pBMghTdE1ME/QJiP0lf6oGE02Ryaj+gGDJK5PBlHLs++A76Y8oZFDu3FIyJwNN2
# ZVd3+w5d5VR4MlwG9DtrT8nyX6GCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wG
# CSqGSIb3DQEHAqCCF20wghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG
# 9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAI01a8XHbDf97V6Dva9Mtv0qR5Kgp8QTcA4k9qq9GOMAIGaqk4vt4tGBMy
# MDI2MTAwOTAwMTc0Mi4xMDVaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmlj
# YSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUw
# LUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHq
# MIIHIDCCBQigAwIBAgITMwAAAijwpYfX88geQAABAAACKDANBgkqhkiG9w0BAQsF
# ADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTQwMDZa
# Fw0yNzA1MTcxOTQwMDZaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTQwMC0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUA
# A4ICDwAwggIKAoICAQCujvbk/sqcCSReZaJfCuf1NwRcc7XknhE6wkLofkNj1mxE
# Ag35qy2xcFjgjartVvA09W8QHcpyMqVSXOTxNHJsmk0qP2CDLvUAulWg7aS5oBOR
# pEX1oz3n0R2nPqeH0IHK1zJxjxaHW21AbuZ0Z+wM3WYNzkBlcHmVe03ZG7rlk28h
# 72r5P5ME8FGpFmYW5Hl7psKbgLEfrYAitpttsb+sZsBUI+hMKl4uLJYotKyZv1ew
# OIinBfRU8QosivjofaBezUf9NdV+iGrWh321WnSsK3A/Jl6GLtbSWXcJWULgbxuq
# nobPK+YlB3174TMWTgX4YWjG7o0Otz/pjHNCKBbB788dynhLdGY6B08E9+4SGrRp
# sty4iJHOydHCA5M4i5yYRwsdut+gmvxIpT8yNXJcjJCg0vO8mv/nFY9Wytv2qmCt
# CFFivGUWqU20/sUeRooQZGiQOJQn095Cj3isIsvRP8KU7hN/EDI8HVsb/NPzMFLv
# RznrRnj0TOnDiOTUcnYwmk+XfoS1owskcCCCwHnbC00D58z83y7K5ZJB745hcn4C
# E2nR3e6RGsr42y5qtt6Mdz/s7MTnDS2UmVHWX1X/HZe3UlX8gj/t63L50xIPqkRC
# BEdM1ADNUaSfo9OQiKb/bj1diZCGTfEDUBBLop1mhkwIF82faplV2busZ+U4kQID
# AQABo4IBSTCCAUUwHQYDVR0OBBYEFKrJpYz48tzouvVkBVthASFpQ93DMB8GA1Ud
# IwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRp
# bWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYI
# KwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1Ud
# EwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeA
# MA0GCSqGSIb3DQEBCwUAA4ICAQCQ6NfLmrRahgVtgWg383GaS07fHyod6bhcUONt
# 2tet+6BaNuH0r7ABkVHheOpxBdrUrOEYVEaIii9dK3cuZLNmp1iUAx/VbmOZYl7x
# z+tNrjCWqrg1jQmq0oRB8iE4QJpwNhGP67oY5huYIU0D4lhDoahqfgKJn/0Bk+9U
# KDPw5XlUYmreFmJlj9YQzcPPep8MxBXxh/Y5I7vQeRaW5SjtiLQOLRk3ggvraDs5
# Sf49MJV6/BwxXC2rvUfEFX6SUDooqKIE9NgVIRq0RZu7Ot0i0Is+HvPP0hB6KwOx
# Mg1SWKOfTtFpWpdo8MJvgKCHkPpXEzgprP+pyIHuO7gVRlSTsbYBFLh2yId/itM4
# uYL0R+2SSBBTpSSRthrGuEmElI5BCHMxzMg/oqHSPwZAIAkM2C4xxi0St7qMuA+m
# +ZzFYkfoF41QoSJn+HjqhqWYQ0m/SO9/KnJRJJUwMd5TiMnjZ+E/DJiUry5udiWy
# Qpvfj2hQFI0djhahoAXDazeEciLF2uEnTur9UfjcwOun/oMY+ULftnOi2jKLMrre
# V097akzz/JxpnDgYJU/tgU7fQflg7IqiL9+0276+joQHo21mVeY5YD8Kh/kUaY6J
# m/OTM88G7evTz/qnRumxovTjMStvpbAHNRhmSTdIPTV32CyuxDKS/V5a5iwA+f9V
# iBo+wjCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcN
# AQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAw
# BgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEw
# MB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk
# 4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9c
# T8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWG
# UNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6Gnsz
# rYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2
# LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLV
# wIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTd
# EonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0
# gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFph
# AXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJ
# YfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXb
# GjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJ
# KwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnP
# EP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMw
# UQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggr
# BgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYw
# DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoY
# xDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtp
# L2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYB
# BQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0B
# AQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U5
# 18JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgAD
# sAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo
# 32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZ
# iefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZK
# PmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RI
# LLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgk
# ujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9
# af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzba
# ukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/
# OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIIC
# NQIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0
# b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOkE0MDAtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQB1rbmF
# kzS7qAK1Oav08AUnhbNIUqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA7nKuzzAiGA8yMDI2MTAwOTAwMDc0M1oY
# DzIwMjYxMDEwMDAwNzQzWjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDucq7PAgEA
# MAcCAQACAgsMMAcCAQACAhQcMAoCBQDudABPAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAB+KoPZx1P82QS66mTTm/ngumgJATaB26jqzMviOQLwnH2WgoCHP
# aw0nAHVACY7SMzgxLEqCenrBiebzLVs0fg8+xwnwjcrJmEAyXRJyqu+0+Zef+rcE
# +7AbBVLoa7KH1E+2XCRuPxorQ2a3SHG4L64yFh4LcCKvmcsDb7cGdUXZKfp9jxnU
# LDf6H9VHoKDTye+BYm7icCXYtOEX5YLFDN08DSsFy8xuoXrjuyM4vNbGtQ+q5j31
# gHeIPimsQp9mzlQBIZbYOiYjN2Nzwv72usCxkbuSH76ovjgwn620UACJwn4/xufY
# ZiGohlvUQc1qyn8Hj8OaxHNsqo+2V5TdFm4xggQNMIIECQIBATCBkzB8MQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3Nv
# ZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAijwpYfX88geQAABAAACKDANBglg
# hkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqG
# SIb3DQEJBDEiBCA1z7hNejYXc4bZT+haWi+67Qs/4bZZ4hMSntX4BC2uXzCB+gYL
# KoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIFWxikZRYGNf4oEVZK1eT45H+3GQ3/qx
# V75VwuBt+iLXMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAAIo8KWH1/PIHkAAAQAAAigwIgQghef/+fMEtvDCDwHcD9od3pRlQmfSrDvO
# KmAllfDV7rswDQYJKoZIhvcNAQELBQAEggIAFbeatnlWAbz+udyBq8aN9/q3gmX7
# 3cQArwr6qxCCPVKhf/0hDLMvTH7InKOpynrTyZAwdbz44KAM5CmEVhtdZybHKUQo
# 40W0KSVKRzTH9u1H2RCF8ieNm+IHiLhxTovBJXxZYBg6LtAzUM7KOvtCiKJ1+9UT
# tKsL1heOvlVtlbo92RBJkfKHDw4rI0/OhuItpyIM4JELZ8tV0tbhx3T1HpCeAYZF
# 5/S8tsKHuxDQAdQQfoAWUTMbPglkr+/O2A8LQdi8P9bFJW/NzqyP9XzL3puF/28A
# 40abNmT90nUsjzNctWp0CYdNrgSDHeVb97FpdeWjjj00hjKakepYeUuOq2F2KDRx
# kgzNtU5TElQHipwWEOXN+XUhWbmkAdEcmp+U9rqQAaYD1yFM9q+Rg7JQ9b9c6Gs2
# gNQrYeIp1sdRcveObh/V82YvcAv9/TtuTSGVZfwlWQAcp2Gc1wWxb972/wG8us8U
# H65JG5EtMNHbDhzrk/77TC4TelO9sAbDwnAhFs4/o+EBLo813G/+Ln1rv+zqpzs/
# EUypIRVW7yzXho9rhiuwvLIycaqS1iGBtaRzh6Cqh42Em1kH2mE7BYUUyxkA6nQm
# 6dXB4rfObs1C1GASJ14+4nDgWzYpl4kQjwcjf+L2g5WmuTI+52djL11Er31bRCpr
# lmTGgFzmakGC3hQ=
# SIG # End signature block
