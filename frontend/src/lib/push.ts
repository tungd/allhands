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

export async function maybeEnableNotifications(props: {
  previousCount: number;
  nextCount: number;
  vapidPublicKey: string;
}) {
  if (props.vapidPublicKey.length === 0) {
    return;
  }
  if (props.previousCount !== 0 || props.nextCount === 0) {
    return;
  }
  if (!("Notification" in globalThis) || Notification.permission !== "default") {
    return;
  }
  if (!("serviceWorker" in navigator)) {
    return;
  }

  const permission = await Notification.requestPermission();
  if (permission !== "granted") {
    return;
  }

  const registration = await navigator.serviceWorker.ready;
  const existing = await registration.pushManager.getSubscription();
  const subscription = existing ?? (await subscribeToPush(registration, props.vapidPublicKey));
  await registerPushSubscription(subscription);
}
