// 清理精靈用的資料整理與判斷規則。
import type { CleanupTarget, CleanupTargets, Finding, Health, OrganizePlan, Overview, PlanRow, ToolName, ToolResult } from "./api";
import { asArray, isObject } from "./format";

/** 清理舊檔時的天數門檻 */
export const OLDER_THAN_DAYS = 7;

export type RunStatus = "pending" | "running" | "ok" | "failed" | "cancelled" | "skipped";

export interface ItemRun {
  status: RunStatus;
  result?: ToolResult;
  error?: string;
}

export function runStatusOf(r: ToolResult): RunStatus {
  if (r.cancelled) return "cancelled";
  return r.ok ? "ok" : "failed";
}

/** 只有 A 類、後端判定可自動清理、而且沒有相關程式在執行的項目可以勾選 */
export function isSelectable(t: CleanupTarget): boolean {
  return (
    t.Risk === "A" && (t.Action === "clear-folder" || t.Action === "clean-old-files") && t.RunningApps.length === 0
  );
}

/** 預計可釋放的大小：清空資料夾是整個資料夾，清舊檔只算舊檔 */
export function expectedBytes(t: CleanupTarget): number {
  return t.Action === "clean-old-files" ? t.OldBytes : t.Bytes;
}

export function cleanupTool(t: CleanupTarget): ToolName {
  return t.Action === "clear-folder" ? "clear_folder" : "clean_old_files";
}

/** apply 為 false 時不帶 apply 參數（試跑） */
export function cleanupArgs(t: CleanupTarget, apply: boolean): Record<string, unknown> {
  const base: Record<string, unknown> =
    t.Action === "clear-folder"
      ? { path: t.RealPath, label: t.Name, processNames: t.Procs }
      : { path: t.RealPath, olderThanDays: OLDER_THAN_DAYS };
  return apply ? { ...base, apply: true } : base;
}

const num = (x: unknown): number => (typeof x === "number" && Number.isFinite(x) ? x : 0);
const str = (x: unknown): string => (typeof x === "string" ? x : x == null ? "" : String(x));

export function parseOverview(data: unknown): Overview | null {
  if (!isObject(data)) return null;
  return {
    os: str(data.os),
    model: str(data.model),
    cpu: str(data.cpu),
    ramTotalBytes: num(data.ramTotalBytes),
    drives: asArray<Record<string, unknown>>(data.drives)
      .filter(isObject)
      .map((d) => ({
        Drive: str(d.Drive),
        FreeBytes: num(d.FreeBytes),
        SizeBytes: typeof d.SizeBytes === "number" ? d.SizeBytes : undefined,
      })),
  };
}

export function parseTargets(data: unknown): CleanupTargets | null {
  if (!isObject(data)) return null;
  const targets = asArray<Record<string, unknown>>(data.targets)
    .filter(isObject)
    .map(
      (t, i): CleanupTarget => ({
        Id: str(t.Id) || `item-${i}`,
        Name: str(t.Name),
        Path: str(t.Path),
        RealPath: str(t.RealPath) || str(t.Path),
        Bytes: num(t.Bytes),
        OldBytes: num(t.OldBytes),
        Files: num(t.Files),
        Risk: t.Risk === "A" ? "A" : "B",
        Method: str(t.Method),
        Action: t.Action === "clear-folder" || t.Action === "clean-old-files" ? t.Action : "manual",
        Procs: asArray<unknown>(t.Procs).map(str).filter(Boolean),
        RunningApps: asArray<unknown>(t.RunningApps).map(str).filter(Boolean),
      }),
    );
  const rb = isObject(data.recycleBin) ? data.recycleBin : {};
  return {
    targets,
    recycleBin: { Count: num(rb.Count), Bytes: num(rb.Bytes) },
    isAdmin: data.isAdmin === true,
  };
}

const SEVERITY_ORDER: Record<Finding["Severity"], number> = { critical: 0, warn: 1, info: 2 };

export function parseHealth(data: unknown): Health | null {
  if (!isObject(data)) return null;
  const findings = asArray<Record<string, unknown>>(data.findings)
    .filter(isObject)
    .map(
      (f): Finding => ({
        Severity: f.Severity === "critical" || f.Severity === "warn" ? f.Severity : "info",
        Area: str(f.Area),
        Title: str(f.Title),
        Detail: str(f.Detail),
        Advice: str(f.Advice),
      }),
    )
    .sort((a, b) => SEVERITY_ORDER[a.Severity] - SEVERITY_ORDER[b.Severity]);
  return { findings, uptimeHours: num(data.uptimeHours) };
}

export function parsePlan(data: unknown): OrganizePlan | null {
  if (!isObject(data)) return null;
  const rows = asArray<Record<string, unknown>>(data.rows)
    .filter(isObject)
    .map(
      (r): PlanRow => ({
        Source: str(r.Source),
        Action: r.Action === "Recycle" ? "Recycle" : "Move",
        Dest: str(r.Dest),
        Reason: str(r.Reason),
        Category: str(r.Category),
        Keep: str(r.Keep),
      }),
    );
  return { planFile: str(data.planFile), rows };
}
