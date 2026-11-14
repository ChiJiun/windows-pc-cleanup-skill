// 極簡 Markdown renderer：段落、標題、清單（含編號）、程式碼區塊、粗體、行內程式碼。
// 全部輸出成 React 節點，由 React 自動跳脫，不使用 dangerouslySetInnerHTML。
// 連結刻意不轉成可點擊的 <a>，避免 AI 回覆裡的網址讓 webview 跳離應用程式。
import type { ReactNode } from "react";

type Block =
  | { type: "p"; lines: string[] }
  | { type: "h"; level: number; text: string }
  | { type: "ul"; items: string[] }
  | { type: "ol"; items: string[]; start: number }
  | { type: "code"; text: string };

function parseBlocks(src: string): Block[] {
  const lines = src.replace(/\r\n?/g, "\n").split("\n");
  const blocks: Block[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (/^\s*```/.test(line)) {
      const buf: string[] = [];
      i++;
      while (i < lines.length && !/^\s*```/.test(lines[i])) buf.push(lines[i++]);
      i++; // 結尾的 ```
      blocks.push({ type: "code", text: buf.join("\n") });
      continue;
    }
    if (!line.trim()) {
      i++;
      continue;
    }
    const h = /^(#{1,6})\s+(.*)$/.exec(line);
    if (h) {
      blocks.push({ type: "h", level: h[1].length, text: h[2] });
      i++;
      continue;
    }
    if (/^\s*[-*+]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*[-*+]\s+/.test(lines[i])) items.push(lines[i++].replace(/^\s*[-*+]\s+/, ""));
      blocks.push({ type: "ul", items });
      continue;
    }
    const ol = /^\s*(\d+)[.)]\s+/.exec(line);
    if (ol) {
      const items: string[] = [];
      while (i < lines.length && /^\s*\d+[.)]\s+/.test(lines[i])) items.push(lines[i++].replace(/^\s*\d+[.)]\s+/, ""));
      blocks.push({ type: "ol", items, start: Number(ol[1]) || 1 });
      continue;
    }
    const buf: string[] = [];
    while (
      i < lines.length &&
      lines[i].trim() &&
      !/^\s*```/.test(lines[i]) &&
      !/^#{1,6}\s+/.test(lines[i]) &&
      !/^\s*[-*+]\s+/.test(lines[i]) &&
      !/^\s*\d+[.)]\s+/.test(lines[i])
    ) {
      buf.push(lines[i++]);
    }
    blocks.push({ type: "p", lines: buf });
  }
  return blocks;
}

function renderInline(text: string): ReactNode[] {
  const out: ReactNode[] = [];
  const re = /(`[^`\n]+`|\*\*[^*\n]+\*\*|__[^_\n]+__)/g;
  let last = 0;
  let m: RegExpExecArray | null;
  let k = 0;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const tok = m[0];
    if (tok.startsWith("`")) out.push(<code key={k++}>{tok.slice(1, -1)}</code>);
    else out.push(<strong key={k++}>{tok.slice(2, -2)}</strong>);
    last = m.index + tok.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

export function Markdown({ text }: { text: string }) {
  const blocks = parseBlocks(text);
  return (
    <div className="md">
      {blocks.map((b, i) => {
        switch (b.type) {
          case "code":
            return <pre key={i}>{b.text}</pre>;
          case "h":
            return (
              <p key={i} className={`md-h md-h${Math.min(b.level, 3)}`}>
                {renderInline(b.text)}
              </p>
            );
          case "ul":
            return (
              <ul key={i}>
                {b.items.map((it, j) => (
                  <li key={j}>{renderInline(it)}</li>
                ))}
              </ul>
            );
          case "ol":
            return (
              <ol key={i} start={b.start}>
                {b.items.map((it, j) => (
                  <li key={j}>{renderInline(it)}</li>
                ))}
              </ol>
            );
          default:
            return (
              <p key={i}>
                {b.lines.map((l, j) => (
                  <span key={j}>
                    {j > 0 && <br />}
                    {renderInline(l)}
                  </span>
                ))}
              </p>
            );
        }
      })}
    </div>
  );
}
