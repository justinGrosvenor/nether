#!/usr/bin/env python3
"""Measure one real warm-forked Nether+Swerver VM per concurrent request."""

import argparse
import concurrent.futures
import http.client
import socket
import statistics
import threading
import time
import uuid
import urllib.parse


def recv_frame(sock: socket.socket) -> tuple[bytes, int]:
    data = bytearray()
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("control socket closed before a framed reply")
        data.extend(chunk)
        marker = data.rfind(b"\x1e")
        if marker >= 0 and data.endswith(b"\n"):
            return bytes(data[:marker]), int(data[marker + 1 : -1])


def ensure_and_hit(control: str, barrier: threading.Barrier, index: int) -> float:
    tenant = f"burst-{uuid.uuid4().hex}-{index}"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as ctl:
        ctl.settimeout(35)
        ctl.connect(control)
        barrier.wait()
        start = time.perf_counter()
        ctl.sendall(f"ensure {tenant}\n".encode())
        path, exit_code = recv_frame(ctl)
        if exit_code != 0:
            raise RuntimeError(path.decode(errors="replace"))

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as upstream:
            upstream.settimeout(10)
            upstream.connect(path.decode())
            upstream.sendall(
                b"GET /baseline11?a=25&b=17 HTTP/1.1\r\n"
                b"Host: guest\r\nConnection: close\r\n\r\n"
            )
            response = bytearray()
            while True:
                chunk = upstream.recv(4096)
                if not chunk:
                    break
                response.extend(chunk)

    if b" 200 " not in response.split(b"\r\n", 1)[0]:
        raise RuntimeError(f"bad HTTP status: {response[:80]!r}")
    if response.partition(b"\r\n\r\n")[2].strip() != b"42":
        raise RuntimeError(f"bad response body: {response[-80:]!r}")
    return (time.perf_counter() - start) * 1000


def gateway_hit(gateway: str, barrier: threading.Barrier, index: int) -> float:
    parsed = urllib.parse.urlsplit(gateway)
    if parsed.scheme != "http" or not parsed.hostname:
        raise ValueError("--gateway must be an http:// URL")
    tenant = f"burst-{uuid.uuid4().hex}-{index}"
    connection = http.client.HTTPConnection(parsed.hostname, parsed.port or 80, timeout=35)
    path = f"{parsed.path.rstrip('/')}/baseline11?a=25&b=17"
    try:
        barrier.wait()
        start = time.perf_counter()
        connection.request("GET", path, headers={"x-tenant": tenant})
        response = connection.getresponse()
        body = response.read().strip()
        if response.status != 200 or body != b"42":
            raise RuntimeError(f"HTTP {response.status}, body={body!r}")
        return (time.perf_counter() - start) * 1000
    finally:
        connection.close()


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * fraction))]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--control", default="/tmp/nsw/control.sock")
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument(
        "--gateway",
        default="",
        help="measure through this host Swerver URL, e.g. http://127.0.0.1:18080/tenant",
    )
    args = parser.parse_args()
    if args.concurrency < 1:
        parser.error("--concurrency must be positive")

    barrier = threading.Barrier(args.concurrency)
    wall_start = time.perf_counter()
    failures: list[str] = []
    timings: list[float] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        worker = gateway_hit if args.gateway else ensure_and_hit
        endpoint = args.gateway if args.gateway else args.control
        futures = [
            pool.submit(worker, endpoint, barrier, index)
            for index in range(args.concurrency)
        ]
        for future in concurrent.futures.as_completed(futures):
            try:
                timings.append(future.result())
            except Exception as error:  # show all failures from a burst
                failures.append(str(error))
    wall_ms = (time.perf_counter() - wall_start) * 1000

    if failures:
        print(f"FAIL {len(timings)}/{args.concurrency} succeeded; wall={wall_ms:.3f} ms")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print(
        f"PASS {len(timings)}/{args.concurrency}; "
        f"via={'gateway' if args.gateway else 'supervisor'}; wall={wall_ms:.3f} ms; "
        f"mean={statistics.mean(timings):.3f} ms; min={min(timings):.3f} ms; "
        f"p50={percentile(timings, 0.50):.3f} ms; "
        f"p95={percentile(timings, 0.95):.3f} ms; max={max(timings):.3f} ms"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
