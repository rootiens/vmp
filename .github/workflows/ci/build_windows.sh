#!/usr/bin/env bash
set -euo pipefail

ROOT_DEP="${1:-}"
JOB_SLOTS="${2:-4}"

VSWHERE="code/tools/ci/vswhere.exe"
if [[ ! -f "$VSWHERE" ]]; then
	echo "::error::vswhere not found at $VSWHERE"
	exit 1
fi

VS_PATH=""
for candidate in \
	"/c/Program Files/Microsoft Visual Studio/2022/Enterprise" \
	"/c/Program Files/Microsoft Visual Studio/2022/Professional" \
	"/c/Program Files/Microsoft Visual Studio/2022/Community"
do
	if [[ -f "${candidate}/MSBuild/Current/Bin/MSBuild.exe" ]]; then
		VS_PATH="$candidate"
		break
	fi
done

if [[ -z "$VS_PATH" ]]; then
	VS_PATH="$("$VSWHERE" -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | tr -d '\r' | head -n1)"
fi

if [[ -z "$VS_PATH" ]]; then
	echo "::error::VS 2022 not found (VS 18+/2026 unsupported for this tree)"
	exit 1
fi

# Normalize to Windows path for cmd/MSBuild
VS_PATH_WIN="$(cygpath -w "$VS_PATH" 2>/dev/null || echo "$VS_PATH" | sed 's|^/c/|C:/|;s|/|\\|g')"
MSBUILD="${VS_PATH}/MSBuild/Current/Bin/MSBuild.exe"
if [[ ! -f "$MSBUILD" ]]; then
	echo "::error::MSBuild not found at $MSBUILD"
	exit 1
fi

echo "Using MSBuild: $MSBUILD"

WIN_SDK="10.0.22000.0"
SDK_INCLUDE="/c/Program Files (x86)/Windows Kits/10/Include"
if [[ ! -d "${SDK_INCLUDE}/${WIN_SDK}" ]]; then
	if [[ -d "${SDK_INCLUDE}/10.0.26100.0" ]]; then
		WIN_SDK="10.0.26100.0"
	elif [[ -d "${SDK_INCLUDE}/10.0.22621.0" ]]; then
		WIN_SDK="10.0.22621.0"
	elif [[ -d "$SDK_INCLUDE" ]]; then
		WIN_SDK="$(ls -1 "$SDK_INCLUDE" | sort -V | tail -n1)"
	fi
fi
echo "Using Windows SDK: $WIN_SDK"

export GYP_MSVS_VERSION=2022
export npm_config_msvs_version=2022

PYTHON_BIN=""
if command -v py >/dev/null 2>&1; then
	PYTHON_BIN="$(py -3.11 -c "import sys; print(sys.executable)" 2>/dev/null || true)"
fi
if [[ -z "$PYTHON_BIN" ]] && command -v python >/dev/null 2>&1; then
	PYTHON_BIN="$(command -v python)"
fi
if [[ -z "$PYTHON_BIN" ]]; then
	echo "::error::Python 3 not found"
	exit 1
fi
export npm_config_python="$PYTHON_BIN"
"$PYTHON_BIN" -m pip install --upgrade setuptools wheel six jinja2 markupsafe ply >/dev/null
echo "python: $PYTHON_BIN"

# Ensure `py -3` works for mojo/udis86 prebuild hooks (they hardcode it).
if ! py -3 -c "import sys; assert sys.version_info[0] == 3" >/dev/null 2>&1; then
	echo "::error::py -3 launcher required (mojo/udis86 scripts)"
	exit 1
fi

# Keep MSYS tools available for prebuild_natives.cmd (pacman/make/diff).
export PATH="$PATH:/c/msys64/usr/bin:/c/msys64/mingw64/bin"

pwsh ./fxd.ps1 get-chrome

VCVARS="${VS_PATH_WIN}\\VC\\Auxiliary\\Build\\vcvars64.bat"
echo "Running prebuild via $VCVARS"
cmd.exe /c "call \"${VCVARS}\" >nul && set \"PATH=%PATH%;C:\\msys64\\usr\\bin;C:\\msys64\\mingw64\\bin\" && prebuild.cmd"
echo "prebuild exit=$?"

if [[ ! -f vendor/udis86/libudis86/itab.c ]]; then
	echo "itab.c missing after prebuild — generating"
	(
		cd vendor/udis86
		py -3 scripts/ud_itab.py docs/x86/optable.xml ./libudis86/
	)
fi
if [[ ! -f vendor/udis86/libudis86/itab.c || ! -f vendor/udis86/libudis86/itab.h ]]; then
	echo "::error::udis86 itab.c/itab.h still missing"
	exit 1
fi

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

"$MSBUILD" CitizenMP.sln \
	-t:build \
	-restore \
	-p:RestorePackagesConfig=true \
	-p:preferredtoolarchitecture=x64 \
	-p:configuration=release \
	-p:WindowsTargetPlatformVersion="$WIN_SDK" \
	-maxcpucount:"$JOB_SLOTS" \
	-v:q \
	-fl1 \
	"-flp1:logfile=errors.log;errorsonly"
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
