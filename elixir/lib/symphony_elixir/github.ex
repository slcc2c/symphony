defmodule SymphonyElixir.GitHub do
  @moduledoc """
  Lightweight GitHub PR status helpers for local workspace checkouts.
  """

  require Logger

  @pr_view_fields ["state", "reviewDecision", "mergeStateStatus", "statusCheckRollup", "url"]

  @spec pr_check_status(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def pr_check_status(workspace_path) do
    case Application.get_env(:symphony_elixir, :github_pr_status_fun) do
      fun when is_function(fun, 1) ->
        fun.(workspace_path)

      _ ->
        do_pr_check_status(workspace_path)
    end
  end

  defp do_pr_check_status(workspace_path) when not is_binary(workspace_path) or workspace_path == "" do
    {:ok, %{has_pr?: false, pending?: false, checks: []}}
  end

  defp do_pr_check_status(workspace_path) do
    if File.dir?(workspace_path) do
      case System.cmd("gh", ["pr", "view", "--json", Enum.join(@pr_view_fields, ",")],
             cd: workspace_path,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          decode_pr_view(output)

        {output, status} ->
          decode_failed_pr_view(workspace_path, output, status)
      end
    else
      {:ok, %{has_pr?: false, pending?: false, checks: []}}
    end
  end

  defp decode_pr_view(output) do
    case Jason.decode(output) do
      {:ok, payload} ->
        checks = Map.get(payload, "statusCheckRollup") || []

        {:ok,
         %{
           has_pr?: true,
           pending?: Enum.any?(checks, &check_pending?/1),
           checks: checks,
           state: Map.get(payload, "state"),
           review_decision: Map.get(payload, "reviewDecision"),
           merge_state_status: Map.get(payload, "mergeStateStatus"),
           url: Map.get(payload, "url")
         }}

      {:error, reason} ->
        {:error, {:gh_pr_view_decode_failed, reason}}
    end
  end

  defp decode_failed_pr_view(workspace_path, output, status) do
    trimmed = String.trim(output)

    if no_pull_request_output?(trimmed) do
      {:ok, %{has_pr?: false, pending?: false, checks: []}}
    else
      Logger.debug("GitHub PR status lookup failed workspace=#{workspace_path} status=#{status} output=#{inspect(trimmed)}")

      {:error, {:gh_pr_view_failed, status, trimmed}}
    end
  end

  defp check_pending?(%{"status" => status}) when is_binary(status) do
    String.upcase(status) != "COMPLETED"
  end

  defp check_pending?(_check), do: false

  defp no_pull_request_output?(output) when is_binary(output) do
    normalized = String.downcase(output)

    String.contains?(normalized, "no pull requests found") or
      String.contains?(normalized, "could not find pull request")
  end
end
