import { useState, useEffect } from "react";
import { Sidebar } from "./components/Sidebar";
import { ChatView } from "./components/ChatView";
import { listSessions, createSession, deleteSession, getSession, type Session, type Message } from "./lib/api";

export default function App() {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null);
  const [initialMessages, setInitialMessages] = useState<Message[]>([]);
  const projectPath = ".";

  useEffect(() => {
    loadSessions();
  }, []);

  async function loadSessions() {
    try {
      const list = await listSessions(projectPath);
      setSessions(list);
    } catch {
      // Server may not be running yet
    }
  }

  async function handleCreateSession() {
    try {
      const session = await createSession({ project_path: projectPath });
      setSessions((prev) => [session, ...prev]);
      setActiveSessionId(session.id);
      setInitialMessages([]);
    } catch (e) {
      console.error("Failed to create session:", e);
    }
  }

  async function handleSelectSession(id: string) {
    setActiveSessionId(id);
    try {
      const data = await getSession(id);
      setInitialMessages(data.messages || []);
    } catch {
      setInitialMessages([]);
    }
  }

  async function handleDeleteSession(id: string) {
    try {
      await deleteSession(id);
      setSessions((prev) => prev.filter((s) => s.id !== id));
      if (activeSessionId === id) {
        setActiveSessionId(null);
        setInitialMessages([]);
      }
    } catch (e) {
      console.error("Failed to delete session:", e);
    }
  }

  return (
    <div className="flex h-screen bg-gray-950 text-gray-100">
      <Sidebar
        sessions={sessions}
        activeSessionId={activeSessionId}
        onSelect={handleSelectSession}
        onCreate={handleCreateSession}
        onDelete={handleDeleteSession}
      />
      <main className="flex-1 flex flex-col">
        {activeSessionId ? (
          <ChatView sessionId={activeSessionId} initialMessages={initialMessages} />
        ) : (
          <div className="flex-1 flex items-center justify-center text-gray-500">
            <div className="text-center">
              <h1 className="text-2xl font-bold mb-2">Synapsis</h1>
              <p>AI Coding Agent</p>
              <button
                onClick={handleCreateSession}
                className="mt-4 px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
              >
                New Session
              </button>
            </div>
          </div>
        )}
      </main>
    </div>
  );
}
