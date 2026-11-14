// AI 助理的工具呼叫卡片：可展開看參數與結果。
import type { ToolCall } from "../api";
import type { ItemRun } from "../cleanup";
import { useI18n, toolLabel } from "../i18n";
import { StatusPill } from "./common";

function argsSummary(args: Record<string, unknown>): string {
  const parts = Object.entries(args).map(([k, v]) => {
    const s = typeof v === "string" ? v : JSON.stringify(v);
    return `${k}=${s && s.length > 40 ? s.slice(0, 40) + "…" : s}`;
  });
  return parts.join("  ");
}

export function ToolCard({ call, run }: { call: ToolCall; run?: ItemRun }) {
  const { t } = useI18n();
  const status = run?.status ?? "pending";
  const output = run?.result?.output ?? "";
  const summaryLine = run?.error ?? output.trim().split("\n").filter(Boolean).slice(-1)[0] ?? "";
  const max = 20000;
  return (
    <details className="tool-card">
      <summary>
        <StatusPill status={status} />
        <span className="tool-name">{toolLabel(t, call.name)}</span>
        <code className="tool-id">{call.name}</code>
        {call.arguments && Object.keys(call.arguments).length > 0 && (
          <span className="tool-args muted">{argsSummary(call.arguments)}</span>
        )}
      </summary>
      <div className="tool-body">
        <div className="small muted">{t("chat.toolArgs")}</div>
        <pre>{JSON.stringify(call.arguments ?? {}, null, 2)}</pre>
        {run?.result?.cancelled && <p className="small">{t("chat.toolCancelledNote")}</p>}
        {summaryLine && (
          <>
            <div className="small muted">{t("chat.toolResult")}</div>
            {run?.error ? (
              <pre className="error-text">{run.error}</pre>
            ) : (
              <pre>{output.length > max ? output.slice(0, max) + "\n…" : output}</pre>
            )}
          </>
        )}
      </div>
    </details>
  );
}
