defmodule NodeJS.Supervisor do
  use Supervisor

  @timeout 30_000
  @default_pool_name :nodejs
  @default_pool_size 4

  @moduledoc """
  NodeJS.Supervisor
  """

  @doc """
  Starts the Node.js supervisor and workers.

  ## Options
    * `:path` - (required) The path to your Node.js code's root directory.
    * `:pool_size` - (optional) The number of workers. Defaults to #{@default_pool_size}.
    * `:name` - (optional) If there are multiple NodeJS supervisors, give then different names.
  """
  @spec start_link(keyword()) :: {:ok, pid} | {:error, any()}
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Stops the Supervisor and underlying node service
  """
  @spec stop() :: :ok
  def stop() do
    Supervisor.stop(__MODULE__)
  end

  defp to_transaction(module, args, opts) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    binary = Keyword.get(opts, :binary, false)

    func = fn pid ->
      try do
        GenServer.call(pid, {module, args, binary}, timeout)
      catch
        :exit, {:timeout, {GenServer, :call, _}} ->
          {:error, "Call timed out."}
      end
    end

    fn -> :poolboy.transaction(get_pool_name(opts), func, :infinity) end
  end

  defp get_pool_name(opts) do
    String.to_atom("pool_" <> to_string(Keyword.get(opts, :name, @default_pool_name)))
  end

  def call(module, args \\ [], opts \\ [])

  def call(module, args, opts) when is_bitstring(module), do: call({module}, args, opts)

  def call(module, args, opts) when is_tuple(module) and is_list(args) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    task =
      module
      |> to_transaction(args, opts)
      |> Task.async()

    try do
      Task.await(task, timeout)
    catch
      :exit, {:timeout, _} -> {:error, "Call timed out."}
    end
  end

  def call!(module, args \\ [], opts \\ []) do
    module
    |> call(args, opts)
    |> case do
      {:ok, result} -> result
      {:error, message} -> raise NodeJS.Error, message: message
    end
  end

  # --- Supervisor Callbacks ---
  @doc false
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    pool_size = Keyword.get(opts, :pool_size, @default_pool_size)
    pool_name = get_pool_name(opts)
    worker = Keyword.get(opts, :worker, NodeJS.Worker)

    pool_opts = [
      name: {:local, pool_name},
      worker_module: worker,
      size: pool_size,
      max_overflow: 0
    ]

    children = [
      :poolboy.child_spec(pool_name, pool_opts, [path])
    ]

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end
end
