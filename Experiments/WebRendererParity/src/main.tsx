import { createRoot } from "react-dom/client";
import "katex/dist/katex.min.css";
import App from "./App";
import "./styles.css";
import "./conversation.css";

const root = document.getElementById("root");

if (!root) {
  throw new Error("Missing #root element");
}

const reactRoot = createRoot(root);

reactRoot.render(
  <App />
);

window.addEventListener(
  "beforeunload",
  () => {
    reactRoot.unmount();
  },
  { once: true }
);
