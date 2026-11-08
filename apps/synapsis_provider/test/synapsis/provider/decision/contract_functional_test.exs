defmodule Synapsis.Provider.Decision.ContractFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.Decision

  test "V2 accepts six named question kinds with their supplied positional evidence" do
    groups = [
      {%{"type" => "text", "text" => "Evidence"},
       %{
         "boolean" => %{"type" => "boolean"},
         "choice" => %{"type" => "choice", "criteria" => %{"a" => nil, "b" => "B"}},
         "score" => %{"type" => "score", "criteria" => ["Low", "High"]},
         "tags" => %{"type" => "tags", "criteria" => %{"blue" => "Blue"}}
       }},
      {%{"type" => "image", "dataUri" => "data:image/png;base64,AA=="},
       %{
         "box" => %{"type" => "box", "instructions" => "Locate the object"}
       }},
      {%{
         "type" => "list",
         "items" => [%{"id" => "b", "content" => ["B"]}, %{"id" => "a", "content" => nil}]
       },
       %{
         "sort" => %{"type" => "sort", "instructions" => "Order supplied IDs"}
       }}
    ]

    for {state, questions} <- groups do
      assert {:ok, batch} =
               Decision.normalize(%{
                 "contractVersion" => 2,
                 "state" => state,
                 "questions" => questions
               })

      assert batch == %{"state" => state, "questions" => questions}
    end

    types =
      Decision.schema()["properties"]["questions"]["additionalProperties"]["anyOf"]
      |> Enum.map(&get_in(&1, ["properties", "type", "const"]))

    assert Enum.sort(types) == ~w(boolean box choice score sort tags)
  end

  test "generic choice and list evidence retain their provider neutral positive ceilings" do
    criteria = Map.new(1..256, &{"option-#{&1}", "Option #{&1}"})

    assert {:ok, _} =
             Decision.normalize(%{
               "contractVersion" => 2,
               "state" => %{"type" => "text", "text" => "Evidence"},
               "questions" => %{"q" => %{"type" => "choice", "criteria" => criteria}}
             })

    items = Enum.map(1..120, &%{"id" => "item-#{&1}", "content" => "Item #{&1}"})

    assert {:ok, batch} =
             Decision.normalize(%{
               "contractVersion" => 2,
               "state" => %{"type" => "list", "items" => items},
               "questions" => %{"q" => %{"type" => "sort"}}
             })

    assert batch["state"]["items"] == items
  end

  test "generic results preserve explicit answers abstentions estimates metadata and extended usage" do
    {:ok, batch} =
      Decision.normalize(%{
        "contractVersion" => 2,
        "state" => %{"type" => "text", "text" => "Evidence"},
        "questions" => %{
          "b" => %{"type" => "boolean"},
          "c" => %{"type" => "choice", "criteria" => %{"a" => nil, "b" => "B"}},
          "s" => %{"type" => "score", "criteria" => ["Low", "High"]},
          "t" => %{"type" => "tags", "criteria" => %{"blue" => "Blue", "red" => "Red"}}
        }
      })

    result = %{
      "model" => "returned",
      "answers" => %{
        "b" => %{"type" => "boolean", "answer" => nil, "probabilityTrue" => 0.4},
        "c" => %{
          "type" => "choice",
          "choice" => "a",
          "probabilities" => %{"a" => 0.2, "b" => 0.7},
          "confidence" => -0.2,
          "metadata" => %{"route" => "fixture"}
        },
        "s" => %{"type" => "score", "score" => 0.71, "probabilities" => [0.3, 0.69]},
        "t" => %{
          "type" => "tags",
          "tags" => [
            %{"id" => "red", "applies" => false},
            %{"id" => "blue", "applies" => nil, "probability" => 0.25}
          ]
        }
      },
      "usage" => %{
        "inputTokens" => 3,
        "outputTokens" => 0,
        "costUsd" => 0,
        "units" => %{"unit" => "requests", "amount" => 1},
        "raw" => %{"vendor" => [1, 2]}
      },
      "metadata" => %{"provider" => "fixture"}
    }

    assert Decision.validate_result(batch, result)
    assert result["answers"]["c"]["choice"] == "a"
  end

  test "categorical boolean capability preserves a supplied zero scalar probability" do
    {:ok, batch} =
      Decision.normalize(%{
        "contractVersion" => 2,
        "state" => %{"type" => "text", "text" => "Supplied evidence"},
        "questions" => %{"check" => %{"type" => "boolean"}}
      })

    result = %{
      "model" => "returned",
      "answers" => %{"check" => %{"type" => "boolean", "probabilityTrue" => 0.0}}
    }

    capabilities = %{
      "questions" => %{"boolean" => %{"probabilities" => "categorical", "abstention" => false}}
    }

    assert Decision.validate_result(batch, result, capabilities)
    assert result["answers"]["check"]["probabilityTrue"] === 0.0
  end

  test "tag capability with omitted abstention preserves an explicit abstention and estimates" do
    {:ok, batch} =
      Decision.normalize(%{
        "contractVersion" => 2,
        "state" => %{"type" => "text", "text" => "Supplied evidence"},
        "questions" => %{"tag" => %{"type" => "tags", "criteria" => %{"blue" => "Blue"}}}
      })

    result = %{
      "model" => "returned",
      "answers" => %{
        "tag" => %{
          "type" => "tags",
          "tags" => [%{"id" => "blue", "applies" => nil, "probability" => 0.25}]
        }
      }
    }

    capabilities = %{"questions" => %{"tags" => %{"probabilities" => "independent"}}}
    assert Decision.validate_result(batch, result, capabilities)

    assert result["answers"]["tag"]["tags"] == [
             %{"id" => "blue", "applies" => nil, "probability" => 0.25}
           ]
  end

  test "box coordinates and complete sort order remain supplied results" do
    {:ok, image} =
      Decision.normalize(%{
        "contractVersion" => 2,
        "state" => %{"type" => "image", "dataUri" => "data:image/png;base64,AA=="},
        "questions" => %{"q" => %{"type" => "box", "instructions" => "Locate object"}}
      })

    box = %{"top" => 0.1, "bottom" => 0.8, "left" => 0.2, "right" => 0.7}

    assert Decision.validate_result(image, %{
             "model" => "returned",
             "answers" => %{"q" => %{"type" => "box", "box" => box, "confidence" => 0.91}}
           })

    {:ok, list} =
      Decision.normalize(%{
        "contractVersion" => 2,
        "state" => %{
          "type" => "list",
          "items" => [%{"id" => "b", "content" => "B"}, %{"id" => "a", "content" => "A"}]
        },
        "questions" => %{"q" => %{"type" => "sort"}}
      })

    assert Decision.validate_result(list, %{
             "model" => "returned",
             "answers" => %{
               "q" => %{"type" => "sort", "order" => ["a", "b"], "confidence" => nil}
             }
           })
  end
end
