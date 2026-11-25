defmodule HayataWeatherAgentStream.Agent do
  use Hayata.Agent

  agent do
    id "hayata_weather_agent_stream"

    state %{}

    llm %{
      adapter: :hayata_openai,
      model: "gpt-4o-mini",
      provider_config: %{
        api_key: System.get_env("OPENAI_API_KEY")
      }
    }

    node "agent", context do
      llm_stream = context.hayata_llm_stream
      messages = HayataWeatherAgentStream.current_messages(context)
      tools = HayataWeatherAgentStream.weather_tools()

      case :hayata_tool.definitions(tools) do
        {:ok, definitions} ->
          request = %{
            messages: messages,
            tools: definitions
          }

          IO.puts("[AGENT] Calling the injected streaming function...")

          case llm_stream.(request) do
            {:ok, response} ->
              HayataWeatherAgentStream.handle_llm_response(response, messages)

            {:error, reason} ->
              raise "LLM generation failed: #{inspect(reason)}"
          end

        {:error, reason} ->
          raise "invalid tool definitions: #{inspect(reason)}"
      end
    end

    node "tools", context do
      calls = Map.get(context, :pending_tool_calls, [])
      messages = context.messages
      tools = HayataWeatherAgentStream.weather_tools()

      IO.puts("[TOOLS] Executing #{length(calls)} tool call(s).")

      tool_messages =
        HayataWeatherAgentStream.execute_tool_calls(calls, tools)

      %{
        messages: messages ++ tool_messages,
        pending_tool_calls: [],
        next_action: :agent
      }
    end

    decision do
      on_step 0, context do
        next "agent", input: context.input
      end

      on_step _step, %{state: %{next_action: :tools}} = context do
        next "tools", input: context.state.pending_tool_calls
      end

      on_step _step, %{state: %{next_action: :agent}} = context do
        next "agent", input: context.state.messages
      end

      on_step _step, %{state: %{next_action: :finish}} = context do
        response = context.state.last_response

        finish %{
          answer: HayataWeatherAgentStream.response_text(response),
          messages: context.state.messages
        }
      end
    end

    max_steps 10
    execution_timeout 60_000
  end
end

defmodule HayataWeatherAgentStream do
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

  def handle_llm_response(response, messages) do
    message = Map.fetch!(response, :message)
    calls = Map.get(message, :tool_calls, [])
    updated_messages = messages ++ [message]

    case calls do
      [] ->
        IO.puts("[AGENT] No tool calls; finishing.")

        %{
          messages: updated_messages,
          pending_tool_calls: [],
          last_response: response,
          next_action: :finish
        }

      _calls ->
        IO.inspect(
          Enum.map(calls, fn call -> Map.get(call, :name) end),
          label: "[AGENT] Requested tools"
        )

        %{
          messages: updated_messages,
          pending_tool_calls: calls,
          last_response: response,
          next_action: :tools
        }
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

  def execute_tool_calls(calls, tools) do
    Enum.map(calls, fn call ->
      id = Map.fetch!(call, :id)
      name = Map.fetch!(call, :name)
      arguments = Map.fetch!(call, :arguments)

      IO.puts("[TOOLS] #{name}(#{inspect(arguments)})")

      result = :hayata_tool.execute(name, arguments, tools)

      %{
        role: :tool,
        tool_call_id: id,
        name: name,
        content: [
          %{
            type: :text,
            text: tool_result_text(result)
          }
        ]
      }
    end)
  end

  defp tool_result_text(result) when is_binary(result) do
    result
  end

  defp tool_result_text({:error, _reason}) do
    ~s({"error":"tool_execution_failed"})
  end

  defp tool_result_text(result) do
    case Code.ensure_loaded?(:json) do
      true ->
        :json.encode(result)
        |> IO.iodata_to_binary()

      false ->
        :jsx.encode(result)
        |> IO.iodata_to_binary()
    end
  rescue
    _error ->
      ~s({"error":"tool_result_not_serializable"})
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

  def response_text(response) do
    message = Map.fetch!(response, :message)
    content = Map.get(message, :content, [])

    content
    |> Enum.filter(fn block -> Map.get(block, :type) == :text end)
    |> Enum.map(fn block -> Map.get(block, :text, "") end)
    |> Enum.join()
  end

  defp run_agent do
    case Hayata.Agent.start_link(HayataWeatherAgentStream.Agent.config()) do
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
    query = "Do I need an umbrella if I am in Buenos Aires today?"
    IO.puts("\n[USER] #{query}")

    case Hayata.Agent.run(
           supervisor_pid,
           query,
           %{subscriber: self(), stream: true}
         ) do
      {:ok, invocation_id} ->
        await_result(invocation_id, System.monotonic_time(:millisecond) + 120_000)

      {:error, reason} ->
        {:error, {:invocation_start_failed, reason}}
    end
  end

  defp await_result(invocation_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case remaining <= 0 do
      true ->
        {:error, :invocation_timeout}

      false ->
        receive do
          {:hayata_agent_event, ^invocation_id, event} ->
            handle_agent_event(event)
            await_result(invocation_id, deadline)

          {:hayata_agent_result, ^invocation_id, {:ok, result}} ->
            IO.puts("\n[FINAL] Streaming completed successfully.")
            {:ok, result}

          {:hayata_agent_result, ^invocation_id, {:error, reason}} ->
            {:error, reason}
        after
          remaining ->
            {:error, :invocation_timeout}
        end
    end
  end

  defp handle_agent_event(%{type: :llm_content_delta, data: %{text: text}})
       when is_binary(text) do
    IO.write(text)
  end

  defp handle_agent_event(%{type: :llm_generation_completed}) do
    IO.puts("")
  end

  defp handle_agent_event(%{type: :llm_generation_failed, data: data}) do
    IO.inspect(data, label: "[STREAM ERROR]")
  end

  defp handle_agent_event(_event) do
    :ok
  end
end
