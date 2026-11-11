defmodule DpExchange.Schwab.DeclaredOptionsTest do
  # Core issue #43: the facade and the Fake declare the option keys each call accepts, so a
  # consumer can `Keyword.take/2` instead of meeting `{:unknown_option, key}`. No network.
  use ExUnit.Case, async: true

  alias DpExchange.Core.Capabilities, as: CoreCapabilities
  alias DpExchange.Core.Venue
  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Fake, Options}

  @probe :dp_contract_unknown_option
  @no_such_function :dp_contract_no_such_function

  defp function_names(module) do
    module.__info__(:functions) |> Keyword.keys() |> Enum.uniq()
  end

  defp inactive?(module, name) do
    declaration = module.capabilities()

    Enum.any?(Venue.behaviour_info(:callbacks), fn {callback, arity} ->
      callback == name and not CoreCapabilities.active?(declaration, {callback, arity})
    end)
  end

  defp nil_valued(keys), do: Enum.map(keys, &{&1, nil})

  defp unique_atoms?(keys), do: Enum.all?(keys, &is_atom/1) and keys == Enum.uniq(keys)

  describe "start_options/0" do
    test "the facade declares exactly the start table" do
      assert Schwab.start_options() == Options.start_keys()
      assert unique_atoms?(Schwab.start_options())
      refute @probe in Schwab.start_options()
    end

    test "the fake declares the same start keys" do
      assert Fake.start_options() == Schwab.start_options()
    end

    test "every declared start key is accepted by the start check, nil-valued" do
      for key <- Schwab.start_options() do
        refute match?({:error, {:unknown_option, ^key}}, Options.check_start([{key, nil}])),
               "start key #{inspect(key)} is declared but refused as unknown"
      end

      assert :ok = Options.check_start(nil_valued(Schwab.start_options()))
    end

    test "a key outside the declaration is refused at start" do
      assert {:error, {:unknown_option, @probe}} = Options.check_start([{@probe, nil}])
      assert {:error, {:unknown_option, @probe}} = Schwab.start_link([{@probe, nil}])
      assert {:error, {:unknown_option, @probe}} = Fake.start_link([{@probe, nil}])
    end
  end

  describe "call_options/1 on the facade" do
    test "every public function answers ok or not_supported" do
      for name <- function_names(Schwab) do
        assert match?({:ok, _}, Schwab.call_options(name)) or
                 Schwab.call_options(name) == {:error, :not_supported},
               "#{name} answered #{inspect(Schwab.call_options(name))}"
      end
    end

    test "an inactive Venue callback is not_supported, an active one is ok" do
      callbacks = Keyword.keys(Venue.behaviour_info(:callbacks))

      for name <- function_names(Schwab), name in callbacks do
        if inactive?(Schwab, name) do
          assert Schwab.call_options(name) == {:error, :not_supported}
        else
          assert {:ok, keys} = Schwab.call_options(name)
          assert unique_atoms?(keys)
        end
      end

      assert Schwab.call_options(:quantization) == {:error, :not_supported}
      assert Schwab.call_options(:withdraw) == {:error, :not_supported}
    end

    test "declared keys equal what the call-site check accepts, and pass it nil-valued" do
      for name <- function_names(Schwab),
          {:ok, keys} <- [Schwab.call_options(name)],
          keys != [] do
        assert unique_atoms?(keys)
        refute @probe in keys

        if name in [:child_spec, :start_link] do
          assert keys == Schwab.start_options()
        else
          assert Enum.sort(keys) == Enum.sort(Enum.uniq(Options.allowed(name))), "#{name}"
          assert :ok = Options.check(name, nil_valued(keys)), "#{name}"
          assert {:error, {:unknown_option, @probe}} = Options.check(name, [{@probe, nil}])
        end
      end
    end

    test "functions that take no options answer an empty list" do
      for name <- [
            :provider_name,
            :runtime_id,
            :asset_classes,
            :capabilities,
            :quotes,
            :start_options,
            :call_options,
            :venue_does_not_serve,
            :needs_refresh?,
            :credential_failure?
          ] do
        assert Schwab.call_options(name) == {:ok, []}, "#{name}"
      end
    end

    test "known shapes" do
      assert {:ok, keys} = Schwab.call_options(:get_price)
      assert :credentials in keys and :market_data_url in keys and :name in keys
      refute :environment in keys
      refute :base_url in keys

      assert {:ok, order} = Schwab.call_options(:place_order)
      refute :retry_attempts in order
      assert :account_hash in order

      assert {:ok, feed} = Schwab.call_options(:coverage)
      assert Enum.sort(feed) == Enum.sort([:name, :credentials, :feed])
    end

    test "an unknown name or a non-atom is unknown_function, never ok" do
      assert Schwab.call_options(@no_such_function) ==
               {:error, {:unknown_function, @no_such_function}}

      assert Schwab.call_options("get_price") == {:error, {:unknown_function, "get_price"}}
      assert Schwab.call_options(nil) == {:error, {:unknown_function, nil}}

      assert Schwab.call_options({:get_price, 2}) ==
               {:error, {:unknown_function, {:get_price, 2}}}

      assert Schwab.call_options(42) == {:error, {:unknown_function, 42}}
    end
  end

  describe "call_options/1 on the fake" do
    test "every public function answers ok or not_supported" do
      for name <- function_names(Fake) do
        assert match?({:ok, _}, Fake.call_options(name)) or
                 Fake.call_options(name) == {:error, :not_supported},
               "#{name} answered #{inspect(Fake.call_options(name))}"
      end
    end

    test "an unknown name or a non-atom is unknown_function" do
      assert Fake.call_options(@no_such_function) ==
               {:error, {:unknown_function, @no_such_function}}

      assert Fake.call_options("get_price") == {:error, {:unknown_function, "get_price"}}
    end

    test "inactive endpoints agree with the facade" do
      for name <- function_names(Schwab), inactive?(Schwab, name) do
        assert Fake.call_options(name) == {:error, :not_supported}
      end
    end

    test "the fake's keys include every key the facade declares, and pass its own check" do
      for name <- function_names(Schwab), {:ok, facade_keys} <- [Schwab.call_options(name)] do
        assert {:ok, fake_keys} = Fake.call_options(name), "#{name}"
        assert unique_atoms?(fake_keys)
        assert facade_keys -- fake_keys == [], "#{name}"

        if name not in [:child_spec, :start_link] and fake_keys != [] do
          assert :ok = Options.check_fake(name, nil_valued(fake_keys)), "#{name}"
        end
      end
    end

    test "fake-only keys are declared on the fake alone" do
      assert {:ok, fake} = Fake.call_options(:market_status)
      assert {:ok, real} = Schwab.call_options(:market_status)
      assert :market_status in fake
      refute :market_status in real
    end
  end
end
