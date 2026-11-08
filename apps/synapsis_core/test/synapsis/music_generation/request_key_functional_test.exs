defmodule Synapsis.MusicGeneration.RequestKeyFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.MusicGeneration.RequestKey

  # Literal prepared-payload expectations, independent of production encoding.
  # The source request-key serializer retains undefined object fields.
  test "minimal prepared prompt retains all ten ASCII-sorted fields and undefined values" do
    canonical =
      ~S({"durationSeconds":undefined,"filename":undefined,"format":undefined,"imageInputs":[],"instrumental":undefined,"lyrics":undefined,"model":undefined,"prompt":"song","provider":undefined,"tool":"music_generate"})

    for request <- [
          %{prompt: "song"},
          %{prompt: "song", quality: "high", request_key: "ignored", tool: "caller-label"}
        ] do
      assert RequestKey.build(request) ===
               {:ok,
                %{
                  canonical: canonical,
                  digest: "26ed9d0598216e73b664f11eb6d33f4fbaa676756ab4aadadf89aab3c787b882"
                }}
    end
  end

  test "nil optional prepared fields mean unset and nil reference input means an empty array" do
    request = %{
      prompt: "song",
      provider: nil,
      model: nil,
      lyrics: nil,
      instrumental: nil,
      duration_seconds: nil,
      format: nil,
      filename: nil,
      image_inputs: nil
    }

    assert RequestKey.build(request) ===
             {:ok,
              %{
                canonical:
                  ~S({"durationSeconds":undefined,"filename":undefined,"format":undefined,"imageInputs":[],"instrumental":undefined,"lyrics":undefined,"model":undefined,"prompt":"song","provider":undefined,"tool":"music_generate"}),
                digest: "26ed9d0598216e73b664f11eb6d33f4fbaa676756ab4aadadf89aab3c787b882"
              }}
  end

  test "complete prepared payload sorts ten fields and preserves an explicit false instrumental flag" do
    request = %{
      tool: "unused caller tool label",
      prompt: "make a song",
      provider: "comfy",
      model: "model-A",
      lyrics: "Verse one",
      instrumental: false,
      duration_seconds: 90,
      format: "wav",
      filename: "track.wav",
      image_inputs: ["first.png", "second.png"]
    }

    assert RequestKey.build(request) ===
             {:ok,
              %{
                canonical:
                  ~S({"durationSeconds":90,"filename":"track.wav","format":"wav","imageInputs":["first.png","second.png"],"instrumental":false,"lyrics":"Verse one","model":"model-A","prompt":"make a song","provider":"comfy","tool":"music_generate"}),
                digest: "1bf4ce5b99322ffa05eb58838ff006583242d1f677caa28d07d5669b22e07dc4"
              }}
  end

  test "explicit empty strings remain quoted instead of becoming undefined" do
    request = %{
      prompt: "",
      provider: "",
      model: "",
      lyrics: "",
      format: "",
      filename: "",
      image_inputs: []
    }

    assert RequestKey.build(request) ===
             {:ok,
              %{
                canonical:
                  ~S({"durationSeconds":undefined,"filename":"","format":"","imageInputs":[],"instrumental":undefined,"lyrics":"","model":"","prompt":"","provider":"","tool":"music_generate"}),
                digest: "b47792ccb1c915c99111a4f7a5f9fe64bb7212b31d40f231595ddc4e3733363a"
              }}
  end

  test "true and false instrumental values have their own exact canonical bytes and fixed digests" do
    assert RequestKey.build(%{prompt: "song", instrumental: true}) ===
             {:ok,
              %{
                canonical:
                  ~S({"durationSeconds":undefined,"filename":undefined,"format":undefined,"imageInputs":[],"instrumental":true,"lyrics":undefined,"model":undefined,"prompt":"song","provider":undefined,"tool":"music_generate"}),
                digest: "aa86510ae4ccea8fd0a88abe6b76b2c21438f2605d0f6d5b30c6628656480aff"
              }}

    assert RequestKey.build(%{prompt: "song", instrumental: false}) ===
             {:ok,
              %{
                canonical:
                  ~S({"durationSeconds":undefined,"filename":undefined,"format":undefined,"imageInputs":[],"instrumental":false,"lyrics":undefined,"model":undefined,"prompt":"song","provider":undefined,"tool":"music_generate"}),
                digest: "498117001238d5669aed37bdd2957799dc8d8df38e4f78de8e2129d6e43b29de"
              }}
  end

  test "prepared whitespace UTF8 decomposed Unicode and JSON escapes remain exact without normalization" do
    request = %{
      prompt: "  café e\u0301 雪😀\n\"quote\"\\path\t\r\b\f  ",
      provider: " Provider ",
      model: " model/Case ",
      lyrics: "sing\nnext \"yes\"\\backslash",
      format: " WAV ",
      filename: " file/雪.wav "
    }

    assert RequestKey.build(request) ===
             {:ok,
              %{
                canonical:
                  ~S({"durationSeconds":undefined,"filename":" file/雪.wav ","format":" WAV ","imageInputs":[],"instrumental":undefined,"lyrics":"sing\nnext \"yes\"\\backslash","model":" model/Case ","prompt":"  café é 雪😀\n\"quote\"\\path\t\r\b\f  ","provider":" Provider ","tool":"music_generate"}),
                digest: "24ab5beaddf8ec16979ef18581e1d8f9581d2ded51da3c6624d11d13d2dced62"
              }}
  end

  test "prepared reference strings retain input order duplicates and whitespace" do
    assert RequestKey.build(%{prompt: "song", image_inputs: [" b/雪.png ", "a.png", " b/雪.png "]}) ===
             {:ok,
              %{
                canonical:
                  ~S({"durationSeconds":undefined,"filename":undefined,"format":undefined,"imageInputs":[" b/雪.png ","a.png"," b/雪.png "],"instrumental":undefined,"lyrics":undefined,"model":undefined,"prompt":"song","provider":undefined,"tool":"music_generate"}),
                digest: "45943d8c7358537a0bfb53cd717ef2ed8e2ef7be5034cd22a78d03e86ce63bd6"
              }}

    assert RequestKey.build(%{prompt: "song", image_inputs: ["a.png", " b/雪.png ", " b/雪.png "]}) ===
             {:ok,
              %{
                canonical:
                  ~S({"durationSeconds":undefined,"filename":undefined,"format":undefined,"imageInputs":["a.png"," b/雪.png "," b/雪.png "],"instrumental":undefined,"lyrics":undefined,"model":undefined,"prompt":"song","provider":undefined,"tool":"music_generate"}),
                digest: "615a4b67572fd438c335708ffa22598023ad4923309f3cd9626e56de8e2b96a7"
              }}
  end

  test "positive integral native duration rounds once to JavaScript binary64 before canonical spelling" do
    for duration <- [9_007_199_254_740_993, 9_007_199_254_740_992, 9_007_199_254_740_992.0] do
      assert RequestKey.build(%{prompt: "song", duration_seconds: duration}) ===
               {:ok,
                %{
                  canonical:
                    ~S({"durationSeconds":9007199254740992,"filename":undefined,"format":undefined,"imageInputs":[],"instrumental":undefined,"lyrics":undefined,"model":undefined,"prompt":"song","provider":undefined,"tool":"music_generate"}),
                  digest: "7fdcdfe9fb8a8a7e8ca620b3545ff9067bb0f0652e18ce373da33aa4a0df3ef0"
                }}
    end

    for duration <- [120, 120.0] do
      assert RequestKey.build(%{prompt: "song", duration_seconds: duration}) ===
               {:ok,
                %{
                  canonical:
                    ~S({"durationSeconds":120,"filename":undefined,"format":undefined,"imageInputs":[],"instrumental":undefined,"lyrics":undefined,"model":undefined,"prompt":"song","provider":undefined,"tool":"music_generate"}),
                  digest: "2a2c4e5267de99eb6199025682585cb6ab552a6a6ff7d364a39229078836b8dd"
                }}
    end
  end

  test "positive integral durations use JavaScript decimal placement and positive exponent spelling" do
    for duration <- [100_000_000_000_000_000_000, 1.0e20] do
      assert RequestKey.build(%{prompt: "song", duration_seconds: duration}) ===
               {:ok,
                %{
                  canonical:
                    ~S({"durationSeconds":100000000000000000000,"filename":undefined,"format":undefined,"imageInputs":[],"instrumental":undefined,"lyrics":undefined,"model":undefined,"prompt":"song","provider":undefined,"tool":"music_generate"}),
                  digest: "f02485fae605481dd2946267c5853a0cb8a1716b115de29df962d3f38326b885"
                }}
    end

    for duration <- [1_000_000_000_000_000_000_000, 1.0e21] do
      assert RequestKey.build(%{prompt: "song", duration_seconds: duration}) ===
               {:ok,
                %{
                  canonical:
                    ~S({"durationSeconds":1e+21,"filename":undefined,"format":undefined,"imageInputs":[],"instrumental":undefined,"lyrics":undefined,"model":undefined,"prompt":"song","provider":undefined,"tool":"music_generate"}),
                  digest: "fdcf086346297e226fad726bbfe6d7e09d03620cae447ced338566679ff06ea1"
                }}
    end
  end
end
