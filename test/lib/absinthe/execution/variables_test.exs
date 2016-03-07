defmodule Absinthe.Execution.VariablesTest.Schema do
  use Absinthe.Schema

  input_object :contact_input do
    field :email, non_null(:string)
    field :address, non_null(:string), deprecate: "no longer used"
  end

  query do
    field :contacts, :string do
      arg :contacts, non_null(list_of(non_null(:contact_input)))

      resolve fn
        %{contacts: _}, _ ->
          {:ok, "we did it"}
        args, _ ->
          {:error, "got: #{inspect args}"}
      end
    end

    field :user, :string do
      arg :contact, non_null(:contact_input)

      resolve fn
        %{contact: %{email: email}}, _ ->
          {:ok, email}
        args, _ ->
          {:error, "got: #{inspect args}"}
      end
    end
  end
end

defmodule Absinthe.Execution.VariablesTest do
  use ExSpec, async: true

  alias Absinthe.Execution

  def parse(query_document, provided \\ %{}) do
    parse(query_document, Things, provided)
  end
  def parse(query_document, schema, provided) do
    # Parse
    {:ok, document} = Absinthe.parse(query_document)
    # Prepare execution context
    {_, execution} = %Execution{schema: schema, document: document}
    |> Execution.prepare(%{variables: provided})

    Execution.Variables.build(execution)
  end

  describe "a required variable" do
    @id_required """
      query FetchThingQuery($id: String!) {
        thing(id: $id) {
          name
        }
      }
      """
    context "when provided" do

      it "returns a value" do
        provided = %{"id" => "foo"}
        assert {:ok, %{variables: %Absinthe.Execution.Variables{
          raw: %{"id" => "foo"},
          processed: %{"id" => %Absinthe.Execution.Variable{value: "foo"}}
        }}} = @id_required |> parse(provided)
      end
    end

    context "when not provided" do
      it "returns an error" do
        assert {:error, %{variables: %Absinthe.Execution.Variables{raw: %{}}, errors: errors}} = @id_required |> parse
        assert [%{locations: [%{column: 0, line: 1}], message: "Variable `id' (String): Not provided"}] == errors
        assert {:ok, %{errors: [%{locations: [%{column: 0, line: 1}], message: "Variable `id' (String): Not provided"}]}} = Absinthe.run(@id_required, Things)
      end
    end
  end

  describe "scalar variable" do
    it "returns an error if it does not parse" do
      doc = """
      query ScalarError($item:Int){foo(bar:$item)}
      """
      assert {:error, %{errors: errors}} = doc |> parse(%{"item" => "asdf"})
      assert [%{locations: [%{column: 0, line: 1}], message: "Variable `item' (Int): Invalid value provided"}] == errors
    end
  end

  describe "a defaulted variable" do
    @default "foo"
    @with_default """
    query FetchThingQuery($id: String = "#{@default}") {
      thing(id: $id) {
        name
      }
    }
    """
    it "when provided" do
      provided = %{"id" => "bar"}
      assert {:ok, %{variables: %Absinthe.Execution.Variables{
        raw: %{"id" => "bar"},
        processed: %{"id" => %Absinthe.Execution.Variable{value: "bar"}}
      }}} = @with_default |> parse(provided)
    end

    it "when not provided" do
      assert {:ok, %{variables: %Absinthe.Execution.Variables{
        raw: %{},
        processed: %{"id" => %Absinthe.Execution.Variable{value: @default, type_stack: ["String"]}}
      }}} = @with_default |> parse
    end
  end

  describe "list variables" do
    it "should work in a basic case" do
      doc = """
      query FindContacts($contacts:[String]) {contacts(contacts:$contacts)}
      """
      assert {:ok, %{variables: %Absinthe.Execution.Variables{
        processed: %{"contacts" => %Absinthe.Execution.Variable{value: value, type_stack: type}}
      }}} = doc |> parse(%{"contacts" => ["ben", "bob"]})
      assert value == ["ben", "bob"]
      assert type == ["String", Absinthe.Type.List]
    end

    it "it strips null values" do
      doc = """
      query FindContacts($contacts:[String]) {contacts(contacts:$contacts)}
      """
      assert {:ok, %{variables: %Absinthe.Execution.Variables{
        processed: %{"contacts" => %Absinthe.Execution.Variable{value: value, type_stack: _}}
      }}} = doc |> parse(%{"contacts" => ["ben", nil, nil, "bob", nil]})
      assert ["ben", "bob"] == value
    end

    it "returns an error if you give it a null value and it's non null" do
      doc = """
      query FindContacts($contacts:[String!]) {contacts(contacts:$contacts)}
      """
      assert {:error, %{errors: errors}} = doc |> parse(%{"contacts" => ["ben", nil, nil, "bob", nil]})
      assert errors != []
    end

    it "works when it's a list of input objects" do
      doc = """
      query FindContacts($contacts:[ContactInput]) {contacts(contacts:$contacts)}
      """
      assert {:ok, %{variables: %Absinthe.Execution.Variables{
        processed: %{"contacts" => %Absinthe.Execution.Variable{value: value, type_stack: type}}
      }}} = doc |> parse(__MODULE__.Schema, %{"contacts" => [%{"email" => "ben"}, %{"email" => "bob"}]})
      assert value == [%{email: "ben"}, %{email: "bob"}]
      assert type == ["ContactInput", Absinthe.Type.List]
    end
  end

  describe "input object variables" do
    it "should work in a basic case" do
      doc = """
      query FindContact($contact:ContactInput) {contact(contact:$contact)}
      """
      assert {:ok, %{errors: errors, variables: %Absinthe.Execution.Variables{
        raw: %{},
        processed: %{"contact" => %Absinthe.Execution.Variable{value: value, type_stack: type}}
      }}} = doc |> parse(__MODULE__.Schema, %{"contact" => %{"email" => "ben"}})
      assert errors == []
      assert %{email: "ben"} == value
      assert ["ContactInput"] == type
    end

    it "should return an error if an inner scalar doesn't parse" do
      doc = """
      query FindContact($contact:ContactInput) {contact(contact:$contact)}
      """
      assert {:error, %{errors: errors}} = doc |> parse(__MODULE__.Schema, %{"contact" => %{"email" => [1,2,3]}})
      assert [%{locations: [%{column: 0, line: 1}], message: "Variable `contact.email' (String): Invalid value provided"}] == errors
    end

    it "should return an error when a required field is explicitly set to nil" do
      doc = """
      query FindContact($contact:ContactInput) {contact(contact:$contact)}
      """
      assert {:error, %{errors: errors}} = doc |> parse(__MODULE__.Schema, %{"contact" => %{"email" => nil}})
      assert [%{locations: [%{column: 0, line: 1}], message: "Variable `contact.email' (String): Not provided"}] == errors
    end

    it "tracks extra values" do
      doc = """
      query FindContact($contact:ContactInput) {user(contact:$contact)}
      """
      assert {:ok, %{errors: errors, data: data}} = doc |> Absinthe.run(__MODULE__.Schema, variables: %{"contact" => %{"email" => "bob", "extra" => "thing"}})
      assert [%{locations: [%{column: 0, line: 1}], message: "Variable `contact.extra': Not present in schema"}] == errors
      assert %{"user" => "bob"} == data
    end

    it "returns an error for inner deprecated fields" do
      doc = """
      query FindContact($contact:ContactInput) {contact(contact:$contact)}
      """
      assert {:ok, %{errors: errors, variables: %Absinthe.Execution.Variables{
        processed: %{"contact" => %Absinthe.Execution.Variable{value: value}}}}} = doc |> parse(__MODULE__.Schema, %{"contact" => %{"email" => "bob", "address" => "boo"}})
      assert %{email: "bob", address: "boo"} == value
      assert [%{locations: [%{column: 0, line: 1}], message: "Variable `contact.address' (String): Deprecated; no longer used"}] == errors
    end
  end

  describe "nested errors" do
    it "should return a useful error message for deeply nested errors" do
      doc = """
      query FindContact($contacts:[ContactInput]) {
        contacts(contacts:$contacts)
      }
      """
      assert {:ok, %{errors: errors}} = doc |> Absinthe.run(__MODULE__.Schema, variables: %{"contacts" => [%{"email" => nil}]})
      assert [%{locations: [%{column: 0, line: 1}], message: "Variable `contacts[].email' (String): Not provided"}] == errors
    end
  end

end
