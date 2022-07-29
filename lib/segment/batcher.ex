defmodule Segment.Analytics.Batcher do
  @moduledoc """
    The `Segment.Analytics.Batcher` module is the default service implementation for the library which uses the
    [Segment Batch HTTP API](https://segment.com/docs/sources/server/http/#batch) to put events in a FIFO queue and
    send on a regular basis.

    The `Segment.Analytics.Batcher` can be configured with
    ```elixir
    config :segment,
      max_batch_size: 100,
      batch_every_ms: 5000
    ```
    * `config :segment, :max_batch_size` The maximum batch size of messages that will be sent to Segment at one time. Default value is 100.
    * `config :segment, :batch_every_ms` The time (in ms) between every batch request. Default value is 2000 (2 seconds)

    The Segment Batch API does have limits on the batch size "There is a maximum of 500KB per batch request and 32KB per call.". While
    the library doesn't check the size of the batch, if this becomes a problem you can change `max_batch_size` to a lower number and probably want
    to change `batch_every_ms` to run more frequently. The Segment API asks you to limit calls to under 50 a second, so even if you have no other
    Segment calls going on, don't go under 20ms!

  """
  use GenServer
  alias Segment.Analytics.{Track, Identify, Screen, Alias, Group, Page}

  @type option :: {:name, Atom.t} | {:name, String.t} | {:api_key, String.t} | {:adapter, Segment.Http.adapter()}
  @type options :: [option]

  @doc """
    Start the `Segment.Analytics.Batcher` GenServer with a keyword list supporting the following options:
     - `:api_key` - Segment write key (requried)
     - `:name` - Atom or String, defaults to #{__MODULE__} (optional)
     - `:adapater` - Tesla client adapter (optional)

    Alternatively, the `Segment.Analytics.Batcher` GenServer can also be started by supplying on the Segment HTTP Source API Write Key
  """
  def start_link(opts \\ [name: __MODULE__])


  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(api_key) when is_binary(api_key) do
    client = Segment.Http.client(api_key)
    GenServer.start_link(__MODULE__, {client, :queue.new()}, name: __MODULE__)
  end

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = opts[:name]
    adapter = opts[:adapter]

    client =
      if adapter do
        Segment.Http.client(opts[:api_key], adapter)
      else
        Segment.Http.client(opts[:api_key])
      end

      GenServer.start_link(__MODULE__, {client, :queue.new()}, name: name)
  end

  @doc """
    Start the `Segment.Analytics.Batcher` GenServer with an Segment HTTP Source API Write Key and a Tesla Adapter. This is mainly used
    for testing purposes to override the Adapter with a Mock.
  """
  @spec start_link(String.t(), Segment.Http.adapter()) :: GenServer.on_start()
  def start_link(api_key, adapter) do
    client = Segment.Http.client(api_key, adapter)
    GenServer.start_link(__MODULE__, {client, :queue.new()}, name: __MODULE__)
  end

  # client
  @doc """
    Make a call to Segment with an event. Should be of type `Track, Identify, Screen, Alias, Group or Page`.
    This event will be queued and sent later in a batch.
  """
  @spec call(Segment.segment_event()) :: :ok
  def call(%{__struct__: mod} = event)
      when mod in [Track, Identify, Screen, Alias, Group, Page] do
    enqueue(event)
  end

  @doc """
    Force the batcher to flush the queue and send all the events as a big batch (warning could exceed batch size)
  """
  @spec flush() :: :ok
  def flush() do
    GenServer.call(__MODULE__, :flush)
  end

  # GenServer Callbacks

  @impl true
  def init({client, queue}) do
    schedule_batch_send()
    {:ok, {client, queue}}
  end

  @impl true
  def handle_cast({:enqueue, event}, {client, queue}) do
    {:noreply, {client, :queue.in(event, queue)}}
  end

  @impl true
  def handle_call(:flush, _from, {client, queue}) do
    items = :queue.to_list(queue)
    if length(items) > 0, do: Segment.Http.batch(client, items)
    {:reply, :ok, {client, :queue.new()}}
  end

  @impl true
  def handle_info(:process_batch, {client, queue}) do
    length = :queue.len(queue)
    {items, queue} = extract_batch(queue, length)

    if length(items) > 0, do: Segment.Http.batch(client, items)

    schedule_batch_send()
    {:noreply, {client, queue}}
  end

  def handle_info({:ssl_closed, _msg}, state), do: {:no_reply, state}

  # Helpers
  defp schedule_batch_send do
    Process.send_after(self(), :process_batch, Segment.Config.batch_every_ms())
  end

  defp enqueue(event) do
    GenServer.cast(__MODULE__, {:enqueue, event})
  end

  defp extract_batch(queue, 0),
    do: {[], queue}

  defp extract_batch(queue, length) do
    max_batch_size = Segment.Config.max_batch_size()

    if length >= max_batch_size do
      :queue.split(max_batch_size, queue)
      |> split_result()
    else
      :queue.split(length, queue) |> split_result()
    end
  end

  defp split_result({q1, q2}), do: {:queue.to_list(q1), q2}
end
