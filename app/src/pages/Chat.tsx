// AI 助理：模型可以呼叫清理工具；會改動電腦的動作一樣要經過後端的 Windows 確認視窗。
import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import type { ChatMessage, ProviderPreset, Settings, ToolCall, ToolResult } from "../api";
import { api } from "../backend";
import { runStatusOf, type ItemRun } from "../cleanup";
import { Markdown } from "../components/Markdown";
import { ToolCard } from "../components/ToolCard";
import { ErrorBanner, Notice, Spinner } from "../components/common";
import { errorText, isObject } from "../format";
import { useI18n } from "../i18n";

/** 每次使用者發話後，最多來回呼叫模型幾次（避免工具呼叫無限循環） */
const MAX_ROUNDS = 12;
/** 每個工具結果送回模型的字數上限 */
const TOOL_OUTPUT_LIMIT = 6000;

interface Props {
  settings: Settings | null;
  presets: ProviderPreset[];
  hasKey: boolean | null;
  onGoSettings: () => void;
}

function normalizeArgs(args: unknown): Record<string, unknown> {
  if (isObject(args)) return args;
  if (typeof args === "string") {
    try {
      const v = JSON.parse(args);
      if (isObject(v)) return v;
    } catch {
      // 不是 JSON 就當作沒有參數
    }
  }
  return {};
}

