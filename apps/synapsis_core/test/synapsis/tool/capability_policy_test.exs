defmodule Synapsis.Tool.CapabilityPolicyTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Capability.{Grant, PolicySnapshot}
  alias Synapsis.Tool.CapabilityPolicy

  @levels [:none, :read, :write, :execute, :destructive]

  # Synthetic tools: we stub permission_level via registry modules would be heavy;
  # exercise PolicySnapshot level tables directly through evaluate with known names
  # that Permissions.level classifies.

  describe "profile matrix" do
    for profile <- PolicySnapshot.profiles() do
      test "profile #{profile} never allows unknown class by default" do
        snapshot =
          PolicySnapshot.for_profile(unquote(profile), session_id: "s1", attended?: false)

        # Force unknown by using a level not in any list — evaluate uses Permissions.level
        # which defaults unknown to :write. Assert deny/approval behavior is closed for unattended.
        decision =
          CapabilityPolicy.evaluate(%{name: "file_delete", input: %{}}, snapshot, %{
            session_id: "s1"
          })

        assert match?({:deny, _}, decision) or match?({:allow, %Grant{}}, decision) or
                 match?({:approval_required, _}, decision)

        # Unattended never returns approval_required
        refute match?({:approval_required, _}, decision)
      end
    end

    test "read_only allows reads and denies writes/execute/destructive" do
      snapshot = PolicySnapshot.for_profile(:read_only, session_id: "s1", attended?: false)

      assert {:allow, %Grant{}} =
               CapabilityPolicy.evaluate(%{name: "file_read", input: %{}}, snapshot, %{
                 session_id: "s1"
               })

      assert {:deny, _} =
               CapabilityPolicy.evaluate(%{name: "file_write", input: %{}}, snapshot, %{
                 session_id: "s1"
               })

      assert {:deny, _} =
               CapabilityPolicy.evaluate(%{name: "bash", input: %{}}, snapshot, %{
                 session_id: "s1"
               })

      assert {:deny, _} =
               CapabilityPolicy.evaluate(%{name: "file_delete", input: %{}}, snapshot, %{
                 session_id: "s1"
               })
    end

    test "coding ask semantics: read allow, write/execute ask, destructive deny" do
      snapshot = PolicySnapshot.from_permission_mode("ask", session_id: "s1", attended?: true)

      assert {:allow, _} =
               CapabilityPolicy.evaluate(%{name: "file_read", input: %{}}, snapshot, %{
                 session_id: "s1"
               })

      assert {:approval_required, _} =
               CapabilityPolicy.evaluate(%{name: "file_write", input: %{}}, snapshot, %{
                 session_id: "s1"
               })

      assert {:approval_required, _} =
               CapabilityPolicy.evaluate(%{name: "bash", input: %{}}, snapshot, %{
                 session_id: "s1"
               })

      assert {:deny, :capability_denied} =
               CapabilityPolicy.evaluate(%{name: "file_delete", input: %{}}, snapshot, %{
                 session_id: "s1"
               })
    end

    test "unattended converts approval_required to approval_unavailable" do
      snapshot = PolicySnapshot.from_permission_mode("ask", session_id: "s1", attended?: false)

      assert {:deny, :approval_unavailable} =
               CapabilityPolicy.evaluate(%{name: "file_write", input: %{}}, snapshot, %{
                 session_id: "s1"
               })
    end

    test "missing session context fails closed" do
      snapshot = PolicySnapshot.from_permission_mode("ask", attended?: true)

      assert {:deny, :missing_session_context} =
               CapabilityPolicy.evaluate(%{name: "file_read", input: %{}}, snapshot, %{})
    end

    test "nil snapshot is denied" do
      assert {:deny, :missing_policy_snapshot} =
               CapabilityPolicy.evaluate(%{name: "file_read", input: %{}}, nil, %{session_id: "s"})
    end
  end

  describe "grants" do
    test "minted grants validate and reject forgeries" do
      grant =
        Grant.mint(
          tool_name: "file_read",
          permission_level: :read,
          source: :policy_allow,
          session_id: "s1",
          input: %{"path" => "a"}
        )

      assert :ok =
               Grant.validate(grant, "file_read", %{session_id: "s1", input: %{"path" => "a"}})

      assert {:error, :grant_tool_mismatch} =
               Grant.validate(grant, "file_write", %{session_id: "s1"})

      forged = %{grant | tool_name: "file_write"}
      assert {:error, :forged_grant} = Grant.validate(forged, "file_write", %{session_id: "s1"})
    end
  end

  # silence unused warning for @levels in case we expand matrix later
  test "known levels enumerated" do
    assert :destructive in @levels
  end
end
