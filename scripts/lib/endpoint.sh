#!/bin/sh
# Shared explicit-endpoint resolution for the deploy and doctor scripts.
#
# A target is always the endpoint named on the command line. `selected` in the saved
# machine list is the TUI's own highlight and is deliberately ignored, so the endpoint a
# user happens to be looking at can never retarget a CLI command. `local` means the
# inherited session and socket; anything else must resolve to exactly one enabled saved
# machine by its unique label, profile id, or SSH target.

# Prints one tab-separated line: KIND LABEL ID TARGET SESSION.
# Exit 2 when the machine list is unreadable, 3 for an unknown or ambiguous name.
endpoint_resolve() {
    herdr_bin=$1
    name=$2
    if [ "$name" = local ]; then
        printf 'local\t\t\t\t\n'
        return 0
    fi
    machines=$("$herdr_bin" machine list --json 2>/dev/null) || {
        printf 'endpoint: %s machine list --json failed\n' "$herdr_bin" >&2
        return 2
    }
    python3 -c '
import json, sys
name = sys.argv[2]
try:
    profiles = json.loads(sys.argv[1])
except ValueError:
    sys.stderr.write("endpoint: herdr machine list did not return JSON\n")
    sys.exit(2)
matches = [
    profile for profile in profiles
    if profile.get("enabled") and name in (profile.get("label"), profile.get("id"), profile.get("target"))
]
if not matches:
    sys.stderr.write("endpoint: unknown endpoint %r; use `herdr machine list`\n" % name)
    sys.exit(3)
if len(matches) > 1:
    labels = ", ".join(str(profile.get("label")) for profile in matches)
    sys.stderr.write("endpoint: ambiguous endpoint %r matches %d profiles: %s\n" % (name, len(matches), labels))
    sys.exit(3)
profile = matches[0]
print("\t".join([
    "remote",
    str(profile.get("label", "")),
    str(profile.get("id", "")),
    str(profile.get("target", "")),
    str(profile.get("session") or "default"),
]))
' "$machines" "$name"
}

# Reads a resolved line into the EP_* variables. Returns the resolver's status.
endpoint_read() {
    IFS='	' read -r EP_KIND EP_LABEL EP_ID EP_TARGET EP_SESSION <<EOF
$(endpoint_resolve "$1" "$2")
EOF
    [ -n "${EP_KIND:-}" ] || return 3
}

# Runs an argv on an SSH endpoint with no shell interpolation of any value.
#
# The outer SSH command string contains only a fixed Python launcher and one base64 token,
# so endpoint-derived paths (spaces, single quotes, `$`, backticks) can never reach a remote
# shell. The remote launcher decodes the argv and execs it without a shell.
#
# usage: endpoint_ssh_exec <ssh-bin> <target> <argv...>
endpoint_ssh_exec() {
    ssh_bin=$1
    target=$2
    shift 2
    b64=$(python3 -c '
import base64, json, sys
sys.stdout.write(base64.b64encode(json.dumps(sys.argv[1:]).encode()).decode())
' "$@") || return 2
    "$ssh_bin" -o BatchMode=yes -o ConnectTimeout=10 "$target" \
        "python3 -c 'import base64,json,subprocess,sys; sys.exit(subprocess.run(json.loads(base64.b64decode(sys.argv[1]))).returncode)' '$b64'"
}
