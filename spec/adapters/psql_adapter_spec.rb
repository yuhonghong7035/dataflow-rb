require 'spec_helper'

RSpec.describe Dataflow::Adapters::PsqlAdapter, type: :model do

  before do
    adapter # make sure it's loaded as it will load extensions
  end

  def create_test_dataset
    client.create_table dataset_name do
      primary_key :_id
      Integer :id
      DateTime :updated_at
      Integer :value
      String :value_s
    end
  end

  def create_test_dataset_with_defaults
    client.create_table dataset_with_defaults do
      primary_key :_id
      column(:another_auto_inc_id, 'SERIAL')
      column(:int_with_default_value, 'SMALLINT DEFAULT 0')
      column(:int, 'SMALLINT')
    end
  end

  context 'selection' do
    before do
      create_test_dataset
      dummy_data.each { |d| client[dataset_name.to_sym].insert(d) }
    end

    # describe 'initialization' do
    #   it 'creates a DB if it does not exist' do
    #     byebug
    #     client.run("DROP DATABASE dataflow_test")
    #     adapter
    #
    #     expect(client.run("select count(*) as count from information_schema.tables where table_schema = 'public'").first[:count]).to eq 0
    #     expect(client.run("select count(*) as count from information_schema.tables").first[:count]).to be > 0
    #   end
    # end

    include_examples 'adapter #find',  use_sym: true
    include_examples 'adapter #all',   use_sym: true
    include_examples 'adapter #count', use_sym: true

    it 'returns queries for parallel processing' do
      queries = adapter.ordered_system_id_queries(batch_size: 2)
      expect(queries.count).to eq 3
      expect(queries[0]).to eq({_id: {'>=' => 1, '<'  => 3}})
      expect(queries[1]).to eq({_id: {'>=' => 3, '<'  => 5}})
      expect(queries[2]).to eq({_id: {'>=' => 5, '<=' => 5}})
    end

    it 'support filtering queries for parallel processing' do
      queries = adapter.ordered_system_id_queries(batch_size: 2, where: {id: {'<' => 3}})
      expect(queries.count).to eq 2
      expect(queries[0]).to eq({_id: {'>=' => 1, '<'  => 3}})
      expect(queries[1]).to eq({_id: {'>=' => 3, '<='  => 4}})
    end

    it 'supports the array type' do
      res = adapter.client["SELECT array_agg(id) as id_list FROM test_table WHERE updated_at = '2016-02-02' GROUP BY updated_at"].to_a
      expect(res).to eq([{ id_list: [1,2,3] }])
    end
  end

  context 'write' do
    before do
      create_test_dataset
    end

    include_examples 'adapter #save', use_sym: true
    include_examples 'adapter #delete', use_sym: true

    it 'only writes the given values' do
      create_test_dataset_with_defaults

      adapter_with_defaults.save(records: [{int: 1}])

      expected = [{
        another_auto_inc_id: 1,
        int_with_default_value: 0,
        int: 1
      }]
      expect(adapter_with_defaults.all).to eq(expected)
    end

  end

  describe '.disconnect_clients' do
    it 'supports disconnecting clients' do
      adapter.client.test_connection
      expect(adapter.client.pool.available_connections.count).to eq 1

      Dataflow::Adapters::SqlAdapter.disconnect_clients
      expect(adapter.client.pool.available_connections.count).to eq 0
    end
  end


  describe '#usage' do
    before do
      create_test_dataset
      dummy_data.each { |d| client[dataset_name.to_sym].insert(d) }
    end

    it 'fetches the used memory size' do
      expect(adapter.usage(dataset: dataset_name)[:memory]).to be > 0
    end

    it 'fetches the used storage size' do
      expect(adapter.usage(dataset: dataset_name)[:storage]).to be > 0
    end

    it 'fetches the db indexes' do
      adapter.create_indexes
      expected_indexes = [
        {'key' => ['id']},
        {'key' => ['updated_at']},
        {'key' => ['id', 'updated_at'], 'unique' => true}
      ]
      db_indexes = adapter.retrieve_dataset_indexes(dataset_name)

      expect(db_indexes - expected_indexes).to eq([])
      expect(expected_indexes - db_indexes).to eq([])
    end
  end

  let(:client) { PostgresqlTestClient }
  let(:db_name) { 'dataflow_test' }
  let(:dataset_name) { 'test_table' }
  let(:dataset_with_defaults) { 'test_table_with_defaults' }
  let(:indexes) { [
      { 'key' => 'id' },
      { 'key' => 'updated_at' },
      { 'key' => ['id', 'updated_at'], 'unique' => true }
    ]
  }
  let(:dummy_data) {
    [
      { id: 1, updated_at: '2016-01-01'.to_time, value: 1, value_s: 'aaa'},
      { id: 1, updated_at: '2016-01-15'.to_time, value: 2, value_s: 'AAA'},
      { id: 1, updated_at: '2016-02-02'.to_time, value: 3, value_s: 'bbb'},
      { id: 2, updated_at: '2016-02-02'.to_time, value: 2, value_s: '011'},
      { id: 3, updated_at: '2016-02-02'.to_time, value: 3, value_s: '012'},
    ]
  }
  let(:data_node) {
    Dataflow::Nodes::DataNode.new(db_name: db_name, name: dataset_name, indexes: indexes)
  }
  let(:adapter) {
    Dataflow::Adapters::PsqlAdapter.new(data_node: data_node, adapter_type: 'postgresql')
  }
  let(:data_node_with_defaults) {
    Dataflow::Nodes::DataNode.new(db_name: db_name, name: dataset_with_defaults, indexes: indexes)
  }
  let(:adapter_with_defaults) {
    Dataflow::Adapters::PsqlAdapter.new(data_node: data_node_with_defaults, adapter_type: 'postgresql')
  }
end
