#!/usr/bin/python3

import json
import os
import urllib.request


def validate(status):
    database = status.get("database_connection")
    if database and database.get("connected") is not True:
        raise RuntimeError("Pulp database is not connected")

    cache = status.get("redis_connection")
    if cache and cache.get("connected") is not True:
        raise RuntimeError("Pulp cache is not connected")

    if not status.get("online_workers"):
        raise RuntimeError("Pulp has no online workers")
    if not status.get("online_content_apps"):
        raise RuntimeError("Pulp has no online content apps")


def check():
    url = os.environ.get(
        "PULP_READINESS_URL", "http://127.0.0.1:24817/pulp/api/v3/status/"
    )
    with urllib.request.urlopen(url, timeout=8) as response:
        validate(json.load(response))


if __name__ == "__main__":
    check()
