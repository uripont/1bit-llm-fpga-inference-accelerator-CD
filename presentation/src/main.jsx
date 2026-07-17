import React from "react";
import { createRoot } from "react-dom/client";
import "reveal.js/dist/reveal.css";
import "./styles.css";
import "./model-output.css";
import App from "./App";

createRoot(document.getElementById("root")).render(<App />);
