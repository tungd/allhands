import { render, screen } from "@solidjs/testing-library";

import { SessionRoute } from "./session";


test("renders timeline activity and a prompt box", () => {
  render(() => <SessionRoute items={[{ id: "evt-1", body: "Need approval" }]} />);

  expect(screen.getByText("Need approval")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Send" })).toBeTruthy();
});
