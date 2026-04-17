import json

from pywebpush import webpush

from allhands_host.store import SessionStore


class NotificationService:
    def __init__(self, store: SessionStore, public_key: str, private_key: str):
        self.store = store
        self.public_key = public_key
        self.private_key = private_key

    def send(self, title: str, body: str) -> None:
        if not self.private_key:
            return

        payload = json.dumps({"title": title, "body": body})
        for subscription in self.store.list_push_subscriptions():
            webpush(
                subscription_info=subscription,
                data=payload,
                vapid_private_key=self.private_key,
                vapid_claims={"sub": "mailto:none@example.com"},
            )

    def send_attention_required(self, title: str, body: str) -> None:
        self.send(title, body)

    def send_completed(self, title: str, body: str) -> None:
        self.send(title, body)
