from django.db import models


class Order(models.Model):
    class Status(models.TextChoices):
        PENDING = "pending"
        PROCESSED = "processed"
        EXPIRED = "expired"

    item = models.CharField(max_length=200)
    quantity = models.PositiveIntegerField(default=1)
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.PENDING, db_index=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-id"]
