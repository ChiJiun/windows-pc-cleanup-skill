// 清理精靈：掃描 → 摘要 → 清理 → 整理下載資料夾（可略過）→ 報告。不需要 AI 也能完整使用。
import { useEffect, useMemo, useState } from "react";
import type { CleanupTarget, CleanupTargets, Health, OrganizePlan, Overview, ToolName, ToolResult } from "../api";
import { api } from "../backend";
import {
  OLDER_THAN_DAYS,
  cleanupArgs,
  cleanupTool,
  expectedBytes,
  isSelectable,
  parseHealth,
  parseOverview,
  parsePlan,
  parseTargets,
  runStatusOf,
  type ItemRun,
  type RunStatus,
} from "../cleanup";
import { CleanupTable } from "../components/CleanupTable";
import { PlanTable } from "../components/PlanTable";
import { DriveList, FindingList, OverviewInfo } from "../components/SystemSummary";
import { ErrorBanner, Notice, OutputBox, Spinner, StatusPill } from "../components/common";
import { dirname, errorText, formatBytes, formatSeconds, isObject } from "../format";
import { toolLabel, useI18n } from "../i18n";

const SCAN_ORDER: ToolName[] = ["start_session", "scan_overview", "scan_cleanup_targets", "scan_startup", "health_check"];

interface ScanStep {
  tool: ToolName;
  status: RunStatus;
  result?: ToolResult;
  error?: string;
  startedAt?: number;
  finishedAt?: number;
}

type CleanPhase = "select" | "previewing" | "preview" | "running" | "done";
type OrgPhase = "idle" | "planning" | "planned" | "applying" | "done" | "skipped";

