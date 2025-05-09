defmodule Archethic.Utils.DetectNodeResponsivenessTest do
  use ArchethicCase, async: false
  @timeout 200
  @sleep_timeout 350

  alias Archethic.Utils.DetectNodeResponsiveness

  alias Archethic.Mining.WorkflowRegistry

  import Mox
  alias Archethic.Crypto
  alias Archethic.P2P
  alias Archethic.P2P.Node

  test "start_link/2 for start state" do
    address = <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>

    replaying_fn = fn count ->
      count
    end

    {:ok, pid} = DetectNodeResponsiveness.start_link(address, 1, replaying_fn, @timeout)
    assert true == Process.alive?(pid)
  end

  test "start_link/2 for hard timeout state" do
    address = <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>
    # dummy replaying fn with count as argument

    replaying_fn = fn count ->
      count
    end

    Process.flag(:trap_exit, true)

    {:ok, pid} = DetectNodeResponsiveness.start_link(address, 1, replaying_fn, @timeout)

    Process.sleep(@sleep_timeout)
    assert_receive {:EXIT, ^pid, {:shutdown, :hard_timeout}}
    assert false == Process.alive?(pid)
  end

  test "start_link/2 for soft timeout state" do
    address = <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>

    me = self()

    replaying_fn = fn count ->
      send(me, :replay)
      count
    end

    {pub1, _} = Crypto.derive_keypair("node1", 0)
    {pub2, _} = Crypto.derive_keypair("node2", 0)
    {pub3, _} = Crypto.derive_keypair("node3", 0)
    {pub4, _} = Crypto.derive_keypair("node4", 0)

    P2P.add_and_connect_node(%Node{
      ip: {127, 0, 0, 1},
      port: 3000,
      authorized?: true,
      last_public_key: pub1,
      first_public_key: pub1,
      available?: true,
      geo_patch: "AAA",
      network_patch: "AAA",
      enrollment_date: DateTime.utc_now(),
      authorization_date: DateTime.utc_now() |> DateTime.add(-10),
      reward_address: <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>
    })

    P2P.add_and_connect_node(%Node{
      first_public_key: pub2,
      last_public_key: pub2,
      authorized?: true,
      available?: true,
      authorization_date: DateTime.utc_now() |> DateTime.add(-10),
      geo_patch: "AAA",
      network_patch: "AAA",
      reward_address: <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>,
      enrollment_date: DateTime.utc_now()
    })

    P2P.add_and_connect_node(%Node{
      first_public_key: pub3,
      last_public_key: pub3,
      authorized?: true,
      available?: true,
      authorization_date: DateTime.utc_now() |> DateTime.add(-10),
      geo_patch: "AAA",
      network_patch: "AAA",
      reward_address: <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>,
      enrollment_date: DateTime.utc_now()
    })

    P2P.add_and_connect_node(%Node{
      first_public_key: pub4,
      last_public_key: pub4,
      authorized?: true,
      available?: true,
      authorization_date: DateTime.utc_now() |> DateTime.add(-10),
      geo_patch: "AAA",
      network_patch: "AAA",
      reward_address: <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>,
      enrollment_date: DateTime.utc_now()
    })

    Process.flag(:trap_exit, true)
    {:ok, pid} = DetectNodeResponsiveness.start_link(address, 4, replaying_fn, @timeout)
    Process.monitor(pid)

    MockDB
    |> stub(:transaction_exists?, fn ^address, _ ->
      false
    end)

    #  first soft_timeout
    assert true == Process.alive?(pid)
    assert_receive :replay, @sleep_timeout
    # second soft_timeout
    assert_receive :replay, @sleep_timeout
    assert true == Process.alive?(pid)
    # third soft_timeout
    assert_receive :replay, @sleep_timeout
    assert true == Process.alive?(pid)
    # last timeout leading to stop as hard_timeout
    Process.sleep(@sleep_timeout)
    assert_receive {:EXIT, ^pid, {:shutdown, :hard_timeout}}
    assert false == Process.alive?(pid)
  end

  test "should not retry if the transaction exists" do
    address = <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>

    me = self()

    replaying_fn = fn _count ->
      send(me, :replay)
    end

    {pub1, _} = Crypto.derive_keypair("node1", 0)
    {pub2, _} = Crypto.derive_keypair("node2", 0)

    P2P.add_and_connect_node(%Node{
      ip: {127, 0, 0, 1},
      port: 3000,
      authorized?: true,
      last_public_key: pub1,
      first_public_key: pub1,
      available?: true,
      geo_patch: "AAA",
      network_patch: "AAA",
      enrollment_date: DateTime.utc_now(),
      authorization_date: DateTime.utc_now() |> DateTime.add(-10),
      reward_address: <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>
    })

    P2P.add_and_connect_node(%Node{
      first_public_key: pub2,
      last_public_key: pub2,
      authorized?: true,
      available?: true,
      authorization_date: DateTime.utc_now() |> DateTime.add(-10),
      geo_patch: "AAA",
      network_patch: "AAA",
      reward_address: <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>,
      enrollment_date: DateTime.utc_now()
    })

    {:ok, pid} = DetectNodeResponsiveness.start_link(address, 2, replaying_fn, @timeout)

    MockDB
    |> stub(:transaction_exists?, fn ^address, _ ->
      Process.send_after(me, :transaction_stored, 50)
      true
    end)

    #  first soft_timeout
    assert_receive :transaction_stored, @sleep_timeout
    assert !Process.alive?(pid)
  end

  test "should retry after the first timeout" do
    address = <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>

    me = self()

    replaying_fn = fn _count ->
      send(me, :replay)
    end

    {pub1, _} = Crypto.derive_keypair("node1", 0)
    {pub2, _} = Crypto.derive_keypair("node2", 0)

    P2P.add_and_connect_node(%Node{
      ip: {127, 0, 0, 1},
      port: 3000,
      authorized?: true,
      last_public_key: pub1,
      first_public_key: pub1,
      available?: true,
      geo_patch: "AAA",
      network_patch: "AAA",
      enrollment_date: DateTime.utc_now(),
      authorization_date: DateTime.utc_now() |> DateTime.add(-10),
      reward_address: <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>
    })

    P2P.add_and_connect_node(%Node{
      first_public_key: pub2,
      last_public_key: pub2,
      authorized?: true,
      available?: true,
      authorization_date: DateTime.utc_now() |> DateTime.add(-10),
      geo_patch: "AAA",
      network_patch: "AAA",
      reward_address: <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>,
      enrollment_date: DateTime.utc_now()
    })

    {:ok, pid} = DetectNodeResponsiveness.start_link(address, 2, replaying_fn, @timeout)

    MockDB
    |> expect(:transaction_exists?, fn ^address, _ ->
      false
    end)
    |> expect(:transaction_exists?, fn ^address, _ ->
      Process.send_after(me, :transaction_stored, 50)
      true
    end)

    assert_receive :replay, @sleep_timeout
    assert_receive :transaction_stored, @sleep_timeout
    assert !Process.alive?(pid)
  end

  test "should run all the nodes to force the retry" do
    address = <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>

    me = self()

    replaying_fn = fn _count ->
      send(me, :replay)
    end

    {pub1, _} = Crypto.derive_keypair("node1", 0)
    {pub2, _} = Crypto.derive_keypair("node2", 0)

    P2P.add_and_connect_node(%Node{
      ip: {127, 0, 0, 1},
      port: 3000,
      authorized?: true,
      last_public_key: pub1,
      first_public_key: pub1,
      available?: true,
      geo_patch: "AAA",
      network_patch: "AAA",
      enrollment_date: DateTime.utc_now(),
      authorization_date: DateTime.utc_now() |> DateTime.add(-10),
      reward_address: <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>
    })

    P2P.add_and_connect_node(%Node{
      first_public_key: pub2,
      last_public_key: pub2,
      authorized?: true,
      available?: true,
      authorization_date: DateTime.utc_now() |> DateTime.add(-10),
      geo_patch: "AAA",
      network_patch: "AAA",
      reward_address: <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>,
      enrollment_date: DateTime.utc_now()
    })

    Process.flag(:trap_exit, true)
    {:ok, pid} = DetectNodeResponsiveness.start_link(address, 2, replaying_fn, @timeout)

    MockDB
    |> stub(:transaction_exists?, fn ^address, _ ->
      false
    end)

    assert_receive :replay, @sleep_timeout
    Process.sleep(@sleep_timeout)
    assert_receive {:EXIT, ^pid, {:shutdown, :hard_timeout}}
    assert !Process.alive?(pid)
  end

  test "should reschedule timeout if the transaction is in mining process" do
    address = <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>

    me = self()

    replaying_fn = fn _count ->
      send(me, :replay)
    end

    {pub1, _} = Crypto.derive_keypair("node1", 0)
    {pub2, _} = Crypto.derive_keypair("node2", 0)

    P2P.add_and_connect_node(%Node{
      ip: {127, 0, 0, 1},
      port: 3000,
      authorized?: true,
      last_public_key: pub1,
      first_public_key: pub1,
      available?: true,
      geo_patch: "AAA",
      network_patch: "AAA",
      enrollment_date: DateTime.utc_now(),
      authorization_date: DateTime.utc_now() |> DateTime.add(-10),
      reward_address: <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>
    })

    P2P.add_and_connect_node(%Node{
      first_public_key: pub2,
      last_public_key: pub2,
      authorized?: true,
      available?: true,
      authorization_date: DateTime.utc_now() |> DateTime.add(-10),
      geo_patch: "AAA",
      network_patch: "AAA",
      reward_address: <<0::8, 0::8, :crypto.strong_rand_bytes(32)::binary>>,
      enrollment_date: DateTime.utc_now()
    })

    {:ok, pid} = DetectNodeResponsiveness.start_link(address, 2, replaying_fn, @timeout)

    MockDB
    |> stub(:transaction_exists?, fn ^address, _ ->
      false
    end)

    Registry.register(WorkflowRegistry, address, [])

    #  first soft_timeout
    Process.sleep(@sleep_timeout)
    assert Process.alive?(pid)
    assert 1 == :sys.get_state(pid) |> Map.get(:count)
  end
end
