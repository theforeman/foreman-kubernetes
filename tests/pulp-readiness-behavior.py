#!/usr/bin/python3

import copy
import importlib.util
import pathlib


script = pathlib.Path(__file__).parent.parent / "charts/foreman-stack/files/pulp-readiness.py"
spec = importlib.util.spec_from_file_location("pulp_readiness", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

healthy = {
    "database_connection": {"connected": True},
    "redis_connection": {"connected": True},
    "online_workers": [{"name": "worker@pulp-worker-0"}],
    "online_content_apps": [{"name": "content@pulp-content-0"}],
}
module.validate(healthy)

mutations = {
    "failed database": lambda status: status["database_connection"].update(connected=False),
    "failed cache": lambda status: status["redis_connection"].update(connected=False),
    "missing workers": lambda status: status.update(online_workers=[]),
    "missing content apps": lambda status: status.update(online_content_apps=[]),
}

for name, mutate in mutations.items():
    unhealthy = copy.deepcopy(healthy)
    mutate(unhealthy)
    try:
        module.validate(unhealthy)
    except RuntimeError:
        continue
    raise SystemExit(f"{name} was accepted")

print("Pulp readiness accepts healthy status and rejects dependency failures.")
