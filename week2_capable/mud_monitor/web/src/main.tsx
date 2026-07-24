import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router";
import App from "./App";
import ProfileGate from "./ProfileGate";
import "./index.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <BrowserRouter>
      <ProfileGate>
        <App />
      </ProfileGate>
    </BrowserRouter>
  </StrictMode>,
);
