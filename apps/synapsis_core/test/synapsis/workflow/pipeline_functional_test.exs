defmodule Synapsis.Workflow.PipelineFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workflow.Pipeline

  # Independently authored ordinary-success expectations for valid UTF-8 input
  # in the default pipeline dialect; no external workflow engine is executed.
  @fixture Path.expand(
             "../../../../synapsis_agent/test/fixtures/openclaw/488631c/lobster-pipeline.json",
             __DIR__
           )
  @external_resource @fixture

  @expected [
    %{
      "id" => "stage-trim-and-spacing",
      "input" => " \tjson  \"[1,2]\"  |  pick --field name \r\n",
      "stages" => [
        %{"name" => "json", "args" => %{"_" => ["[1,2]"]}, "raw" => ~S(json  "[1,2]")},
        %{
          "name" => "pick",
          "args" => %{"_" => [], "field" => "name"},
          "raw" => "pick --field name"
        }
      ]
    },
    %{
      "id" => "quoted-pipes",
      "input" => ~S(json "a|b" 'c|d' | join "|"),
      "stages" => [
        %{"name" => "json", "args" => %{"_" => ["a|b", "c|d"]}, "raw" => ~S(json "a|b" 'c|d')},
        %{"name" => "join", "args" => %{"_" => ["|"]}, "raw" => ~S(join "|")}
      ]
    },
    %{
      "id" => "single-quote-escapes",
      "input" => ~S(json 'C:\notes\q' 'it\'s'),
      "stages" => [
        %{
          "name" => "json",
          "args" => %{"_" => [~S(C:\notes\q), "it's"]},
          "raw" => ~S(json 'C:\notes\q' 'it\'s')
        }
      ]
    },
    %{
      "id" => "double-quote-known-escapes",
      "input" => ~S(json "a\"b" "c\\d" "\$cash"),
      "stages" => [
        %{
          "name" => "json",
          "args" => %{"_" => [~S(a"b), ~S(c\d), "$cash"]},
          "raw" => ~S(json "a\"b" "c\\d" "\$cash")
        }
      ]
    },
    %{
      "id" => "double-quote-backtick",
      "input" => ~S(json "\`tick"),
      "stages" => [
        %{"name" => "json", "args" => %{"_" => ["`tick"]}, "raw" => ~S(json "\`tick")}
      ]
    },
    %{
      "id" => "double-quote-unknown-escapes",
      "input" => ~S(json "\n\t\q"),
      "stages" => [
        %{"name" => "json", "args" => %{"_" => [~S(\n\t\q)]}, "raw" => ~S(json "\n\t\q")}
      ]
    },
    %{
      "id" => "double-quote-line-continuation",
      "input" => "json \"first\\\nsecond\"",
      "stages" => [
        %{
          "name" => "json",
          "args" => %{"_" => ["firstsecond"]},
          "raw" => "json \"first\\\nsecond\""
        }
      ]
    },
    %{
      "id" => "quote-concatenation-and-empty-tokens",
      "input" => ~S(json pre"mid"'tail' "" ''),
      "stages" => [
        %{
          "name" => "json",
          "args" => %{"_" => ["premidtail", "", ""]},
          "raw" => ~S(json pre"mid"'tail' "" '')
        }
      ]
    },
    %{
      "id" => "ascii-token-whitespace",
      "input" => "json\talpha\nbeta\rgamma",
      "stages" => [
        %{
          "name" => "json",
          "args" => %{"_" => ["alpha", "beta", "gamma"]},
          "raw" => "json\talpha\nbeta\rgamma"
        }
      ]
    },
    %{
      "id" => "internal-nbsp",
      "input" => "json alpha\u00A0beta",
      "stages" => [
        %{
          "name" => "json",
          "args" => %{"_" => ["alpha\u00A0beta"]},
          "raw" => "json alpha\u00A0beta"
        }
      ]
    },
    %{
      "id" => "nel-preserved",
      "input" => "\u0085json value\u0085",
      "stages" => [
        %{
          "name" => "\u0085json",
          "args" => %{"_" => ["value\u0085"]},
          "raw" => "\u0085json value\u0085"
        }
      ]
    },
    %{
      "id" => "ecmascript-outer-whitespace",
      "input" =>
        "\t\n\v\f\r \u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u2028\u2029\u202F\u205F\u3000\uFEFFjson value\uFEFF\u3000\u205F\u202F\u2029\u2028\u200A\u2009\u2008\u2007\u2006\u2005\u2004\u2003\u2002\u2001\u2000\u1680\u00A0 \r\f\v\n\t",
      "stages" => [
        %{"name" => "json", "args" => %{"_" => ["value"]}, "raw" => "json value"}
      ]
    },
    %{
      "id" => "unicode-text",
      "input" => ~S(json "雪😀" "é" "👩‍💻"),
      "stages" => [
        %{
          "name" => "json",
          "args" => %{"_" => ["雪😀", "é", "👩‍💻"]},
          "raw" => ~S(json "雪😀" "é" "👩‍💻")
        }
      ]
    },
    %{
      "id" => "flag-values-and-booleans",
      "input" => "pick --field=name --count 2 --verbose --final --value=a=b item",
      "stages" => [
        %{
          "name" => "pick",
          "args" => %{
            "_" => ["item"],
            "field" => "name",
            "count" => "2",
            "verbose" => true,
            "final" => true,
            "value" => "a=b"
          },
          "raw" => "pick --field=name --count 2 --verbose --final --value=a=b item"
        }
      ]
    },
    %{
      "id" => "repeated-flags",
      "input" => "pick --field first --field=last --toggle --toggle=false item",
      "stages" => [
        %{
          "name" => "pick",
          "args" => %{"_" => ["item"], "field" => "last", "toggle" => "false"},
          "raw" => "pick --field first --field=last --toggle --toggle=false item"
        }
      ]
    },
    %{
      "id" => "ordinary-json-value",
      "input" => "json --json payload tail",
      "stages" => [
        %{
          "name" => "json",
          "args" => %{"_" => ["tail"], "json" => "payload"},
          "raw" => "json --json payload tail"
        }
      ]
    },
    %{
      "id" => "exec-json-boolean",
      "input" => ~S(exec --json printf "%s" '{"x":1}'),
      "stages" => [
        %{
          "name" => "exec",
          "args" => %{"_" => ["printf", "%s", ~S({"x":1})], "json" => true},
          "raw" => ~S(exec --json printf "%s" '{"x":1}')
        }
      ]
    },
    %{
      "id" => "exec-json-explicit-string",
      "input" => "exec --json=false echo done",
      "stages" => [
        %{
          "name" => "exec",
          "args" => %{"_" => ["echo", "done"], "json" => "false"},
          "raw" => "exec --json=false echo done"
        }
      ]
    },
    %{
      "id" => "empty-flag-and-positional",
      "input" => ~S(json --label= ""),
      "stages" => [
        %{
          "name" => "json",
          "args" => %{"_" => [""], "label" => ""},
          "raw" => ~S(json --label= "")
        }
      ]
    },
    %{
      "id" => "quoted-flag-and-value",
      "input" => ~S(json "--field" "display name" item),
      "stages" => [
        %{
          "name" => "json",
          "args" => %{"_" => ["item"], "field" => "display name"},
          "raw" => ~S(json "--field" "display name" item)
        }
      ]
    },
    %{
      "id" => "unquoted-backslashes",
      "input" => ~S(json C:\tmp\file plain\word),
      "stages" => [
        %{
          "name" => "json",
          "args" => %{"_" => [~S(C:\tmp\file), ~S(plain\word)]},
          "raw" => ~S(json C:\tmp\file plain\word)
        }
      ]
    },
    %{
      "id" => "unquoted-backslash-before-pipe",
      "input" => ~S(json left\| json right),
      "stages" => [
        %{"name" => "json", "args" => %{"_" => ["left\\"]}, "raw" => "json left\\"},
        %{"name" => "json", "args" => %{"_" => ["right"]}, "raw" => "json right"}
      ]
    },
    %{
      "id" => "trailing-pipe",
      "input" => "json ready | \t",
      "stages" => [
        %{"name" => "json", "args" => %{"_" => ["ready"]}, "raw" => "json ready"}
      ]
    },
    %{
      "id" => "quoted-command-name",
      "input" => ~S("json"  "ready now"),
      "stages" => [
        %{
          "name" => "json",
          "args" => %{"_" => ["ready now"]},
          "raw" => ~S("json"  "ready now")
        }
      ]
    }
  ]

  test "every frozen successful source vector matches independently authored literals" do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    assert fixture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert fixture["vectors"] == @expected
  end

  test "native parser matches every frozen ordinary-success source vector" do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    for %{"id" => id, "input" => input, "stages" => stages} <- fixture["vectors"] do
      assert Pipeline.parse(input) == {:ok, stages}, id
    end
  end
end
