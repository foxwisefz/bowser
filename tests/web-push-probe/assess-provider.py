"""Classify provider admission independently of subscription implementation."""
import json
import pathlib
import subprocess
import sys

out = pathlib.Path(sys.argv[1])
service = sys.argv[2]


def records(name):
    return [json.loads(line) for line in (out / name).read_text().splitlines()]


control = records("provider-control.jsonl")
assert any(r["event"] == "control_reply" and r["details"]["ok"] for r in control)
provider = records("provider.jsonl")
assert any(r["event"] == "control_request" for r in provider)
reached_provider = any(r["event"] == "provider_request" for r in provider)

# UUID-based test service only; never collect unrelated website/app logs.
predicate = f'eventMessage CONTAINS "{service}"'
with (out / "provider-connection.log").open("w") as log:
    subprocess.run(
        ["/usr/bin/log", "show", "--start", sys.argv[3], "--style", "compact", "--predicate", predicate],
        stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30,
    )
connection_log = (out / "provider-connection.log").read_text()
sandbox_denied = any(
    "com.apple.WebKit.Networking" in line and f"mach-lookup {service}" in line and "deny(" in line
    for line in connection_log.splitlines()
)
assert reached_provider or sandbox_denied, "Inconclusive: provider works, but no WebKit admission evidence."
assert not (reached_provider and sandbox_denied), "Mixed admission evidence: investigate before drawing a conclusion."
result = {
    "controlReachedProvider": True,
    "webkitReachedProvider": reached_provider,
    "webkitSandboxDeniedLookup": sandbox_denied,
    "subscriptionBackendImplemented": False,
}
(out / "provider-result.json").write_text(json.dumps(result, indent=2) + "\n")
print("Provider admission:", json.dumps(result, sort_keys=True))
if sandbox_denied:
    print("BLOCKED: system WebKit sandbox rejected custom provider lookup despite a successful control connection.")
else:
    print("REACHED: WebKit contacted the test provider; subscription and encrypted delivery remain unimplemented.")
