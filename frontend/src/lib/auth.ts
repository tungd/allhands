export type BasicCredentials = {
  username: string;
  password: string;
};

const STORAGE_KEY = "allhands.basic-auth";

export const AUTH_REQUIRED_EVENT = "allhands:auth-required";

function isValidNextPath(value: string) {
  return value.startsWith("/") && !value.startsWith("//");
}

export function resolveNextPath(value: string | null | undefined, fallback = "/control-room") {
  if (!value || !isValidNextPath(value)) {
    return fallback;
  }
  return value;
}

export function buildLoginPath(next: string) {
  return `/login?next=${encodeURIComponent(resolveNextPath(next))}`;
}

export function getStoredCredentials(): BasicCredentials | null {
  const raw = globalThis.localStorage?.getItem(STORAGE_KEY);
  if (!raw) {
    return null;
  }

  try {
    const parsed = JSON.parse(raw) as Partial<BasicCredentials>;
    if (typeof parsed.username !== "string" || typeof parsed.password !== "string") {
      return null;
    }
    return parsed;
  } catch {
    return null;
  }
}

export function storeCredentials(credentials: BasicCredentials) {
  globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify(credentials));
}

export function clearStoredCredentials() {
  globalThis.localStorage?.removeItem(STORAGE_KEY);
}

export function buildAuthorizationHeader(credentials = getStoredCredentials()) {
  if (credentials == null) {
    return null;
  }
  return `Basic ${btoa(`${credentials.username}:${credentials.password}`)}`;
}

export function requireStoredCredentials() {
  const credentials = getStoredCredentials();
  if (credentials == null) {
    return null;
  }
  return credentials;
}

export function dispatchAuthRequired() {
  clearStoredCredentials();
  globalThis.window?.dispatchEvent(new CustomEvent(AUTH_REQUIRED_EVENT));
}
