defmodule Hayata.Agent.DSL do
  @moduledoc """
  Declarative DSL for defining Hayata agents.
  """

  defmacro agent(do: block) do
    definition = parse_agent_block(block)

    config = build_config(definition)
    module = __CALLER__.module

    quote do
      def config do
        unquote(config)
      end

      def __hayata_config__ do
        config()
      end

      def child_spec(_argument) do
        Hayata.Agent.child_spec(config())
      end

      def start_link(_argument) do
        Hayata.Agent.start_link(config())
      end

      def __hayata_agent_module__ do
        unquote(module)
      end
    end
  end

  defp parse_agent_block(block) do
    expressions = block_expressions(block)

    initial = %{
      id: nil,
      state: quote(do: %{}),
      nodes: [],
      decision: nil,
      max_steps: nil,
      execution_timeout: nil
    }

    expressions
    |> Enum.reduce(initial, &parse_agent_expression/2)
    |> validate_agent_definition()
  end

  defp block_expressions({:__block__, _metadata, expressions}) do
    expressions
  end

  defp block_expressions(expression) do
    [expression]
  end

  defp parse_agent_expression({:id, _metadata, [value]}, definition) do
    Map.put(definition, :id, value)
  end

  defp parse_agent_expression({:state, _metadata, [value]}, definition) do
    Map.put(definition, :state, value)
  end

  defp parse_agent_expression(
         {:max_steps, _metadata, [value]},
         definition
       ) do
    Map.put(definition, :max_steps, value)
  end

  defp parse_agent_expression(
         {:execution_timeout, _metadata, [value]},
         definition
       ) do
    Map.put(definition, :execution_timeout, value)
  end

  defp parse_agent_expression(
         {:node, _metadata, [name, [do: body]]},
         definition
       ) do
    node_id = parse_node_id(name)

    node = %{
      id: node_id,
      function: build_node_function(body)
    }

    nodes = [node | definition.nodes]

    Map.put(definition, :nodes, nodes)
  end

  defp parse_agent_expression(
         {:decision, _metadata, [[do: body]]},
         definition
       ) do
    steps = parse_decision_block(body)

    Map.put(definition, :decision, steps)
  end

  defp parse_agent_expression(expression, _definition) do
    raise ArgumentError,
          "unsupported Hayata agent definition: #{Macro.to_string(expression)}"
  end

  defp validate_agent_definition(%{id: nil}) do
    raise ArgumentError, "Hayata agent definition requires an id"
  end

  defp validate_agent_definition(%{nodes: []}) do
    raise ArgumentError, "Hayata agent definition requires at least one node"
  end

  defp validate_agent_definition(%{decision: nil}) do
    raise ArgumentError, "Hayata agent definition requires a decision block"
  end

  defp validate_agent_definition(definition) do
    validate_unique_nodes(definition.nodes)
    validate_unique_steps(definition.decision)

    definition
  end

  defp validate_unique_nodes(nodes) do
    node_ids = Enum.map(nodes, & &1.id)

    case length(node_ids) == MapSet.size(MapSet.new(node_ids)) do
      true ->
        :ok

      false ->
        raise ArgumentError, "Hayata agent contains duplicated node identifiers"
    end
  end

  defp validate_unique_steps(steps) do
    step_ids = Enum.map(steps, & &1.step)

    case length(step_ids) == MapSet.size(MapSet.new(step_ids)) do
      true ->
        :ok

      false ->
        raise ArgumentError, "Hayata agent contains duplicated decision steps"
    end
  end

  defp parse_node_id(name) when is_binary(name) do
    String.to_atom(name)
  end

  defp parse_node_id(name) do
    raise ArgumentError,
          "node identifier must be a string literal, got: #{Macro.to_string(name)}"
  end

  defp build_node_function([{:->, _metadata, _clauses} = clause]) do
    {:fn, [], [clause]}
  end

  defp build_node_function({:fn, _metadata, _clauses} = function) do
    function
  end

  defp build_node_function(body) do
    raise ArgumentError,
          "node body must be an anonymous function, got: #{Macro.to_string(body)}"
  end

  defp parse_decision_block(block) do
    block
    |> block_expressions()
    |> Enum.map(&parse_decision_step/1)
  end

  defp parse_decision_step(
         {:on_step, _metadata, [step, [do: body]]}
       )
       when is_integer(step) and step >= 0 do
    %{
      step: step,
      result: parse_decision_result(body)
    }
  end

  defp parse_decision_step(expression) do
    raise ArgumentError,
          "invalid decision step: #{Macro.to_string(expression)}"
  end

  defp parse_decision_result(
         {:next, _metadata, [name, options]}
       )
       when is_list(options) do
    node_id = parse_node_id(name)
    input = Keyword.fetch!(options, :input)

    quote do
      {:next, unquote(node_id), unquote(context_value(input))}
    end
  end

  defp parse_decision_result(
         {:finish, _metadata, [value]}
       ) do
    quote do
      {:finish, unquote(context_value(value))}
    end
  end

  defp parse_decision_result(expression) do
    raise ArgumentError,
          "unsupported decision result: #{Macro.to_string(expression)}"
  end

  defp context_value({:__aliases__, _metadata, _parts} = expression) do
    expression
  end

  defp context_value(value) when is_atom(value) do
    quote do
      Map.fetch!(var!(context), unquote(value))
    end
  end

  defp context_value(value) do
    value
  end

  defp build_config(definition) do
    nodes =
      definition.nodes
      |> Enum.reverse()
      |> Enum.map(fn node ->
        {node.id, node.function}
      end)

    context_variable = {:context, [], nil}

    decision_clauses =
      Enum.map(definition.decision, fn decision ->
        {:->, [],
         [
           [decision.step],
           decision.result
         ]}
      end)

    decision_case =
      {:case, [],
       [
         {{:., [], [Map, :fetch!]}, [], [context_variable, :step]},
         [do: decision_clauses]
       ]}

    decision_policy =
      {:fn, [],
       [
         {:->, [],
          [
            [context_variable],
            decision_case
          ]}
       ]}

    config_entries =
      [
        {:id, definition.id},
        {:state, definition.state},
        {:nodes, {:%{}, [], nodes}},
        {:decision_policy, decision_policy}
      ]
      |> maybe_add(:max_steps, definition.max_steps)
      |> maybe_add(:execution_timeout, definition.execution_timeout)

    {:%{}, [], config_entries}
  end

  defp maybe_add(entries, _key, nil) do
    entries
  end

  defp maybe_add(entries, key, value) do
    entries ++ [{key, value}]
  end
end
