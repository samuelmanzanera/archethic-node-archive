defmodule Archethic.TransactionChain.TransactionData.Recipient do
  @moduledoc """
  Represents a call to a Smart Contract

  Action & Args are nil for a :transaction trigger and are filled for a {:transaction, action, args} trigger
  """
  alias Archethic.Crypto
  alias Archethic.TransactionChain.Transaction
  alias Archethic.Utils
  alias Archethic.Utils.TypedEncoding

  defstruct [:address, :action, :args]

  @unnamed_action 0
  @named_action 1

  @type t :: %__MODULE__{
          address: Crypto.prepended_hash(),
          action: String.t() | nil,
          args: list(any()) | map() | nil
        }

  @doc """
  Serialize a recipient
  """
  @spec serialize(
          recipient :: t(),
          version :: pos_integer(),
          serialization_mode :: Transaction.serialization_mode()
        ) :: bitstring()
  def serialize(recipient, version, serialization_mode \\ :compact)

  def serialize(%__MODULE__{address: address}, _version = 1, _serialization_mode) do
    <<address::binary>>
  end

  def serialize(%__MODULE__{address: address, action: nil}, _version, _serialization_mode) do
    <<@unnamed_action::8, address::binary>>
  end

  def serialize(
        %__MODULE__{address: address, action: action, args: args},
        version,
        serialization_mode
      ) do
    serialized_args = serialize_args(args, version, serialization_mode)

    <<@named_action::8, address::binary, byte_size(action)::8, action::binary,
      serialized_args::bitstring>>
  end

  defp serialize_args(args, _version = 2, _) do
    serialized_args = Jason.encode!(args)
    args_bytes = serialized_args |> byte_size() |> Utils.VarInt.from_value()
    <<args_bytes::binary, serialized_args::binary>>
  end

  defp serialize_args(args, _version = 3, mode) when is_list(args) do
    bin = args |> Enum.map(&TypedEncoding.serialize(&1, mode)) |> :erlang.list_to_bitstring()
    <<length(args)::8, bin::bitstring>>
  end

  defp serialize_args(args, _, mode) when is_map(args), do: TypedEncoding.serialize(args, mode)

  @doc """
  Deserialize a recipient
  """
  @spec deserialize(
          rest :: bitstring(),
          version :: pos_integer(),
          serialization_mode :: Transaction.serialization_mode()
        ) :: {t(), bitstring()}
  def deserialize(binary, version, serialization_mode \\ :compact)

  def deserialize(rest, _version = 1, _serialization_mode) do
    {address, rest} = Utils.deserialize_address(rest)
    {%__MODULE__{address: address}, rest}
  end

  def deserialize(<<@unnamed_action::8, rest::bitstring>>, _version, _serialization_mode) do
    {address, rest} = Utils.deserialize_address(rest)
    {%__MODULE__{address: address}, rest}
  end

  def deserialize(<<@named_action::8, rest::bitstring>>, version, serialization_mode) do
    {address, <<action_bytes::8, rest::bitstring>>} = Utils.deserialize_address(rest)
    <<action::binary-size(action_bytes), rest::bitstring>> = rest
    {args, rest} = deserialize_args(rest, version, serialization_mode)

    {%__MODULE__{address: address, action: action, args: args}, rest}
  end

  defp deserialize_args(rest, _version = 2, _) do
    {args_bytes, rest} = Utils.VarInt.get_value(rest)
    <<args::binary-size(args_bytes), rest::bitstring>> = rest
    {Jason.decode!(args), rest}
  end

  defp deserialize_args(<<0::8, rest::bitstring>>, _version = 3, _), do: {[], rest}

  defp deserialize_args(<<nb_args::8, rest::bitstring>>, _version = 3, mode) do
    {args, rest} =
      Enum.reduce(1..nb_args, {[], rest}, fn _, {args, rest} ->
        {arg, rest} = TypedEncoding.deserialize(rest, mode)
        {[arg | args], rest}
      end)

    {Enum.reverse(args), rest}
  end

  defp deserialize_args(rest, _, mode), do: TypedEncoding.deserialize(rest, mode)

  @doc false
  @spec cast(recipient :: binary() | map()) :: t()
  def cast(recipient) when is_binary(recipient), do: %__MODULE__{address: recipient}

  def cast(recipient = %{address: address}) do
    action = Map.get(recipient, :action)
    args = Map.get(recipient, :args)
    %__MODULE__{address: address, action: action, args: args}
  end

  @doc false
  @spec to_map(recipient :: t()) :: map()
  def to_map(%__MODULE__{address: address, action: action, args: args}),
    do: %{address: address, action: action, args: args}

  @spec to_address(recipient :: t()) :: list(binary())
  def to_address(%{address: address}), do: address

  @type trigger_key :: {:transaction, nil | String.t(), nil | non_neg_integer()}

  @doc """
  Return the args names for this recipient or nil
  """
  @spec get_trigger(t()) :: trigger_key()
  def get_trigger(%__MODULE__{action: nil, args: nil}), do: {:transaction, nil, nil}

  def get_trigger(%__MODULE__{action: action, args: args_values})
      when is_list(args_values),
      do: {:transaction, action, length(args_values)}

  def get_trigger(%__MODULE__{action: action, args: args_values})
      when is_map(args_values),
      do: {:transaction, action, map_size(args_values)}
end
