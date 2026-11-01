from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from .models import Order
from .tasks import expire_stale_orders


@override_settings(CELERY_TASK_ALWAYS_EAGER=True)
class OrderApiTests(TestCase):
    def test_create_and_list(self):
        client = APIClient()
        with self.captureOnCommitCallbacks(execute=True):
            resp = client.post("/api/orders/", {"item": "widget", "quantity": 2}, format="json")
        self.assertEqual(resp.status_code, 201)
        self.assertEqual(Order.objects.get().status, "processed")  # async task ran (eager)
        self.assertEqual(client.get("/api/orders/").json()["count"], 1)

    def test_healthz(self):
        self.assertEqual(self.client.get("/healthz").status_code, 200)

    def test_expire_noop_on_fresh_orders(self):
        Order.objects.create(item="x")
        self.assertEqual(expire_stale_orders(), 0)
