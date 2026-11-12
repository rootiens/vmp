#!/usr/bin/env bash
# Fast static checks before a 30–60min Windows compile. Run locally on any OS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

fail=0

check_decl() {
	local sym="$1"
	local decl_glob="$2"
	if rg -q --glob '*.cpp' --glob '*.h' --glob '*.hpp' "\\b${sym}\\b" code; then
		if ! rg -q --glob "$decl_glob" "\\b${sym}\\b" code; then
			echo "::error::${sym} used but no declaration under ${decl_glob}"
			fail=1
		else
			echo "ok  ${sym}"
		fi
	fi
}

# Symbols that have burned CI time before.
check_decl 'GetApiIdentifier' '**/LegitimacyAPI.h'
check_decl 'GetEntitlementSource' '**/LegitimacyAPI.h'
check_decl 'SyncCriticalTrace' '**/Utils.h'
check_decl 'FlushCrashLog' '**/Utils.h'

# Call sites must have a matching definition somewhere (export or body).
for sym in GetApiIdentifier GetEntitlementSource; do
	if rg -q --glob '*.cpp' "ros::${sym}\\s*\\(" code; then
		if ! rg -q --glob '*.cpp' --glob '*.h' "${sym}\\s*\\(" code/components/ros-patches-five; then
			echo "::error::ros::${sym} called but not defined under ros-patches-five"
			fail=1
		fi
	fi
done

# Two-arg filesystem APIs reject fwPlatformString on newer MSVC — require path{}.
if rg -n 'filesystem::(exists|directory_iterator)\s*(\{\s*)?[A-Za-z_][A-Za-z0-9_]*\s*,\s*ec' code/client/launcher/Console.Logging.cpp; then
	if ! rg -q 'filesystem::path\s+\w+\s*\{\s*MakeRelativeCitPath' code/client/launcher/Console.Logging.cpp; then
		echo "::error::Console.Logging.cpp: wrap MakeRelativeCitPath in std::filesystem::path before exists/iterator+ec"
		fail=1
	fi
fi

if [[ "$fail" -ne 0 ]]; then
	echo "preflight FAILED"
	exit 1
fi

echo "preflight OK"
