// 一鍵連結：用 OpenRouter 登入、加入 Claude Desktop、使用地端模型。
import { useEffect, useState } from "react";
import type { ClaudeDesktopStatus, LocalServer, Settings } from "../api";
import { api } from "../backend";
import { errorText } from "../format";
import { useI18n } from "../i18n";
import { Notice, Spinner } from "./common";

interface Props {
  settings: Settings | null;
  /** 設定被這裡改掉（切換供應商或模型）時通知上層，讓設定頁同步草稿 */
  onApplied: (s: Settings) => void;
  onKeyChanged: () => void;
}

export function ConnectCard({ settings, onApplied, onKeyChanged }: Props) {
  const { t } = useI18n();
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);

  // OpenRouter
  const [orBusy, setOrBusy] = useState(false);
  const [orHasKey, setOrHasKey] = useState(false);

  // Claude Desktop
  const [cd, setCd] = useState<ClaudeDesktopStatus | null>(null);
  const [cdBusy, setCdBusy] = useState(false);

  // 地端模型
  const [local, setLocal] = useState<LocalServer[] | null>(null);
  const [localBusy, setLocalBusy] = useState(false);

  function refresh() {
    api.hasApiKey("openrouter").then(setOrHasKey).catch(() => setOrHasKey(false));
    api.claudeDesktopStatus().then(setCd).catch((e) => setError(errorText(e)));
  }

  // 設定頁不會重新掛載，所以在視窗重新取得焦點時（例如使用者剛改完 Claude Desktop 設定切回來）重新檢查
  useEffect(() => {
    refresh();
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, []);

  async function openrouterLogin() {
    setError(null);
    setInfo(null);
    setOrBusy(true);
    try {
      await api.openrouterLogin();
      const s = await api.getSettings();
      setOrHasKey(true);
      onKeyChanged();
      onApplied(s);
      setInfo(t("connect.or.done", { model: s.model }));
    } catch (e) {
      setError(errorText(e));
    } finally {
      setOrBusy(false);
    }
  }

  async function claudeDesktop(add: boolean) {
    setError(null);
    setInfo(null);
    setCdBusy(true);
    try {
      const done = await api.claudeDesktopConnect(add);
      setInfo(done ? t("connect.cd.restart") : t("connect.cd.cancelled"));
      setCd(await api.claudeDesktopStatus());
    } catch (e) {
      setError(errorText(e));
    } finally {
      setCdBusy(false);
    }
  }

  async function detect() {
    setError(null);
    setLocalBusy(true);
    try {
      setLocal(await api.detectLocalModels());
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLocalBusy(false);
    }
  }

  async function applyLocal(server: LocalServer, model: string) {
    if (!settings) return;
    setError(null);
    // 以已儲存的設定為基礎（設定頁上尚未儲存的草稿不會被一起存進去）；
    // 原本就是同一個供應商時保留自訂的位址（例如另一台電腦上的 Ollama），換供應商時才改回預設位址
    const baseUrl = settings.provider === server.provider ? settings.baseUrl : "";
    const next: Settings = { ...settings, provider: server.provider, model, baseUrl };
    try {
      await api.saveSettings(next);
      onApplied(next);
      setInfo(t("connect.local.applied", { name: server.label, model }));
    } catch (e) {
      setError(errorText(e));
    }
  }

  const cdLabel = !cd
    ? null
    : cd.connected
      ? cd.pointsToThisExe
        ? { cls: "pill-ok", text: t("connect.cd.connected") }
        : { cls: "pill-pending", text: t("connect.cd.stale") }
      : { cls: "pill-pending", text: t("connect.cd.notConnected") };

  return (
    <section className="card">
      <h2>{t("connect.title")}</h2>
      <p className="muted small">{t("connect.intro")}</p>
      {error && <Notice kind="error">{error}</Notice>}
      {info && <Notice kind="info">{info}</Notice>}

      <h3>
        {t("connect.or.title")} {orHasKey && <span className="pill pill-ok">{t("connect.or.connected")}</span>}
      </h3>
      <p className="small">{t("connect.or.desc")}</p>
      <div className="actions">
        <button type="button" className="btn-primary" onClick={openrouterLogin} disabled={orBusy}>
          {orHasKey ? t("connect.or.relogin") : t("connect.or.button")}
        </button>
        {orBusy && (
          <>
            <Spinner label={t("connect.or.waiting")} />
            <button type="button" className="btn-ghost btn-sm" onClick={() => void api.openrouterCancel()}>
              {t("common.cancel")}
            </button>
          </>
        )}
      </div>
      {orHasKey && !orBusy && <p className="muted small">{t("connect.or.replaceHint")}</p>}

      <h3>
        {t("connect.cd.title")} {cdLabel && <span className={`pill ${cdLabel.cls}`}>{cdLabel.text}</span>}
      </h3>
      <p className="small">{t("connect.cd.desc")}</p>
      {cd && !cd.found && <p className="muted small">{t("connect.cd.notFound")}</p>}
      {cd?.invalidJson && <Notice kind="error">{t("connect.cd.invalid", { path: cd.configPath })}</Notice>}
      {cd && (!cd.found || cd.invalidJson) && (
        <div className="actions">
          <button type="button" className="btn-ghost btn-sm" onClick={refresh}>
            {t("connect.recheck")}
          </button>
        </div>
      )}
      {cd?.found && !cd.invalidJson && (
        <div className="actions">
          {(!cd.connected || !cd.pointsToThisExe) && (
            <button type="button" className="btn-primary" onClick={() => claudeDesktop(true)} disabled={cdBusy}>
              {cd.connected ? t("connect.cd.reconnect") : t("connect.cd.add")}
            </button>
          )}
          {cd.connected && (
            <button type="button" className="btn-ghost btn-sm" onClick={() => claudeDesktop(false)} disabled={cdBusy}>
              {t("connect.cd.remove")}
            </button>
          )}
          {cdBusy && <Spinner />}
          <span className="muted small">{cd.configPath}</span>
        </div>
      )}

      <h3>{t("connect.local.title")}</h3>
      <p className="small">{t("connect.local.desc")}</p>
      <div className="actions">
        <button type="button" className="btn" onClick={detect} disabled={localBusy}>
          {t("connect.local.detect")}
        </button>
        {localBusy && <Spinner />}
      </div>
      {local?.map((s) => (
        <div key={s.provider} className="form-hint">
          <strong className="small">{s.label}</strong>{" "}
          {!s.running ? (
            <span className="muted small">{t("connect.local.notRunning", { name: s.label })}</span>
          ) : s.models.length === 0 ? (
            <span className="muted small">{t("connect.local.noModels", { name: s.label })}</span>
          ) : (
            <>
              <span className="muted small">{t("connect.local.use")}</span>
              <div className="chips">
                {s.models.map((m) => (
                  <button
                    key={m}
                    type="button"
                    className={`chip ${settings?.provider === s.provider && settings.model === m ? "chip-on" : ""}`}
                    onClick={() => applyLocal(s, m)}
                  >
                    {m}
                  </button>
                ))}
              </div>
            </>
          )}
        </div>
      ))}
    </section>
  );
}
