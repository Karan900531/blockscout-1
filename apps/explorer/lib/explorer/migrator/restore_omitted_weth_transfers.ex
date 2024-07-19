defmodule Explorer.Migrator.RestoreOmittedWETHTransfers do
  @moduledoc """

  """

  use GenServer, restart: :transient

  alias Explorer.Chain.{Log, TokenTransfer}
  alias Explorer.Helper

  import Explorer.Chain.SmartContract, only: [burn_address_hash_string: 0]

  require Logger

  @enqueue_busy_waiting_timeout 500
  @migration_timeout 250

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(_) do
    GenServer.cast(__MODULE__, :migrate)
    {:ok, %{queue: [], current_concurrency: 0}, {:continue, :ok}}
  end

  # check here if all tokens which logs we are looking for exists
  @impl true
  def handle_continue(:ok, state) do
    Log.stream_unfetched_weth_token_transfers(&enqueue_if_queue_is_not_full/1)

    to_insert =
      Application.get_env(:explorer, Explorer.Chain.TokenTransfer)[:whitelisted_weth_contracts]
      |> Enum.each(fn contract_address_hash_string ->
        if !Chain.token_from_address_hash_exists?(contract_address_hash_string) do
          %{
            contract_address_hash: contract_address_hash_string,
            type: "ERC-20"
          }
        end
      end)
      |> Enum.reject(&is_nil/1)

    if !Enum.empty?(to_insert) do
      Chain.import(%{tokens: %{params: to_insert}})
    end

    # {:stop, :normal, state}

    {:noreply, state}
  end

  defp enqueue_if_queue_is_not_full(log) do
    if GenServer.call(__MODULE__, :not_full?) do
      GenServer.cast(__MODULE__, {:append_to_queue, log})
    else
      :timer.sleep(@enqueue_busy_waiting_timeout)

      enqueue_if_queue_is_not_full(log)
    end
  end

  @impl true
  def handle_call(:not_full?, _from, %{queue: queue} = state) do
    {:reply, Enum.count(queue) < max_queue_size(), state}
  end

  @impl true
  def handle_cast({:append_to_queue, log}, %{queue: queue} = state) do
    {:noreply, %{state | queue: [log | queue]}}
  end

  def handle_cast(:migrate, %{queue: queue, current_concurrency: current_concurrency} = state) do
    if Enum.count(queue) > 0 and current_concurrency < concurrency() do
      to_take = batch_size() * (concurrency() - current_concurrency)
      {to_process, remainder} = Enum.split(queue, to_take)

      spawned_tasks =
        to_process
        |> Enum.chunk_every(batch_size())
        |> Enum.map(fn batch ->
          Task.Supervisor.async_nolink(Explorer.WETHMigratorSupervisor, fn ->
            migrate_batch(batch)
          end)
        end)

      {:noreply, %{state | queue: remainder, current_concurrency: current_concurrency + Enum.count(spawned_tasks)}}
    else
      Process.send_after(self(), :migrate, @migration_timeout)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, _answer}, %{current_concurrency: counter} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | current_concurrency: counter - 1}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %{current_concurrency: counter} = state) do
    {:noreply, %{state | current_concurrency: counter - 1}}
  end

  defp migrate_batch(batch) do
    token_transfers =
      batch
      |> Enum.map(fn log ->
        with %{second_topic: second_topic, third_topic: nil, fourth_topic: nil, data: data}
             when not is_nil(second_topic) <-
               log,
             [amount] <- Helper.decode_data(data, [{:uint, 256}]) do
          {from_address_hash, to_address_hash} =
            if log.first_topic == TokenTransfer.weth_deposit_signature() do
              {burn_address_hash_string(), Helper.truncate_address_hash(second_topic)}
            else
              {Helper.truncate_address_hash(second_topic), burn_address_hash_string()}
            end

          token_transfer = %{
            amount: Decimal.new(amount || 0),
            block_number: log.block_number,
            block_hash: log.block_hash,
            log_index: log.index,
            from_address_hash: from_address_hash,
            to_address_hash: to_address_hash,
            token_contract_address_hash: log.address_hash,
            transaction_hash: log.transaction_hash,
            token_ids: nil,
            token_type: "ERC-20"
          }

          token_transfer
        else
          _ ->
            Logger.error(
              "Failed to decode log: (tx_hash, block_hash, index) = #{to_string(log.transaction_hash)},  #{to_string(log.block_hash)}, #{to_string(log.index)}"
            )

            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if !Enum.empty?(token_transfers) do
      Chain.import(%{token_transfers: %{params: token_transfers}})
    end
  end

  def concurrency, do: Application.get_env(:explorer, __MODULE__)[:concurrency]

  def batch_size, do: Application.get_env(:explorer, __MODULE__)[:batch_size]

  def max_queue_size, do: concurrency() * batch_size() * 2
end
