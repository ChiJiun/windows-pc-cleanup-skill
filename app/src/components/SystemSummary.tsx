// 掃描摘要：系統資訊、各磁碟可用空間、健檢發現。
import type { Finding, Health, Overview } from "../api";
import { formatBytes } from "../format";
import { useI18n, type MsgKey } from "../i18n";

export function OverviewInfo({ overview }: { overview: Overview }) {
  const { t } = useI18n();
  const rows: [MsgKey, string][] = [
    ["summary.os", overview.os],
    ["summary.model", overview.model],
    ["summary.cpu", overview.cpu],
    ["summary.ram", formatBytes(overview.ramTotalBytes)],
  ];
  return (
    <dl className="kv">
      {rows
        .filter(([, v]) => v)
        .map(([k, v]) => (
          <div key={k}>
            <dt>{t(k)}</dt>
            <dd>{v}</dd>
          </div>
        ))}
    </dl>
  );
}

export function DriveList({ drives }: { drives: NonNullable<Overview["drives"]> }) {
  const { t } = useI18n();
  if (!drives.length) return <p className="muted">{t("summary.noDrives")}</p>;
  return (
    <ul className="drives">
      {drives.map((d) => {
        const size = d.SizeBytes && d.SizeBytes > 0 ? d.SizeBytes : null;
        const usedPct = size ? Math.min(100, Math.max(0, ((size - d.FreeBytes) / size) * 100)) : null;
        const freePct = size ? (d.FreeBytes / size) * 100 : null;
        const level = freePct === null ? "" : freePct < 10 ? "crit" : freePct < 20 ? "warn" : "";
        return (
          <li key={d.Drive} className="drive">
            <div className="drive-head">
              <strong>{d.Drive}</strong>
              <span className="muted">
                {size
                  ? t("summary.driveFreeOf", { free: formatBytes(d.FreeBytes), size: formatBytes(size) })
                  : t("summary.driveFree", { free: formatBytes(d.FreeBytes) })}
              </span>
            </div>
            {usedPct !== null && (
              <div className={`bar ${level}`} aria-hidden="true">
                <span style={{ width: `${usedPct}%` }} />
              </div>
            )}
          </li>
        );
      })}
    </ul>
  );
}

const SEV_KEY: Record<Finding["Severity"], MsgKey> = {
  critical: "severity.critical",
  warn: "severity.warn",
  info: "severity.info",
};

export function FindingList({ health }: { health: Health }) {
  const { t } = useI18n();
  return (
    <div>
      {health.uptimeHours > 0 && (
        <p className="muted small">{t("summary.uptime", { h: Math.round(health.uptimeHours) })}</p>
      )}
      {health.findings.length === 0 ? (
        <p className="muted">{t("summary.noFindings")}</p>
      ) : (
        <ul className="findings">
          {health.findings.map((f, i) => (
            <li key={i} className={`finding sev-${f.Severity}`}>
              <div className="finding-head">
                <span className={`sev-badge sev-${f.Severity}`}>{t(SEV_KEY[f.Severity])}</span>
                <strong>{f.Title}</strong>
                {f.Area && <span className="muted small">{f.Area}</span>}
              </div>
              {f.Detail && <p className="pre-wrap">{f.Detail}</p>}
              {f.Advice && (
                <p className="advice pre-wrap">
                  <span className="muted">{t("summary.advice")}</span>
                  {f.Advice}
                </p>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
