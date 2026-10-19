"""Refuse to occupy WebKit's shared test hook if an existing job owns it."""
import json
import os
import pathlib
import subprocess
import sys

service = "org.webkit.webpushtestdaemon.service"
domains = [f"gui/{os.getuid()}", f"user/{os.getuid()}", "system"]
checked = []
for domain in domains:
    result = subprocess.run(
        ["launchctl", "print", domain], capture_output=True, text=True, timeout=5
    )
    if result.returncode:
        sys.exit(f"Cannot inspect {domain}; refusing to register the shared WebKit test service.")
    # A job may have an unrelated label, so inspect MachServices as well as labels.
    # Do not save the domain listing: it contains unrelated applications' details.
    if service in result.stdout:
        sys.exit(f"WebKit test service is already present in {domain}; leaving it untouched.")
    checked.append(domain)

(pathlib.Path(sys.argv[1]) / "provider-preflight.json").write_text(
    json.dumps({"service": service, "absentFromDomains": checked}, indent=2) + "\n"
)
