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
# MIInKAYJKoZIhvcNAQcCoIInGTCCJxUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB+ovywHXVDBv/e
# Xmg6LWX5MmLr2HEaYmdXTE+jsj2WM6CCDLowggX1MIID3aADAgECAhMzAAACHU0Z
# yE7XD1dIAAAAAAIdMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQzWhcNMjcwNDE1MTg1
# OTQzWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDQvewXxx9gZZFC6Ys1WBay8BJ8kGA4JQnH5CMafqOASlTpK9H8
# o5ZXTXt0caVQTNMUPt445wXYD+dFtaKWTwDn1I52oUSrC9vJin1Gsqt+zyKJL5Dg
# 3eQXbQNR61DmMy20GLTIO3SFed9Rfi/ophgCLGFLDR3r0KvHjwMb/jYWS0celV/4
# Lz27LfAekm8v9E5IXaeiXbAUYZKK090n4CVl3JBtbN+9DtI9SNu/yjvozW52/u7R
# X/Ttpa/KDlpuokZ+Zcbvmtd9ur9gFLvZzh41o9MsE/clQtdaFWGvuo6Jua/ntpgk
# ey3E5/vBFe+MJPG6phdnuo6r57ZudCudiI1bAgMBAAGjggGbMIIBlzAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFH6QuMwqcPG0hQlQ6c5jCtTTLrVeMEUGA1UdEQQ+MDykOjA4MR4wHAYDVQQL
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xFjAUBgNVBAUTDTIzMDAxMis1MDc1NTkw
# HwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEwYAYDVR0fBFkwVzBVoFOg
# UYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNybDBtBggrBgEFBQcBAQRh
# MF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# Y2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# dDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBKTbYOjzwTG/DXGaz9
# s6+fQeaTtDcFmMY+5UyVFCyj7Pv+5i37qfX8lSL/tBIfYQfWsMuBQlfZurJD6r4H
# VJ2CeH+1fgiq8dcHdVKoZ3Sa2qXoX3cq9iS8cVb06B7+5/XJ7I0OxHH9fDsvJ3T3
# w5V/ZtAIFmLrl+P0CtG+92uzRsn0nTbdFjOkLMLWPLAU3THohKRlSEMgFJpPkm5n
# 5UAZ35xX6FWCrDLsSKb555bTifwa8mJBwdlof0bmfYidH+dxZ1FdDxvLnNl9zeKs
# A4kejaaIqqIPguhwAti5Ql7BlTNoJNwxCvBmqW2MQLnCkYN/VVUsR3V2x/rcTNzo
# Bf/Z/SpROvdaA2ZOOd1uioXJt3tdLQ7vHpqpib0KfWr/FWXW10q38VxfCnRQBqzb
# SuztR7nEMuzX7Ck+B/XaPDXd1qh72+QYyB0Z2VzWmO9zsnb9Uq/dwu8LGeQqnyu6
# 7SDGACvnXii2fb9+US492VTnXSnFKyqwgzUyFMtZK1/sHYTv6bG4TtQUygQxTN+Z
# V+aJIlKO2MqZ7bKrAnOzS9m6NgoTdWOq11bTOZwKlIEV/EhV9SWkDmdpR/hPPT2v
# 6TEj4F8PT/zHjRezIU5c/DGlt/VhY/pK0XkJtEyMmmS1BMtjU/rqBZVMIm3dnxQs
# /TBByr+Cf8Z1r7aifQVQ+WSqzjCCBr0wggSloAMCAQICEzMAAAA5O7Y3Gb8GHWcA
# AAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRl
# IEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoXDTM2MDMyMjIyMTMwNFow
# VzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEo
# MCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAyNDCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeqlRYHNa265v4IY9fH8TKh
# emHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo0dtS/EW6I/yEL/bLSY8h
# KpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATvQVL4tcf03aTycsz8QeCd
# M0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a1uv1zerOYMnsneRRwCbp
# yW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1FyQfK0fVkaya8SmVHQ/t
# Of23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfOGSWHIIV4YrTJTT6PNty5
# REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7ttOu1bVnXfHaqPYl2rPs
# 20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJuz2MXMCt7iw7lFPG9LXK
# Gjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxSCwyoGIq0PhaA7Y+VPct5
# pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOmVQop36wUVUYklUy++vDW
# eEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3SkE/xIkgpfl22MM1itkZ
# 35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGC
# NxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPXLQaUEggxMBkGCSsGAQQB
# gjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# ci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0
# dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAx
# MV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOCAgEAFJQfOChP7onn6fLI
# MKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D5W4wMwYeLystcEqfkjz4
# NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBYnbu0+THSuVHTe0VTTPVh
# ily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSIvgn0JksVBVMYVI5QFu/q
# hnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6aR9y34aiM1qmxaxBi6OU
# nyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4wPKC5OmHm1DQIt/MNokbb
# H3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7RTX8AdBPo0I6OEojf39z
# uFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK/fg8B2qjW88MT/WF5V5u
# vZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSKYBv0VisCzfxgeU+dquXW
# 9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkwYTu/9dLeH2pDqeJZAABV
# DWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVTQl0v4q8J/AUmQN5W4n10
# 1cY2L4A7GTQG1h32HHAvfQESWP0xghnEMIIZwAIBATBuMFcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jv
# c29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIdTRnITtcPV0gAAAAAAh0w
# DQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIKFDjCXVmZ+2LkoaLdk0gESdWsr52GkdrEuAvidGbQ67MEIG
# CisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBvAGYAdKEagBhodHRwOi8v
# d3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAEggEAnnnHrRjLor2DeqQ9
# rmRuP1hMERzElFB9X77gU58+CPE9sVfmb5E+JY0E8aWFoX7aqV3lQjeZIKXUS00J
# jYriIRCtcW+sUViGAq/h+eCQquLePF9+TDQIYvlka20ZpFrwYgUJvsQ7qT6cazR+
# Dxzo5I7Le+Lv/4BMeUWtBTgP29rtQo8A8eEwWAnNFTIEJerpiAyBgTd4grmX2aJR
# 1leso9Uvi3qNUMa8Fd58ed2FM2Pxmh2gJVcCEMj5lJ7LGP21mouDXx331RWrQpxr
# NM4ORBWQtKDkcT0OipzQ6nObW1M4TD0qwsxKouY9K28SwDHOa9hzhk0KqLAa9UUM
# F+W6ZqGCF5QwgheQBgorBgEEAYI3AwMBMYIXgDCCF3wGCSqGSIb3DQEHAqCCF20w
# ghdpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsqhkiG9w0BCRABBKCCAUEEggE9
# MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAM1MeAY2OoJ8gl
# 5LUlPmUCkWSBQK4ceGZkn5jpxlVrbgIGaqqLqxXjGBMyMDI2MTAwODAzMDMyNC41
# NTVaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScw
# JQYDVQQLEx5uU2hpZWxkIFRTUyBFU046RjAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMT
# HE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2WgghHqMIIHIDCCBQigAwIBAgIT
# MwAAAiAk4ebgF7m0jgABAAACIDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGlt
# ZS1TdGFtcCBQQ0EgMjAxMDAeFw0yNjAyMTkxOTM5NTJaFw0yNzA1MTcxOTM5NTJa
# MIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046RjAwMi0wNUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1l
# LVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDR
# YY7yr7ijW6CR178uKveIMufutWOicxgJwKOce/2GOQceus6ZWfX14i3jNg3JOP7M
# GJMkOAucwWBwiA8URp+ZYkGjpVoVkGZsV27WjqLwpf2AwqBsJ/TzqwE7JFFaxup3
# Ldxj8GjdJymDFRrdVN/pYHoBFrjD1IkIDu8b1CWn8tgomiKRSY+STvJq99mVkdph
# MBIUGOegQny8qRd24VME0xi8Oomks9Zq9EjDeKHGpvAbXUEQ6m3cROoEPhTE/miw
# eQH9TqJt3IOsqPv3L8urojB747XBC2y0CDIHlKLcLl3ZG8D7JXKnWTFen3msMPJp
# cvrQ3zUBVJrH/mI3RxHmCh9ppDP0uG1+PJwk6H/x+sfoG9hW64xoXkpx6DEfNZNf
# cXdKbXF28XEXdLNnzo3SLNVymeQJhNqOSKhnU84QnKmrjEk541JiurlDCkCWO9lU
# BUMb9x0nyfXUbNRPVLgP+PTMRdXOowJdYCzCQfN2ZqL0s4YI28F1Dbn7Bgw2E4P1
# E9unsvMzJHtzhS2Th3TpCfBbOGalIlF9x/DJZ/ssm/yyzT9YtIFeqmfNxBPTE3aO
# uh6HxmTICzfYAATvWNhBbo19QwsjPeA9JvhqTLC2KUNgrXroGy4eDZo0n7jFYjZk
# Uih1Ty+8E6qEvV2Na6Z5gUyD5a+tHGDmq69CmUiHfwIDAQABo4IBSTCCAUUwHQYD
# VR0OBBYEFNvInOCIhxGA8mY7l1g07UHvyNgzMB8GA1UdIwQYMBaAFJ+nFV0AXmJd
# g/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0El
# MjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4wXAYIKwYBBQUHMAKGUGh0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwVGlt
# ZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3DQEBCwUA
# A4ICAQCtKGBto1BSvm4WFI+J0NSyVhU1LHL7F3fbjZ2d7F5Kn/FCTBZXpzrDVl63
# FLRNcIFpnJy4/nlg43r7T5sJPdo4Ms8ADSHQEJnHSu3x9UpjCzREBPi9+nHhvDgR
# x/1WmBD6gQUZJLOhcN2TxW4KJyhinMtiBFtkNRZ2vmZ1MAdNXTm5d0Lwk3wzj+/f
# 7VCCTWCXJSoqNa3VU/6sACHI97Evbnzg8bd3hxrfz6CcCVuf77egvRHinthJuwSR
# ePP7aVmcevb1nWUIAICdBebHQOrzNIeWBIQwvcFaS3SFc+49rqrwQOMFDR4FYBzS
# 7b0QeBVxFuLL2iVu4KAHMNUhLLSD4iKLDFBNTOtTzTlhGvMgG77A1cjeQrDMHa6o
# ReMDeUDqHUrxv8g7IRdIh+h0gDLkzN0xIuzli0Bv7JtybGJbV6JxaDF4CzSCIMRp
# K59nI6iKo4LgnbQBZJW7+6akYsKG/pXPlfxNv2InpD10tSCkCvw9kr6W1+NRN+Eu
# ZczRgAwWlcK9XJZ3uu/v/oxHtO7/kmVIs51F9qV6Y2QNXd6tU46YPrK98m2QDys+
# lvLNimK0e1xZ7Z1GawKohKGvlLALWDlZQqgHfJ31CB0LlIDI7iLyYTpd2iyKjqsk
# bQiyMtICH+RmH/oCg7JOK0ZA3XIMba9aSWgBF3QZ6pG3EGeQqjCCB3EwggVZoAMC
# AQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29m
# dCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4XDTIxMDkzMDE4MjIy
# NVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDk4aZM57RyIQt5osvXJHm9
# DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25PhdgM/9cT8dm95VTcVrifkpa/rg2
# Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPFdvWGUNzBRMhxXFExN6AKOG6N
# 7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6GnszrYBbfowQHJ1S/rboYiXc
# ag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBpDco2LXCOMcg1KL3jtIckw+DJ
# j361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50ZuyjLVwIYwXE8s4mKyzbnijYjk
# lqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3EXzTdEonW/aUgfX782Z5F37Zy
# L9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0lBw0gg/wEPK3Rxjtp+iZfD9M
# 269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1qGFphAXPKZ6Je1yh2AuIzGHLX
# pyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ+QuJYfM2BjUYhEfb3BvR/bLU
# HMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PAPBXbGjfHCBUYP3irRbb1Hode
# 2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkwEgYJKwYBBAGCNxUBBAUCAwEA
# ATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxGNSnPEP8vBO4wHQYDVR0OBBYE
# FJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARVMFMwUQYMKwYBBAGCN0yDfQEB
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEE
# AYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB
# /zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvXzpoYxDBWBgNVHR8ETzBNMEug
# SaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9N
# aWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsG
# AQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jv
# b0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG9w0BAQsFAAOCAgEAnVV9/Cqt
# 4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0xM7U518JxNj/aZGx80HU5bbsP
# MeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmCVgADsAW+iehp4LoJ7nvfam++
# Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449xvNo32X2pFaq95W2KFUn0CS9
# QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wMnosZiefwC2qBwoEZQhlSdYo2
# wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDSPeZKPmY7T7uG+jIa2Zb0j/aR
# AfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2dY3RILLFORy3BFARxv2T5JL5z
# bcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxnGSgkujhLmm77IVRrakURR6nx
# t67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+CrvsQWY9af3LwUFJfn6Tvsv4O+S3
# Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokLjzbaukz5m/8K6TT4JDVnK+AN
# uOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL6Xu/OHBE0ZDxyKs6ijoIYn/Z
# cGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNNMIICNQIBATCB+aGB0aSBzjCB
# yzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMc
# TWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBU
# U1MgRVNOOkYwMDItMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1T
# dGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCTGA9vpsJ6glqCLmI0rggGx4YE
# EqCBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMA0GCSqGSIb3
# DQEBCwUAAgUA7nFe3TAiGA8yMDI2MTAwODAwMTQyMVoYDzIwMjYxMDA5MDAxNDIx
# WjB0MDoGCisGAQQBhFkKBAExLDAqMAoCBQDucV7dAgEAMAcCAQACAieaMAcCAQAC
# AhLSMAoCBQDucrBdAgEAMDYGCisGAQQBhFkKBAIxKDAmMAwGCisGAQQBhFkKAwKg
# CjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcNAQELBQADggEBACjR5v0c
# VZOdGMAnoV+FrHADvduIbOwCumafzcWj+RzPzjfSlbqiJ+bMY41PUlCjT/UXwpQp
# ouj679MndtzyY/Q5LolWriUk/HdzWtClIoEbbiE0ppySeqiuMJ1kM79B1GagtAH3
# VLASQrcN9s6Q9+LiQNvlgj2jvDMb9UK/eG9/3FtUk7lUQB/jPo1CKxkZvefnuQc1
# weRvdgbH+0ZWZ+wNxl/6+bwefZxOzLrx09mMCXTNAP2ynQO8mim5TEYTksmZMrR6
# 292kPB6njghMi5mP/9njb+HyTTmtJMA6vIwbA0tpgV1VpiHCIcb7ZvQ+dRPfrf1v
# AY5CVX1pMUa16/UxggQNMIIECQIBATCBkzB8MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQ
# Q0EgMjAxMAITMwAAAiAk4ebgF7m0jgABAAACIDANBglghkgBZQMEAgEFAKCCAUow
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMC8GCSqGSIb3DQEJBDEiBCBacHxM
# c68NSKP1eFIdNMX49PSJ8rBO63bMKK9RDYOlGTCB+gYLKoZIhvcNAQkQAi8xgeow
# gecwgeQwgb0EION7vyOlPA1VqlEp0QIVGlNd8S5YWBnKj97LuTWHSO2vMIGYMIGA
# pH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UE
# AxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIgJOHm4Be5tI4A
# AQAAAiAwIgQg/55tbzekP78zJ9GMptedn3fejrcos7sHzJANkoc8Sc8wDQYJKoZI
# hvcNAQELBQAEggIANov8QWBmqhq+t5ZfEYSmjYmbgb8qzTujpsvfyKSa44azsWBw
# LGA4Qre82gdWXC7LnhBPIstue09sXagiI2uL7m0+ZCUtvhUD1GTndaGosyCkRwpP
# l8nDagL01q9BJRfugdi3IoF6ye2g6SvxuhbLyMXkPTACeLFaGCosnNKx9vO8986e
# SvfSgy6OpoBVxhvXQQoOQdWTEZxAB4YKW9pJ+Dbvqj3PvWx7rhnIeceqGk7iWdOY
# D3mY3M0WoNVA6yMQvE2wu3kQSgH5fPQdV/+WxayPESGqLmhcSZMuRyYz69UvUdvB
# ej8Tt1SWdOt1cKxoekEFOpDkxCiFJdzOcQ0cmdbVCxnL0NzqdfGx7O3szPzjz0be
# ETeZgleHw19Rv41/h8WaGL1HglNR+A32HJBuWqDf+hz6JDpz0RqefsHlzX+F6sf0
# xPnZjsSMUJS0Nz2zshsjU1vrLjSfg5EkcePMp8T8Gm90DzQ6/dgy3yrPqKVaeRTd
# uDsv942/rJr+KH6q8BFgjfCmviQJR0ZoY3SUrDTqMxcmfA6K3PUHpwr07r/1v2Sc
# BS1UB2WPJM+uMTe9OyGEGOKvMOM0NoNwshlizXm+yonkjdArQBN6Fa3u/QLYwBDS
# czdXSX0UruPJvmVq64BXHqzLKWbeS0tJX7iaEMPMcQWWkfy7G/3vndi7fZI=
# SIG # End signature block