export function Chat({ settings, presets, hasKey, onGoSettings }: Props) {
  const { t } = useI18n();
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [toolRuns, setToolRuns] = useState<Record<string, ItemRun>>({});
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [stopping, setStopping] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const stopRef = useRef(false);
  const endRef = useRef<HTMLDivElement>(null);

  const preset = settings ? presets.find((p) => p.id === settings.provider) : undefined;
  const providerLabel = preset?.label ?? settings?.provider ?? "";
  const missingModel = !settings || !settings.model.trim();
  const missingKey = Boolean(preset?.needsKey) && hasKey === false;
  const configured = !missingModel && !missingKey;

  useEffect(() => {
    endRef.current?.scrollIntoView({ block: "end" });
  }, [messages, toolRuns, busy]);

  function toolContent(r: ToolResult): string {
    const head: string[] = [];
    if (r.cancelled) head.push(t("chat.cancelledForModel"));
    head.push(`ok=${r.ok} exitCode=${r.exitCode}`);
    const out = r.output ?? "";
    const body = out.length > TOOL_OUTPUT_LIMIT ? out.slice(0, TOOL_OUTPUT_LIMIT) + "\n" + t("chat.truncatedForModel") : out;
    return head.join("\n") + "\n" + body;
  }

  async function runCall(call: ToolCall): Promise<string> {
    if (stopRef.current) {
      setToolRuns((p) => ({ ...p, [call.id]: { status: "skipped" } }));
      return t("chat.stoppedForModel");
    }
    setToolRuns((p) => ({ ...p, [call.id]: { status: "running" } }));
    try {
      const r = await api.runTool(call.name, normalizeArgs(call.arguments));
      setToolRuns((p) => ({ ...p, [call.id]: { status: runStatusOf(r), result: r } }));
      return toolContent(r);
    } catch (e) {
      const msg = errorText(e);
      setToolRuns((p) => ({ ...p, [call.id]: { status: "failed", error: msg } }));
      return t("chat.toolErrorForModel", { error: msg });
    }
  }

  async function send(text: string) {
    const content = text.trim();
    if (!content || busy || !configured) return;
    let msgs: ChatMessage[] = [...messages, { role: "user", content }];
    setMessages(msgs);
    setInput("");
    setError(null);
    setNotice(null);
    setBusy(true);
    stopRef.current = false;
    setStopping(false);
    try {
      for (let round = 0; ; round++) {
        if (stopRef.current) {
          setNotice(t("chat.stopped"));
          break;
        }
        if (round >= MAX_ROUNDS) {
          setNotice(t("chat.roundLimit", { n: MAX_ROUNDS }));
          break;
        }
        const reply = await api.chat(msgs);
        const calls = (reply.toolCalls ?? []).map((c) => ({ ...c, arguments: normalizeArgs(c.arguments) }));
        const assistant: ChatMessage = {
          role: "assistant",
          content: reply.content ?? "",
          ...(calls.length ? { toolCalls: calls } : {}),
        };
        msgs = [...msgs, assistant];
        setMessages(msgs);
        if (!calls.length) break;
        // 每個 toolCall 都要有對應的 tool 訊息，即使被停止或失敗
        for (const call of calls) {
          const result = await runCall(call);
          msgs = [...msgs, { role: "tool", toolCallId: call.id, content: result }];
          setMessages(msgs);
        }
      }
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
      setStopping(false);
    }
  }

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    // 中文輸入法選字時按 Enter 不送出
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      void send(input);
    }
  }

  function clear() {
    setMessages([]);
    setToolRuns({});
    setError(null);
    setNotice(null);
  }

  const suggestions = [t("chat.suggest1"), t("chat.suggest2"), t("chat.suggest3")];

  return (
    <div className="page chat-page">
      <header className="page-head chat-head">
        <div>
          <h1>{t("chat.title")}</h1>
          {settings && (
            <p className="muted small">
              {t("chat.using", { provider: providerLabel, model: settings.model || t("chat.noModel") })}
            </p>
          )}
        </div>
        <button type="button" className="btn-ghost" onClick={clear} disabled={busy || messages.length === 0}>
          {t("chat.clear")}
        </button>
      </header>

      {!configured ? (
        <Notice kind="warn">
          <div>{missingModel ? t("chat.notConfigured") : t("chat.noKey", { provider: providerLabel })}</div>
          <button type="button" className="btn btn-sm" onClick={onGoSettings}>
            {t("chat.goSettings")}
          </button>
        </Notice>
      ) : preset && !preset.local ? (
        <Notice kind="warn">
          <div>{t("chat.cloudNotice", { provider: providerLabel })}</div>
          <div className="small">{settings?.redact ? t("chat.redactOn") : t("chat.redactOff")}</div>
        </Notice>
      ) : (
        <Notice kind="info">{t("chat.localNotice")}</Notice>
      )}

      <div className="chat-log" aria-live="polite">
        {messages.length === 0 && (
          <div className="chat-empty">
            <p className="muted">{t("chat.empty")}</p>
            <div className="suggestions">
              {suggestions.map((s) => (
                <button key={s} type="button" className="btn-ghost suggestion" disabled={!configured || busy} onClick={() => send(s)}>
                  {s}
                </button>
              ))}
            </div>
          </div>
        )}
        {messages.map((m, i) => {
          if (m.role === "tool") return null;
          if (m.role === "user")
            return (
              <div key={i} className="msg msg-user">
                <div className="bubble pre-wrap">{m.content}</div>
              </div>
            );
          return (
            <div key={i} className="msg msg-assistant">
              {m.content.trim() && (
                <div className="bubble">
                  <Markdown text={m.content} />
                </div>
              )}
              {m.toolCalls?.map((c) => (
                <ToolCard key={c.id} call={c} run={toolRuns[c.id]} />
              ))}
            </div>
          );
        })}
        {busy && (
          <div className="msg msg-assistant">
            <Spinner label={stopping ? t("chat.stopping") : t("chat.thinking")} />
          </div>
        )}
        {notice && <Notice kind="info">{notice}</Notice>}
        <ErrorBanner message={error} onClose={() => setError(null)} />
        <div ref={endRef} />
      </div>

      <div className="chat-input">
        <textarea
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={onKeyDown}
          placeholder={configured ? t("chat.placeholder") : t("chat.placeholderDisabled")}
          disabled={!configured}
          rows={3}
        />
        <div className="chat-input-actions">
          {busy ? (
            <button
              type="button"
              className="btn"
              disabled={stopping}
              onClick={() => {
                stopRef.current = true;
                setStopping(true);
              }}
            >
              {t("chat.stop")}
            </button>
          ) : (
            <button type="button" className="btn-primary" disabled={!configured || !input.trim()} onClick={() => send(input)}>
              {t("chat.send")}
            </button>
          )}
          <span className="muted small">{t("chat.enterHint")}</span>
        </div>
      </div>
    </div>
  );
}
