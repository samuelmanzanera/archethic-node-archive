defmodule Archethic.Contracts do
  @moduledoc """
  Handle smart contracts based on a new language running in an custom interpreter for Archethic network.
  Each smart contract is register and supervised as long running process to interact with later on.
  """

  alias __MODULE__.Interpreter.Conditions, as: ConditionsInterpreter
  alias __MODULE__.Interpreter.Constants, as: ConstantsInterpreter
  alias __MODULE__.Contract.ActionWithoutTransaction
  alias __MODULE__.Contract.ActionWithTransaction
  alias __MODULE__.Contract.ConditionRejected
  alias __MODULE__.Contract.Failure
  alias __MODULE__.Contract.State
  alias __MODULE__.Interpreter
  alias __MODULE__.Interpreter.Library
  alias __MODULE__.Interpreter.Contract, as: InterpretedContract
  alias __MODULE__.Loader

  alias __MODULE__.WasmContract
  alias __MODULE__.WasmModule
  alias __MODULE__.WasmSpec
  alias __MODULE__.Wasm.ReadResult
  alias __MODULE__.Wasm.UpdateResult

  alias Archethic
  alias Archethic.Crypto
  alias Archethic.TransactionChain.Transaction
  alias Archethic.TransactionChain.Transaction.ValidationStamp
  alias Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations
  alias Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations.UnspentOutput

  alias Archethic.TransactionChain.TransactionData
  alias Archethic.TransactionChain.TransactionData.Recipient
  alias Archethic.TransactionChain.TransactionData.Ownership
  alias Archethic.Utils
  alias Archethic.UTXO

  require Logger

  @extended_mode? Mix.env() != :prod

  @doc """
  Return the minimum trigger interval in milliseconds.
  Depends on the env
  """
  @spec minimum_trigger_interval(boolean()) :: pos_integer()
  def minimum_trigger_interval(extended_mode? \\ @extended_mode?) do
    if extended_mode? do
      1_000
    else
      60_000
    end
  end

  @doc """
  Execute the contract trigger.
  """
  @spec execute_trigger(
          trigger :: InterpretedContract.trigger_type() | WasmContract.trigger_type(),
          contract :: InterpretedContract.t() | WasmContract.t(),
          maybe_trigger_tx :: nil | Transaction.t(),
          maybe_recipient :: nil | Recipient.t(),
          inputs :: list(UnspentOutput.t()),
          opts :: Keyword.t()
        ) ::
          {:ok, ActionWithTransaction.t() | ActionWithoutTransaction.t()}
          | {:error, Failure.t()}
  def execute_trigger(
        trigger_type,
        contract,
        maybe_trigger_tx,
        maybe_recipient,
        inputs,
        opts \\ []
      )

  def execute_trigger(
        {:transaction, "upgrade", _},
        %WasmContract{
          transaction: contract_tx,
          state: state,
          module: %WasmModule{spec: %WasmSpec{upgrade_opts: upgrade_opts}}
        },
        trigger_tx,
        %Recipient{args: args},
        _inputs,
        _opts
      ) do
    case upgrade_opts do
      nil ->
        {:error, :upgrade_not_supported}

      %WasmSpec.UpgradeOpts{from: from} ->
        {:ok, genesis_address} =
          trigger_tx |> Transaction.previous_address() |> Archethic.fetch_genesis_address()

        if genesis_address == from do
          with {:ok, %{"bytecode" => new_code, "manifest" => manifest}} <-
                 WasmSpec.cast_wasm_input(args, %{"bytecode" => "string", "manifest" => "map"}),
               {:ok, new_code_bytes} <- Base.decode16(new_code, case: :mixed),
               {:ok, new_module} <-
                 WasmModule.parse(:zlib.unzip(new_code_bytes), WasmSpec.from_manifest(manifest)) do
            upgrade_state =
              if "onUpgrade" in WasmModule.list_exported_functions_name(new_module) do
                case WasmModule.execute(new_module, "onUpgrade", state: state) do
                  {:ok, %UpdateResult{state: migrated_state}} ->
                    migrated_state

                  _ ->
                    state
                end
              else
                state
              end

            {:ok,
             %UpdateResult{
               state: upgrade_state,
               transaction: %{
                 type: :contract,
                 data: %{
                   contract: %{bytecode: new_code_bytes, manifest: manifest}
                 }
               }
             }}
          else
            _ -> {:error, :invalid_upgrade_params}
          end
        else
          {:error, :upgrade_not_authorized}
        end
    end
    |> cast_trigger_result(state, contract_tx)
  end

  def execute_trigger(
        trigger_type,
        contract = %{
          transaction: contract_tx = %Transaction{address: contract_address},
          state: state
        },
        maybe_trigger_tx,
        maybe_recipient,
        inputs,
        opts
      ) do
    # TODO: trigger_tx & recipient should be transformed into recipient here
    # TODO: rescue should be done in here as well
    # TODO: implement timeout

    opts =
      case Keyword.get(opts, :time_now) do
        # you must use the :time_now opts during the validation workflow
        # because there is no validation_stamp yet
        nil -> Keyword.put(opts, :time_now, time_now(trigger_type, maybe_trigger_tx))
        _ -> opts
      end

    trigger_tx_address =
      case maybe_trigger_tx do
        nil -> nil
        %Transaction{address: addr} -> addr
      end

    key =
      {:execute_trigger, trigger_type, contract_address, trigger_tx_address,
       Keyword.fetch!(opts, :time_now), inputs_digest(inputs)}

    fn ->
      case contract do
        %WasmContract{} ->
          exec_wasm(contract, trigger_type, maybe_trigger_tx, maybe_recipient, inputs, opts)

        _ ->
          Interpreter.execute_trigger(
            trigger_type,
            contract,
            maybe_trigger_tx,
            maybe_recipient,
            inputs,
            opts
          )
      end
    end
    |> cache_interpreter_execute(key,
      timeout_err_msg: "Trigger's execution timed-out",
      cache?: Keyword.get(opts, :cache?, true),
      timeout: 15000
    )
    |> cast_trigger_result(state, contract_tx)
  end

  defp exec_wasm(
         %WasmContract{
           state: state,
           module: module = %WasmModule{spec: %WasmSpec{triggers: triggers}},
           transaction: contract_tx
         },
         trigger_type,
         maybe_trigger_tx,
         maybe_recipient,
         inputs,
         _opts
       ) do
    trigger =
      Enum.find(triggers, fn %WasmSpec.Trigger{type: type, name: fn_name} ->
        case trigger_type do
          {:transaction, action_name, _} when action_name != nil ->
            type == :transaction and fn_name == action_name

          trigger ->
            type == trigger
        end
      end)

    if trigger != nil do
      %WasmSpec.Trigger{input: input} = trigger

      with {:ok, args} <- maybe_recipient_arg(maybe_recipient),
           {:ok, args} <- WasmSpec.cast_wasm_input(args, input) do
        # FIXME: remove the fetch genesis address when it will be integrated in the transaction's structure

        maybe_trigger_tx =
          case maybe_trigger_tx do
            nil ->
              nil

            tx ->
              Map.put(
                tx,
                :genesis,
                tx
                |> Transaction.previous_address()
                |> Archethic.fetch_genesis_address()
                |> elem(1)
              )
          end

        WasmModule.execute(
          module,
          trigger.name,
          transaction: maybe_trigger_tx,
          state: state,
          balance: UTXO.get_balance(inputs),
          arguments: args,
          contract:
            Map.put(
              contract_tx,
              :genesis,
              contract_tx
              |> Transaction.previous_address()
              |> Archethic.fetch_genesis_address()
              |> elem(1)
            ),
          encrypted_seed: get_encrypted_seed(contract_tx)
        )
      else
        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :trigger_not_exists}
    end
  end

  defp maybe_recipient_arg(nil), do: {:ok, nil}
  defp maybe_recipient_arg(%Recipient{args: args}) when is_map(args), do: {:ok, args}
  defp maybe_recipient_arg(_), do: {:error, "Wasm contract support only arguments as map"}

  defp time_now({:transaction, _, _}, %Transaction{
         validation_stamp: %ValidationStamp{timestamp: timestamp}
       }) do
    timestamp
  end

  defp time_now(:oracle, %Transaction{
         validation_stamp: %ValidationStamp{timestamp: timestamp}
       }) do
    timestamp
  end

  defp time_now({:datetime, timestamp}, nil) do
    timestamp
  end

  defp time_now({:interval, interval}, nil) do
    Utils.get_current_time_for_interval(interval)
  end

  defp cast_trigger_result(res = {:ok, _, next_state, logs}, prev_state, contract_tx) do
    if State.empty?(next_state) do
      cast_valid_trigger_result(res, prev_state, contract_tx, nil)
    else
      encoded_state = State.serialize(next_state)

      if State.valid_size?(encoded_state) do
        cast_valid_trigger_result(res, prev_state, contract_tx, encoded_state)
      else
        {:error,
         %Failure{
           logs: logs,
           error: :state_exceed_threshold,
           stacktrace: [],
           user_friendly_error: "Execution was successful but the state exceed the threshold"
         }}
      end
    end
  end

  defp cast_trigger_result(
         {:ok, %UpdateResult{transaction: next_tx, state: next_state}},
         prev_state,
         contract_tx = %Transaction{data: %TransactionData{contract: contract}}
       ) do
    next_tx =
      if next_tx != nil do
        if next_tx.data.contract == nil do
          next_tx
          |> put_in([Access.key(:data, %{}), :contract], contract)
          |> Transaction.cast()
        else
          Transaction.cast(next_tx)
        end
      end

    if State.empty?(next_state) do
      cast_valid_trigger_result({:ok, next_tx, next_state, []}, prev_state, contract_tx, nil)
    else
      encoded_state = State.serialize(next_state)

      if State.valid_size?(encoded_state) do
        cast_valid_trigger_result(
          {:ok, next_tx, next_state, []},
          prev_state,
          contract_tx,
          encoded_state
        )
      else
        {:error,
         %Failure{
           logs: [],
           error: :state_exceed_threshold,
           stacktrace: [],
           user_friendly_error: "Execution was successful but the state exceed the threshold"
         }}
      end
    end
  end

  defp cast_trigger_result({:ok, nil}, _, _),
    do:
      {:error,
       %Failure{
         logs: [],
         error: :invalid_trigger_output,
         stacktrace: [],
         user_friendly_error: "Trigger must return either a new transaction or a new state"
       }}

  defp cast_trigger_result(err = {:error, %Failure{}}, _, _), do: err

  defp cast_trigger_result({:error, :trigger_not_exists}, _, _) do
    {:error,
     %Failure{
       logs: [],
       error: :trigger_not_exists,
       stacktrace: [],
       user_friendly_error: "Trigger not found in the contract"
     }}
  end

  defp cast_trigger_result({:error, err, stacktrace, _logs}, _, _) do
    {:error, raise_to_failure(err, stacktrace)}
  end

  defp cast_trigger_result({:error, reason}, _, _) when is_binary(reason) do
    {:error,
     %Failure{
       error: :execution_raise,
       user_friendly_error: reason,
       stacktrace: [],
       logs: []
     }}
  end

  defp cast_trigger_result({:error, %{"message" => message}}, _, _) do
    {:error,
     %Failure{
       error: :contract_throw,
       user_friendly_error: message,
       stacktrace: [],
       logs: []
     }}
  end

  # No output transaction, no state update
  defp cast_valid_trigger_result({:ok, nil, next_state, logs}, previous_state, _, encoded_state)
       when next_state == previous_state do
    {:ok, %ActionWithoutTransaction{encoded_state: encoded_state, logs: logs}}
  end

  # No output transaction but state update
  defp cast_valid_trigger_result({:ok, nil, _next_state, logs}, _, contract_tx, encoded_state) do
    {:ok,
     %ActionWithTransaction{
       encoded_state: encoded_state,
       logs: logs,
       next_tx: generate_next_tx(contract_tx)
     }}
  end

  defp cast_valid_trigger_result({:ok, next_tx, _next_state, logs}, _, _, encoded_state) do
    {:ok, %ActionWithTransaction{encoded_state: encoded_state, logs: logs, next_tx: next_tx}}
  end

  @doc """
  Execute contract's function
  """
  @spec execute_function(
          contract :: InterpretedContract.t() | WasmContract.t(),
          function_name :: String.t(),
          args_values :: list() | map(),
          inputs :: list(UnspentOutput.t())
        ) ::
          {:ok, value :: any(), logs :: list(String.t())}
          | {:error, Failure.t()}
  def execute_function(
        %WasmContract{
          module: module = %WasmModule{spec: spec},
          state: state,
          transaction: contract_tx
        },
        function_name,
        args_values,
        inputs
      )
      when is_map(args_values) do
    case WasmSpec.get_function_spec(spec, function_name) do
      {:error, :function_does_not_exist} ->
        {:error,
         %Failure{
           error: :function_does_not_exist,
           user_friendly_error: "#{function_name} is not exposed as public function",
           stacktrace: [],
           logs: []
         }}

      {:ok, %WasmSpec.Function{input: input}} ->
        with {:ok, arg} <- WasmSpec.cast_wasm_input(args_values, input),
             {:ok, %ReadResult{value: value}} <-
               WasmModule.execute(module, function_name,
                 state: state,
                 balance: UTXO.get_balance(inputs),
                 arguments: arg,
                 encrypted_seed: get_encrypted_seed(contract_tx),
                 contract:
                   Map.put(
                     contract_tx,
                     :genesis,
                     Archethic.fetch_genesis_address(contract_tx.address) |> elem(1)
                   )
               ) do
          {:ok, value, []}
        else
          {:error, reason} ->
            {:error,
             %Failure{
               user_friendly_error: "#{inspect(reason)}",
               error: :invalid_function_call
             }}
        end
    end
  end

  def execute_function(%WasmContract{}, _function_name, _args_values, _input),
    do:
      {:error,
       %Failure{
         user_friendly_error: "Wasm contract support only arguments as map",
         error: :invalid_function_call
       }}

  def execute_function(
        contract = %InterpretedContract{
          transaction: contract_tx,
          version: contract_version,
          state: state
        },
        function_name,
        args_values,
        inputs
      ) do
    case get_function_from_contract(contract, function_name, args_values) do
      {:error, :function_does_not_exist} ->
        {:error,
         %Failure{
           user_friendly_error: "The function you are trying to call does not exist",
           error: :function_does_not_exist
         }}

      {:error, :function_is_private} ->
        {:error,
         %Failure{
           user_friendly_error: "The function you are trying to call is private",
           error: :function_is_private
         }}

      {:ok, function} ->
        contract_constants =
          contract_tx
          |> ConstantsInterpreter.from_transaction(contract_version)
          |> ConstantsInterpreter.set_balance(inputs)

        constants = %{
          "contract" => contract_constants,
          :time_now => DateTime.utc_now() |> DateTime.to_unix(),
          :encrypted_seed => get_encrypted_seed(contract_tx),
          :state => state
        }

        task =
          Task.Supervisor.async_nolink(Archethic.task_supervisors(), fn ->
            try do
              # TODO: logs
              logs = []
              value = Interpreter.execute_function(function, constants, args_values)
              {:ok, value, logs}
            rescue
              err -> {:error, raise_to_failure(err, __STACKTRACE__)}
            end
          end)

        # 500ms to execute or raise
        case Task.yield(task, 500) || Task.shutdown(task) do
          nil ->
            {:error,
             %Failure{
               user_friendly_error: "Function's execution timed-out",
               error: :function_timeout
             }}

          {:ok, {:error, failure}} ->
            {:error, failure}

          {:ok, {:ok, value, logs}} ->
            {:ok, value, logs}
        end
    end
  end

  @doc """
  Called by the telemetry poller
  """
  def maximum_calls_in_queue() do
    genesis_addresses =
      Registry.select(Archethic.ContractRegistry, [
        {{:"$1", :_, :_}, [], [:"$1"]}
      ])

    invalid_calls = :ets.info(:archethic_invalid_call) |> Keyword.get(:size)

    queued_calls =
      Task.Supervisor.async_stream_nolink(
        Archethic.task_supervisors(),
        genesis_addresses,
        fn genesis_address ->
          genesis_address
          |> UTXO.stream_unspent_outputs()
          |> Enum.filter(&(&1.unspent_output.type == :call))
          |> Enum.count()
        end,
        timeout: 5_000,
        ordered: false,
        on_timeout: :kill_task,
        max_concurrency: 100
      )
      |> Stream.filter(&match?({:ok, _}, &1))
      |> Stream.map(&elem(&1, 1))
      |> Enum.sum()

    :telemetry.execute(
      [:archethic, :contract],
      %{
        queued_calls: queued_calls - invalid_calls,
        invalid_calls: invalid_calls
      }
    )
  rescue
    _ ->
      # this will fail at startup because ContractRegistry does not exist yet
      :ok
  end

  defp get_function_from_contract(%{functions: functions}, function_name, args_values) do
    case Map.get(functions, {function_name, length(args_values)}) do
      nil ->
        {:error, :function_does_not_exist}

      function ->
        case function do
          %{visibility: :public} -> {:ok, function}
          %{visibility: :private} -> {:error, :function_is_private}
        end
    end
  end

  @doc """
  Load transaction into the Smart Contract context leveraging the interpreter
  """
  @spec load_transaction(
          tx :: Transaction.t(),
          genesis_address :: Crypto.prepended_hash(),
          opts :: Keyword.t()
        ) :: :ok
  defdelegate load_transaction(tx, genesis_address, opts), to: Loader

  @doc """
  Validate any kind of condition.
  The transaction and datetime depends on the condition.
  """
  @spec execute_condition(
          condition_type :: InterpretedContract.condition_type(),
          contract :: InterpretedContract.t() | WasmContract.t(),
          incoming_transaction :: Transaction.t(),
          maybe_recipient :: nil | Recipient.t(),
          validation_time :: DateTime.t(),
          inputs :: list(UnspentOutput.t()),
          opts :: Keyword.t()
        ) :: {:ok, logs :: list(String.t())} | {:error, ConditionRejected.t() | Failure.t()}
  def execute_condition(
        condition_key,
        contract,
        transaction,
        maybe_recipient,
        datetime,
        inputs,
        opts \\ []
      )

  def execute_condition(
        :inherit,
        %WasmContract{module: module},
        transaction = %Transaction{
          validation_stamp: %ValidationStamp{
            ledger_operations: %LedgerOperations{
              unspent_outputs: next_unspent_outputs
            }
          }
        },
        _maybe_recipient,
        _datetime,
        inputs,
        _opts
      ) do
    if "onInherit" in WasmModule.list_exported_functions_name(module) do
      next_state =
        case Enum.find(next_unspent_outputs, &(&1.type == :state)) do
          nil ->
            %{}

          %UnspentOutput{encoded_payload: encoded_payload} ->
            {state, _} = State.deserialize(encoded_payload)
            state
        end

      case WasmModule.execute(module, "onInherit",
             state: next_state,
             balance: UTXO.get_balance(inputs),
             transaction: transaction
           ) do
        {:ok, _} ->
          {:ok, []}

        {:error, reason} ->
          {:error,
           %Failure{
             error: :invalid_inherit_condition,
             user_friendly_error: "#{inspect(reason)}",
             logs: [],
             stacktrace: []
           }}
      end
    else
      {:ok, []}
    end
  end

  def execute_condition(
        _condition_key,
        %WasmContract{},
        _transaction,
        _recipient,
        _datetime,
        _inputs,
        _opts
      ),
      do: {:ok, []}

  def execute_condition(
        condition_key,
        contract = %InterpretedContract{conditions: conditions},
        transaction = %Transaction{},
        maybe_recipient,
        datetime,
        inputs,
        opts
      ) do
    conditions
    |> Map.get(condition_key)
    |> do_execute_condition(
      condition_key,
      contract,
      transaction,
      datetime,
      maybe_recipient,
      inputs,
      opts
    )
  end

  defp do_execute_condition(nil, :inherit, _, _, _, _, _, _), do: {:ok, []}

  defp do_execute_condition(nil, _, _, _, _, _, _, _) do
    {:error,
     %Failure{
       error: :missing_condition,
       user_friendly_error: "Missing condition",
       logs: [],
       stacktrace: []
     }}
  end

  defp do_execute_condition(
         %ConditionsInterpreter{args: args, subjects: subjects},
         condition_key,
         contract = %InterpretedContract{
           version: version,
           transaction: %Transaction{address: contract_address}
         },
         transaction = %Transaction{address: tx_address},
         datetime,
         maybe_recipient,
         inputs,
         opts
       ) do
    named_action_constants = Interpreter.get_named_action_constants(args, maybe_recipient)

    condition_constants =
      get_condition_constants(condition_key, contract, transaction, datetime, inputs)

    key =
      {:execute_condition, condition_key, contract_address, tx_address, datetime,
       inputs_digest(inputs)}

    cache_interpreter_execute(
      fn ->
        case Interpreter.execute_condition(
               version,
               subjects,
               Map.merge(named_action_constants, condition_constants)
             ) do
          {:ok, logs} -> {:ok, logs}
          {:error, subject, logs} -> {:error, %ConditionRejected{subject: subject, logs: logs}}
        end
      end,
      key,
      timeout_err_msg: "Condition's execution timed-out",
      cache?: Keyword.get(opts, :cache?, true)
    )
  end

  @doc """
  Termine a smart contract execution when a new transaction on the chain happened
  """
  @spec stop_contract(binary()) :: :ok
  defdelegate stop_contract(address), to: Loader

  @doc """
  Returns a contract instance from a transaction
  """
  @spec from_transaction(Transaction.t()) ::
          {:ok, InterpretedContract.t() | WasmContract.t()} | {:error, String.t()}
  def from_transaction(tx = %Transaction{data: %TransactionData{code: code}}) do
    if code != "" do
      InterpretedContract.from_transaction(tx)
    else
      WasmContract.from_transaction(tx)
    end
  end

  @doc """
  Returns a contract instance from a transaction
  """
  @spec validate_and_parse_transaction(transaction :: Transaction.t()) ::
          {:ok, InterpretedContract.t() | WasmContract.t()} | {:error, String.t()}
  def validate_and_parse_transaction(tx = %Transaction{version: version}) when version < 4,
    do: InterpretedContract.from_transaction(tx)

  def validate_and_parse_transaction(%Transaction{data: %TransactionData{contract: nil}}),
    do: {:error, "No contract to parse"}

  def validate_and_parse_transaction(%Transaction{data: %TransactionData{contract: contract}}),
    do: WasmContract.validate_and_parse(contract)

  defp get_condition_constants(
         :inherit,
         %InterpretedContract{
           transaction: contract_tx,
           functions: functions,
           version: contract_version,
           state: state
         },
         transaction = %Transaction{
           validation_stamp: %ValidationStamp{
             ledger_operations: %LedgerOperations{
               consumed_inputs: consumed_inputs,
               unspent_outputs: unspent_outputs
             }
           }
         },
         datetime,
         inputs
       ) do
    new_inputs =
      inputs
      |> Enum.reject(fn input ->
        Enum.any?(
          consumed_inputs,
          &(&1.unspent_output.type == input.type and &1.unspent_output.from == input.from)
        )
      end)
      |> Enum.concat(unspent_outputs)

    next_constants =
      transaction
      |> ConstantsInterpreter.from_transaction(contract_version)
      |> ConstantsInterpreter.set_balance(new_inputs)

    previous_contract_constants =
      contract_tx
      |> ConstantsInterpreter.from_transaction(contract_version)
      |> ConstantsInterpreter.set_balance(inputs)

    %{
      "previous" => previous_contract_constants,
      "next" => next_constants,
      :time_now => DateTime.to_unix(datetime),
      :functions => functions,
      :encrypted_seed => get_encrypted_seed(contract_tx),
      :state => state
    }
  end

  defp get_condition_constants(
         _,
         %InterpretedContract{
           transaction: contract_tx,
           functions: functions,
           version: contract_version,
           state: state
         },
         transaction,
         datetime,
         inputs
       ) do
    contract_constants =
      contract_tx
      |> ConstantsInterpreter.from_transaction(contract_version)
      |> ConstantsInterpreter.set_balance(inputs)

    %{
      "transaction" => ConstantsInterpreter.from_transaction(transaction, contract_version),
      "contract" => contract_constants,
      :time_now => DateTime.to_unix(datetime),
      :functions => functions,
      :encrypted_seed => get_encrypted_seed(contract_tx),
      :state => state
    }
  end

  # create a new transaction with the same code
  defp generate_next_tx(%Transaction{data: %TransactionData{code: code, contract: contract}}) do
    if code != "" do
      %Transaction{
        version: 3,
        type: :contract,
        data: %TransactionData{
          code: code
        }
      }
    else
      %Transaction{
        type: :contract,
        data: %TransactionData{
          contract: contract
        }
      }
    end
  end

  defp raise_to_failure(
         err = %Library.ErrorContractThrow{code: code, message: message, data: data},
         stacktrace
       ) do
    %Failure{
      user_friendly_error: append_line_to_error(err, stacktrace),
      error: :contract_throw,
      stacktrace: stacktrace,
      data: %{"code" => code, "message" => message, "data" => data},
      logs: []
    }
  end

  defp raise_to_failure(err, stacktrace) do
    %Failure{
      user_friendly_error: append_line_to_error(err, stacktrace),
      error: :execution_raise,
      stacktrace: stacktrace,
      logs: []
    }
  end

  defp append_line_to_error(err, stacktrace) do
    case Enum.find_value(stacktrace, fn
           {_, _, _, [file: 'nofile', line: line]} -> line
           _ -> false
         end) do
      line when is_integer(line) -> Exception.message(err) <> " - L#{line}"
      _ -> Exception.message(err)
    end
  end

  defp cache_interpreter_execute(fun, key, opts) do
    func = fn ->
      try do
        fun.()
      rescue
        err ->
          # error or throw from the user's code (ex: 1 + "abc")
          {:error, err, __STACKTRACE__}
      end
    end

    result =
      if Keyword.fetch!(opts, :cache?) do
        # We set the maximum timeout for a transaction to be processed before the kill the cache
        Utils.JobCache.get!(key,
          function: func,
          timeout: Keyword.get(opts, :timeout, 5_000),
          ttl: 60_000
        )
      else
        func.()
      end

    case result do
      {:error, err, stacktrace} -> {:error, raise_to_failure(err, stacktrace)}
      result -> result
    end
  rescue
    _ ->
      timeout_err_msg = Keyword.get(opts, :timeout_err_msg, "Contract's execution timeouts")
      {:error, %Failure{user_friendly_error: timeout_err_msg, error: :execution_timeout}}
  end

  defp inputs_digest(inputs) do
    inputs
    |> Enum.map(fn
      %UnspentOutput{from: nil, type: type} ->
        <<UnspentOutput.type_to_str(type)::binary>>

      %UnspentOutput{from: from, type: type} ->
        <<from::binary, UnspentOutput.type_to_str(type)::binary>>
    end)
    |> :erlang.list_to_binary()
    |> then(fn binary -> :crypto.hash(:sha256, binary) end)
  end

  @doc """
  Add seed ownership to transaction (on contract version != 0)
  Sign a next transaction in the contract chain
  """
  @spec sign_next_transaction(
          contract :: InterpretedContract.t() | WasmContract.t(),
          next_tx :: Transaction.t(),
          index :: non_neg_integer()
        ) :: {:ok, Transaction.t()} | {:error, :decryption_failed}
  def sign_next_transaction(
        %{
          transaction:
            prev_tx = %Transaction{previous_public_key: previous_public_key, address: address}
        },
        %Transaction{version: version, type: next_type, data: next_data},
        index
      ) do
    case get_contract_seed(prev_tx) do
      {:ok, contract_seed} ->
        ownership = create_new_seed_ownership(contract_seed)
        next_data = Map.update(next_data, :ownerships, [ownership], &[ownership | &1])

        signed_tx =
          Transaction.new(
            next_type,
            next_data,
            contract_seed,
            index,
            curve: Crypto.get_public_key_curve(previous_public_key),
            origin: Crypto.get_public_key_origin(previous_public_key),
            version: version
          )

        {:ok, signed_tx}

      error ->
        Logger.debug("Cannot decrypt the transaction seed", contract: Base.encode16(address))
        error
    end
  end

  defp create_new_seed_ownership(seed) do
    storage_nonce_pub_key = Crypto.storage_nonce_public_key()

    aes_key = :crypto.strong_rand_bytes(32)
    secret = Crypto.aes_encrypt(seed, aes_key)
    encrypted_key = Crypto.ec_encrypt(aes_key, storage_nonce_pub_key)

    %Ownership{secret: secret, authorized_keys: %{storage_nonce_pub_key => encrypted_key}}
  end

  @doc """
  Remove the seed ownership of a contract transaction
  """
  @spec remove_seed_ownership(tx :: Transaction.t()) :: Transaction.t()
  def remove_seed_ownership(tx) do
    storage_nonce_public_key = Crypto.storage_nonce_public_key()

    update_in(tx, [Access.key!(:data), Access.key!(:ownerships)], fn ownerships ->
      case Enum.find_index(
             ownerships,
             &Ownership.authorized_public_key?(&1, storage_nonce_public_key)
           ) do
        nil -> ownerships
        index -> List.delete_at(ownerships, index)
      end
    end)
  end

  @doc """
  Same as remove_seed_ownership but raise if no ownership matches contract seed
  """
  @spec remove_seed_ownership!(tx :: Transaction.t()) :: Transaction.t()
  def remove_seed_ownership!(tx) do
    case remove_seed_ownership(tx) do
      ^tx -> raise "Contract does not have seed ownership"
      tx -> tx
    end
  end

  @doc """
  Determines if a contract has any triggers
  """
  @spec contains_trigger?(InterpretedContract.t() | WasmContract.t()) :: boolean()
  def contains_trigger?(contract = %InterpretedContract{}),
    do: InterpretedContract.contains_trigger?(contract)

  def contains_trigger?(contract = %WasmContract{}), do: WasmContract.contains_trigger?(contract)

  @doc """
  Return the ownership related to the storage nonce public key
  """
  @spec get_seed_ownership(Transaction.t()) :: Ownership.t() | nil
  def get_seed_ownership(%Transaction{data: %TransactionData{ownerships: ownerships}}) do
    storage_nonce_public_key = Crypto.storage_nonce_public_key()
    Enum.find(ownerships, &Ownership.authorized_public_key?(&1, storage_nonce_public_key))
  end

  @doc """
  Return the encrypted seed and encrypted aes key
  """
  @spec get_encrypted_seed(Transaction.t()) :: {binary(), binary()} | nil
  def get_encrypted_seed(tx = %Transaction{}) do
    case get_seed_ownership(tx) do
      %Ownership{secret: secret, authorized_keys: authorized_keys} ->
        storage_nonce_public_key = Crypto.storage_nonce_public_key()
        encrypted_key = Map.get(authorized_keys, storage_nonce_public_key)

        {secret, encrypted_key}

      nil ->
        nil
    end
  end

  @doc """
  Try to find the contract's seed in the transaction's ownerships
  """
  @spec get_contract_seed(Transaction.t()) :: {:ok, binary()} | {:error, :decryption_failed}
  def get_contract_seed(tx = %Transaction{}) do
    {secret, encrypted_key} = get_encrypted_seed(tx)

    case Crypto.ec_decrypt_with_storage_nonce(encrypted_key) do
      {:ok, aes_key} -> Crypto.aes_decrypt(secret, aes_key)
      {:error, :decryption_failed} -> {:error, :decryption_failed}
    end
  end
end
