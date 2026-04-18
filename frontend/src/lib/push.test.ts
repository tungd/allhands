import { maybeEnableNotifications, normalizePermission } from "./push";


test("maps denied permissions to an unsubscribed state", () => {
  expect(normalizePermission("denied")).toBe("unsubscribed");
});


test("requests permission after the first session appears", async () => {
  const requestPermission = vi.fn().mockResolvedValue("granted");
  const getSubscription = vi.fn().mockResolvedValue(null);
  const subscribe = vi.fn().mockResolvedValue({
    toJSON: () => ({
      endpoint: "https://example.invalid/1",
      keys: {}
    })
  });

  vi.stubGlobal("Notification", { permission: "default", requestPermission });
  vi.stubGlobal("navigator", {
    serviceWorker: {
      ready: Promise.resolve({
        pushManager: {
          getSubscription,
          subscribe
        }
      })
    }
  });
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({})
    })
  );

  await maybeEnableNotifications({ previousCount: 0, nextCount: 1, vapidPublicKey: "BElidedValue" });

  expect(requestPermission).toHaveBeenCalledOnce();
});
