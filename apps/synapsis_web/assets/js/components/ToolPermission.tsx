interface ToolPermissionProps {
  tool: string;
  toolUseId: string;
  input: Record<string, unknown>;
  onApprove: (toolUseId: string) => void;
  onDeny: (toolUseId: string) => void;
}

export function ToolPermission({ tool, toolUseId, input, onApprove, onDeny }: ToolPermissionProps) {
  return (
    <div className="bg-yellow-900/20 border border-yellow-700 rounded-lg px-4 py-3">
      <div className="text-sm text-yellow-300 font-medium mb-2">Permission Required: {tool}</div>
      <pre className="text-xs text-gray-400 font-mono mb-3 overflow-x-auto bg-gray-900 rounded px-2 py-1">
        {JSON.stringify(input, null, 2)}
      </pre>
      <div className="flex gap-2">
        <button
          onClick={() => onApprove(toolUseId)}
          className="px-3 py-1 text-xs bg-green-600 text-white rounded hover:bg-green-700"
        >
          Approve
        </button>
        <button
          onClick={() => onDeny(toolUseId)}
          className="px-3 py-1 text-xs bg-red-600 text-white rounded hover:bg-red-700"
        >
          Deny
        </button>
      </div>
    </div>
  );
}
