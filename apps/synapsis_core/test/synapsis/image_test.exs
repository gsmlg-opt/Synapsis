defmodule Synapsis.ImageTest do
  use ExUnit.Case, async: true

  alias Synapsis.Image

  # Minimal valid 1x1 white PNG (67 bytes)
  @minimal_png <<
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    # IHDR chunk
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x02,
    0x00,
    0x00,
    0x00,
    0x90,
    0x77,
    0x53,
    0xDE,
    # IDAT chunk
    0x00,
    0x00,
    0x00,
    0x0C,
    0x49,
    0x44,
    0x41,
    0x54,
    0x08,
    0xD7,
    0x63,
    0xF8,
    0xCF,
    0xC0,
    0x00,
    0x00,
    0x00,
    0x02,
    0x00,
    0x01,
    0xE2,
    0x21,
    0xBC,
    0x33,
    # IEND chunk
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82
  >>

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "synapsis_img_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "encode_file/1" do
    test "encodes a valid PNG file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.png")
      File.write!(path, @minimal_png)

      assert {:ok, result} = Image.encode_file(path)
      assert result.type == "image"
      assert result.media_type == "image/png"
      assert is_binary(result.data)
      # Verify it is valid base64
      assert {:ok, _} = Base.decode64(result.data)
      # Verify round-trip: decoded data matches original
      assert Base.decode64!(result.data) == @minimal_png
    end

    test "returns error for non-existent file" do
      assert {:error, msg} = Image.encode_file("/nonexistent/path/image.png")
      assert msg =~ "file not found"
    end

    test "returns error for unsupported file extension" do
      assert {:error, msg} = Image.encode_file("/tmp/document.pdf")
      assert msg =~ "unsupported image type"
      assert msg =~ ".pdf"
    end

    test "returns error for .txt file" do
      assert {:error, msg} = Image.encode_file("/tmp/notes.txt")
      assert msg =~ "unsupported image type"
    end

    test "handles all supported image types", %{tmp_dir: tmp_dir} do
      types = [
        {".jpg", "image/jpeg"},
        {".jpeg", "image/jpeg"},
        {".gif", "image/gif"},
        {".webp", "image/webp"},
        {".png", "image/png"}
      ]

      for {ext, expected_media_type} <- types do
        path = Path.join(tmp_dir, "test#{ext}")
        File.write!(path, "fake_image_data")

        assert {:ok, result} = Image.encode_file(path),
               "expected encode_file to succeed for #{ext}"

        assert result.media_type == expected_media_type,
               "expected media_type #{expected_media_type} for #{ext}, got #{result.media_type}"
      end
    end

    test "rejects files exceeding 20MB limit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "huge.png")
      oversized = @minimal_png <> :binary.copy(<<0>>, 21 * 1024 * 1024)
      File.write!(path, oversized)

      assert {:error, msg} = Image.encode_file(path)
      assert msg =~ "too large"
      assert msg =~ "MB"
    end

    test "handles case-insensitive extensions", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "photo.PNG")
      File.write!(path, @minimal_png)

      assert {:ok, result} = Image.encode_file(path)
      assert result.media_type == "image/png"
    end
  end

  describe "media_type/1" do
    test "returns correct type for .png" do
      assert Image.media_type(".png") == "image/png"
    end

    test "returns correct type for .jpg" do
      assert Image.media_type(".jpg") == "image/jpeg"
    end

    test "returns correct type for .jpeg" do
      assert Image.media_type(".jpeg") == "image/jpeg"
    end

    test "returns correct type for .gif" do
      assert Image.media_type(".gif") == "image/gif"
    end

    test "returns correct type for .webp" do
      assert Image.media_type(".webp") == "image/webp"
    end

    test "returns error for unsupported extension" do
      assert {:error, msg} = Image.media_type(".bmp")
      assert msg =~ "unsupported extension"
    end

    test "returns error for .txt extension" do
      assert {:error, _} = Image.media_type(".txt")
    end

    test "returns error for .pdf extension" do
      assert {:error, _} = Image.media_type(".pdf")
    end
  end

  describe "supported?/1" do
    test "returns true for .png" do
      assert Image.supported?("photo.png") == true
    end

    test "returns true for .jpg" do
      assert Image.supported?("photo.jpg") == true
    end

    test "returns true for .jpeg" do
      assert Image.supported?("photo.jpeg") == true
    end

    test "returns true for .gif" do
      assert Image.supported?("animation.gif") == true
    end

    test "returns true for .webp" do
      assert Image.supported?("image.webp") == true
    end

    test "returns false for .txt" do
      assert Image.supported?("notes.txt") == false
    end

    test "returns false for .pdf" do
      assert Image.supported?("document.pdf") == false
    end

    test "returns false for .bmp" do
      assert Image.supported?("bitmap.bmp") == false
    end

    test "returns false for extensionless file" do
      assert Image.supported?("Makefile") == false
    end

    test "handles uppercase extensions" do
      assert Image.supported?("PHOTO.PNG") == true
      assert Image.supported?("image.JPG") == true
    end
  end

  describe "encode_url/1" do
    test "wraps a URL in the expected structure" do
      url = "https://example.com/img.png"
      assert {:ok, %{type: "image_url", url: ^url}} = Image.encode_url(url)
    end
  end

  describe "to_anthropic_content/1" do
    test "formats base64 image for Anthropic API" do
      input = %{type: "image", media_type: "image/png", data: "abc123"}
      result = Image.to_anthropic_content(input)

      assert result["type"] == "image"
      assert result["source"]["type"] == "base64"
      assert result["source"]["media_type"] == "image/png"
      assert result["source"]["data"] == "abc123"
    end
  end

  describe "to_openai_content/1" do
    test "formats base64 image for OpenAI API" do
      input = %{type: "image", media_type: "image/png", data: "abc123"}
      result = Image.to_openai_content(input)

      assert result["type"] == "image_url"
      assert result["image_url"]["url"] == "data:image/png;base64,abc123"
    end

    test "passes through image_url type for OpenAI" do
      input = %{type: "image_url", url: "https://example.com/img.jpg"}
      result = Image.to_openai_content(input)

      assert result["type"] == "image_url"
      assert result["image_url"]["url"] == "https://example.com/img.jpg"
    end
  end

  describe "to_google_content/1" do
    test "formats base64 image for Google API" do
      input = %{type: "image", media_type: "image/jpeg", data: "xyz789"}
      result = Image.to_google_content(input)

      assert result["inlineData"]["mimeType"] == "image/jpeg"
      assert result["inlineData"]["data"] == "xyz789"
    end
  end
end
