from django.urls import include, path
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView

from core.views import healthz, readyz

urlpatterns = [
    path("", include("django_prometheus.urls")),  # /metrics (scraped by Prometheus; NOT routed by Ingress)
    path("healthz", healthz),  # liveness: process is up (no dependency checks!)
    path("readyz", readyz),  # readiness: can serve traffic (DB + Redis reachable)
    path("api/", include("orders.urls")),
    # OpenAPI schema + Swagger UI (under /api/ so Ingress/nginx route them to Django)
    path("api/schema/", SpectacularAPIView.as_view(), name="schema"),
    path("api/docs/", SpectacularSwaggerView.as_view(url_name="schema"), name="swagger-ui"),
]
