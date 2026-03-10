#!/usr/bin/env python3

import argparse
import http.client
import json
import socket
import sys
import time
from urllib.parse import urlparse


def touch(path: str) -> None:
    with open(path, "w", encoding="utf-8"):
        pass


def connect(url: str, timeout: float):
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"unsupported scheme: {parsed.scheme}")
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    conn_cls = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
    conn = conn_cls(host, port, timeout=timeout)
    path = parsed.path or "/"
    if parsed.query:
        path = f"{path}?{parsed.query}"
    return conn, path


def emit(result) -> None:
    sys.stdout.write(json.dumps(result))
    sys.stdout.flush()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--expect", type=int, required=True)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--last-event-id")
    parser.add_argument("--ready-file")
    parser.add_argument("--start-read-delay-ms", type=int, default=0)
    args = parser.parse_args()

    result = {
        "status": None,
        "headers": {},
        "events": [],
        "error": None,
    }

    connection = None
    try:
        connection, path = connect(args.url, args.timeout)
        headers = {"Accept": "text/event-stream"}
        if args.last_event_id:
            headers["Last-Event-ID"] = args.last_event_id
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        result["status"] = response.status
        result["headers"] = {key.lower(): value for key, value in response.getheaders()}

        if args.ready_file:
            touch(args.ready_file)

        if args.start_read_delay_ms > 0:
            time.sleep(args.start_read_delay_ms / 1000.0)

        current = {"id": None, "event": None, "data": []}
        deadline = time.monotonic() + args.timeout

        while len(result["events"]) < args.expect:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                result["error"] = "timeout"
                break
            if connection.sock is not None:
                connection.sock.settimeout(remaining)
            try:
                raw_line = response.readline()
            except socket.timeout:
                result["error"] = "timeout"
                break

            if not raw_line:
                if len(result["events"]) < args.expect and result["error"] is None:
                    result["error"] = "eof"
                break

            line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")
            if line == "":
                if current["id"] is not None or current["event"] is not None or current["data"]:
                    result["events"].append(
                        {
                            "id": current["id"],
                            "event": current["event"],
                            "data": "\n".join(current["data"]),
                        }
                    )
                current = {"id": None, "event": None, "data": []}
                continue

            if line.startswith(":"):
                continue

            field, _, value = line.partition(":")
            if value.startswith(" "):
                value = value[1:]

            if field == "id":
                current["id"] = value
            elif field == "event":
                current["event"] = value
            elif field == "data":
                current["data"].append(value)
    except Exception as exc:
        result["error"] = str(exc)
    finally:
        if connection is not None:
            try:
                connection.close()
            except Exception:
                pass

    emit(result)


if __name__ == "__main__":
    main()
