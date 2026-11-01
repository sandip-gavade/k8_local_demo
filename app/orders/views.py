from django.db import transaction
from rest_framework import generics

from .models import Order
from .serializers import OrderSerializer
from .tasks import process_order


class OrderListCreateView(generics.ListCreateAPIView):
    queryset = Order.objects.all()
    serializer_class = OrderSerializer

    def perform_create(self, serializer):
        order = serializer.save()
        # on_commit: the worker must not run before the row is visible (classic Celery race).
        transaction.on_commit(lambda: process_order.delay(order.pk))
