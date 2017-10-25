defmodule Dataloader do
  defstruct [
    sources: %{},
    options: [],
  ]

  alias Dataloader.Source

  @type t :: %__MODULE__{
    sources: %{source_name => Dataloader.Source.t},
    options: [option],
  }

  @type option :: {:timeout, pos_integer}
  @type source_name :: any

  @spec new([option]) :: t
  def new(opts \\ []), do: %__MODULE__{options: opts}

  @spec add_source(t, source_name, Dataloader.Source.t) :: t
  def add_source(%{sources: sources} = loader, name, source) do
    sources = Map.put(sources, name, source)
    %{loader | sources: sources}
  end

  @spec load_many(t, source_name, any, [any]) :: t | no_return()
  def load_many(loader, source_name, batch_key, vals) when is_list(vals) do
    source =
      loader
      |> get_source(source_name)
      |> do_load(batch_key, vals)

    put_in(loader.sources[source_name], source)
  end

  @spec load(t, source_name, any, any) :: t | no_return()
  def load(loader, source_name, batch_key, val) do
    load_many(loader, source_name, batch_key, [val])
  end

  defp do_load(source, batch_key, vals) do
    Enum.reduce(vals, source, &Source.load(&2, batch_key, &1))
  end

  @spec run(t) :: t | no_return
  def run(dataloader) do
    # TODO: pmap
    timeout = dataloader.options[:timeout] || 15_000

    {tasks, refs} =
      dataloader.sources
      |> Enum.map(fn {name, source} ->
        task = Task.async(fn -> {name, Source.run(source)} end)
        {task, {task.ref, name}}
      end)
      |> Enum.unzip

    refs = Map.new(refs)

    sources =
      tasks
      |> Task.yield_many(timeout)
      |> shutdown_tasks(refs)
      |> collect_failures
      |> case do
        {:ok, results} ->
          results
        {:error, failures} ->
          raise """
          Sources did not complete within #{timeout}
          Timed out: #{inspect failures}
          """
      end

    %{dataloader | sources: sources}
  end

  defp collect_failures(tasks_and_results, failures \\ [], success \\ [])
  defp collect_failures([], [] = _failures, success) do
    {:ok, Map.new(success)}
  end
  defp collect_failures([], failures, _acc) do
    {:error, failures}
  end
  defp collect_failures([{:ok, result} | rest], failures, success) do
    collect_failures(rest, failures, [result | success])
  end
  defp collect_failures([{:error, name} | rest], failures, success) do
    collect_failures(rest, [name | failures], success)
  end

  defp shutdown_tasks(tasks, refs) do
    for {task, res} <- tasks do
      with nil <- res || Task.shutdown(task, :brutal_kill) do
        {:error, Map.fetch!(refs, task.ref)}
      end
    end
  end

  @spec get(t, source_name, any, any) :: any | no_return()
  def get(loader, source, batch_key, item_key) do
    loader
    |> get_source(source)
    |> Source.get(batch_key, item_key)
  end

  @spec get_many(t, source_name, any, any) :: [any] | no_return()
  def get_many(loader, source, batch_key, item_keys) when is_list(item_keys) do
    source = get_source(loader, source)
    for key <- item_keys do
      Source.get(source, batch_key, key)
    end
  end

  @spec pending_batches?(t) :: boolean
  def pending_batches?(loader) do
    Enum.any?(loader.sources, fn {_name, source} -> Source.pending_batches?(source) end)
  end

  defp get_source(loader, source_name) do
    loader.sources[source_name] || raise "Source does not exist: #{inspect source_name}"
  end

end