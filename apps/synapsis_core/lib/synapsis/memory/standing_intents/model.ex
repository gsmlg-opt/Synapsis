defmodule Synapsis.Memory.StandingIntents.Model do
  @moduledoc """
  Pure standing-intent storage, public projection and lifecycle transformations.

  OpenClaw 488631c's model, create facade and SQL lifecycle define this boundary.
  Storage uses camelCase keys, JSON-text keywords and encoded scope strings;
  `to_intent/1` is a lossy public projection and must never replace a stored row.

  Creation takes already prepared strings, resolved integer timestamps/options,
  an externally generated UUID and an explicit clock observation. Tool argument
  preparation (including JavaScript Date.parse), candidate search, persistence,
  prompt delivery and scheduling belong to callers. Rows supplied to lifecycle
  functions must have the source's decoded integer-column shape.

  Match preparation and trigger membership are pure data operations, not indexed
  candidate search. Prepared maps use native snake_case atom keys and kind atoms;
  nil represents source undefined. Context helpers accept public projections and
  never commit fire accounting or inject a prompt themselves.
  """

  @active ~w(pending armed fired)
  @fields ~w(id description triggerKeywords triggerEmbedding channelScope senderScope
             creatorSender status expiresAt maxFires fireCount cooldownSeconds
             lastFiredAt createdAt sourceSessionId)
  @expiry_ms 7_776_000_000
  @injection_count 3
  @injection_chars 1_200
  @unix_epoch_days Calendar.ISO.date_to_iso_days(1970, 1, 1)
  @time_clip_ms 8_640_000_000_000_000
  @tokens ~r/[\p{L}\p{N}_-]+/u
  # ECMAScript WhiteSpace + LineTerminator, including BOM and excluding NEL.
  @trim ~r/\A[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+|[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+\z/u

  @type row :: %{required(String.t()) => term()}

  @doc "Encode a channel or conversation identity without losing provider/account custody."
  @spec encode_channel_scope(String.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def encode_channel_scope(scope, identity)
      when scope in ["channel", "conversation"] and is_map(identity) do
    with {:ok, provider} <- identity(Map.get(identity, :provider)),
         {:ok, account} <- account(Map.get(identity, :account_id)),
         provider = lowercase(provider),
         {:ok, target} <- channel_identity(scope, provider, identity) do
      Jason.encode(["v1", scope, provider, account, target])
    end
  end

  def encode_channel_scope(_, _), do: {:error, :invalid_scope}

  @doc "Encode a sender identity independently of the channel/conversation scope."
  @spec encode_sender_scope(map()) :: {:ok, String.t()} | {:error, atom()}
  def encode_sender_scope(identity) when is_map(identity) do
    with {:ok, provider} <- identity(Map.get(identity, :provider)),
         {:ok, account} <- account(Map.get(identity, :account_id)),
         {:ok, sender} <- identity(Map.get(identity, :sender_id)) do
      Jason.encode(["v1", lowercase(provider), account, sender])
    end
  end

  def encode_sender_scope(_), do: {:error, :invalid_identity}

  @doc "Construct a raw row from prepared domain values, without performing tool preparation."
  @spec new_row(String.t(), map(), integer()) :: {:ok, row()} | {:error, atom()}
  def new_row(id, %{"description" => description, "triggerKeywords" => keywords} = params, now)
      when is_binary(description) and is_list(keywords) and is_integer(now) do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         creator when is_binary(creator) <- known_creator(params["creatorSender"]),
         true <- Enum.all?(keywords, &is_binary/1),
         expires = default(params, "expiresAt", add(now, @expiry_ms)),
         max_fires = default(params, "maxFires", 3),
         cooldown = default(params, "cooldownSeconds", 86_400),
         true <- is_integer(expires) and is_integer(max_fires) and max_fires > 0,
         true <- is_integer(cooldown) and cooldown >= 0,
         true <- nullable_string?(params["channelScope"]),
         true <- nullable_string?(params["senderScope"]),
         true <- nullable_string?(params["sourceSessionId"]),
         {:ok, keyword_text} <- Jason.encode(keywords) do
      {:ok,
       %{
         "id" => id,
         "description" => description,
         "triggerKeywords" => keyword_text,
         "triggerEmbedding" => nil,
         "channelScope" => params["channelScope"],
         "senderScope" => params["senderScope"],
         "creatorSender" => creator,
         "status" => "armed",
         "expiresAt" => expires,
         "maxFires" => max_fires,
         "fireCount" => 0,
         "cooldownSeconds" => cooldown,
         "lastFiredAt" => nil,
         "createdAt" => now,
         "sourceSessionId" => params["sourceSessionId"]
       }}
    else
      _ -> {:error, :invalid_prepared_row}
    end
  end

  def new_row(_, _, _), do: {:error, :invalid_prepared_row}

  @doc "Project a raw storage row to the source's public intent shape."
  @spec to_intent(row()) :: map()
  def to_intent(row) do
    {scope, channel} = channel_projection(row["channelScope"])

    row
    |> Map.take(@fields)
    |> Map.merge(%{
      "scope" => scope,
      "channelScope" => channel,
      "senderScope" => sender_projection(row["senderScope"]),
      "creatorSender" => known_creator(row["creatorSender"]),
      "triggerKeywords" => keyword_projection(row["triggerKeywords"])
    })
  end

  @doc "Expire active rows before rearming cooled-down fired rows; preserve all other fields."
  @spec maintain(row(), integer()) :: row()
  def maintain(row, now) when is_integer(now) do
    cond do
      row["status"] in @active and row["expiresAt"] <= now ->
        Map.put(row, "status", "expired")

      row["status"] == "fired" and row["expiresAt"] > now and
        row["fireCount"] < row["maxFires"] and not is_nil(row["lastFiredAt"]) and
          rearm_at(row) <= now ->
        Map.put(row, "status", "armed")

      true ->
        row
    end
  end

  @doc "Earliest deadline from rows maintained at one observation time; :infinity means none."
  @spec next_due([row()]) :: integer() | :infinity
  def next_due(rows) do
    Enum.reduce(rows, :infinity, fn row, due ->
      if row["status"] in @active do
        expiry = min(due, row["expiresAt"])

        if row["status"] == "fired" and row["fireCount"] < row["maxFires"] and
             not is_nil(row["lastFiredAt"]),
           do: min(expiry, rearm_at(row)),
           else: expiry
      else
        due
      end
    end)
  end

  @doc "Prospective fire transition; caller still owns exact search, context fit and atomic commit."
  @spec fire(row(), integer()) :: row() | nil
  def fire(row, now) when is_integer(now) do
    if row["status"] == "armed" and not is_nil(known_creator(row["creatorSender"])) and
         row["expiresAt"] > now and row["fireCount"] < row["maxFires"] and
         (is_nil(row["lastFiredAt"]) or rearm_at(row) <= now) do
      count = add(row["fireCount"], 1)

      Map.merge(row, %{
        "fireCount" => count,
        "lastFiredAt" => now,
        "status" => if(count >= row["maxFires"], do: "done", else: "fired")
      })
    end
  end

  @doc "Cancel an active raw row without implicitly performing expiry maintenance."
  @spec cancel(row() | nil) :: row() | nil
  def cancel(%{"status" => status} = row) when status in @active,
    do: Map.put(row, "status", "cancelled")

  def cancel(_), do: nil

  @doc "Extract source Unicode letter/number/underscore/hyphen tokens, retaining duplicates."
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text) when is_binary(text) do
    Regex.scan(@tokens, lowercase(text)) |> List.flatten()
  end

  @doc "Prepare ordered unique prompt tokens, a text-query AST and encoded scope identities."
  @spec prepare_match(map()) :: map() | nil
  def prepare_match(%{prompt: prompt} = params) do
    case prompt |> tokenize() |> Enum.uniq() do
      [] ->
        nil

      tokens ->
        provider = optional_identity(params[:provider])
        provider = if provider, do: lowercase(provider)
        channel = optional_identity(params[:channel])
        sender = optional_identity(params[:sender_id])

        identity = %{
          provider: provider,
          account_id: params[:account_id],
          conversation_id: channel
        }

        scopes =
          if provider do
            kinds = if channel, do: ["channel", "conversation"], else: ["channel"]

            Enum.map(kinds, fn kind ->
              {:ok, encoded} = encode_channel_scope(kind, identity)
              encoded
            end)
          else
            []
          end

        sender_scope =
          if provider && sender do
            {:ok, encoded} = encode_sender_scope(Map.put(identity, :sender_id, sender))
            encoded
          end

        %{
          prompt_tokens: tokens,
          fts_query: %{kind: :any, clauses: Enum.map(tokens, &%{kind: :phrase, text: &1})},
          channel_scopes: scopes,
          sender_scope: sender_scope,
          now_ms: params[:now_ms]
        }
    end
  end

  @doc "Match any stored keyword's complete token set; candidate admission is a separate step."
  @spec trigger_matches?(row(), [String.t()]) :: boolean()
  def trigger_matches?(row, prompt_tokens) do
    prompt = MapSet.new(prompt_tokens)

    row["triggerKeywords"]
    |> keyword_projection()
    |> Enum.any?(fn keyword ->
      tokens = tokenize(keyword)
      tokens != [] and Enum.all?(tokens, &MapSet.member?(prompt, &1))
    end)
  end

  @doc "Check the complete source render against its intent count and UTF-16-unit limits."
  @spec context_fits?([map()]) :: boolean()
  def context_fits?(intents) do
    length(intents) <= @injection_count and
      utf16_length(render_context(intents)) <= @injection_chars
  end

  @doc "Build verbatim dated context from fitting entries among the first three public intents."
  @spec build_context([map()]) :: String.t() | nil
  def build_context(intents) do
    included =
      intents
      |> Enum.take(@injection_count)
      |> Enum.reduce([], fn intent, included ->
        candidate = included ++ [intent]
        if context_fits?(candidate), do: candidate, else: included
      end)

    if included != [], do: render_context(included)
  end

  @doc "Source turn eligibility only; this predicate does not establish trusted ingress identity."
  @spec eligible_turn?(map()) :: boolean()
  def eligible_turn?(context) do
    context[:trigger] == "user" and
      (present_string?(context[:session_key]) or present_string?(context[:session_id])) and
      (normalized_provider(context[:message_provider]) == "webchat" or
         not is_nil(optional_identity(context[:channel_id])) or
         not is_nil(optional_identity(context[:chat_id])))
  end

  defp render_context(intents) do
    lines =
      Enum.map_join(intents, "\n", fn intent ->
        "Standing intent (created #{created_date(intent["createdAt"])}): #{intent["description"]}"
      end)

    "<standing_intents>\n" <> lines <> "\n</standing_intents>"
  end

  defp created_date(timestamp)
       when is_integer(timestamp) and timestamp >= -@time_clip_ms and timestamp <= @time_clip_ms do
    {year, month, day} =
      timestamp
      |> Integer.floor_div(86_400_000)
      |> Kernel.+(@unix_epoch_days)
      |> Calendar.ISO.date_from_iso_days()

    iso_year =
      cond do
        year in 0..9999 -> String.pad_leading(Integer.to_string(year), 4, "0")
        year < 0 -> "-" <> String.pad_leading(Integer.to_string(-year), 6, "0")
        true -> "+" <> String.pad_leading(Integer.to_string(year), 6, "0")
      end

    # Source slices the ISO timestamp's first ten UTF-16 units, including for
    # signed extended years. This date prefix is entirely ASCII.
    date = iso_year <> "-" <> two_digits(month) <> "-" <> two_digits(day)
    binary_part(date, 0, 10)
  end

  defp created_date(_), do: raise(ArgumentError, "invalid standing-intent creation date")
  defp two_digits(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp utf16_length(value),
    do: div(byte_size(:unicode.characters_to_binary(value, :utf8, {:utf16, :big})), 2)

  defp present_string?(value), do: is_binary(value) and value != ""
  defp optional_identity(nil), do: nil

  defp optional_identity(value) when is_binary(value) do
    case trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalized_provider(value) do
    case optional_identity(value) do
      nil -> nil
      provider -> lowercase(provider)
    end
  end

  defp channel_identity("channel", provider, _), do: {:ok, provider}
  defp channel_identity("conversation", _, params), do: identity(params[:conversation_id])

  defp identity(value) when is_binary(value) do
    case trim(value) do
      "" -> {:error, :invalid_identity}
      value -> {:ok, value}
    end
  end

  defp identity(_), do: {:error, :invalid_identity}

  defp account(nil), do: {:ok, "default"}

  defp account(value) when is_binary(value) do
    case trim(value) do
      "" -> {:ok, "default"}
      value -> {:ok, value}
    end
  end

  defp account(_), do: {:error, :invalid_identity}

  defp known_creator(value) when is_binary(value) do
    value = trim(value)
    if value != "" and lowercase(value) != "unknown", do: value
  end

  defp known_creator(_), do: nil

  defp stored_scope(text, count) when is_binary(text) do
    with {:ok, ["v1" | _] = parts} <- Jason.decode(text),
         true <- length(parts) == count,
         true <- Enum.all?(parts, &(is_binary(&1) and &1 != "")) do
      parts
    else
      _ -> nil
    end
  end

  defp stored_scope(_, _), do: nil

  defp channel_projection(text) do
    case stored_scope(text, 5) do
      ["v1", kind, _, _, identity] when kind in ["channel", "conversation"] -> {kind, identity}
      _ -> {"anywhere", nil}
    end
  end

  defp sender_projection(text) do
    case stored_scope(text, 4) do
      ["v1", _, _, sender] -> sender
      _ -> nil
    end
  end

  defp keyword_projection(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, keywords} when is_list(keywords) ->
        Enum.filter(keywords, &(is_binary(&1) and &1 != ""))

      _ ->
        []
    end
  end

  defp keyword_projection(_), do: []

  defp default(params, key, fallback) do
    case Map.get(params, key) do
      nil -> fallback
      value -> value
    end
  end

  defp nullable_string?(value), do: is_nil(value) or is_binary(value)
  defp trim(value), do: Regex.replace(@trim, value, "")
  defp lowercase(value), do: String.downcase(value, :greek)

  # Source arithmetic is binary64 even for decoded integral values. Round at
  # each operation before converting an integral result back to a storage value.
  defp add(left, right), do: trunc(left / 1 + right / 1)
  defp rearm_at(row), do: add(row["lastFiredAt"], trunc(row["cooldownSeconds"] / 1 * 1_000))
end
