// 清理項目表格：只有 A 類、可自動清理、沒有相關程式執行中的項目可以勾選。
import type { CleanupTarget } from "../api";
import { OLDER_THAN_DAYS, isSelectable } from "../cleanup";
import { formatBytes } from "../format";
import { useI18n } from "../i18n";

interface Props {
  targets: CleanupTarget[];
  selected: Set<string>;
  disabled: boolean;
  onToggle: (id: string, on: boolean) => void;
  onToggleAll: (on: boolean) => void;
}

export function CleanupTable({ targets, selected, disabled, onToggle, onToggleAll }: Props) {
  const { t } = useI18n();
  const selectable = targets.filter(isSelectable);
  const allOn = selectable.length > 0 && selectable.every((x) => selected.has(x.Id));
  if (!targets.length) return <p className="muted">{t("cleanup.empty")}</p>;
  return (
    <div className="table-wrap">
      <table className="table">
        <thead>
          <tr>
            <th className="col-check">
              <input
                type="checkbox"
                checked={allOn}
                disabled={disabled || selectable.length === 0}
                onChange={(e) => onToggleAll(e.target.checked)}
                aria-label={t("cleanup.selectAll")}
              />
            </th>
            <th>{t("cleanup.colName")}</th>
            <th className="num">{t("cleanup.colSize")}</th>
            <th className="num">{t("cleanup.colOld")}</th>
            <th>{t("cleanup.colRisk")}</th>
            <th>{t("cleanup.colHandling")}</th>
          </tr>
        </thead>
        <tbody>
          {targets.map((x) => {
            const can = isSelectable(x);
            const running = x.RunningApps.length > 0;
            return (
              <tr key={x.Id} className={can ? "" : "row-dim"}>
                <td className="col-check">
                  <input
                    type="checkbox"
                    checked={can && selected.has(x.Id)}
                    disabled={disabled || !can}
                    onChange={(e) => onToggle(x.Id, e.target.checked)}
                    aria-label={x.Name}
                  />
                </td>
                <td>
                  <div className="cell-title">{x.Name}</div>
                  <div className="path" title={x.RealPath}>
                    {x.RealPath}
                  </div>
                </td>
                <td className="num">{formatBytes(x.Bytes)}</td>
                <td className="num">{x.Action === "clean-old-files" || x.OldBytes > 0 ? formatBytes(x.OldBytes) : "—"}</td>
                <td>
                  <span className={`risk risk-${x.Risk}`} title={t(x.Risk === "A" ? "cleanup.riskAHint" : "cleanup.riskBHint")}>
                    {x.Risk}
                  </span>
                </td>
                <td className="handling">
                  {running && (
                    <div className="warn-text">{t("cleanup.closeFirst", { apps: x.RunningApps.join("、") })}</div>
                  )}
                  {can && (
                    <div className="small">
                      {x.Action === "clear-folder" ? t("cleanup.methodClear") : t("cleanup.methodOld", { days: OLDER_THAN_DAYS })}
                    </div>
                  )}
                  {!can && !running && x.Risk === "A" && x.Action === "manual" && (
                    <div className="small muted">{t("cleanup.manualOnly")}</div>
                  )}
                  {!can && x.Risk === "B" && <div className="small muted">{t("cleanup.riskBOnly")}</div>}
                  {x.Method && <div className="small muted pre-wrap">{x.Method}</div>}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
