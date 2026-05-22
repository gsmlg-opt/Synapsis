defmodule Synapsis.Workspace.Search do
  @moduledoc """
  Full-text search over workspace documents using PostgreSQL tsvector.

  All database access is delegated to `Synapsis.WorkspaceDocuments`.
  """

  alias Synapsis.WorkspaceDocuments

  @doc """
  Search workspace documents using PostgreSQL full-text search.

  Options:
    - `:scope` - limit to :global, :agent, or :session
    - `:agent_id` - filter by agent
    - `:kind` - filter by document kind
    - `:limit` - max results (default 20)
  """
  @spec search(String.t(), keyword()) :: [Synapsis.WorkspaceDocument.t()]
  def search(query_text, opts \\ []) do
    WorkspaceDocuments.search(query_text, opts)
  end
end
