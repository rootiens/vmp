#!/usr/bin/env bash
set -euo pipefail

ROOT_DEP="${1:-}"
JOB_SLOTS="${2:-4}"

VSWHERE="code/tools/ci/vswhere.exe"
if [[ ! -f "$VSWHERE" ]]; then
	echo "::error::vswhere not found at $VSWHERE"
	exit 1
fi

VS_PATH="$("$VSWHERE" -latest -prerelease -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | tr -d '\r')"
MSBUILD="${VS_PATH}/MSBuild/Current/Bin/MSBuild.exe"
if [[ ! -f "$MSBUILD" ]]; then
	echo "::error::MSBuild not found at $MSBUILD"
	exit 1
fi

echo "Using MSBuild: $MSBUILD"

export GYP_MSVS_VERSION=2022
export npm_config_msvs_version=2022

# Prefer CPython from setup-python / py launcher — not MSYS/MinGW python.
PYTHON_BIN=""
if command -v py >/dev/null 2>&1; then
	PYTHON_BIN="$(py -3.11 -c "import sys; print(sys.executable)" 2>/dev/null || true)"
fi
if [[ -z "$PYTHON_BIN" ]] && command -v python >/dev/null 2>&1; then
	PYTHON_BIN="$(command -v python)"
fi
if [[ -n "$PYTHON_BIN" ]]; then
	export npm_config_python="$PYTHON_BIN"
	"$PYTHON_BIN" -m pip install --upgrade setuptools wheel >/dev/null
	echo "node-gyp python: $PYTHON_BIN"
fi

pwsh ./fxd.ps1 get-chrome

# Run prebuild under a VS developer environment so node-gyp can compile ffi-napi.
VCVARS="${VS_PATH}\\VC\\Auxiliary\\Build\\vcvars64.bat"
cmd.exe /c "call \"${VCVARS}\" && prebuild.cmd"

pwsh ./fxd.ps1 gen -game "$PROGRAM"

BUILD_DIR="code/build/${PROGRAM}"
if [[ "$PROGRAM" == "server" ]]; then
	BUILD_DIR="${BUILD_DIR}/windows"
fi

if [[ ! -f "${BUILD_DIR}/CitizenMP.sln" ]]; then
	echo "::error::Premake did not generate ${BUILD_DIR}/CitizenMP.sln"
	exit 1
fi

cd "$BUILD_DIR"

"$MSBUILD" CitizenMP.sln -t:build -restore -p:RestorePackagesConfig=true -p:preferredtoolarchitecture=x64 -p:configuration=release -maxcpucount:"$JOB_SLOTS" -v:q -fl1 "-flp1:logfile=errors.log;errorsonly"
MSBUILD_ERROR=$?

if [[ $MSBUILD_ERROR -eq 0 ]]; then
	echo "Successfully build $PROGRAM"
else
	RED=$'\e[31m'
	echo "::error::Failed to build $PROGRAM, MSBuild returned with error code: $MSBUILD_ERROR"
	if [[ -f errors.log ]]; then
		while IFS= read -r LINE; do echo "$RED$LINE"; done < errors.log
	fi
	exit "$MSBUILD_ERROR"
fi
