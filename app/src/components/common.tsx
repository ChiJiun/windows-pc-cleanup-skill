// 小型共用元件：錯誤訊息、提示、狀態標籤、輸出區塊、讀取中圖示。
import type { ReactNode } from "react";
import type { RunStatus } from "../cleanup";
import { useI18n, type MsgKey } from "../i18n";

export function ErrorBanner({ message, onClose }: { message: string | null; onClose?: () => void }) {
  const { t } = useI18n();
  if (!message) return null;
  return (
    <div className="banner banner-error" role="alert">
      <div className="banner-body">
        <strong>{t("common.error")}</strong>
        <span className="pre-wrap">{message}</span>
      </div>
      {onClose && (
        <button type="button" className="btn-ghost btn-sm" onClick={onClose} aria-label={t("common.close")}>
          ×
        </button>
      )}
    </div>
  );
}

export function Notice({ kind = "info", children }: { kind?: "info" | "warn" | "ok" | "error"; children: ReactNode }) {
  return (
    <div className={`banner banner-${kind}`}>
      <div>{children}</div>
    </div>
  );
}

export function Spinner({ label }: { label?: string }) {
  return (
    <span className="spinner-wrap" role="status">
      <span className="spinner" aria-hidden="true" />
      {label && <span>{label}</span>}
    </span>
  );
}

const STATUS_KEY: Record<RunStatus, MsgKey> = {
  pending: "status.pending",
  running: "status.running",
  ok: "status.ok",
  failed: "status.failed",
  cancelled: "status.cancelled",
  skipped: "status.skipped",
};

export function StatusPill({ status, label }: { status: RunStatus; label?: string }) {
  const { t } = useI18n();
  return (
    <span className={`pill pill-${status}`}>
      {status === "running" && <span className="spinner spinner-sm" aria-hidden="true" />}
      {label ?? t(STATUS_KEY[status])}
    </span>
  );
}

/** 可展開的文字輸出（腳本輸出、錯誤訊息）。以純文字顯示，不解析 HTML。 */
export function OutputBox({ text, summary, open }: { text: string; summary?: string; open?: boolean }) {
  const { t } = useI18n();
  if (!text) return null;
  const max = 20000;
  const shown = text.length > max ? text.slice(0, max) + "\n…" : text;
  return (
    <details className="output" open={open}>
      <summary>{summary ?? t("common.showOutput")}</summary>
      <pre>{shown}</pre>
    </details>
  );
}
