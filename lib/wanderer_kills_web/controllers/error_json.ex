defmodule WandererKillsWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by Phoenix when there is an error in the controller
  and needs to render error pages.
  """

  # By default, Phoenix returns the following error messages:
  #
  # 400 - Bad Request
  # 401 - Unauthorized  
  # 403 - Forbidden
  # 404 - Not Found
  # 422 - Unprocessable Entity
  # 500 - Internal Server Error

  def render(template, _assigns) do
    # Extract the status code from the template name
    status_code = template |> to_string() |> String.trim_trailing(".json")

    %{
      error: Phoenix.Controller.status_message_from_template(template),
      status: status_code
    }
  end
end
