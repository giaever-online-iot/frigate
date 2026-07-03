#!/usr/bin/env python3
"""M1: can a strict snap with network+network-bind do mDNS multicast?
Evidence either way: join+send ok answers the interface question; responses>0
proves the full loop (the host's own avahi typically answers)."""
import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_common import write_result

out: dict = {"status": "complete"}
GROUP, PORT = "224.0.0.251", 5353
# Minimal mDNS PTR query for _services._dns-sd._udp.local
QUERY = (b"\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00"
         b"\x09_services\x07_dns-sd\x04_udp\x05local\x00\x00\x0c\x00\x01")

try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("", PORT))
    mreq = struct.pack("4sl", socket.inet_aton(GROUP), socket.INADDR_ANY)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    out["multicast_join"] = {"ok": True}
except OSError as e:
    out["multicast_join"] = {"ok": False, "errno": e.errno, "error": str(e)}
    write_result("mdns", out)
    sys.exit(0)

try:
    s.sendto(QUERY, (GROUP, PORT))
    out["query_sent"] = {"ok": True}
except OSError as e:
    out["query_sent"] = {"ok": False, "errno": e.errno, "error": str(e)}

responses = 0
senders = set()
s.settimeout(0.5)
deadline = time.monotonic() + 3.0
while time.monotonic() < deadline:
    try:
        _, addr = s.recvfrom(9000)
        responses += 1
        senders.add(addr[0])
    except socket.timeout:
        continue
    except OSError as e:
        out["recv_error"] = str(e)
        break
out["responses"] = responses
out["unique_senders"] = sorted(senders)[:10]
write_result("mdns", out)
