defmodule Synapsis.Tool.Capability.PolicySnapshot do
  @moduledoc """
  Immutable capability policy captured at admission / turn start (Track C).
  """

  @profiles ~w(read_only heartbeat reflect coding maintenance dangerous)a

  @enforce_keys [:profile, :attended?]
  defstruct [
    :profile,
    :attended?,
    :session_id,
    :run_id,
    :permission_mode,
    allow_levels: [],
    deny_levels: [],
    approval_levels: [],
    capability_overrides: %{},
    metadata: %{}
  ]

  @type profile ::
          :read_only | :heartbeat | :reflect | :coding | :maintenance | :dangerous

  @type t :: %__MODULE__{
          profile: profile(),
          attended?: boolean(),
          session_id: String.t() | nil,
          run_id: String.t() | nil,
          permission_mode: String.t() | nil,
          allow_levels: [atom()],
          deny_levels: [atom()],
          approval_levels: [atom()],
          capability_overrides: map(),
          metadata: map()
        }

  @doc "Build a snapshot for a named tool profile."
  @spec for_profile(profile() | String.t(), keyword()) :: t()
  def for_profile(profile, opts \\ []) do
    profile = normalize_profile(profile)

    {allow, approve, deny} = profile_levels(profile)

    %__MODULE__{
      profile: profile,
      attended?: Keyword.get(opts, :attended?, profile == :coding),
      session_id: Keyword.get(opts, :session_id),
      run_id: Keyword.get(opts, :run_id),
      permission_mode: Keyword.get(opts, :permission_mode),
      allow_levels: allow,
      approval_levels: approve,
      deny_levels: deny,
      capability_overrides: Keyword.get(opts, :capability_overrides, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Build a coding snapshot from an agent/session permission mode."
  @spec from_permission_mode(String.t() | atom() | nil, keyword()) :: t()
  def from_permission_mode(mode, opts \\ []) do
    mode = mode |> to_string() |> String.downcase()

    {allow, approve, deny} =
      case mode do
        "yolo" ->
          {[:none, :read, :write, :execute, :destructive], [], []}

        "restrict" ->
          {[:none], [:read, :write, :execute, :destructive], []}

        # Corrected ask semantics (C-006)
        _ask ->
          {[:none, :read], [:write, :execute], [:destructive]}
      end

    %__MODULE__{
      profile: :coding,
      attended?: Keyword.get(opts, :attended?, true),
      session_id: Keyword.get(opts, :session_id),
      run_id: Keyword.get(opts, :run_id),
      permission_mode: mode,
      allow_levels: allow,
      approval_levels: approve,
      deny_levels: deny,
      capability_overrides: Keyword.get(opts, :capability_overrides, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Build a coding snapshot from a live session permission config."
  @spec from_session_config(Synapsis.Tool.Permission.SessionConfig.t(), keyword()) :: t()
  def from_session_config(%Synapsis.Tool.Permission.SessionConfig{} = config, opts \\ []) do
    {allow, approve, deny} =
      Enum.reduce(
        [
          {:read, config.allow_read},
          {:write, config.allow_write},
          {:execute, config.allow_execute},
          {:destructive, config.allow_destructive}
        ],
        {[:none], [], []},
        fn {level, setting}, {allow_acc, ask_acc, deny_acc} ->
          case setting do
            :allow -> {[level | allow_acc], ask_acc, deny_acc}
            :ask -> {allow_acc, [level | ask_acc], deny_acc}
            :deny -> {allow_acc, ask_acc, [level | deny_acc]}
            _ -> {allow_acc, [level | ask_acc], deny_acc}
          end
        end
      )

    overrides =
      config.overrides
      |> List.wrap()
      |> Enum.reduce(%{}, fn
        %{pattern: pattern, decision: decision}, acc ->
          Map.put(acc, pattern, decision)

        {pattern, decision}, acc ->
          Map.put(acc, pattern, decision)

        _, acc ->
          acc
      end)

    %__MODULE__{
      profile: :coding,
      attended?: Keyword.get(opts, :attended?, true),
      session_id: config.session_id || Keyword.get(opts, :session_id),
      run_id: Keyword.get(opts, :run_id),
      permission_mode: Keyword.get(opts, :permission_mode),
      allow_levels: Enum.reverse(allow),
      approval_levels: Enum.reverse(approve),
      deny_levels: Enum.reverse(deny),
      capability_overrides: Map.merge(overrides, Keyword.get(opts, :capability_overrides, %{})),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec profiles() :: [profile()]
  def profiles, do: @profiles

  defp normalize_profile(profile) when is_atom(profile) and profile in @profiles, do: profile

  defp normalize_profile(profile) when is_binary(profile) do
    profile
    |> String.to_existing_atom()
    |> normalize_profile()
  rescue
    ArgumentError -> :coding
  end

  defp normalize_profile(_), do: :coding

  defp profile_levels(:read_only), do: {[:none, :read], [], [:write, :execute, :destructive]}

  defp profile_levels(:heartbeat),
    do: {[:none, :read], [], [:write, :execute, :destructive]}

  defp profile_levels(:reflect),
    do: {[:none, :read], [:write], [:execute, :destructive]}

  defp profile_levels(:coding), do: {[:none, :read], [:write, :execute], [:destructive]}

  defp profile_levels(:maintenance),
    do: {[:none, :read, :write], [:execute], [:destructive]}

  defp profile_levels(:dangerous),
    do: {[:none, :read, :write, :execute, :destructive], [], []}
end
