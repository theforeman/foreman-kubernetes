#!/usr/bin/python3

import os
import socket

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "pulpcore.app.settings")

import django

django.setup()

from pulpcore.app.models import AppStatus


app_type = os.environ["PULP_APP_TYPE"]
hostname = socket.gethostname()
online = AppStatus.objects.online().filter(
    app_type=app_type, name__endswith=f"@{hostname}"
).exists()

if not online:
    raise SystemExit(f"this {app_type} process has no online database heartbeat")
