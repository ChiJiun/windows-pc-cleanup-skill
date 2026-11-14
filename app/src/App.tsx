// 主畫面：左側導覽 + 四個分頁。分頁切換時只隱藏不卸載，掃描結果與對話不會因為切頁而消失。
import { useCallback, useEffect, useState, type ReactNode } from "react";
import "./App.css";
import type { ProviderId, ProviderPreset, Settings as SettingsT } from "./api";
import { api, isUsingMock } from "./backend";
import { ErrorBanner } from "./components/common";
import { IconBroom, IconChat, IconInfo, IconSettings, IconWizard } from "./components/Icons";
import { errorText } from "./format";
import { useI18n, type MsgKey } from "./i18n";
import { About } from "./pages/About";
import { Chat } from "./pages/Chat";
import { Settings } from "./pages/Settings";
import { Wizard } from "./pages/Wizard";

type Page = "wizard" | "chat" | "settings" | "about";

const NAV: { id: Page; label: MsgKey; icon: () => ReactNode }[] = [
  { id: "wizard", label: "nav.wizard", icon: IconWizard },
  { id: "chat", label: "nav.chat", icon: IconChat },
  { id: "settings", label: "nav.settings", icon: IconSettings },
  { id: "about", label: "nav.about", icon: IconInfo },
];

interface Props {
  initialSettings: SettingsT | null;
  initialError: string | null;
}

export default function App({ initialSettings, initialError }: Props) {
  const { t } = useI18n();
  const [page, setPage] = useState<Page>("wizard");
  const [settings, setSettings] = useState<SettingsT | null>(initialSettings);
  const [presets, setPresets] = useState<ProviderPreset[]>([]);
  const [hasKey, setHasKey] = useState<boolean | null>(null);
  const [error, setError] = useState<string | null>(initialError);

  useEffect(() => {
    api
      .providerPresets()
      .then(setPresets)
      .catch((e) => setError(errorText(e)));
  }, []);

  const refreshKey = useCallback((provider: ProviderId) => {
    api
      .hasApiKey(provider)
      .then(setHasKey)
      .catch(() => setHasKey(null));
  }, []);

  const provider = settings?.provider;
  useEffect(() => {
    if (provider) refreshKey(provider);
  }, [provider, refreshKey]);

  return (
    <div className="app">
      <nav className="sidebar" aria-label={t("app.name")}>
        <div className="brand">
          <IconBroom />
          <span>{t("app.name")}</span>
        </div>
        <ul>
          {NAV.map((n) => (
            <li key={n.id}>
              <button
                type="button"
                className={`nav-item ${page === n.id ? "active" : ""}`}
                aria-current={page === n.id ? "page" : undefined}
                onClick={() => setPage(n.id)}
              >
                <n.icon />
                <span>{t(n.label)}</span>
              </button>
            </li>
          ))}
        </ul>
        {isUsingMock() && <div className="mock-tag">{t("app.mock")}</div>}
      </nav>

      <main className="content">
        <ErrorBanner message={error} onClose={() => setError(null)} />
        <div hidden={page !== "wizard"}>
          <Wizard />
        </div>
        <div hidden={page !== "chat"} className="fill">
          <Chat settings={settings} presets={presets} hasKey={hasKey} onGoSettings={() => setPage("settings")} />
        </div>
        <div hidden={page !== "settings"}>
          <Settings
            settings={settings}
            presets={presets}
            onSaved={setSettings}
            onKeyChanged={(p) => {
              if (p === settings?.provider) refreshKey(p);
            }}
          />
        </div>
        <div hidden={page !== "about"}>
          <About />
        </div>
      </main>
    </div>
  );
}
