#!/usr/bin/env bash
# Fast static checks before a 30–60min Windows compile. Works without ripgrep (GHA Windows).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

fail=0

has() {
	git grep -q -- "$1" -- "${@:2}"
}

check_decl() {
	local sym="$1"
	shift
	local decl_files=("$@")
	if has "$sym" code; then
		local found=0
		for f in "${decl_files[@]}"; do
			if [[ -f "$f" ]] && grep -q "$sym" "$f"; then
				found=1
				break
			fi
		done
		if [[ "$found" -eq 0 ]]; then
			echo "::error::${sym} used but missing from ${decl_files[*]}"
			fail=1
		else
			echo "ok  ${sym}"
		fi
	fi
}

check_decl GetApiIdentifier code/components/ros-patches-five/include/LegitimacyAPI.h
check_decl GetEntitlementSource code/components/ros-patches-five/include/LegitimacyAPI.h
check_decl SyncCriticalTrace code/client/shared/Utils.h
check_decl FlushCrashLog code/client/shared/Utils.h

for sym in GetApiIdentifier GetEntitlementSource; do
	if has "ros::${sym}" code; then
		if ! has "$sym" code/components/ros-patches-five; then
			echo "::error::ros::${sym} called but not defined under ros-patches-five"
			fail=1
		fi
	fi
done

if has 'directory_iterator{ logsPath, ec }' code/client/launcher/Console.Logging.cpp; then
	if ! has 'filesystem::path logsPath' code/client/launcher/Console.Logging.cpp; then
		echo "::error::Console.Logging.cpp: wrap MakeRelativeCitPath in std::filesystem::path before exists/iterator+ec"
		fail=1
	fi
fi

if [[ "$fail" -ne 0 ]]; then
	echo "preflight FAILED"
	exit 1
fi

echo "preflight OK"
