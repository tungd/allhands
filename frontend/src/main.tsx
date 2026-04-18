import { render } from "solid-js/web";

import { App } from "./app";
import { getServerInfo } from "./lib/api";

if ("serviceWorker" in navigator) {
  void navigator.serviceWorker.register("/sw.js");
}

async function bootstrap() {
  const info = await getServerInfo().catch(() => ({ vapidPublicKey: "" }));
  render(() => <App vapidPublicKey={info.vapidPublicKey} />, document.getElementById("root")!);
}

void bootstrap();
