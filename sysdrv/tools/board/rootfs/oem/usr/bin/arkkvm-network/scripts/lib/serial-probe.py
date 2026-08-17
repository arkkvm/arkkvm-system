#!/usr/bin/env python3
"""Serial subnet probe (fallback when SSH unreachable)"""
import sys
import time

try:
    import serial
except ImportError:
    print("pyserial not installed", file=sys.stderr)
    sys.exit(1)

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/cu.usbserial-120"
BAUD = 115200


def main():
    s = serial.Serial(PORT, BAUD, timeout=1)
    time.sleep(0.2)
    s.reset_input_buffer()
    s.write(b"\n")
    time.sleep(0.5)
    buf = s.read(1024).decode("utf-8", "replace")
    if "login:" in buf.lower():
        s.write(b"root\n")
        time.sleep(0.3)
        s.write(b"ArkKVM\n")
        time.sleep(1)
        s.read(2048)

    cmd = b"ip -4 addr show eth0; ip route show default\n"
    s.write(cmd)
    time.sleep(2)
    out = s.read(4096).decode("utf-8", "replace")
    print(out)
    s.close()


if __name__ == "__main__":
    main()
