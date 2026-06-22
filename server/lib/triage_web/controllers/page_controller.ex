defmodule TriageWeb.PageController do
  use TriageWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
