import { buildAuthorizationHeader, dispatchAuthRequired } from "./auth";

export class UnauthorizedError extends Error {
  constructor() {
    super("authentication required");
    this.name = "UnauthorizedError";
  }
}

export async function authorizedFetch(input: RequestInfo | URL, init: RequestInit = {}) {
  const headers = new Headers(init.headers);
  const authorization = buildAuthorizationHeader();

  if (authorization) {
    headers.set("Authorization", authorization);
  }

  const response = await fetch(input, { ...init, headers });
  if (response.status === 401) {
    dispatchAuthRequired();
    throw new UnauthorizedError();
  }
  return response;
}
