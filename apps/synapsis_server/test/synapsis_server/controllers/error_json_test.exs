defmodule SynapsisServer.ErrorJSONTest do
  use SynapsisServer.ConnCase, async: true

  test "renders 404" do
    assert SynapsisServer.ErrorJSON.render("404.json", %{}) == %{
             errors: %{detail: "Not Found"}
           }
  end

  test "renders 500" do
    assert SynapsisServer.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end

  test "renders 400" do
    assert SynapsisServer.ErrorJSON.render("400.json", %{}) == %{
             errors: %{detail: "Bad Request"}
           }
  end

  test "renders 403" do
    assert SynapsisServer.ErrorJSON.render("403.json", %{}) == %{
             errors: %{detail: "Forbidden"}
           }
  end

  test "renders 422" do
    assert SynapsisServer.ErrorJSON.render("422.json", %{}) == %{
             errors: %{detail: "Unprocessable Content"}
           }
  end

  test "renders unknown template" do
    result = SynapsisServer.ErrorJSON.render("503.json", %{})
    assert %{errors: _} = result
  end
end
