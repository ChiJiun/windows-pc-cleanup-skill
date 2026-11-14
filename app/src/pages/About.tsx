// 關於與贊助。
import { useEffect, useState } from "react";
import type { AppInfo } from "../api";
import { api } from "../backend";
import { ErrorBanner } from "../components/common";
import { errorText } from "../format";
import { funding } from "../funding";
import { useI18n } from "../i18n";

const REPO_URL = "https://github.com/ChiJiun/windows-pc-cleanup-skill";

/** 帳號名稱只允許 GitHub / Ko-fi 合法字元，避免組出奇怪的網址 */
const safeName = (s: string) => (/^[A-Za-z0-9_-]{1,64}$/.test(s.trim()) ? s.trim() : "");

export function About() {
  const { t } = useI18n();
  const [info, setInfo] = useState<AppInfo | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .appInfo()
      .then(setInfo)
      .catch((e) => setError(errorText(e)));
  }, []);

  async function openUrl(url: string) {
    setError(null);
    try {
      await api.openUrl(url);
    } catch (e) {
      setError(errorText(e));
    }
  }

  const gh = safeName(funding.githubSponsors);
  const kofi = safeName(funding.kofi);

  return (
    <div className="page">
      <header className="page-head">
        <h1>{t("about.title")}</h1>
        <p className="muted">{t("about.tagline")}</p>
      </header>
      <ErrorBanner message={error} onClose={() => setError(null)} />

      <section className="card">
        <h2>{t("about.app")}</h2>
        <dl className="kv">
          <div>
            <dt>{t("about.version")}</dt>
            <dd>{info?.version ?? "—"}</dd>
          </div>
          <div>
            <dt>{t("about.license")}</dt>
            <dd>MIT</dd>
          </div>
          {info && (
            <div>
              <dt>{t("about.admin")}</dt>
              <dd>{info.isAdmin ? t("common.yes") : t("common.no")}</dd>
            </div>
          )}
          {info?.sessionsRoot && (
            <div>
              <dt>{t("about.sessions")}</dt>
              <dd className="path" title={info.sessionsRoot}>
                {info.sessionsRoot}
              </dd>
            </div>
          )}
        </dl>
        <p className="small">{t("about.principle")}</p>
        <div className="actions">
          <button type="button" className="btn" onClick={() => openUrl(REPO_URL)}>
            {t("about.github")}
          </button>
          <span className="muted small path">{REPO_URL}</span>
        </div>
      </section>

      <section className="card">
        <h2>{t("about.sponsor")}</h2>
        <p className="small">{t("about.sponsorDesc")}</p>
        {gh || kofi ? (
          <div className="actions">
            {gh && (
              <button type="button" className="btn-primary" onClick={() => openUrl(`https://github.com/sponsors/${gh}`)}>
                GitHub Sponsors
              </button>
            )}
            {kofi && (
              <button type="button" className="btn-primary" onClick={() => openUrl(`https://ko-fi.com/${kofi}`)}>
                Ko-fi
              </button>
            )}
          </div>
        ) : (
          <p className="muted">{t("about.sponsorSoon")}</p>
        )}
      </section>
    </div>
  );
}
