# defmodule Archethic.TransactionChain.MemTablesLoaderTest do
#   use ArchethicCase

#   alias Archethic.Crypto

#   alias Archethic.TransactionChain.MemTables.PendingLedger
#   alias Archethic.TransactionChain.MemTablesLoader
#   alias Archethic.TransactionChain.Transaction
#   alias Archethic.TransactionChain.Transaction.ValidationStamp
#   alias Archethic.TransactionChain.TransactionData
#   alias Archethic.TransactionChain.TransactionData.Recipient

#   alias Archethic.ContractFactory

#   import Mox

#   describe "load_transaction/1" do
#     test "should track pending transaction when a code proposal transaction is loaded" do
#       assert :ok =
#                %Transaction{
#                  address: "@CodeProp1",
#                  previous_public_key: "CodeProp0",
#                  data: %TransactionData{},
#                  type: :code_proposal,
#                  validation_stamp: %ValidationStamp{
#                    timestamp: DateTime.utc_now()
#                  }
#                }
#                |> MemTablesLoader.load_transaction()

#       assert ["@CodeProp1"] == PendingLedger.get_signatures("@CodeProp1")
#     end

#     test "should track pending transaction when a smart contract requires conditions is loaded" do
#       code = """
#       condition inherit: []

#       condition transaction: [
#        content: regex_match?(\"hello\")
#       ]

#       actions triggered_by: transaction do end
#       """

#       seed = :crypto.strong_rand_bytes(32)

#       tx =
#         %Transaction{address: address} =
#         ContractFactory.create_valid_contract_tx(code, seed: seed)

#       assert :ok == MemTablesLoader.load_transaction(tx)

#       assert [address] == PendingLedger.get_signatures(address)
#     end

#     test "should track recipients to add signature to pending transaction" do
#       assert :ok =
#                %Transaction{
#                  address: "@CodeProp1",
#                  previous_public_key: "CodeProp0",
#                  data: %TransactionData{},
#                  type: :code_proposal,
#                  validation_stamp: %ValidationStamp{
#                    timestamp: DateTime.utc_now()
#                  }
#                }
#                |> MemTablesLoader.load_transaction()

#       assert :ok =
#                %Transaction{
#                  address: "@CodeApproval1",
#                  previous_public_key: "CodeApproval0",
#                  data: %TransactionData{
#                    recipients: [%Recipient{address: "@CodeProp1"}]
#                  },
#                  type: :code_approval,
#                  validation_stamp: %ValidationStamp{
#                    timestamp: DateTime.utc_now()
#                  }
#                }
#                |> MemTablesLoader.load_transaction()

#       assert ["@CodeProp1", "@CodeApproval1"] = PendingLedger.get_signatures("@CodeProp1")
#     end
#   end

#   describe "start_link/1" do
#     test "should load from database the transaction to index" do
#       MockDB
#       |> stub(:list_transactions, fn _ ->
#         [
#           %Transaction{
#             address: Crypto.hash("Alice2"),
#             previous_public_key: "Alice1",
#             data: %TransactionData{},
#             type: :transfer,
#             validation_stamp: %ValidationStamp{
#               timestamp: DateTime.utc_now()
#             }
#           },
#           %Transaction{
#             address: Crypto.hash("Alice1"),
#             previous_public_key: "Alice0",
#             data: %TransactionData{},
#             type: :transfer,
#             validation_stamp: %ValidationStamp{
#               timestamp: DateTime.utc_now() |> DateTime.add(-10)
#             }
#           },
#           %Transaction{
#             address: "@CodeProp1",
#             previous_public_key: "CodeProp0",
#             data: %TransactionData{},
#             type: :code_proposal,
#             validation_stamp: %ValidationStamp{
#               timestamp: DateTime.utc_now()
#             }
#           },
#           %Transaction{
#             address: "@CodeApproval1",
#             previous_public_key: "CodeApproval0",
#             data: %TransactionData{
#               recipients: [%Recipient{address: "@CodeProp1"}]
#             },
#             type: :code_approval,
#             validation_stamp: %ValidationStamp{
#               timestamp: DateTime.utc_now()
#             }
#           }
#         ]
#       end)

#       assert {:ok, _} = MemTablesLoader.start_link()

#       assert ["@CodeProp1", "@CodeApproval1"] == PendingLedger.get_signatures("@CodeProp1")
#     end
#   end
# end
