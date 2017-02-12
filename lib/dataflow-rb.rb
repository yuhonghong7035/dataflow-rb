# frozen_string_literal: true
require 'schema/inference'
require 'mongoid'
require 'sequel'
require 'msgpack'
require 'parallel'
require 'smarter_csv'
require 'timeliness'
require 'chronic'

require 'dataflow/version'
require 'dataflow/extensions/msgpack'
require 'dataflow/extensions/mongo_driver'

require 'dataflow/event_mixin'
require 'dataflow/logger'
require 'dataflow/properties_mixin'
require 'dataflow/schema_mixin'
require 'dataflow/node'

require 'dataflow/adapters/csv_adapter'
require 'dataflow/adapters/mongo_db_adapter'
require 'dataflow/adapters/sql_adapter'
require 'dataflow/adapters/mysql_adapter'
require 'dataflow/adapters/psql_adapter'
require 'dataflow/adapters/settings'

require 'dataflow/errors/invalid_configuration_error'
require 'dataflow/errors/not_implemented_error'

require 'dataflow/nodes/mixin/add_internal_timestamp'
require 'dataflow/nodes/mixin/rename_dotted_fields'

require 'dataflow/nodes/data_node'
require 'dataflow/nodes/compute_node'
require 'dataflow/nodes/join_node'
require 'dataflow/nodes/map_node'
require 'dataflow/nodes/merge_node'
require 'dataflow/nodes/select_keys_node'
require 'dataflow/nodes/snapshot_node'
require 'dataflow/nodes/sql_query_node'
require 'dataflow/nodes/upsert_node'
require 'dataflow/nodes/export/to_csv_node'
require 'dataflow/nodes/filter/drop_while_node'
require 'dataflow/nodes/filter/newest_node'
require 'dataflow/nodes/filter/where_node'
require 'dataflow/nodes/transformation/to_time_node'

unless defined?(Rails) || Mongoid.configured?
  env = defined?(RSpec) ? 'test' : 'default'
  # setup mongoid for stand-alone usage
  config_file_path = File.join(File.dirname(__FILE__), 'config', 'mongoid.yml')
  Mongoid.load!(config_file_path, env)
end

module Dataflow
  CsvPath = "#{Dir.pwd}/datanodes/csv"

  # helper that tries to find a data node by id and then by name
  def self.data_node(id)
    Dataflow::Nodes::DataNode.find(id)
  rescue Mongoid::Errors::DocumentNotFound
    Dataflow::Nodes::DataNode.find_by(name: id)
  end

  # helper that tries to find a computed node by id and then name
  def self.compute_node(id)
    Dataflow::Nodes::ComputeNode.find(id)
  rescue Mongoid::Errors::DocumentNotFound
    Dataflow::Nodes::ComputeNode.find_by(name: id)
  end
end
