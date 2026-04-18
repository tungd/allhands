import { render, screen, within } from "@solidjs/testing-library";

import { ControlRoom } from "./control-room";


test("renders the focused session and quick switch tray", () => {
  render(() => (
    <ControlRoom
      sessions={[
        { id: "a", title: "API Refactor", status: "attention_required" },
        { id: "b", title: "Docs Cleanup", status: "running" }
      ]}
      sheetOpen={false}
    />
  ));

  const focused = screen.getByLabelText("Focused session");

  expect(within(focused).getByText("API Refactor")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Docs Cleanup" })).toBeTruthy();
  expect((screen.getByRole("link", { name: "New session" }) as HTMLAnchorElement).getAttribute("href")).toBe(
    "/control-room/new"
  );
});
