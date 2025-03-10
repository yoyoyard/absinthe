defmodule Absinthe.Subscription do
  @moduledoc """
  Real time updates via GraphQL

  For a how to guide on getting started with Absinthe.Subscriptions in your phoenix
  project see the Absinthe.Phoenix package.

  Define in your schema via `Absinthe.Schema.subscription/2`

  ## Basic Usage

  ## Performance Characteristics

  There are a couple of limitations to the beta release of subscriptions that
  are worth keeping in mind if you want to use this in production:

  By design, all subscription docs triggered by a mutation are run inside the
  mutation process as a form of back pressure.

  At the moment however database batching does not happen across the set of
  subscription docs. Thus if you have a lot of subscription docs and they each
  do a lot of extra DB lookups you're going to delay incoming mutation responses
  by however long it takes to do all that work.

  Before the final version of 1.4.0 we want

  - Batching across subscriptions
  - More user control over back pressure / async balance.
  """

  require Logger
  alias __MODULE__

  @doc """
  Add Absinthe.Subscription to your process tree.
  """
  defdelegate start_link(pubsub), to: Subscription.Supervisor

  def child_spec(pubsub) do
    %{
      id: __MODULE__,
      start: {Subscription.Supervisor, :start_link, [pubsub]},
      type: :supervisor
    }
  end

  @type subscription_field_spec :: {atom, term | (term -> term)}

  @doc """
  Publish a mutation

  This function is generally used when trying to publish to one or more subscription
  fields "out of band" from any particular mutation.

  ## Examples

  Note: As with all subscription examples if you're using Absinthe.Phoenix `pubsub`
  will be `MyAppWeb.Endpoint`.

  ```
  Absinthe.Subscription.publish(pubsub, user, [new_users: user.account_id])
  ```
  ```
  # publish to two subscription fields
  Absinthe.Subscription.publish(pubsub, user, [
    new_users: user.account_id,
    other_user_subscription_field: user.id,
  ])
  ```
  """
  @spec publish(
          Absinthe.Subscription.Pubsub.t(),
          term,
          Absinthe.Resolution.t() | [subscription_field_spec]
        ) :: :ok
  def publish(pubsub, mutation_result, %Absinthe.Resolution{} = info) do
    subscribed_fields = get_subscription_fields(info)
    publish(pubsub, mutation_result, subscribed_fields)
  end

  def publish(pubsub, mutation_result, subscribed_fields) do
    _ = publish_remote(pubsub, mutation_result, subscribed_fields)
    _ = Subscription.Local.publish_mutation(pubsub, mutation_result, subscribed_fields)
    :ok
  end

  defp get_subscription_fields(resolution_info) do
    mutation_field = resolution_info.definition.schema_node
    schema = resolution_info.schema
    subscription = Absinthe.Schema.lookup_type(schema, :subscription) || %{fields: []}

    subscription_fields = fetch_fields(subscription.fields, mutation_field.triggers)

    for {sub_field_id, sub_field} <- subscription_fields do
      triggers = Absinthe.Type.function(sub_field, :triggers)
      config = Map.fetch!(triggers, mutation_field.identifier)
      {sub_field_id, config}
    end
  end

  # TODO: normalize the `.fields` type.
  defp fetch_fields(fields, triggers) when is_map(fields) do
    Map.take(fields, triggers)
  end

  defp fetch_fields(_, _), do: []

  @doc false
  def subscribe(pubsub, field_key, doc_id, doc) do
    registry = pubsub |> registry_name

    {:ok, _} = Registry.register(registry, field_key, {doc_id, doc})
    {:ok, _} = Registry.register(registry, {self(), doc_id}, field_key)
  end

  @doc false
  def unsubscribe(pubsub, doc_id) do
    registry = pubsub |> registry_name
    self = self()

    for {^self, field_key} <- Registry.lookup(registry, {self, doc_id}) do
      Registry.unregister_match(registry, field_key, {doc_id, :_})
    end

    Registry.unregister(registry, {self, doc_id})
    :ok
  end

  @doc false
  def get(pubsub, key) do
    pubsub
    |> registry_name
    |> Registry.lookup(key)
    |> Enum.map(&elem(&1, 1))
    |> Map.new()
  end

  @doc false
  def registry_name(pubsub) do
    Module.concat([pubsub, :Registry])
  end

  @doc false
  def publish_remote(pubsub, mutation_result, subscribed_fields) do
    {:ok, pool_size} =
      pubsub
      |> registry_name
      |> Registry.meta(:pool_size)

    shard = :erlang.phash2(mutation_result, pool_size)

    proxy_topic = Subscription.Proxy.topic(shard)

    :ok = pubsub.publish_mutation(proxy_topic, mutation_result, subscribed_fields)
  end

  ## Middleware callback
  @doc false
  def call(%{state: :resolved, errors: [], value: value} = res, _) do
    with {:ok, pubsub} <- extract_pubsub(res.context) do
      if subscription_middleware = Application.get_env(:absinthe, :subscription_middleware) do
        subscription_middleware.publish(value, res)
      else
        __MODULE__.publish(pubsub, value, res)
      end
    end

    res
  end

  def call(res, _), do: res

  @doc false
  def extract_pubsub(context) do
    with {:ok, pubsub} <- Map.fetch(context, :pubsub),
         pid when is_pid(pid) <- Process.whereis(registry_name(pubsub)) do
      {:ok, pubsub}
    else
      _ -> :error
    end
  end

  @doc false
  def add_middleware(middleware) do
    middleware ++ [{__MODULE__, []}]
  end
end
