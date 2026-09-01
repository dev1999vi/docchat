import { useEffect, useRef, useState } from "react";
import {
  listDocuments,
  uploadDocument,
  createConversation,
  streamAnswer,
} from "./api";

export default function App() {
  const [documents, setDocuments] = useState([]);
  const [conversationId, setConversationId] = useState(null);
  const [messages, setMessages] = useState([]);
  const [input, setInput] = useState("");
  const [streaming, setStreaming] = useState(false);
  const [uploadError, setUploadError] = useState("");
  const fileRef = useRef();

  async function refreshDocuments() {
    try {
      setDocuments(await listDocuments());
    } catch (e) {
      // ignore transient errors
    }
  }

  useEffect(() => {
    refreshDocuments();
    createConversation().then((c) => setConversationId(c.id)).catch(() => {});
    const interval = setInterval(refreshDocuments, 4000);
    return () => clearInterval(interval);
  }, []);

  async function handleUpload(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    setUploadError("");
    try {
      await uploadDocument(file);
      await refreshDocuments();
    } catch (err) {
      setUploadError(err.message);
    } finally {
      if (fileRef.current) fileRef.current.value = "";
    }
  }

  async function handleAsk(e) {
    e.preventDefault();
    const question = input.trim();
    if (!question || streaming || !conversationId) return;

    setInput("");
    setMessages((m) => [...m, { role: "user", content: question }]);
    setMessages((m) => [...m, { role: "assistant", content: "", citations: [] }]);
    setStreaming(true);

    await streamAnswer(conversationId, question, {
      onToken: (text) =>
        setMessages((m) => {
          const copy = [...m];
          copy[copy.length - 1] = {
            ...copy[copy.length - 1],
            content: copy[copy.length - 1].content + text,
          };
          return copy;
        }),
      onCitations: (list) =>
        setMessages((m) => {
          const copy = [...m];
          copy[copy.length - 1] = { ...copy[copy.length - 1], citations: list };
          return copy;
        }),
      onError: (msg) =>
        setMessages((m) => {
          const copy = [...m];
          copy[copy.length - 1] = {
            ...copy[copy.length - 1],
            content: `⚠️ ${msg}`,
          };
          return copy;
        }),
    });

    setStreaming(false);
  }

  return (
    <div className="app">
      <aside className="sidebar">
        <h1>DocChat</h1>
        <label className="upload-btn">
          + Upload PDF
          <input
            ref={fileRef}
            type="file"
            accept="application/pdf"
            onChange={handleUpload}
            hidden
          />
        </label>
        {uploadError && <p className="error">{uploadError}</p>}
        <ul className="doc-list">
          {documents.map((d) => (
            <li key={d.id} className={`doc doc-${d.status}`}>
              <span className="doc-title">{d.title}</span>
              <span className="doc-status">{d.status}</span>
            </li>
          ))}
          {documents.length === 0 && <p className="hint">No documents yet.</p>}
        </ul>
      </aside>

      <main className="chat">
        <div className="messages">
          {messages.length === 0 && (
            <p className="hint center">
              Upload a PDF, then ask a question about it.
            </p>
          )}
          {messages.map((m, i) => (
            <div key={i} className={`msg msg-${m.role}`}>
              <div className="msg-content">{m.content || "…"}</div>
              {m.citations?.length > 0 && (
                <div className="citations">
                  {m.citations.map((c) => (
                    <div key={c.index} className="citation">
                      <strong>[{c.index}]</strong> p.{c.page_number}: {c.snippet}
                    </div>
                  ))}
                </div>
              )}
            </div>
          ))}
        </div>

        <form className="composer" onSubmit={handleAsk}>
          <input
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder="Ask about your documents…"
            disabled={streaming}
          />
          <button type="submit" disabled={streaming || !input.trim()}>
            {streaming ? "…" : "Ask"}
          </button>
        </form>
      </main>
    </div>
  );
}
