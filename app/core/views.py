import redis
from django.conf import settings
from django.db import connection
from django.http import JsonResponse


def healthz(request):
    """Liveness. Must NOT touch DB/Redis, or a DB blip makes K8s restart healthy pods."""
    return JsonResponse({"status": "ok"})


def readyz(request):
    """Readiness. Failing removes the pod from Service endpoints without restarting it."""
    checks = {}
    try:
        with connection.cursor() as cur:
            cur.execute("SELECT 1")
        checks["database"] = "ok"
    except Exception as exc:  # noqa: BLE001 - report any failure as not ready
        checks["database"] = f"error: {type(exc).__name__}"
    try:
        redis.Redis.from_url(settings.REDIS_URL, socket_connect_timeout=1).ping()
        checks["redis"] = "ok"
    except Exception as exc:  # noqa: BLE001
        checks["redis"] = f"error: {type(exc).__name__}"
    ready = all(v == "ok" for v in checks.values())
    return JsonResponse({"status": "ok" if ready else "unavailable", **checks}, status=200 if ready else 503)
