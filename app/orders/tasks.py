import logging
from datetime import timedelta

from celery import shared_task
from django.utils import timezone

from .models import Order

log = logging.getLogger(__name__)


@shared_task
def process_order(order_id: int) -> None:
    """Async task: triggered on create. Idempotent (only moves pending -> processed)."""
    updated = Order.objects.filter(pk=order_id, status=Order.Status.PENDING).update(status=Order.Status.PROCESSED)
    log.info("process_order id=%s updated=%s", order_id, updated)


@shared_task
def expire_stale_orders() -> int:
    """Periodic task (Celery beat): expire orders stuck in pending for > 5 min."""
    cutoff = timezone.now() - timedelta(minutes=5)
    n = Order.objects.filter(status=Order.Status.PENDING, created_at__lt=cutoff).update(status=Order.Status.EXPIRED)
    log.info("expire_stale_orders expired=%s", n)
    return n
