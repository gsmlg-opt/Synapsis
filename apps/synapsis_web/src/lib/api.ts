const BASE_URL = import.meta.env.DEV ? "http://localhost:4000" : "";

async function fetchJSON(url: string, options?: RequestInit) {
  const res = await fetch(`${BASE_URL}${url}`, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

export interface Session {
  id: string;
  title: string | null;
  agent: string;
  provider: string;
  model: string;
  status: string;
  project_path: string;
  inserted_at: string;
  updated_at: string;
}

export interface MessagePart {
  type: string;
  content?: string;
  text?: string;
  tool?: string;
  tool_use_id?: string;
  input?: Record<string, unknown>;
  is_error?: boolean;
  status?: string;
}

export interface Message {
  id: string;
  role: string;
  parts: MessagePart[];
  token_count: number;
  inserted_at: string;
}

export async function listSessions(projectPath: string = "."): Promise<Session[]> {
  const res = await fetchJSON(`/api/sessions?project_path=${encodeURIComponent(projectPath)}`);
  return res.data;
}

export async function createSession(opts: {
  project_path: string;
  provider?: string;
  model?: string;
  agent?: string;
}): Promise<Session> {
  const res = await fetchJSON("/api/sessions", {
    method: "POST",
    body: JSON.stringify(opts),
  });
  return res.data;
}

export async function getSession(id: string): Promise<Session & { messages: Message[] }> {
  const res = await fetchJSON(`/api/sessions/${id}`);
  return res.data;
}

export async function deleteSession(id: string): Promise<void> {
  await fetch(`${BASE_URL}/api/sessions/${id}`, { method: "DELETE" });
}

export async function sendMessage(sessionId: string, content: string): Promise<void> {
  await fetchJSON(`/api/sessions/${sessionId}/messages`, {
    method: "POST",
    body: JSON.stringify({ content }),
  });
}

export async function getProviders(): Promise<{ name: string; has_api_key: boolean }[]> {
  const res = await fetchJSON("/api/providers");
  return res.data;
}

export async function getModels(provider: string): Promise<{ id: string; name: string }[]> {
  const res = await fetchJSON(`/api/providers/${provider}/models`);
  return res.data;
}

export async function getConfig(): Promise<Record<string, unknown>> {
  const res = await fetchJSON("/api/config");
  return res.data;
}
