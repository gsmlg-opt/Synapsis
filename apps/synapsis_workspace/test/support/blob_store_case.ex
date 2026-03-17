defmodule Synapsis.Workspace.BlobStoreCase do
  @moduledoc "Shared test helpers for blob store tests."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Synapsis.Workspace.BlobStore
    end
  end

  setup do
    # Create a temp directory for blob storage during tests
    tmp_dir = Path.join(System.tmp_dir!(), "synapsis_blob_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    %{blob_root: tmp_dir}
  end
end
