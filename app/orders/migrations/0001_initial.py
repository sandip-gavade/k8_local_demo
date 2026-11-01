from django.db import migrations, models


class Migration(migrations.Migration):
    initial = True
    dependencies = []
    operations = [
        migrations.CreateModel(
            name="Order",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("item", models.CharField(max_length=200)),
                ("quantity", models.PositiveIntegerField(default=1)),
                (
                    "status",
                    models.CharField(
                        choices=[("pending", "Pending"), ("processed", "Processed"), ("expired", "Expired")],
                        db_index=True,
                        default="pending",
                        max_length=20,
                    ),
                ),
                ("created_at", models.DateTimeField(auto_now_add=True)),
            ],
            options={"ordering": ["-id"]},
        ),
    ]
