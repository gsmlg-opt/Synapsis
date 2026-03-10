defmodule Synapsis.SessionPermissionTest do
  use Synapsis.DataCase

  alias Synapsis.SessionPermission

  describe "changeset/2" do
    test "valid changeset with session_id" do
      attrs = %{session_id: Ecto.UUID.generate()}
      changeset = SessionPermission.changeset(%SessionPermission{}, attrs)
      assert changeset.valid?
    end

    test "invalid without session_id" do
      changeset = SessionPermission.changeset(%SessionPermission{}, %{})
      refute changeset.valid?
      assert %{session_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts all optional fields" do
      attrs = %{
        session_id: Ecto.UUID.generate(),
        mode: :autonomous,
        allow_write: false,
        allow_execute: false,
        allow_destructive: :deny,
        tool_overrides: %{"bash(git *)" => "allow", "bash(rm *)" => "deny"}
      }

      changeset = SessionPermission.changeset(%SessionPermission{}, attrs)
      assert changeset.valid?
    end

    test "defaults are correct" do
      attrs = %{session_id: Ecto.UUID.generate()}
      changeset = SessionPermission.changeset(%SessionPermission{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :mode) == :interactive
      assert Ecto.Changeset.get_field(changeset, :allow_write) == true
      assert Ecto.Changeset.get_field(changeset, :allow_execute) == true
      assert Ecto.Changeset.get_field(changeset, :allow_destructive) == :ask
      assert Ecto.Changeset.get_field(changeset, :tool_overrides) == %{}
    end

    test "rejects invalid mode" do
      attrs = %{session_id: Ecto.UUID.generate(), mode: :invalid}
      changeset = SessionPermission.changeset(%SessionPermission{}, attrs)
      refute changeset.valid?
    end

    test "rejects invalid allow_destructive" do
      attrs = %{session_id: Ecto.UUID.generate(), allow_destructive: :invalid}
      changeset = SessionPermission.changeset(%SessionPermission{}, attrs)
      refute changeset.valid?
    end
  end
end
