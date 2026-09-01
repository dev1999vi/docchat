// API calls proxied through Vite's /api prefix to the Rails server.
const BASE = "/api";

export async function listDocuments() {
  const res = await fetch(`${BASE}/documents`);
  if (!res.ok) throw new Error("Failed to load documents");
  return res.json();
}

export async function uploadDocument(file) {
  const form = new FormData();
  form.append("file", file);
  const res = await fetch(`${BASE}/documents`, { method: "POST", body: form });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.error || "Upload failed");
  }
  return res.json();
}

export async function createConversation() {
  const res = await fetch(`${BASE}/conversations`, { method: "POST" });
  if (!res.ok) throw new Error("Failed to create conversation");
  return res.json();
}

// Streams an answer. Calls the provided handlers as SSE events arrive.
// handlers: { onToken(text), onCitations(list), onDone(id), onError(msg) }
export async function streamAnswer(conversationId, content, handlers) {
  const res = await fetch(`${BASE}/conversations/${conversationId}/messages`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content }),
  });

  if (!res.ok || !res.body) {
    handlers.onError?.("Request failed");
    return;
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    // SSE events are separated by a blank line.
    const parts = buffer.split("\n\n");
    buffer = parts.pop() ?? "";

    for (const part of parts) {
      const event = parseSSE(part);
      if (!event) continue;
      dispatch(event, handlers);
    }
  }
}

function parseSSE(block) {
  let eventName = "message";
  const dataLines = [];
  for (const line of block.split("\n")) {
    if (line.startsWith("event:")) eventName = line.slice(6).trim();
    else if (line.startsWith("data:")) dataLines.push(line.slice(5).trim());
  }
  if (dataLines.length === 0) return null;
  try {
    return { event: eventName, data: JSON.parse(dataLines.join("\n")) };
  } catch {
    return null;
  }
}

function dispatch({ event, data }, handlers) {
  switch (event) {
    case "token":
      handlers.onToken?.(data.text);
      break;
    case "citations":
      handlers.onCitations?.(data);
      break;
    case "done":
      handlers.onDone?.(data.message_id);
      break;
    case "error":
      handlers.onError?.(data.message);
      break;
  }
}
