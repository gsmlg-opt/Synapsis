defmodule Synapsis.ImageTest do
  use ExUnit.Case

  test "encode_file/1 encodes a valid image" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "synapsis_img_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "test.png")
    # Write a minimal valid PNG header
    png_data = <<
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52
    >>

    File.write!(path, png_data)

    assert {:ok, result} = Synapsis.Image.encode_file(path)
    assert result.type == "image"
    assert result.media_type == "image/png"
    assert is_binary(result.data)

    File.rm_rf!(tmp_dir)
  end

  test "encode_file/1 rejects unsupported types" do
    assert {:error, _} = Synapsis.Image.encode_file("/tmp/test.pdf")
  end

  test "encode_file/1 rejects missing files" do
    assert {:error, _} = Synapsis.Image.encode_file("/nonexistent/image.png")
  end

  test "encode_url/1 wraps a URL" do
    assert {:ok, %{type: "image_url", url: "https://example.com/img.png"}} =
             Synapsis.Image.encode_url("https://example.com/img.png")
  end

  test "to_anthropic_content/1 formats for Anthropic API" do
    result =
      Synapsis.Image.to_anthropic_content(%{type: "image", media_type: "image/png", data: "abc"})

    assert result["type"] == "image"
    assert result["source"]["type"] == "base64"
    assert result["source"]["data"] == "abc"
  end

  test "to_openai_content/1 formats base64 image for OpenAI API" do
    result =
      Synapsis.Image.to_openai_content(%{type: "image", media_type: "image/png", data: "abc"})

    assert result["type"] == "image_url"
    assert result["image_url"]["url"] =~ "data:image/png;base64,abc"
  end

  test "to_openai_content/1 passes through image_url type" do
    result =
      Synapsis.Image.to_openai_content(%{type: "image_url", url: "https://example.com/img.jpg"})

    assert result["type"] == "image_url"
    assert result["image_url"]["url"] == "https://example.com/img.jpg"
  end

  test "to_google_content/1 formats for Google API" do
    result =
      Synapsis.Image.to_google_content(%{type: "image", media_type: "image/jpeg", data: "xyz"})

    assert result["inlineData"]["mimeType"] == "image/jpeg"
    assert result["inlineData"]["data"] == "xyz"
  end
end
