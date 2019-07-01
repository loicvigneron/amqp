defmodule BasicTest do
  use ExUnit.Case

  alias AMQP.Connection
  alias AMQP.Channel
  alias AMQP.Basic
  alias AMQP.Queue

  setup do
    {:ok, conn} = Connection.open
    {:ok, chan} = Channel.open(conn)
    on_exit fn -> :ok = Connection.close(conn) end
    {:ok, conn: conn, chan: chan}
  end

  test "basic publish to default exchange", meta do
    assert :ok = Basic.publish(meta[:chan], "", "", "ping")
  end

  test "basic return", meta do
    :ok = Basic.return(meta[:chan], self())

    exchange = ""
    routing_key = "non-existent-queue"
    payload = "payload"

    Basic.publish(meta[:chan], exchange, routing_key, payload, mandatory: true)

    assert_receive {:basic_return,
                     ^payload,
                     %{routing_key: ^routing_key,
                       exchange: ^exchange,
                       reply_text: "NO_ROUTE"}}

    :ok = Basic.cancel_return(meta[:chan])

    Basic.publish(meta[:chan], exchange, routing_key, payload, mandatory: true)

    refute_receive {:basic_return, _payload, _properties}
  end

  describe "basic consume" do
    setup meta do
      {:ok, %{queue: queue}} = Queue.declare(meta[:chan])
      on_exit fn ->
        if Process.alive?(meta[:chan].pid), do: Queue.delete(meta[:chan], queue)
      end

      {:ok, Map.put(meta, :queue, queue)}
    end

    test "consumer receives :basic_consume_ok message", meta do
      {:ok, consumer_tag} = Basic.consume(meta[:chan], meta[:queue])
      assert_receive {:basic_consume_ok, %{consumer_tag: ^consumer_tag}}
    end

    test "consumer receives :basic_deliver message", meta do
      {:ok, consumer_tag} = Basic.consume(meta[:chan], meta[:queue])

      payload = "foo"
      correlation_id = "correlation_id"
      exchange = ""
      routing_key = meta[:queue]

      Basic.publish(meta[:chan], exchange, routing_key, payload, correlation_id: correlation_id)

      assert_receive {:basic_deliver,
                      ^payload,
                      %{consumer_tag: ^consumer_tag,
                        correlation_id: ^correlation_id,
                        routing_key: ^routing_key}}
    end

    test "consumer receives :basic_cancel_ok message", meta do
      {:ok, consumer_tag} = Basic.consume(meta[:chan], meta[:queue])
      {:ok, ^consumer_tag} = Basic.cancel(meta[:chan], consumer_tag)

      assert_receive {:basic_cancel_ok, %{consumer_tag: ^consumer_tag}}
    end

    test "consumer receives :basic_cancel message", meta do
      {:ok, consumer_tag} = Basic.consume(meta[:chan], meta[:queue])
      {:ok, _} = Queue.delete(meta[:chan], meta[:queue])

      assert_receive {:basic_cancel, %{consumer_tag: ^consumer_tag}}
    end

    test "cancel returns {:ok, consumer_tag}", meta do
      {:ok, consumer_tag} = Basic.consume(meta[:chan], meta[:queue])

      assert {:ok, ^consumer_tag} = Basic.cancel(meta[:chan], consumer_tag)
    end

    test "cancel returns {:error, reason} when channel is closing or blocking", meta do
      {:ok, consumer_tag} = Basic.consume(meta[:chan], meta[:queue])

      spawn fn -> Channel.close(meta[:chan]) end
      spawn fn -> assert {:error, :closing} = Basic.cancel(meta[:chan], consumer_tag) end
    end

    test "receives {:DOWN, _, _, _} message when queue does not exist", meta do
      catch_exit(Basic.consume(meta[:chan], "non-existent-queue"))
      assert_receive {:DOWN, _, _, _, _}
    end
  end
end
