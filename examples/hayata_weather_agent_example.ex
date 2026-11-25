defmodule HayataWeatherAgent.Agent do
  use Hayata.Agent

  agent do
    id "weather_agent"

    state %{}

    llm %{
      adapter: :hayata_openai,
      model: "gpt-4o-mini",
      provider_config: %{
        api_key: System.get_env("OPENAI_API_KEY")
      }
    }

    node "agent", context do
      tool_loop = context.hayata_tool_loop
      messages = HayataWeatherAgent.current_messages(context)

      request = %{messages: messages}
      tools = HayataWeatherAgent.weather_tools()

      IO.puts("[AGENT] Running the LLM tool loop...")

      case tool_loop.(request, tools, 5) do
        {:ok, loop_result} ->
          response = loop_result.response
          updated_messages = loop_result.messages

          IO.puts(
            "[AGENT] Tool loop completed after #{loop_result.iterations} iteration(s)."
          )

          %{
            messages: updated_messages,
            last_response: response
          }

        {:error, reason} ->
          raise "tool loop failed: #{inspect(reason)}"
      end
    end

    decision do
      on_step 0, context do
        next "agent", input: context.input
      end

      on_step 1, context do
        response = context.state.last_response

        finish %{
          answer: HayataWeatherAgent.response_text(response),
          messages: context.state.messages
        }
      end
    end

    max_steps 5
    execution_timeout 60_000
  end
end

defmodule HayataWeatherAgent do
  def run do
    case System.get_env("OPENAI_API_KEY") do
      nil ->
        {:error, :missing_openai_api_key}

      "" ->
        {:error, :missing_openai_api_key}

      _api_key ->
        case Application.ensure_all_started(:hayata) do
          {:ok, _started} ->
            run_agent()

          {:error, reason} ->
            {:error, {:application_start_failed, reason}}
        end
    end
  end

  def get_current_weather(%{"location" => location}) do
    get_current_weather(%{location: location})
  end

  def get_current_weather(%{location: location}) when is_binary(location) do
    normalized_location = String.downcase(location)

    case {
      String.contains?(normalized_location, "madrid"),
      String.contains?(normalized_location, "buenos aires"),
      String.contains?(normalized_location, "ciudad de méxico"),
      String.contains?(normalized_location, "cdmx")
    } do
      {true, _, _, _} ->
        "The weather in Madrid is sunny, 22°C."

      {_, true, _, _} ->
        "The weather in Buenos Aires is rainy, 15°C."

      {_, _, true, _} ->
        "The weather in Mexico City is cloudy, 19°C."

      {_, _, _, true} ->
        "The weather in Mexico City is cloudy, 19°C."

      _ ->
        "No weather data found for #{location}."
    end
  end

  def current_messages(%{messages: messages}) do
    messages
  end

  def current_messages(%{input: input}) do
    [
      %{
        role: :user,
        content: [
          %{type: :text, text: input}
        ]
      }
    ]
  end

  def weather_tools do
    [
      %{
        name: "get_current_weather",
        description: "Gets the current weather for a specific location.",
        parameters: %{
          type: :object,
          properties: %{
            location: %{type: :string}
          },
          required: ["location"]
        },
        handler: &get_current_weather/1
      }
    ]
  end

  def response_text(response) do
    message = Map.fetch!(response, :message)
    content = Map.get(message, :content, [])

    content
    |> Enum.filter(fn block -> Map.get(block, :type) == :text end)
    |> Enum.map(fn block -> Map.get(block, :text, "") end)
    |> Enum.join()
  end

  defp run_agent do
    case Hayata.Agent.start_link(HayataWeatherAgent.Agent.config()) do
      {:ok, supervisor_pid} ->
        try do
          execute_query(supervisor_pid)
        after
          Hayata.Agent.stop(supervisor_pid)
        end

      {:error, reason} ->
        {:error, {:agent_start_failed, reason}}
    end
  end

  defp execute_query(supervisor_pid) do
    query = "¿Necesito paraguas si estoy en Buenos Aires hoy?"
    IO.puts("\n[USER] #{query}")

    case Hayata.Agent.run(supervisor_pid, query, %{subscriber: self()}) do
      {:ok, invocation_id} ->
        await_result(invocation_id)

      {:error, reason} ->
        {:error, {:invocation_start_failed, reason}}
    end
  end

  defp await_result(invocation_id) do
    receive do
      {:hayata_agent_result, ^invocation_id, {:ok, result}} ->
        IO.puts("\n[FINAL] #{Map.get(result, :answer, "(no text response)")}")
        {:ok, result}

      {:hayata_agent_result, ^invocation_id, {:error, reason}} ->
        {:error, reason}
    after
      120_000 ->
        {:error, :invocation_timeout}
    end
  end
end
