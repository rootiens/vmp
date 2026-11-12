#!/usr/bin/env python3
from __future__ import annotations

import re
import urllib.request
from pathlib import Path


def parse(text: str) -> dict[str, str]:
	mods: dict[str, str] = {}
	path = None
	url = None

	for raw in text.splitlines():
		line = raw.strip()
		if line.startswith("[submodule"):
			path = None
			url = None
		elif line.startswith("path ="):
			path = line.split("=", 1)[1].strip()
		elif line.startswith("url ="):
			url = line.split("=", 1)[1].strip()

		if path and url:
			mods[path] = url
			path = None
			url = None

	return mods


def main() -> None:
	local_path = Path(".gitmodules")
	local_text = local_path.read_text(encoding="utf-8")
	local = parse(local_text)

	upstream_text = urllib.request.urlopen(
		"https://raw.githubusercontent.com/citizenfx/fivem/master/.gitmodules"
	).read().decode("utf-8")
	upstream = parse(upstream_text)

	missing = sorted(set(local) - set(upstream))
	if missing:
		raise SystemExit(f"No public URL mapping for submodule paths: {missing[:20]}")

	def replacer(match: re.Match[str]) -> str:
		block = match.group(0)
		path_m = re.search(r"^\s*path\s*=\s*(.+)$", block, re.M)
		if not path_m:
			return block

		path = path_m.group(1).strip()
		public_url = upstream.get(path)
		if not public_url:
			return block

		return re.sub(r"^(\s*url\s*=\s*).*$", rf"\1{public_url}", block, count=1, flags=re.M)

	rewritten = re.sub(
		r"(?ms)^\[submodule [^\]]+\]\n(?:^[^\n]*\n)*?(?=^\[submodule |\Z)",
		replacer,
		local_text if local_text.endswith("\n") else local_text + "\n",
	)
	local_path.write_text(rewritten, encoding="utf-8")
	print(f"Rewrote {len(local)} submodule URLs to public mirrors")


if __name__ == "__main__":
	main()
