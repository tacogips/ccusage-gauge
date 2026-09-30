import { render } from "solid-js/web";
import "uno.css";
import "./styles.css";
import App from "./App";
import { applyColorScheme, readStoredColorScheme } from "./colorScheme";

applyColorScheme(document.documentElement, readStoredColorScheme());
render(() => <App />, document.getElementById("root")!);
