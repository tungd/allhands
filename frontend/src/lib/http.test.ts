import { AUTH_REQUIRED_EVENT, getStoredCredentials, storeCredentials } from "./auth";
import { UnauthorizedError, authorizedFetch } from "./http";

const AUTHORIZATION = `Basic ${btoa("td:secret")}`;

beforeEach(() => {
  localStorage.clear();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

test("adds the stored basic auth header to protected requests", async () => {
  storeCredentials({ username: "td", password: "secret" });
  const fetchMock = vi.fn().mockResolvedValue({
    ok: true,
    status: 200,
    body: null,
    json: async () => ({})
  });
  vi.stubGlobal("fetch", fetchMock);

  await authorizedFetch("/sessions");

  expect(new Headers(fetchMock.mock.calls[0]?.[1]?.headers).get("Authorization")).toBe(AUTHORIZATION);
});

test("clears stored credentials and emits an auth-required event on 401", async () => {
  storeCredentials({ username: "td", password: "secret" });
  const listener = vi.fn();
  window.addEventListener(AUTH_REQUIRED_EVENT, listener);
  vi.stubGlobal(
    "fetch",
    vi.fn().mockResolvedValue({
      ok: false,
      status: 401,
      body: null,
      json: async () => ({ error: "authentication required" })
    })
  );

  await expect(authorizedFetch("/sessions")).rejects.toBeInstanceOf(UnauthorizedError);

  expect(getStoredCredentials()).toBeNull();
  expect(listener).toHaveBeenCalledOnce();
  window.removeEventListener(AUTH_REQUIRED_EVENT, listener);
});
