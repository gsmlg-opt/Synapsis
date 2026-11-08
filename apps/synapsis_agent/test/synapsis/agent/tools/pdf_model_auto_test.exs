defmodule Synapsis.Agent.Tools.PDFModelAutoTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Tools.PDF.Model
  alias Synapsis.{Config.Store, Models, Providers}

  setup do
    for type <- [:model, :provider], do: Synapsis.DataCase.clear_config_store(type)

    on_exit(fn ->
      for provider <- Store.list(:provider), do: Providers.delete(provider["id"])
      Synapsis.DataCase.clear_config_store(:model)
    end)

    :ok
  end

  test "native group precedes tied generic priority and each saved account retains its distinct UUID" do
    a = account("a-native", "anthropic", "anthropic", [vision("native-a")], 1)
    b = account("b-native", "anthropic", "anthropic", [vision("native-b")], 2)
    g = account("c-google", "google", "google", [vision("gemini")], 3)
    o = account("z-openai", "openai", "openai", [vision("vision")], 4)

    assert_resolved(%{}, context(o, "vision"), [
      "a-native/native-a",
      "b-native/native-b",
      "c-google/gemini",
      "z-openai/vision"
    ])

    assert {:ok, prepared} = Model.prepare(%{}, context(o, "vision"))

    assert Enum.map(prepared.models, & &1.provider_id) == [
             a.provider.id,
             b.provider.id,
             g.provider.id,
             o.provider.id
           ]

    assert Enum.uniq(Enum.map(prepared.models, & &1.model_id)) |> length() == 4
    assert Enum.map(prepared.models, & &1.native) == [true, true, true, false]
  end

  test "configured native primary precedes another native provider with earlier static priority" do
    account("anthropic", "anthropic", "anthropic", [vision("native-chosen")], 1)
    google = account("google", "google", "google", [vision("gemini-chosen")], 2)
    account("openai", "openai", "openai", [vision("vision-chosen")], 3)

    assert_resolved(%{}, context(google, "base"), [
      "google/gemini-chosen",
      "anthropic/native-chosen",
      "openai/vision-chosen"
    ])
  end

  test "pinned native and generic defaults participate only through already saved exact model records" do
    a = account("anthropic", "anthropic", "anthropic", [%{id: "claude-opus-5-5"}], 1)
    account("google", "google", "google", [%{id: "gemini-3-flash-preview"}], 2)
    account("openai", "openai", "openai", [%{id: "gpt-6-astra"}], 3)
    active = account("custom", nil, "openai", [%{id: "active-never-preferred"}], 4)

    ctx =
      Map.put(context(a, "base"), :active_model, %{
        provider: active.provider.name,
        model: "active-never-preferred",
        supports_images: true
      })

    assert_resolved(%{}, ctx, [
      "anthropic/claude-opus-5-5",
      "google/gemini-3-flash-preview",
      "openai/gpt-6-astra"
    ])
  end

  test "configured text primary follows native PDF and precedes generic images with image false retained" do
    text =
      account("minimax", "minimax", "openai", [text("text-primary"), vision("ordinary-image")], 1)

    account("anthropic", "anthropic", "anthropic", [vision("native")], 2)
    account("openai", "openai", "openai", [vision("vision")], 3)

    assert_resolved(%{}, context(text, "text-primary"), [
      "anthropic/native",
      "minimax/text-primary",
      "openai/vision"
    ])
  end

  test "nonprimary text hint uses first configured text and source document default when preferred equals image default" do
    o = account("openai", "openai", "openai", [vision("vision")], 1)

    m =
      account(
        "minimax",
        "minimax",
        "openai",
        [text("text-first"), text("text-second"), vision("MiniMax-VL-01"), text("MiniMax-M2.7")],
        2
      )

    assert_resolved(%{}, context(o, "vision"), ["openai/vision", "minimax/text-first"])
    assert_resolved(%{}, context(m, "MiniMax-VL-01"), ["minimax/MiniMax-M2.7", "openai/vision"])
  end

  test "text extraction default remains after generic image when no configured text metadata exists" do
    o = account("openai", "openai", "openai", [vision("vision")], 1)
    account("minimax", "minimax", "openai", [%{id: "MiniMax-M2.7"}], 2)
    assert_resolved(%{}, context(o, "vision"), ["openai/vision", "minimax/MiniMax-M2.7"])
  end

  test "configured custom vision models follow persisted source order rather than alphabetic picker order" do
    custom = account("custom", nil, "openai", [vision("z-first"), vision("a-second")], 1)
    account("other", nil, "openai", [vision("other-image")], 2)
    assert_resolved(%{}, context(custom, "text"), ["custom/z-first", "other/other-image"])
    [first, second] = custom.models
    assert {:ok, _} = Models.update(first, %{selection_order: 2})
    assert {:ok, _} = Models.update(second, %{selection_order: 0})
    assert :ok = Store.reload(:model)
    assert_resolved(%{}, context(custom, "text"), ["custom/a-second", "other/other-image"])
  end

  test "self-prefixed configured model preserves both complete source refs as distinct saved model identities" do
    c = account("custom", nil, "openai", [vision("custom/vision-one"), %{id: "vision-one"}], 1)
    assert {:ok, result} = Model.resolve(%{}, nil, context(c, "text"))
    assert refs(result) == ["custom/vision-one", "custom/custom/vision-one"]
    assert Enum.map(result, & &1.model) == ["vision-one", "custom/vision-one"]
    assert Enum.map(result, & &1.model_id) == [Enum.at(c.models, 1).id, hd(c.models).id]
  end

  test "canonical execution alias retains saved instance and text preference" do
    c =
      account(
        "minimax-cn",
        "minimax",
        "openai",
        [text("text-china"), vision("ordinary-image")],
        1
      )

    assert_resolved(%{}, context(c, "text-china"), ["minimax-cn/text-china"])
  end

  test "actual image-capable active fallback is used only after every automatic lane and preserves slash-bearing model ID" do
    c = account("custom", nil, "openai", [%{id: "active/with/slashes"}], 1)

    ctx =
      Map.put(context(c, "text"), :active_model, %{
        provider: "custom",
        model: "active/with/slashes",
        supports_images: true
      })

    assert_resolved(%{}, ctx, ["custom/active/with/slashes"])
    assert {:ok, [candidate]} = Model.resolve(%{}, nil, ctx)
    assert candidate.model == "active/with/slashes"
    assert candidate.model_id == hd(c.models).id
    assert {:ok, runtime} = Model.runtime(candidate)
    assert runtime.provider_id == c.provider.id
  end

  test "existing explicit PDF and image precedence and admitted override remain independent of automatic order" do
    o = account("openai", "openai", "openai", [vision("gpt-4o"), vision("gpt-4o-mini")], 1)
    account("anthropic", "anthropic", "anthropic", [vision("native")], 2)

    config = %{
      "pdfModel" => %{
        "primary" => " openai/gpt-4o ",
        "fallbacks" => ["openai/gpt-4o-mini", "openai/gpt-4o"]
      },
      "imageModel" => "anthropic/native"
    }

    assert_resolved(config, context(o, "gpt-4o"), ["openai/gpt-4o", "openai/gpt-4o-mini"])
    assert {:ok, [override]} = Model.resolve(config, "openai/gpt-4o-mini")
    assert override.reference == "openai/gpt-4o-mini"
    assert {:ok, [image]} = Model.resolve(%{"imageModel" => "openai/gpt-4o-mini"}, nil)
    assert image.reference == "openai/gpt-4o-mini"
  end

  test "complete selection generation changes on ordinary nonselected inputs even when full candidate refs stay the same" do
    a = account("anthropic", "anthropic", "anthropic", [vision("native"), text("nonselected")], 1)
    c = account("custom", nil, "openai", [%{id: "active"}, %{id: "active-second"}], 2)

    ctx =
      Map.put(context(a, "base"), :active_model, %{
        provider: "custom",
        model: "active",
        supports_images: true
      })

    assert {:ok, before} = Model.prepare(%{}, ctx)
    assert refs(before.models) == ["anthropic/native"]
    assert is_binary(before.fingerprint)
    assert {:ok, same} = Model.prepare(%{}, ctx)
    assert same.fingerprint == before.fingerprint

    assert {:ok, _} =
             Models.update(Enum.at(a.models, 1), %{input: ["text", "audio"], selection_order: 8})

    assert {:ok, modality} = Model.prepare(%{}, ctx)
    assert refs(modality.models) == ["anthropic/native"]
    refute modality.fingerprint == before.fingerprint

    assert {:ok, _} =
             Providers.update(a.provider.id, %{
               config: %{
                 "media_understanding" => %{
                   "profile" => "anthropic",
                   "autoPriority" => %{"image" => 21}
                 }
               }
             })

    assert {:ok, metadata} = Model.prepare(%{}, ctx)
    assert refs(metadata.models) == ["anthropic/native"]
    refute metadata.fingerprint == modality.fingerprint

    changed_default = %{
      ctx
      | configured_default: %{provider: a.provider.name, model: "another-default"}
    }

    assert {:ok, default} = Model.prepare(%{}, changed_default)
    assert refs(default.models) == ["anthropic/native"]
    refute default.fingerprint == metadata.fingerprint

    changed_active = %{
      changed_default
      | active_model: %{provider: c.provider.name, model: "active-second", supports_images: true}
    }

    assert {:ok, active} = Model.prepare(%{}, changed_active)
    assert refs(active.models) == ["anthropic/native"]
    refute active.fingerprint == default.fingerprint
  end

  defp refs(models), do: Enum.map(models, & &1.reference)
  defp vision(id), do: %{id: id, input: ["text", "image"]}
  defp text(id), do: %{id: id, input: ["text"]}

  defp context(account, model),
    do: %{configured_default: %{provider: account.provider.name, model: model}, active_model: nil}

  defp assert_resolved(config, context, expected) do
    assert {:ok, candidates} = Model.resolve(config, nil, context)
    assert refs(candidates) == expected
    assert {:ok, prepared} = Model.prepare(config, context)
    assert refs(prepared.models) == expected
    assert Enum.all?(candidates, & &1.available)
    assert Enum.all?(candidates, &(is_binary(&1.provider_id) and is_binary(&1.model_id)))
  end

  defp account(name, profile, type, inputs, index) do
    fixture = Gaoxy.Test.open()
    config = if profile, do: %{"media_understanding" => %{"profile" => profile}}, else: %{}
    id = "00000000-0000-4000-8000-" <> String.pad_leading(to_string(index), 12, "0")

    assert {:ok, provider} =
             Providers.create(%{
               id: id,
               name: name,
               type: type,
               base_url: Gaoxy.Test.url(fixture),
               api_key_encrypted: "ordinary-fixture",
               config: config
             })

    assert {:ok, models} =
             Models.import(
               provider.id,
               Enum.with_index(inputs, fn attrs, i -> Map.put(attrs, :selection_order, i) end)
             )

    %{provider: provider, models: models, fixture: fixture}
  end
end
