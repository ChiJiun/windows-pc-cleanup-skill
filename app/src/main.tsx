import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import type { Settings } from "./api";
import { api, initBackend } from "./backend";
import { errorText } from "./format";
import { I18nProvider, detectLang } from "./i18n";

async function boot() {
  await initBackend();
  let settings: Settings | null = null;
  let error: string | null = null;
  try {
    settings = await api.getSettings();
  } catch (e) {
    error = errorText(e);
  }
  const lang = settings?.lang === "en" || settings?.lang === "zh-TW" ? settings.lang : detectLang();
  document.documentElement.lang = lang;

  ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
    <React.StrictMode>
      <I18nProvider initial={lang}>
        <App initialSettings={settings} initialError={error} />
      </I18nProvider>
    </React.StrictMode>,
  );
}

void boot();
