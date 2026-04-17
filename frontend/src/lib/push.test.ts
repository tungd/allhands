import { normalizePermission } from "./push";


test("maps denied permissions to an unsubscribed state", () => {
  expect(normalizePermission("denied")).toBe("unsubscribed");
});
