import type { Session } from "../lib/api";

interface SidebarProps {
  sessions: Session[];
  activeSessionId: string | null;
  onSelect: (id: string) => void;
  onCreate: () => void;
  onDelete: (id: string) => void;
}

export function Sidebar({ sessions, activeSessionId, onSelect, onCreate, onDelete }: SidebarProps) {
  return (
    <aside className="w-64 bg-gray-900 border-r border-gray-800 flex flex-col">
      <div className="p-4 border-b border-gray-800">
        <h2 className="text-lg font-semibold">Synapsis</h2>
        <button
          onClick={onCreate}
          className="mt-2 w-full px-3 py-1.5 text-sm bg-blue-600 text-white rounded hover:bg-blue-700"
        >
          + New Session
        </button>
      </div>
      <div className="flex-1 overflow-y-auto">
        {sessions.map((session) => (
          <div
            key={session.id}
            onClick={() => onSelect(session.id)}
            className={`px-4 py-3 cursor-pointer border-b border-gray-800 hover:bg-gray-800 flex justify-between items-center ${
              session.id === activeSessionId ? "bg-gray-800" : ""
            }`}
          >
            <div className="min-w-0 flex-1">
              <div className="text-sm truncate">{session.title || `Session ${session.id.slice(0, 8)}`}</div>
              <div className="text-xs text-gray-500 mt-0.5">
                {session.provider}/{session.model.split("-").slice(0, 2).join("-")}
              </div>
            </div>
            <button
              onClick={(e) => {
                e.stopPropagation();
                onDelete(session.id);
              }}
              className="ml-2 text-gray-600 hover:text-red-400 text-xs"
            >
              ✕
            </button>
          </div>
        ))}
      </div>
    </aside>
  );
}
