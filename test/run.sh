#!/usr/bin/env bash
# Offline boot test: mocks + the real hub + assertions + lifecycle scenarios,
# concatenated into one Luau chunk because the Luau CLI's require() sandboxes
# each module's globals.
#
#   test/run.sh          the place belongs to someone else — dev tools stay locked
#   test/run.sh owner    the place belongs to the local player — dev tools apply

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

luau="$root/.freebuff/tools/luau.exe"
if [ ! -x "$luau" ]; then
	if command -v luau >/dev/null 2>&1; then
		luau="$(command -v luau)"
	else
		echo "boot test: no Luau CLI found (.freebuff/tools/luau.exe or luau on PATH)" >&2
		exit 127
	fi
fi

# The bundle lives inside test/ so stack traces point at real paths.
bundle="$root/test/.bundle.lua"
trap 'rm -f "$bundle"' EXIT

# Source is inlined rather than required, because the CLI sandboxes a required
# module's globals and both the hub and the packs are ordinary Roblox code that
# needs game, Instance, Color3 and the rest. Inlining the pack sources also
# means the loader compiles them through the same loadstring path it uses in
# game, and the scenarios can boot the hub a second time for real.
for file in "$root/secrete.lua" "$root"/modules/*.lua; do
	if grep -q ']==]' "$file"; then
		echo "boot test: $file contains the long-string terminator" >&2
		exit 1
	fi
done

{
	printf '__harnessHubSource = [==[\n'
	cat "$root/secrete.lua"
	printf ']==]\n\n'

	printf '__harnessPackSources = {\n'
	for file in "$root"/modules/*.lua; do
		printf '\t[%s%s%s] = [==[\n' '"' "$(basename "$file" .lua)" '"'
		cat "$file"
		printf ']==],\n'
	done
	printf '}\n\n'

	cat "$root/test/mocks.lua"
	# the hub ends with `return Secrete`; in a concatenated chunk that has to
	# become an assignment so the assertions can pick it up
	sed 's/^return Secrete$/__harness.secrete = Secrete/' "$root/secrete.lua"
	cat "$root/test/assertions.lua"
	cat "$root/test/scenarios.lua"
} >"$bundle"

if [ "$#" -gt 0 ]; then
	"$luau" "$bundle" -a "$@"
else
	"$luau" "$bundle"
fi
