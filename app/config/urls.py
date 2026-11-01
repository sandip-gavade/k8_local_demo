from django.urls import include, path

from core.views import healthz, readyz

urlpatterns = [
    path("healthz", healthz),  # liveness: process is up (no dependency checks!)
    path("readyz", readyz),  # readiness: can serve traffic (DB + Redis reachable)
    path("api/", include("orders.urls")),
]
