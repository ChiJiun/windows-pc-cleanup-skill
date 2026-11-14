// 整理計畫預覽表格。
import type { PlanRow } from "../api";
import { basename } from "../format";
import { useI18n } from "../i18n";

const MAX_ROWS = 1000;

export function PlanTable({ rows }: { rows: PlanRow[] }) {
  const { t } = useI18n();
  const shown = rows.slice(0, MAX_ROWS);
  return (
    <>
      <div className="table-wrap table-scroll">
        <table className="table">
          <thead>
            <tr>
              <th>{t("organize.colFile")}</th>
              <th>{t("organize.colAction")}</th>
              <th>{t("organize.colDest")}</th>
              <th>{t("organize.colReason")}</th>
            </tr>
          </thead>
          <tbody>
            {shown.map((r, i) => (
              <tr key={i}>
                <td>
                  <div className="cell-title" title={r.Source}>
                    {basename(r.Source)}
                  </div>
                </td>
                <td>
                  <span className={`act act-${r.Action}`}>
                    {r.Action === "Move" ? t("organize.actMove") : t("organize.actRecycle")}
                  </span>
                </td>
                <td>
                  <div className="path" title={r.Action === "Move" ? r.Dest : ""}>
                    {r.Action === "Move" ? r.Dest : t("organize.recycleBin")}
                  </div>
                </td>
                <td className="small pre-wrap">
                  {r.Reason}
                  {r.Keep && (
                    <div className="muted path" title={r.Keep}>
                      {t("organize.keepCopy", { path: r.Keep })}
                    </div>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {rows.length > MAX_ROWS && <p className="muted small">{t("organize.truncated", { n: MAX_ROWS, total: rows.length })}</p>}
    </>
  );
}
