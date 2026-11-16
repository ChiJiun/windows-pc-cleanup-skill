// 設定：語言、AI 供應商與模型、API key、遮蔽、MCP 設定片段。
import { useEffect, useState } from "react";
import type { Lang, ProviderId, ProviderPreset, Settings as SettingsT } from "../api";
import { api } from "../backend";
import { ErrorBanner, Notice, Spinner } from "../components/common";
import { ConnectCard } from "../components/ConnectCard";
import { errorText } from "../format";
import { useI18n } from "../i18n";

interface Props {
  settings: SettingsT | null;
  presets: ProviderPreset[];
  onSaved: (s: SettingsT) => void;
  onKeyChanged: (provider: ProviderId) => void;
}

async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // webview 不允許 clipboard API 時退回舊方法
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try {
      ok = document.execCommand("copy");
    } catch {
      ok = false;
    }
    document.body.removeChild(ta);
    return ok;
  }
}

export function Settings({ settings, presets, onSaved, onKeyChanged }: Props) {
  const { t, lang, setLang } = useI18n();
  const [draft, setDraft] = useState<SettingsT | null>(settings);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [savedMsg, setSavedMsg] = useState(false);
  const [models, setModels] = useState<string[] | null>(null);
  const [loadingModels, setLoadingModels] = useState(false);
  const [keyInput, setKeyInput] = useState("");
  const [draftHasKey, setDraftHasKey] = useState<boolean | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [mcp, setMcp] = useState<string>("");
  const [mcpError, setMcpError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  // 設定第一次載入時建立草稿；之後（例如切換語言）只同步語言，不蓋掉尚未儲存的修改
  useEffect(() => {
    setDraft((prev) => (prev && settings ? { ...prev, lang: settings.lang } : settings));
  }, [settings]);

  useEffect(() => {
    api
      .mcpConfig()
      .then(setMcp)
      .catch((e) => setMcpError(errorText(e)));
  }, []);

  const provider = draft?.provider;
  useEffect(() => {
    if (!provider) return;
    setDraftHasKey(null);
    setConfirmDelete(false);
    api
      .hasApiKey(provider)
      .then(setDraftHasKey)
      .catch((e) => setError(errorText(e)));
  }, [provider]);

  const preset = draft ? presets.find((p) => p.id === draft.provider) : undefined;
  const dirty =
    !!draft &&
    !!settings &&
    (draft.provider !== settings.provider ||
      draft.model !== settings.model ||
      draft.baseUrl !== settings.baseUrl ||
      draft.redact !== settings.redact);
  const showBaseUrl = !!preset && (preset.local || preset.id === "custom");
  const showKey = !!preset && (preset.needsKey || preset.id === "custom");

  async function changeLang(l: Lang) {
    setLang(l);
    if (!settings) return;
    const next = { ...settings, lang: l };
    try {
      await api.saveSettings(next);
      onSaved(next);
    } catch (e) {
      setError(errorText(e));
    }
  }

  async function save(): Promise<boolean> {
    if (!draft) return false;
    setSaving(true);
    setError(null);
    try {
      // 模型留空時帶入該供應商的預設模型（輸入框的 placeholder 顯示的就是它）
      const model = draft.model.trim() || preset?.defaultModel || "";
      const next: SettingsT = { ...draft, lang, model, baseUrl: draft.baseUrl.trim() };
      setDraft(next);
      await api.saveSettings(next);
      onSaved(next);
      setSavedMsg(true);
      window.setTimeout(() => setSavedMsg(false), 2000);
      return true;
    } catch (e) {
      setError(errorText(e));
      return false;
    } finally {
      setSaving(false);
    }
  }

  async function fetchModels() {
    // listModels 依後端已儲存的設定查詢，所以先儲存草稿
    if (dirty && !(await save())) return;
    setLoadingModels(true);
    setError(null);
    try {
      setModels(await api.listModels());
    } catch (e) {
      setError(errorText(e));
      setModels(null);
    } finally {
      setLoadingModels(false);
    }
  }

  function changeProvider(id: ProviderId) {
    const p = presets.find((x) => x.id === id);
    setModels(null);
    setKeyInput("");
    setDraft((d) => (d ? { ...d, provider: id, model: p?.defaultModel ?? "", baseUrl: "" } : d));
  }

  async function saveKey() {
    if (!draft || !keyInput.trim()) return;
    setError(null);
    try {
      await api.setApiKey(draft.provider, keyInput.trim());
      setKeyInput("");
      setDraftHasKey(await api.hasApiKey(draft.provider));
      onKeyChanged(draft.provider);
    } catch (e) {
      setKeyInput("");
      setError(errorText(e));
    }
  }

  async function deleteKey() {
    if (!draft) return;
    setError(null);
    setConfirmDelete(false);
    try {
      await api.deleteApiKey(draft.provider);
      setDraftHasKey(await api.hasApiKey(draft.provider));
      onKeyChanged(draft.provider);
    } catch (e) {
      setError(errorText(e));
    }
  }

  // 一鍵連結改了供應商或模型：已經存好，同步上層；草稿只更新供應商、模型、位址，其他尚未儲存的修改（例如遮蔽開關）保留
  function applied(s: SettingsT) {
    setModels(null);
    setKeyInput("");
    setDraft((d) => (d ? { ...d, provider: s.provider, model: s.model, baseUrl: s.baseUrl } : s));
    onSaved(s);
  }

  async function copyMcp() {
    if (!mcp) return;
    const ok = await copyText(mcp);
    setCopied(ok);
    if (!ok) setMcpError(t("settings.copyFailed"));
    window.setTimeout(() => setCopied(false), 2000);
  }

  return (
    <div className="page">
      <header className="page-head">
        <h1>{t("settings.title")}</h1>
      </header>

      <ErrorBanner message={error} onClose={() => setError(null)} />

      <section className="card">
        <h2>{t("settings.language")}</h2>
        <div className="form-row">
          <label htmlFor="lang">{t("settings.language")}</label>
          <select id="lang" value={lang} onChange={(e) => changeLang(e.target.value as Lang)}>
            <option value="zh-TW">繁體中文</option>
            <option value="en">English</option>
          </select>
        </div>
      </section>

      <ConnectCard
        settings={settings}
        onApplied={applied}
        onKeyChanged={() => {
          onKeyChanged("openrouter");
          if (draft?.provider === "openrouter") api.hasApiKey("openrouter").then(setDraftHasKey).catch(() => {});
        }}
      />

      <section className="card">
        <h2>{t("settings.ai")}</h2>
        {!draft ? (
          <p className="muted">{t("settings.notLoaded")}</p>
        ) : (
          <>
            <div className="form-row">
              <label htmlFor="provider">{t("settings.provider")}</label>
              <select id="provider" value={draft.provider} onChange={(e) => changeProvider(e.target.value as ProviderId)}>
                {presets.length === 0 && <option value={draft.provider}>{draft.provider}</option>}
                {presets.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.label}
                    {p.local ? ` (${t("settings.localTag")})` : ""}
                  </option>
                ))}
              </select>
            </div>
            {preset && (
              <p className="muted small form-hint">
                {preset.local ? t("settings.localHint") : t("settings.cloudHint", { provider: preset.label })}
              </p>
            )}

            <div className="form-row">
              <label htmlFor="model">{t("settings.model")}</label>
              <div className="input-group">
                <input
                  id="model"
                  type="text"
                  list="model-list"
                  value={draft.model}
                  placeholder={preset?.defaultModel}
                  spellCheck={false}
                  onChange={(e) => setDraft({ ...draft, model: e.target.value })}
                />
                <button type="button" className="btn" onClick={fetchModels} disabled={loadingModels || saving}>
                  {t("settings.listModels")}
                </button>
              </div>
              <datalist id="model-list">
                {(models ?? []).map((m) => (
                  <option key={m} value={m} />
                ))}
              </datalist>
            </div>
            {loadingModels && <Spinner label={t("settings.loadingModels")} />}
            {models && !loadingModels && (
              <div className="form-hint">
                {models.length === 0 ? (
                  <span className="muted small">{t("settings.noModels")}</span>
                ) : (
                  <>
                    <span className="muted small">{t("settings.modelsFound", { n: models.length })}</span>
                    <div className="chips">
                      {models.slice(0, 60).map((m) => (
                        <button
                          key={m}
                          type="button"
                          className={`chip ${m === draft.model ? "chip-on" : ""}`}
                          onClick={() => setDraft({ ...draft, model: m })}
                        >
                          {m}
                        </button>
                      ))}
                    </div>
                  </>
                )}
              </div>
            )}

            {showBaseUrl && (
              <div className="form-row">
                <label htmlFor="baseUrl">{t("settings.baseUrl")}</label>
                <input
                  id="baseUrl"
                  type="text"
                  value={draft.baseUrl}
                  placeholder={preset?.defaultBaseUrl || "https://"}
                  spellCheck={false}
                  onChange={(e) => setDraft({ ...draft, baseUrl: e.target.value })}
                />
              </div>
            )}
            {showBaseUrl && <p className="muted small form-hint">{t("settings.baseUrlHint")}</p>}

            <div className="form-row">
              <span className="label">{t("settings.redact")}</span>
              <label className="switch">
                <input type="checkbox" checked={draft.redact} onChange={(e) => setDraft({ ...draft, redact: e.target.checked })} />
                <span>{t("settings.redactLabel")}</span>
              </label>
            </div>
            <p className="muted small form-hint">{t("settings.redactHint")}</p>

            <div className="actions">
              <button type="button" className="btn-primary" onClick={save} disabled={!dirty || saving}>
                {t("common.save")}
              </button>
              {saving && <Spinner />}
              {savedMsg && <span className="ok-text small">{t("settings.saved")}</span>}
              {dirty && !saving && <span className="muted small">{t("settings.unsaved")}</span>}
            </div>
          </>
        )}
      </section>

      {draft && showKey && preset && (
        <section className="card">
          <h2>{t("settings.apiKey")}</h2>
          <p className="small">
            {t("settings.keyStatusFor", { provider: preset.label })}{" "}
            {draftHasKey === null ? (
              <span className="muted">…</span>
            ) : draftHasKey ? (
              <span className="pill pill-ok">{t("settings.keySet")}</span>
            ) : (
              <span className="pill pill-pending">{t("settings.keyNotSet")}</span>
            )}
          </p>
          <div className="form-row">
            <label htmlFor="apikey">{t("settings.apiKey")}</label>
            <div className="input-group">
              <input
                id="apikey"
                type="password"
                autoComplete="off"
                value={keyInput}
                placeholder={t("settings.keyPlaceholder")}
                onChange={(e) => setKeyInput(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") void saveKey();
                }}
              />
              <button type="button" className="btn-primary" onClick={saveKey} disabled={!keyInput.trim()}>
                {t("common.save")}
              </button>
            </div>
          </div>
          <p className="muted small form-hint">{t("settings.keyHint")}</p>
          {draftHasKey && (
            <div className="actions">
              {confirmDelete ? (
                <>
                  <span className="small">{t("settings.deleteKeyConfirm")}</span>
                  <button type="button" className="btn-danger btn-sm" onClick={deleteKey}>
                    {t("settings.deleteKeyYes")}
                  </button>
                  <button type="button" className="btn-ghost btn-sm" onClick={() => setConfirmDelete(false)}>
                    {t("common.cancel")}
                  </button>
                </>
              ) : (
                <button type="button" className="btn-ghost btn-sm" onClick={() => setConfirmDelete(true)}>
                  {t("settings.deleteKey")}
                </button>
              )}
            </div>
          )}
        </section>
      )}

      <section className="card">
        <h2>{t("settings.mcp")}</h2>
        <p className="small">{t("settings.mcpDesc")}</p>
        <p className="muted small">{t("settings.mcpOthers")}</p>
        {mcp ? (
          <>
            <pre className="code-block">{mcp}</pre>
            <div className="actions">
              <button type="button" className="btn" onClick={copyMcp}>
                {copied ? t("settings.copied") : t("settings.copy")}
              </button>
            </div>
          </>
        ) : (
          !mcpError && <Spinner />
        )}
        {mcpError && <Notice kind="error">{mcpError}</Notice>}
      </section>
    </div>
  );
}