export function Wizard() {
  const { t } = useI18n();

  // ---- 掃描 ----
  const [steps, setSteps] = useState<ScanStep[]>([]);
  const [scanState, setScanState] = useState<"idle" | "scanning" | "ready" | "aborted">("idle");
  const [now, setNow] = useState(() => Date.now());
  const [overview, setOverview] = useState<Overview | null>(null);
  const [targets, setTargets] = useState<CleanupTargets | null>(null);
  const [health, setHealth] = useState<Health | null>(null);

  // ---- 清理 ----
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [cleanPhase, setCleanPhase] = useState<CleanPhase>("select");
  const [cleanItems, setCleanItems] = useState<CleanupTarget[]>([]);
  const [previewRuns, setPreviewRuns] = useState<Record<string, ItemRun>>({});
  const [applyRuns, setApplyRuns] = useState<Record<string, ItemRun>>({});
  const [cleanError, setCleanError] = useState<string | null>(null);
  const [rescanning, setRescanning] = useState(false);

  // ---- 整理下載資料夾 ----
  const [orgRoot, setOrgRoot] = useState("");
  const [orgPhase, setOrgPhase] = useState<OrgPhase>("idle");
  const [plan, setPlan] = useState<OrganizePlan | null>(null);
  const [planResult, setPlanResult] = useState<ToolResult | null>(null);
  const [orgApply, setOrgApply] = useState<ItemRun | null>(null);
  const [orgError, setOrgError] = useState<string | null>(null);

  // ---- 報告 ----
  const [reportBusy, setReportBusy] = useState(false);
  const [reportPath, setReportPath] = useState<string | null>(null);
  const [sessionDir, setSessionDir] = useState<string | null>(null);
  const [reportOutput, setReportOutput] = useState<string>("");
  const [reportError, setReportError] = useState<string | null>(null);

  const scanning = scanState === "scanning";
  const busy =
    scanning ||
    rescanning ||
    cleanPhase === "previewing" ||
    cleanPhase === "running" ||
    orgPhase === "planning" ||
    orgPhase === "applying" ||
    reportBusy;

  useEffect(() => {
    if (!scanning) return;
    const id = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(id);
  }, [scanning]);

  const resetCleanup = () => {
    setSelected(new Set());
    setCleanPhase("select");
    setCleanItems([]);
    setPreviewRuns({});
    setApplyRuns({});
    setCleanError(null);
  };

  function applyScanData(tool: ToolName, data: unknown) {
    if (tool === "scan_overview") setOverview(parseOverview(data));
    else if (tool === "scan_cleanup_targets") setTargets(parseTargets(data));
    else if (tool === "health_check") setHealth(parseHealth(data));
  }

  async function runScan() {
    const updateStep = (tool: ToolName, patch: Partial<ScanStep>) =>
      setSteps((prev) => prev.map((s) => (s.tool === tool ? { ...s, ...patch } : s)));

    setSteps(SCAN_ORDER.map((tool) => ({ tool, status: "pending" })));
    setScanState("scanning");
    setOverview(null);
    setTargets(null);
    setHealth(null);
    resetCleanup();
    setPlan(null);
    setPlanResult(null);
    setOrgApply(null);
    setOrgPhase("idle");
    setReportPath(null);
    setReportOutput("");

    let aborted = false;
    for (const tool of SCAN_ORDER) {
      const startedAt = Date.now();
      setNow(startedAt);
      updateStep(tool, { status: "running", startedAt });
      try {
        const r = await api.runTool(tool);
        updateStep(tool, { status: r.ok ? "ok" : "failed", result: r, finishedAt: Date.now() });
        if (r.ok) applyScanData(tool, r.data);
        else if (tool === "start_session") aborted = true;
      } catch (e) {
        updateStep(tool, { status: "failed", error: errorText(e), finishedAt: Date.now() });
        if (tool === "start_session") aborted = true;
      }
      if (aborted) {
        setSteps((prev) => prev.map((s) => (s.status === "pending" ? { ...s, status: "skipped" } : s)));
        break;
      }
    }
    setScanState(aborted ? "aborted" : "ready");
  }

  async function rescanTargets() {
    setRescanning(true);
    setCleanError(null);
    try {
      const r = await api.runTool("scan_cleanup_targets");
      if (r.ok) {
        setTargets(parseTargets(r.data));
        resetCleanup();
      } else {
        setCleanError(r.output || t("common.failedNoOutput"));
      }
    } catch (e) {
      setCleanError(errorText(e));
    } finally {
      setRescanning(false);
    }
  }

  // ---- 清理：先試跑，列出會做什麼，使用者確認後才執行 ----
  const selectedItems = useMemo(
    () => (targets?.targets ?? []).filter((x) => selected.has(x.Id) && isSelectable(x)),
    [targets, selected],
  );
  const selectedBytes = selectedItems.reduce((n, x) => n + expectedBytes(x), 0);
  const execItems = cleanItems.filter((x) => previewRuns[x.Id]?.status === "ok");
  const execBytes = execItems.reduce((n, x) => n + expectedBytes(x), 0);

  async function previewCleanup() {
    const items = selectedItems;
    if (!items.length) return;
    setCleanError(null);
    setCleanItems(items);
    setApplyRuns({});
    setPreviewRuns(Object.fromEntries(items.map((x) => [x.Id, { status: "pending" } as ItemRun])));
    setCleanPhase("previewing");
    for (const x of items) {
      setPreviewRuns((p) => ({ ...p, [x.Id]: { status: "running" } }));
      let run: ItemRun;
      try {
        const r = await api.runTool(cleanupTool(x), cleanupArgs(x, false));
        run = { status: runStatusOf(r), result: r };
      } catch (e) {
        run = { status: "failed", error: errorText(e) };
      }
      setPreviewRuns((p) => ({ ...p, [x.Id]: run }));
    }
    setCleanPhase("preview");
  }

  async function runCleanup() {
    const items = execItems;
    if (!items.length) return;
    setCleanError(null);
    setApplyRuns(Object.fromEntries(items.map((x) => [x.Id, { status: "pending" } as ItemRun])));
    setCleanPhase("running");
    for (const x of items) {
      setApplyRuns((p) => ({ ...p, [x.Id]: { status: "running" } }));
      let run: ItemRun;
      try {
        // apply: true 時後端會跳出 Windows 確認視窗，使用者按取消會回傳 cancelled
        const r = await api.runTool(cleanupTool(x), cleanupArgs(x, true));
        run = { status: runStatusOf(r), result: r };
      } catch (e) {
        run = { status: "failed", error: errorText(e) };
      }
      setApplyRuns((p) => ({ ...p, [x.Id]: run }));
    }
    setCleanPhase("done");
  }

  const applyCounts = useMemo(() => {
    const c = { ok: 0, failed: 0, cancelled: 0 };
    for (const r of Object.values(applyRuns)) {
      if (r.status === "ok") c.ok++;
      else if (r.status === "cancelled") c.cancelled++;
      else if (r.status === "failed") c.failed++;
    }
    return c;
  }, [applyRuns]);

  // ---- 整理下載資料夾 ----
  async function makePlan() {
    setOrgError(null);
    setOrgApply(null);
    setPlan(null);
    setPlanResult(null);
    setOrgPhase("planning");
    try {
      const root = orgRoot.trim();
      const r = await api.runTool("organize_plan", root ? { root } : {});
      setPlanResult(r);
      if (r.ok) {
        setPlan(parsePlan(r.data) ?? { planFile: "", rows: [] });
        setOrgPhase("planned");
      } else {
        setOrgError(r.output || t("common.failedNoOutput"));
        setOrgPhase("idle");
      }
    } catch (e) {
      setOrgError(errorText(e));
      setOrgPhase("idle");
    }
  }

  async function applyPlan() {
    setOrgError(null);
    setOrgPhase("applying");
    setOrgApply({ status: "running" });
    try {
      const r = await api.runTool("organize_apply", { apply: true });
      setOrgApply({ status: runStatusOf(r), result: r });
      setOrgPhase(r.cancelled ? "planned" : "done");
    } catch (e) {
      setOrgApply({ status: "failed", error: errorText(e) });
      setOrgPhase("planned");
    }
  }

  const planCounts = useMemo(() => {
    const rows = plan?.rows ?? [];
    return { move: rows.filter((r) => r.Action === "Move").length, recycle: rows.filter((r) => r.Action === "Recycle").length };
  }, [plan]);

  // ---- 報告 ----
  async function buildReport() {
    setReportError(null);
    setReportBusy(true);
    try {
      const r = await api.runTool("build_report");
      setReportOutput(r.output);
      const path = isObject(r.data) && typeof r.data.reportPath === "string" ? r.data.reportPath : null;
      if (r.ok && path) {
        setReportPath(path);
        let dir: string | null = null;
        try {
          dir = (await api.appInfo()).currentSession;
        } catch {
          // 取不到就用報告所在的資料夾
        }
        setSessionDir(dir || dirname(path));
      } else {
        setReportError(r.output || t("common.failedNoOutput"));
      }
    } catch (e) {
      setReportError(errorText(e));
    } finally {
      setReportBusy(false);
    }
  }

  async function open(path: string) {
    setReportError(null);
    try {
      await api.openSessionPath(path);
    } catch (e) {
      setReportError(errorText(e));
    }
  }

  const ready = scanState === "ready";

  return (
    <div className="page">
      <header className="page-head">
        <h1>{t("wizard.title")}</h1>
        <p className="muted">{t("wizard.subtitle")}</p>
      </header>

      {/* 1. 掃描 */}
      <section className="card">
        <h2>
          <span className="step-no">1</span>
          {t("wizard.scanTitle")}
        </h2>
        <p className="muted">{t("wizard.scanDesc")}</p>
        <div className="actions">
          <button type="button" className="btn-primary" onClick={runScan} disabled={busy}>
            {scanState === "idle" ? t("wizard.startScan") : t("wizard.rescan")}
          </button>
          {scanning && <Spinner label={t("wizard.scanning")} />}
        </div>
        {steps.length > 0 && (
          <ol className="steps">
            {steps.map((s) => {
              const elapsed =
                s.startedAt !== undefined ? formatSeconds((s.finishedAt ?? now) - s.startedAt) : "";
              return (
                <li key={s.tool} className="step">
                  <div className="step-row">
                    <StatusPill status={s.status} />
                    <span className="step-name">{toolLabel(t, s.tool)}</span>
                    {elapsed && <span className="muted small">{elapsed}</span>}
                    {s.tool === "health_check" && s.status === "running" && (
                      <span className="muted small">{t("wizard.healthHint")}</span>
                    )}
                  </div>
                  {s.error && <div className="error-text pre-wrap">{s.error}</div>}
                  {s.result && <OutputBox text={s.result.output} />}
                </li>
              );
            })}
          </ol>
        )}
        {scanState === "aborted" && <Notice kind="error">{t("wizard.scanAborted")}</Notice>}
      </section>

      {/* 2. 摘要 */}
      {ready && (
        <section className="card">
          <h2>
            <span className="step-no">2</span>
            {t("wizard.summaryTitle")}
          </h2>
          <div className="grid-2">
            <div>
              <h3>{t("summary.drives")}</h3>
              {overview ? <DriveList drives={overview.drives ?? []} /> : <p className="muted">{t("summary.noData")}</p>}
              {overview && <OverviewInfo overview={overview} />}
            </div>
            <div>
              <h3>{t("summary.findings")}</h3>
              {health ? <FindingList health={health} /> : <p className="muted">{t("summary.noData")}</p>}
            </div>
          </div>
        </section>
      )}

      {/* 3. 清理 */}
      {ready && (
        <section className="card">
          <h2>
            <span className="step-no">3</span>
            {t("wizard.cleanupTitle")}
          </h2>
          {!targets ? (
            <p className="muted">{t("summary.noData")}</p>
          ) : (
            <>
              <Notice kind="warn">{t("cleanup.warnA")}</Notice>
              {!targets.isAdmin && <p className="muted small">{t("cleanup.notAdmin")}</p>}
              {targets.recycleBin.Count > 0 && (
                <p className="muted small">
                  {t("cleanup.recycleBinInfo", {
                    n: targets.recycleBin.Count,
                    size: formatBytes(targets.recycleBin.Bytes),
                  })}
                </p>
              )}

              <CleanupTable
                targets={targets.targets}
                selected={selected}
                disabled={busy || cleanPhase !== "select"}
                onToggle={(id, on) =>
                  setSelected((prev) => {
                    const next = new Set(prev);
                    if (on) next.add(id);
                    else next.delete(id);
                    return next;
                  })
                }
                onToggleAll={(on) =>
                  setSelected(on ? new Set(targets.targets.filter(isSelectable).map((x) => x.Id)) : new Set())
                }
              />

              {cleanPhase === "select" && (
                <div className="actions">
                  <button
                    type="button"
                    className="btn-primary"
                    disabled={busy || selectedItems.length === 0}
                    onClick={previewCleanup}
                  >
                    {t("cleanup.cleanSelected")}
                  </button>
                  <span className="muted small">
                    {t("cleanup.selectedInfo", { n: selectedItems.length, size: formatBytes(selectedBytes) })}
                  </span>
                  <button type="button" className="btn-ghost" disabled={busy} onClick={rescanTargets}>
                    {t("cleanup.rescan")}
                  </button>
                  {rescanning && <Spinner />}
                </div>
              )}

              {cleanPhase !== "select" && (
                <div className="confirm-panel">
                  <h3>{cleanPhase === "previewing" || cleanPhase === "preview" ? t("cleanup.previewTitle") : t("cleanup.resultTitle")}</h3>
                  {(cleanPhase === "previewing" || cleanPhase === "preview") && (
                    <p className="muted small">{t("cleanup.previewDesc")}</p>
                  )}
                  <div className="table-wrap">
                    <table className="table">
                      <thead>
                        <tr>
                          <th>{t("cleanup.colName")}</th>
                          <th>{t("cleanup.colWhat")}</th>
                          <th className="num">{t("cleanup.colFree")}</th>
                          <th>{t("cleanup.colUndo")}</th>
                          <th>{t("cleanup.colStatus")}</th>
                        </tr>
                      </thead>
                      <tbody>
                        {cleanItems.map((x) => {
                          const pre = previewRuns[x.Id];
                          const app = applyRuns[x.Id];
                          const run = app ?? pre;
                          const isApply = Boolean(app);
                          return (
                            <tr key={x.Id}>
                              <td>
                                <div className="cell-title">{x.Name}</div>
                                <div className="path" title={x.RealPath}>
                                  {x.RealPath}
                                </div>
                              </td>
                              <td className="small">
                                {x.Action === "clear-folder"
                                  ? t("cleanup.methodClear")
                                  : t("cleanup.methodOld", { days: OLDER_THAN_DAYS })}
                                {x.Procs.length > 0 && (
                                  <div className="muted">{t("cleanup.procsNote", { procs: x.Procs.join("、") })}</div>
                                )}
                              </td>
                              <td className="num">{formatBytes(expectedBytes(x))}</td>
                              <td className="small">{t("cleanup.notReversible")}</td>
                              <td>
                                {run && (
                                  <StatusPill
                                    status={run.status}
                                    label={
                                      !isApply && run.status === "ok"
                                        ? t("cleanup.dryRunOk")
                                        : !isApply && run.status === "failed"
                                          ? t("cleanup.dryRunFailed")
                                          : undefined
                                    }
                                  />
                                )}
                                {!isApply && run?.status === "failed" && cleanPhase === "preview" && (
                                  <div className="muted small">{t("cleanup.excluded")}</div>
                                )}
                                {run?.error && <div className="error-text small pre-wrap">{run.error}</div>}
                                {run?.result && <OutputBox text={run.result.output} />}
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>

                  {cleanPhase === "previewing" && <Spinner label={t("cleanup.previewing")} />}

                  {cleanPhase === "preview" && (
                    <>
                      <Notice kind="warn">{t("cleanup.warnA")}</Notice>
                      <p className="small">{t("cleanup.confirmNote")}</p>
                      <div className="actions">
                        <button type="button" className="btn-danger" disabled={busy || execItems.length === 0} onClick={runCleanup}>
                          {t("cleanup.execute", { n: execItems.length, size: formatBytes(execBytes) })}
                        </button>
                        <button type="button" className="btn-ghost" disabled={busy} onClick={resetCleanup}>
                          {t("common.back")}
                        </button>
                      </div>
                    </>
                  )}

                  {cleanPhase === "running" && <Spinner label={t("cleanup.running")} />}

                  {cleanPhase === "done" && (
                    <>
                      <Notice kind={applyCounts.failed ? "warn" : "ok"}>
                        {t("cleanup.doneSummary", applyCounts)}
                      </Notice>
                      <div className="actions">
                        <button type="button" className="btn-primary" disabled={busy} onClick={rescanTargets}>
                          {t("cleanup.rescanAfter")}
                        </button>
                        {rescanning && <Spinner />}
                      </div>
                    </>
                  )}
                </div>
              )}
              <ErrorBanner message={cleanError} onClose={() => setCleanError(null)} />
            </>
          )}
        </section>
      )}

      {/* 4. 整理下載資料夾 */}
      {ready && (
        <section className="card">
          <h2>
            <span className="step-no">4</span>
            {t("wizard.organizeTitle")}
            <span className="tag">{t("common.optional")}</span>
          </h2>
          {orgPhase === "skipped" ? (
            <div className="actions">
              <span className="muted">{t("organize.skipped")}</span>
              <button type="button" className="btn-ghost" onClick={() => setOrgPhase("idle")}>
                {t("organize.unskip")}
              </button>
            </div>
          ) : (
            <>
              <p className="muted">{t("organize.desc")}</p>
              <div className="form-row">
                <label htmlFor="org-root">{t("organize.root")}</label>
                <input
                  id="org-root"
                  type="text"
                  value={orgRoot}
                  placeholder={t("organize.rootPlaceholder")}
                  onChange={(e) => setOrgRoot(e.target.value)}
                  disabled={busy}
                  spellCheck={false}
                />
              </div>
              <div className="actions">
                <button type="button" className="btn-primary" disabled={busy} onClick={makePlan}>
                  {plan ? t("organize.replan") : t("organize.makePlan")}
                </button>
                {orgPhase !== "done" && (
                  <button type="button" className="btn-ghost" disabled={busy} onClick={() => setOrgPhase("skipped")}>
                    {t("organize.skip")}
                  </button>
                )}
                {orgPhase === "planning" && <Spinner label={t("organize.planning")} />}
              </div>

              {plan && (
                <>
                  {plan.rows.length === 0 ? (
                    <Notice kind="ok">{t("organize.nothing")}</Notice>
                  ) : (
                    <>
                      <p>{t("organize.planSummary", { total: plan.rows.length, move: planCounts.move, recycle: planCounts.recycle })}</p>
                      <PlanTable rows={plan.rows} />
                      {orgPhase !== "done" && (
                        <div className="confirm-panel">
                          <p className="small">{t("organize.undoBefore")}</p>
                          <div className="actions">
                            <button type="button" className="btn-danger" disabled={busy} onClick={applyPlan}>
                              {t("organize.apply", { n: plan.rows.length })}
                            </button>
                            {orgPhase === "applying" && <Spinner label={t("organize.applying")} />}
                          </div>
                        </div>
                      )}
                    </>
                  )}
                </>
              )}
              {planResult && !plan && <OutputBox text={planResult.output} />}

              {orgApply && orgApply.status !== "running" && (
                <div className="result-block">
                  {orgApply.status === "cancelled" ? (
                    <Notice kind="info">{t("organize.cancelled")}</Notice>
                  ) : orgApply.status === "ok" ? (
                    <Notice kind="ok">
                      <div>{t("organize.done")}</div>
                      <div className="small">{t("organize.undoAfter")}</div>
                    </Notice>
                  ) : (
                    <Notice kind="error">{orgApply.error ?? t("organize.failed")}</Notice>
                  )}
                  {orgApply.result && <OutputBox text={orgApply.result.output} open={orgApply.status === "ok"} />}
                </div>
              )}
              <ErrorBanner message={orgError} onClose={() => setOrgError(null)} />
            </>
          )}
        </section>
      )}

      {/* 5. 報告 */}
      {ready && (
        <section className="card">
          <h2>
            <span className="step-no">5</span>
            {t("wizard.reportTitle")}
          </h2>
          <p className="muted">{t("report.desc")}</p>
          <div className="actions">
            <button type="button" className="btn-primary" disabled={busy} onClick={buildReport}>
              {reportPath ? t("report.rebuild") : t("report.build")}
            </button>
            {reportBusy && <Spinner label={t("report.building")} />}
            {reportPath && (
              <button type="button" className="btn" onClick={() => open(reportPath)}>
                {t("report.open")}
              </button>
            )}
            {sessionDir && reportPath && (
              <button type="button" className="btn" onClick={() => open(sessionDir)}>
                {t("report.openFolder")}
              </button>
            )}
          </div>
          {reportPath && (
            <p className="path small" title={reportPath}>
              {reportPath}
            </p>
          )}
          {reportOutput && <OutputBox text={reportOutput} />}
          <ErrorBanner message={reportError} onClose={() => setReportError(null)} />
        </section>
      )}
    </div>
  );
}
