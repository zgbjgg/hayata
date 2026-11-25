defmodule HayataTelemetryExample do
  @handler_id {__MODULE__, :agent_invocations}

  require Logger

  def attach do
    Logger.configure(level: :info)

    :telemetry.attach_many(
      @handler_id,
      [
        [:hayata, :agent, :invocation, :start],
        [:hayata, :agent, :invocation, :stop],
        [:hayata, :agent, :invocation, :exception],
        [:hayata, :node, :execution, :start],
        [:hayata, :node, :execution, :stop],
        [:hayata, :node, :execution, :exception],
        [:hayata, :edge, :start],
        [:hayata, :edge, :stop],
        [:hayata, :edge, :exception],
        [:hayata, :reducer, :start],
        [:hayata, :reducer, :stop]
      ],
      &__MODULE__.handle_event/4,
      %{}
    )
  end

  def detach do
    :telemetry.detach(@handler_id)
  end

  def handle_event(event, measurements, metadata, _config) do
    Logger.info("Hayata telemetry event\n#{inspect(%{
      event: event,
      measurements: measurements,
      metadata: metadata
    }, pretty: true)}")
  end
end
