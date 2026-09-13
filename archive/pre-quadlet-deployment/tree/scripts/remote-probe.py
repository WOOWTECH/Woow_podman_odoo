#!/usr/bin/env python3
"""Probe an Odoo origin while validating DNS, redirects, and connected peers."""
import argparse
import ipaddress
import socket
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import urljoin, urlsplit

MAX_REDIRECTS = 10
TAILSCALE_NETWORKS = (
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("fd7a:115c:a1e0::/48"),
)


def fail(message: str):
    raise ValueError(message)


def effective_address(address: ipaddress._BaseAddress) -> ipaddress._BaseAddress:
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        return address.ipv4_mapped
    return address


def prohibited(address: ipaddress._BaseAddress) -> bool:
    effective = effective_address(address)
    return effective.is_loopback or effective.is_unspecified


def approved_tailnet_peer(address: ipaddress._BaseAddress,
                          explicit_peer: ipaddress._BaseAddress | None = None) -> bool:
    effective = effective_address(address)
    explicit = effective_address(explicit_peer) if explicit_peer is not None else None
    return effective == explicit or any(effective in network for network in TAILSCALE_NETWORKS)


def validate_url(url: str, *, origin: bool = False,
                 explicit_peer: ipaddress._BaseAddress | None = None) -> tuple[str, int, list[ipaddress._BaseAddress]]:
    parsed = urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        fail("URL must use http(s) and include a host")
    if parsed.username or parsed.password or parsed.fragment:
        fail("URL credentials and fragments are forbidden")
    if origin and (parsed.query or parsed.path not in ("", "/")):
        fail("remote URL must be an origin without path or query")
    host = parsed.hostname.lower()
    if host.rstrip(".") == "localhost":
        fail("remote URL must not use localhost")
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    try:
        addresses = sorted(
            {ipaddress.ip_address(item[4][0]) for item in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)},
            key=lambda item: (item.version, int(item)),
        )
    except socket.gaierror as exc:
        fail(f"remote URL host does not resolve: {exc}")
    if not addresses:
        fail("remote URL host does not resolve")
    if any(prohibited(address) for address in addresses):
        fail("remote URL must not resolve to loopback/wildcard")
    if any(not approved_tailnet_peer(address, explicit_peer) for address in addresses):
        fail("remote URL must resolve only to Tailscale CGNAT/ULA addresses or the explicit peer")
    return host, port, addresses


def location_from(headers: bytes) -> str | None:
    location = None
    for raw in headers.splitlines():
        if raw.lower().startswith(b"location:"):
            location = raw.split(b":", 1)[1].strip().decode("latin-1")
    return location


def probe(url: str, curl: str = "curl",
          explicit_peer: ipaddress._BaseAddress | None = None) -> tuple[int, str]:
    current = url
    for redirects in range(MAX_REDIRECTS + 1):
        host, port, addresses = validate_url(current, explicit_peer=explicit_peer)
        selected = addresses[0]
        pinned = f"[{selected}]" if selected.version == 6 else str(selected)
        with tempfile.NamedTemporaryFile() as header_file:
            command = [
                curl, "--noproxy", "*", "--fail", "--show-error",
                "--connect-timeout", "10", "--max-time", "30", "--max-redirs", "0",
                "--proto", "=http,https", "--resolve", f"{host}:{port}:{pinned}",
                "--dump-header", header_file.name, "--output", "/dev/null",
                "--write-out", "%{http_code}\n%{remote_ip}\n%{url_effective}", current,
            ]
            result = subprocess.run(command, text=True, capture_output=True)
            if result.returncode:
                raise RuntimeError(result.stderr.strip() or f"curl failed with status {result.returncode}")
            fields = result.stdout.splitlines()
            if len(fields) != 3:
                fail("curl returned malformed connection evidence")
            try:
                status = int(fields[0])
                peer = ipaddress.ip_address(fields[1].strip("[]"))
            except ValueError as exc:
                fail(f"curl returned malformed status/peer: {exc}")
            if (prohibited(peer) or peer not in addresses or
                    not approved_tailnet_peer(peer, explicit_peer)):
                fail("effective peer was not an approved tailnet peer")
            effective = fields[2]
            effective_host, effective_port, effective_addresses = validate_url(
                effective, explicit_peer=explicit_peer)
            if effective_host != host or effective_port != port or peer not in effective_addresses:
                fail("curl effective URL/peer changed outside the validated destination")
            headers = Path(header_file.name).read_bytes()
        if 300 <= status < 400:
            location = location_from(headers)
            if not location:
                fail(f"HTTP {status} did not provide a redirect location")
            if redirects == MAX_REDIRECTS:
                fail("too many redirects")
            current = urljoin(current, location)
            validate_url(current, explicit_peer=explicit_peer)
            continue
        if not 200 <= status < 300:
            fail(f"remote returned HTTP {status}")
        return status, current
    fail("too many redirects")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("origin")
    parser.add_argument("--curl", default="curl")
    parser.add_argument("--peer", help="exact approved peer IP when gateway addressing is not Tailscale CGNAT/ULA")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    try:
        explicit_peer = ipaddress.ip_address(args.peer) if args.peer else None
    except ValueError as exc:
        fail(f"explicit peer must be an IP address: {exc}")
    validate_url(args.origin, origin=True, explicit_peer=explicit_peer)
    if args.validate_only:
        return
    base = args.origin.rstrip("/")
    for path in ("/web/health", "/"):
        status, effective = probe(base + path, args.curl, explicit_peer)
        print(f"remote={base + path} effective={effective} status={status}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError) as exc:
        raise SystemExit(f"Remote gate failed: {exc}")
