import { render } from "solid-js/web";

import { App } from "./app";

if ("serviceWorker" in navigator) {
  void navigator.serviceWorker.register("/sw.js");
}

render(() => <App />, document.getElementById("root")!);
