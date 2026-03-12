defmodule Synapsis.Workspace.Search do
  @moduledoc """
  Full-text search over workspace documents using PostgreSQL tsvector.
  """

  import Ecto.Query
  alias Synapsis.Repo
  alias Synapsis.WorkspaceDocument

  @doc """
  Search workspace documents using PostgreSQL full-text search.

  Options:
    - `:scope` - limit to :global, :project, or :session
    - `:project_id` - filter by project
    - `:kind` - filter by document kind
    - `:limit` - max results (default 20)
  """
  @spec search(String.t(), keyword()) :: [WorkspaceDocument.t()]
  def search(query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    project_id = Keyword.get(opts, :project_id)
    kind = Keyword.get(opts, :kind)
    scope = Keyword.get(opts, :scope)

    query =
      from d in WorkspaceDocument,
        where:
          is_nil(d.deleted_at) and
            fragment(
              "? @@ websearch_to_tsquery('english', ?)",
              d.search_vector,
              ^query_text
            ),
        order_by:
          fragment(
            "ts_rank(?, websearch_to_tsquery('english', ?)) DESC",
            d.search_vector,
            ^query_text
          ),
        limit: ^limit

    query = if project_id, do: where(query, [d], d.project_id == ^project_id), else: query
    query = if kind, do: where(query, [d], d.kind == ^kind), else: query

    query =
      case scope do
        :global -> where(query, [d], is_nil(d.project_id))
        :project -> where(query, [d], not is_nil(d.project_id) and is_nil(d.session_id))
        :session -> where(query, [d], not is_nil(d.session_id))
        _ -> query
      end

    Repo.all(query)
  end
end
