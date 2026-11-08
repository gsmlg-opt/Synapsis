defmodule Synapsis.Agent.Tools.PDFFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Tools.PDF.{Context, Model}
  alias Synapsis.{Models, Providers}

  test "ordinary inputs retain first-seen document order, defaults and explicit sorted page selection" do
    assert {:ok, input} =
             Context.normalize(
               %{"pdf" => " first.pdf ", "pdfs" => ["second.pdf", "first.pdf"]},
               %{}
             )

    assert input.references == ["first.pdf", "second.pdf"]
    assert input.prompt == "Analyze this PDF document."
    assert input.max_bytes == 10 * 1024 * 1024
    assert input.max_pages == 20
    assert input.page_numbers == nil

    assert {:ok, selected} =
             Context.normalize(
               %{
                 "pdf" => "ordinary.pdf",
                 "pages" => "4, 1-3, 2",
                 "prompt" => "Describe the figures",
                 "maxBytesMb" => 1
               },
               %{"pdfMaxPages" => 3}
             )

    assert selected.page_numbers == [1, 2, 3]
    assert selected.selection_truncated
    assert selected.prompt == "Describe the figures"
    assert selected.max_bytes == 1024 * 1024
  end

  test "configured candidate order, admitted override and imageModel secondary selection are explicit" do
    fixture = Gaoxy.Test.open()

    {:ok, provider} =
      Providers.create(%{
        name: "pdf-model-#{System.unique_integer([:positive])}",
        type: "openai",
        base_url: Gaoxy.Test.url(fixture),
        api_key_encrypted: "fixture"
      })

    records =
      for id <- ["gpt-4o", "gpt-4o-mini"],
          do: elem(Models.create(%{provider_id: provider.id, model: id}), 1)

    on_exit(fn ->
      Enum.each(records, &Models.delete/1)
      Providers.delete(provider.id)
    end)

    primary = provider.name <> "/gpt-4o"
    fallback = provider.name <> "/gpt-4o-mini"

    config = %{
      "pdfModel" => %{"primary" => primary, "fallbacks" => [fallback]},
      "imageModel" => fallback
    }

    assert {:ok, candidates} = Model.resolve(config, nil)
    assert Enum.map(candidates, & &1.reference) == [primary, fallback]
    assert Enum.all?(candidates, &(&1.protocol == "openai" and &1.supports_images))
    assert Enum.all?(candidates, &(&1.max_tokens == 4096))
    assert {:ok, [override]} = Model.resolve(config, fallback)
    assert override.reference == fallback
    assert {:ok, [secondary]} = Model.resolve(%{"imageModel" => fallback}, nil)
    assert secondary.reference == fallback

    assert {:ok, [fallback_only]} =
             Model.resolve(%{"pdfModel" => %{"fallbacks" => [fallback]}}, nil)

    assert fallback_only.reference == fallback

    for empty <- ["", "   ", %{}, %{"primary" => "", "fallbacks" => []}] do
      assert {:ok, [image]} = Model.resolve(%{"pdfModel" => empty, "imageModel" => fallback}, nil)
      assert image.reference == fallback
    end
  end
end
