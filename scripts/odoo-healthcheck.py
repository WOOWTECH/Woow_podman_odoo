#!/usr/bin/env python3
"""Probe Odoo's database-independent HTTP health endpoint."""

import http.client
import sys

HOST = "127.0.0.1"
PORT = 8069
PATH = "/web/health"
TIMEOUT_SECONDS = 3


def check(host=HOST, port=PORT):
    connection = http.client.HTTPConnection(host, port, timeout=TIMEOUT_SECONDS)
    try:
        connection.request("GET", PATH)
        response = connection.getresponse()
        response.read(1)
        return 200 <= response.status < 400
    except (OSError, http.client.HTTPException):
        return False
    finally:
        connection.close()


def main():
    return 0 if check() else 1


if __name__ == "__main__":
    sys.exit(main())
