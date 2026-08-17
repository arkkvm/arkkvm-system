#!/usr/bin/env python3
"""Verify arkkvm-network status on device via serial (not local dry-run).

Default serial: /dev/cu.usbserial-120  115200  root/ArkKVM
"""
from __future__ import annotations

import argparse
import re
import sys
import time

try:
    import serial
except ImportError:
    print("ERROR: pyserial not installed (pip install pyserial)", file=sys.stderr)
    sys.exit(1)

DEFAULT_PORT = "/dev/cu.usbserial-120"
BAUD = 115200
LOGIN_USER = b"root\n"
LOGIN_PASS = b"ArkKVM\n"
PROMPT_RE = re.compile(r"[\r\n][^\r\n]*[#$]\s*$")


class SerialSession:
    def __init__(self, port: str, baud: int = BAUD):
        self.s = serial.Serial(port, baud, timeout=0.5)
        time.sleep(0.2)
        self.s.reset_input_buffer()

    def close(self) -> None:
        self.s.close()

    def _read_available(self, max_bytes: int = 8192) -> str:
        chunks: list[bytes] = []
        total = 0
        while total < max_bytes:
            n = self.s.in_waiting
            if n:
                data = self.s.read(min(n, max_bytes - total))
                chunks.append(data)
                total += len(data)
            else:
                break
        return b"".join(chunks).decode("utf-8", "replace")

    def _wait_prompt(self, timeout: float = 8.0) -> str:
        end = time.time() + timeout
        buf = ""
        while time.time() < end:
            buf += self._read_available()
            if PROMPT_RE.search(buf):
                return buf
            time.sleep(0.1)
        return buf

    def login_if_needed(self) -> None:
        self.s.write(b"\n")
        time.sleep(0.6)
        buf = self._read_available(4096)
        low = buf.lower()
        if "login:" in low:
            self.s.write(LOGIN_USER)
            time.sleep(0.4)
            self.s.write(LOGIN_PASS)
            time.sleep(1.2)
            self._read_available(4096)

    def run(self, cmd: str, timeout: float = 10.0) -> str:
        self.s.write((cmd.strip() + "\n").encode())
        return self._wait_prompt(timeout)


def section(title: str) -> None:
    print(f"\n{'=' * 60}")
    print(title)
    print("=" * 60)


def check(name: str, ok: bool, detail: str = "") -> bool:
    mark = "PASS" if ok else "FAIL"
    line = f"[{mark}] {name}"
    if detail:
        line += f" — {detail}"
    print(line)
    return ok


def count_default_routes(text: str) -> list[str]:
    return [ln.strip() for ln in text.splitlines() if ln.strip().startswith("default")]


def main() -> int:
    ap = argparse.ArgumentParser(description="Serial device network verification")
    ap.add_argument("port", nargs="?", default=DEFAULT_PORT, help=f"Serial port (default {DEFAULT_PORT})")
    args = ap.parse_args()

    print(f"Serial port: {args.port} @ {BAUD}")
    sess = SerialSession(args.port)
    try:
        sess.login_if_needed()

        section("Init scripts")
        out = sess.run("ls -la /etc/init.d/S16network* 2>/dev/null; echo DONE")
        has_main = "S16network" in out and "S16network-unified" not in out.split("S16network")[0]
        has_dup = "S16network-unified" in out
        check("S16network present", "/etc/init.d/S16network" in out or "S16network" in out)
        check("No duplicate S16network-unified", not has_dup, "remove if present")

        section("network.conf VLAN")
        conf = sess.run("grep -E '^\\[vlan\\]|^enabled=|^\\[vlan.primary\\]|^id=|^route_metric=' /userdata/arkkvm/network.conf 2>/dev/null; echo DONE")
        print(conf.strip())
        vlan_on = re.search(r"(?m)^enabled=true\s*$", conf) is not None
        primary_id = None
        m = re.search(r"(?m)^id=(\d+)\s*$", conf)
        if m:
            primary_id = int(m.group(1))
        check("Read network.conf", "[vlan]" in conf or "enabled=" in conf)

        section("Default routes")
        routes = sess.run("ip route show default; echo DONE")
        print(routes.strip())
        defaults = count_default_routes(routes)
        if vlan_on and primary_id is not None:
            primary_dev = f"eth0.{primary_id}"
            on_primary = any(primary_dev in r for r in defaults)
            on_parent = any(re.search(r"\bdev eth0\b", r) and primary_dev not in r for r in defaults)
            check("Single default route", len(defaults) <= 1, f"count={len(defaults)}")
            check("Default on primary VLAN", on_primary, primary_dev)
            check("No default on parent eth0", not on_parent)
        else:
            check("Default route present", len(defaults) >= 1, f"count={len(defaults)}")

        section("udhcpc daemons")
        ps = sess.run("ps | grep -v grep | grep udhcpc; echo DONE")
        print(ps.strip() if "udhcpc" in ps else "(no udhcpc processes)")
        if vlan_on and primary_id is not None:
            primary_dev = f"eth0.{primary_id}"
            check("udhcpc on primary VLAN", f"-i {primary_dev}" in ps or f"-i{primary_dev}" in ps, primary_dev)
            check("udhcpc on eth0 (management)", "-i eth0" in ps or "-ieth0" in ps)

        section("Link monitor")
        lm = sess.run("test -f /run/network-unified-link-monitor.pid && cat /run/network-unified-link-monitor.pid; echo DONE")
        print(lm.strip())
        pid_m = re.search(r"(?m)^(\d+)\s*$", lm)
        has_lm = pid_m is not None and int(pid_m.group(1)) > 1
        check("Link monitor running", has_lm, pid_m.group(1) if pid_m else "not deployed or not started")

        section("DHCP lease files")
        leases = sess.run("ls -la /run/udhcpc.*.info 2>/dev/null; echo DONE")
        print(leases.strip() if "udhcpc" in leases else "(no lease files)")

        section("Interfaces")
        ifaces = sess.run("ip addr show eth0; ip addr show eth0.5 2>/dev/null; ip addr show eth0.10 2>/dev/null; echo DONE")
        print(ifaces.strip())

    finally:
        sess.close()

    print("\nDone.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
