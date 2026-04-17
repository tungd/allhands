function decodeBase64Url(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padding = "=".repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(`${normalized}${padding}`);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

export function normalizePermission(permission: NotificationPermission) {
  return permission === "granted" ? "subscribed" : "unsubscribed";
}

export async function subscribeToPush(
  registration: ServiceWorkerRegistration,
  publicKey: string
) {
  return registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: decodeBase64Url(publicKey)
  });
}

export async function registerPushSubscription(subscription: PushSubscription): Promise<void> {
  const response = await fetch("/push/subscriptions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(subscription.toJSON())
  });
  if (!response.ok) {
    throw new Error("failed to register push subscription");
  }
}
