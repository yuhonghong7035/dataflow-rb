# frozen_string_literal: true
module Dataflow
  module Nodes
    # Represents a compution. May stores its output in a separate data node.
    # It depends on other data nodes to compute its own data.
    class ComputeNode
      include Mongoid::Document
      include Dataflow::Node
      include Dataflow::PropertiesMixin
      include Dataflow::EventMixin
      include Dataflow::SchemaMixin

      event :computing_started    # handler(node)
      event :computing_progressed # handler(node, pct_complete:)
      event :computing_finished   # handler(node, state)

      delegate :find, :all, :all_paginated, :count, :ordered_system_id_queries,
               :db_backend, :db_name, :use_symbols?,
               :read_dataset_name, :write_dataset_name,
               to: :data_node

      #############################################
      # Dependencies definition
      #############################################
      class << self
        def dependency_opts
          @dependency_opts || {}
        end

        def data_node_opts
          @data_node_opts || {}
        end

        # DSL to be used while making computeqd nodes. It supports enforcing validations
        # by checking whether there is exactly, at_least (min) or at_most (max)
        # a given number of dependencies. Usage:
        # class MyComputeNode < ComputeNode
        #   ensure_dependencies exactly: 1 # could be e.g.: min: 3, or max: 5
        # end
        def ensure_dependencies(opts)
          raise Dataflow::Errors::InvalidConfigurationError, "ensure_dependencies must be given a hash. Received: #{opts.class}" unless opts.is_a?(Hash)
          valid_keys = %i(exactly min max).freeze
          has_attributes = (valid_keys - opts.keys).count < valid_keys.count
          raise Dataflow::Errors::InvalidConfigurationError, "ensure_dependencies must have at least one of 'min', 'max' or 'exactly' attributes set. Given: #{opts.keys}" unless has_attributes

          add_property(:dependency_ids, opts)
          @dependency_opts = opts
        end

        # DSL to ensure that a data node must be set before a computed node
        # can be recomputed (as it will presumably use it to store data).
        def ensure_data_node_exists
          @data_node_opts = { ensure_exists: true }
        end
      end

      # The node name
      field :name,                        type: String

      # The execution model:
      field :execution_model,             type: Symbol, default: :local

      # For remote computation only:
      # Controls on which queue this execution wi;l be routed
      field :execution_queue,             type: String, default: 'dataflow.ruby'

      # Unique ID of the current execution
      field :execution_uuid,              type: BSON::ObjectId

      # The data node to which we will write the computation output
      field :data_node_id,                type: BSON::ObjectId

      # Whether to clear the data from the data node before computing
      field :clear_data_on_compute,       type: Boolean, default: true

      # The dependencies this node requires for computing.
      field :dependency_ids,              type: Array, default: []

      # Represents the maximum record count that should be used
      # per process during computation.
      field :limit_per_process,           type: Integer, default: 0

      # Maximum number of processes to use in parallel. Use 1 per core when 0.
      field :max_parallel_processes,      type: Integer, default: 0

      # Use automatic recomputing interval. In seconds.
      field :recompute_interval,          type: Integer, default: 0

      # Used as a computing lock. Will be set to 'computing'
      # if currently computing or nil otherwise.
      field :computing_state,             type: String,   editable: false

      # When has the computing started.
      field :computing_started_at,        type: Time,     editable: false

      # Indicates the last time a successful computation has started.
      field :last_compute_starting_time,  type: Time,     editable: false

      # The last time an heartbeat was received.
      # Useful to detect stale computation that need to be reaped.
      field :last_heartbeat_time,         type: Time,     editable: false

      # Necessary fields:
      validates_presence_of :name

      # Before create: run default initializations
      before_create :set_defaults

      # Sets the default parameters before creating the object.
      def set_defaults
        # support setting the fields with a Document rather
        # than an ObjectId. Handle the transformations here:
        if data_node_id.present?
          self.data_node_id = data_node_id._id unless data_node_id.is_a?(BSON::ObjectId)

          # the data node use_double_buffering setting
          # must match clear_data_on_compute:
          if data_node.use_double_buffering != clear_data_on_compute
            data_node.use_double_buffering = clear_data_on_compute
            data_node.save
          end
        end

        # Again support having an ObjectId or a document.
        self.dependency_ids = dependency_ids.map { |dep|
          next dep if dep.is_a? BSON::ObjectId
          dep._id
        }

        # Update the data node schema with the required schema
        # for this computed node.
        data_node&.update_schema(required_schema)
      end

      # Fetch the data node if it is set
      def data_node
        @data_node ||= Dataflow::Nodes::DataNode.find(data_node_id) if data_node_id.present?
      end

      # Override the relation because self.dependencies is not ordered.
      def dependencies(reload: false)
        return @dependencies if @dependencies.present? && !reload
        @dependencies = dependency_ids.map do |x|
          Dataflow::Node.find(x)
        end
      end

      # retrieve the whole dependency tree
      def all_dependencies
        (super + dependencies + dependencies.flat_map(&:all_dependencies)).uniq
      end

      # Finds out how many "layers" how dependencies this node relies on.
      # This is useful to sort nodes by dependency levels:
      # we're sure that a node of dependency_level 0 comes before than a node
      # of dependency level 1, which comes before a level 2 and etc.
      # On the basic case, the dependency_level of a compute node is equal
      # to the maximum dependency level of any of it's dependencies + 1.
      def dependency_level(current_level = 0)
        # find out the max dependency based on fields that may be node ids
        max_lvl = super(current_level)
        # find out the max deps based on the direct compute dependencies
        deps_lvl = dependencies.map { |x| x.dependency_level(current_level) + 1 }.max.to_i

        [max_lvl, deps_lvl].max
      end

      # Returns false if any of our dependencies has
      # been updated after our last update.
      # We define a computed node's last update as the time it started its
      # last successful update (instead of the time it completed it, has
      # dependencies may have changed in the mean time).
      # @return [Boolean]
      def updated?
        return false if updated_at.blank?

        dependencies.each do |dependency|
          return false unless dependency.updated?
          return false if dependency.updated_at > updated_at
        end
        true
      end

      # Logs out the dependencies tree update time and whether
      # it should or not be updated. Useful to understand
      # why a given nodes had to be recomputed.
      def explain_update(depth: 0, verbose: false)
        if depth == 0 || !updated? || verbose
          logger.log("#{'>' * (depth + 1)} #{name} [COMPUTE] | #{updated? ? 'UPDATED' : 'OLD'} = #{updated_at}")
        end

        return if updated? && !verbose

        dependencies.each do |dependency|
          dependency.explain_update(depth: depth + 1, verbose: verbose)
        end
        true
      end

      # Keep a uniform interface with a DataNode.
      def updated_at
        last_compute_starting_time
      end

      def updated_at=(val)
        self.last_compute_starting_time = val
      end

      # Checks whether an automatic recomputing is needed.
      # @return [Boolean]
      def needs_automatic_recomputing?
        interval = recompute_interval.to_i
        return false if interval <= 0
        return false if updated?
        return false if locked_for_computing?
        return true if updated_at.blank?

        updated_at + interval.seconds < Time.now
      end

      # Update the dependencies that need to be updated
      # and then compute its own data.
      # @param force_recompute [Boolean] if true, computes
      #        even if the node is already up to date.
      def recompute(depth: 0, force_recompute: false)
        send_heartbeat
        logger.log("#{'>' * (depth + 1)} #{name} started recomputing...")
        start_time = Time.now

        parallel_each(dependencies) do |dependency|
          logger.log("#{'>' * (depth + 1)} #{name} checking deps: #{dependency.name}...")
          if !dependency.updated? || force_recompute
            dependency.recompute(depth: depth + 1, force_recompute: force_recompute)
          end
          send_heartbeat
        end

        # Dependencies data may have changed in a child process.
        # Reload to make sure we have the latest metadata.
        logger.log("#{'>' * (depth + 1)} #{name} reloading dependencies...")
        dependencies(reload: true)

        compute(depth: depth, force_compute: force_recompute)
        logger.log("#{'>' * (depth + 1)} #{name} took #{Time.now - start_time} seconds to recompute.")

        true
      end

      # Compute this node's data if not already updated.
      # Acquires a computing lock before computing.
      # In the eventuality that the lock is already acquired, it awaits
      # until it finishes or times out.
      # @param force_compute [Boolean] if true, computes
      #        even if the node is already up to date.
      def compute(depth: 0, force_compute: false, source: nil)
        has_compute_lock = false
        validate!

        if updated? && !force_compute
          logger.log("#{'>' * (depth + 1)} #{name} is up-to-date.")
          return
        end

        has_compute_lock = acquire_computing_lock!
        if has_compute_lock
          logger.log("#{'>' * (depth + 1)} #{name} started computing.")
          on_computing_started
          start_time = Time.now

          if data_node.present? && clear_data_on_compute != data_node.use_double_buffering
            # make sure the data node has a compatible settings
            data_node.use_double_buffering = clear_data_on_compute
            data_node.save
          end

          send_heartbeat
          pre_compute(force_compute: force_compute)

          # update this node's schema with the necessary fields
          data_node&.update_schema(required_schema)

          if clear_data_on_compute
            # Pre-compute, we recreate the table, the unique indexes
            data_node&.recreate_dataset(dataset_type: :write)
            data_node&.create_unique_indexes(dataset_type: :write)
          end

          send_heartbeat
          Executor.execute(self)

          if clear_data_on_compute
            # Post-compute, delay creating other indexes for insert speed
            data_node&.create_non_unique_indexes(dataset_type: :write)
            # swap read/write datasets
            data_node&.swap_read_write_datasets!
          end

          set_last_compute_starting_time(start_time)
          duration = Time.now - start_time
          logger.log("#{'>' * (depth + 1)} #{name} took #{duration} seconds to compute.")
          on_computing_finished(state: 'computed')
          true
        else
          logger.log("#{'>' * (depth + 1)} [IS AWAITING] #{name}.")
          await_computing!
          logger.log("#{'>' * (depth + 1)} [IS DONE AWAITING] #{name}.")
        end

      rescue Errors::RemoteExecutionError => e
        on_computing_finished(state: 'error', error: e) if has_compute_lock
        logger.error(error: e, custom_message: "#{name} failed computing remotely.")
      rescue StandardError => e
        on_computing_finished(state: 'error', error: e) if has_compute_lock
        logger.error(error: e, custom_message: "#{name} failed computing.")
        raise
      ensure
        release_computing_lock! if has_compute_lock
        true
      end

      # Check wethere this node can or not compute.
      # Errors are added to the active model errors.
      # @return [Boolean] true has no errors and can be computed.
      def valid_for_computation?
        # Perform additional checks: also add errors to "self.errors"
        opts = self.class.dependency_opts
        ensure_exact_dependencies(count: opts[:exactly]) if opts.key?(:exactly)
        ensure_at_most_dependencies(count: opts[:max])   if opts.key?(:max)
        ensure_at_least_dependencies(count: opts[:min])  if opts.key?(:min)
        ensure_no_cyclic_dependencies
        ensure_keys_are_set
        ensure_data_node_exists if self.class.data_node_opts[:ensure_exists]

        errors.count == 0
      end

      # Check this node's locking status.
      # @return [Boolean] Whtere this node is locked or not.
      def locked_for_computing?
        computing_state == 'computing'
      end

      # Force the release of this node's computing lock.
      # Do not use unless there is a problem with the lock.
      def force_computing_lock_release!
        release_computing_lock!
      end

      def execution_valid?(uuid)
        execution_uuid.to_s == uuid.to_s
      end

      # Keep a compatible interface with the data node
      def schema
        required_schema
      end

      # Interface to execute this node locally
      def execute_local_computation
        compute_impl
      end

      # Interface to execute a part (batch) of this node locally.
      # This method is called when the framework needs to execute a batch on a worker.
      # Override when needed, to execute a batch depending on the params.
      # If you override, you may want to override the make_batch_params as well.
      def execute_local_batch_computation(batch_params)
        records = dependencies.first.all(where: batch_params)
        compute_batch(records: records)
      end

      # Interface used to retrieve the params for scheduled batchs. Override when needed.
      # The default implemention is to make queries that would
      # ensure the full processing of the first dependency's records.
      # @return [Array] of params that are passed to scheduled batches.
      def make_batch_params
        make_batch_queries(node: dependencies.first)
      end

      private

      # Default compute implementation:
      # - recreate the table
      # - compute the records
      # - save them to the DB
      # (the process may be overwritten on a per-node basis if needed)
      # Override if you need to have a completely custom compute implementation
      def compute_impl
        process_parallel(node: dependencies.first)
      end

      # This is an interface only.
      # Override when you can implement a computation in terms of
      # the records of the first dependent node.
      # @param records [Array] a batch of records from the first dependency
      # @return [Array] an array of results that are to be pushed to the data node (if set).
      def compute_batch(records:)
        []
      end

      def process_parallel(node:)
        queries = make_batch_queries(node: node)
        return if queries.blank?

        queries_count = queries.count
        parallel_each(queries.each_with_index) do |query, idx|
          send_heartbeat

          progress = (idx / queries_count.to_f * 100).ceil
          on_computing_progressed(pct_complete: progress)
          logger.log("Executing #{name} [Batch #{idx}/#{queries_count}]")

          records = node.all(where: query)

          new_records = if block_given?
                          yield records
                        else
                          compute_batch(records: records)
                        end

          data_node&.add(records: new_records)
        end
      end

      # Makes queries that support traversing the node's records in parallel without overlap.
      def make_batch_queries(node:, where: {})
        return [] if node.blank?
        record_count = node.count
        return [] if record_count == 0

        equal_split_per_process = (record_count / Parallel.processor_count.to_f).ceil
        count_per_process = equal_split_per_process
        limit = limit_per_process.to_i
        count_per_process = [limit, equal_split_per_process].min if limit > 0

        node.ordered_system_id_queries(batch_size: count_per_process, where: where)
      end

      def acquire_computing_lock!
        # make sure that any pending changes are saved.
        save

        compute_state = {
          computing_state: 'computing',
          computing_started_at: Time.now,
          execution_uuid: BSON::ObjectId.new
        }
        find_query = { _id: _id, computing_state: { '$ne' => 'computing' } }
        update_query = { '$set' => compute_state }

        # send a query directly to avoid mongoid's caching layers
        res = Dataflow::Nodes::ComputeNode.where(find_query).find_one_and_update(update_query)

        # reload the model data after the query above
        reload

        # the query is atomic so if res != nil, we acquired the lock
        !res.nil?
      end

      def release_computing_lock!
        # make sure that any pending changes are saved.
        save

        find_query = { _id: _id }
        update_query = { '$set' => { computing_state: nil, computing_started_at: nil, execution_uuid: nil } }

        # send a query directly to avoid mongoid's caching layers
        Dataflow::Nodes::ComputeNode.where(find_query).find_one_and_update(update_query)

        # reload the model data after the query above
        reload
      end

      def await_computing!
        max_wait_time = 15.minutes
        while Time.now < last_heartbeat_time + max_wait_time
          sleep 5
          # reloads with the data stored on mongodb:
          # something maybe have been changed by another process.
          reload
          return unless locked_for_computing?
        end

        raise StandardError, "Awaiting computing on #{name} reached timeout."
      end

      # Interface only. Re-implement for node-specific behavior before computing
      def pre_compute(force_compute:); end

      # Override to define a required schema.
      def required_schema
        data_node&.schema
      end

      def send_heartbeat
        update_query = { '$set' => { last_heartbeat_time: Time.now } }
        Dataflow::Nodes::ComputeNode.where(_id: _id)
                                    .find_one_and_update(update_query)
      end

      def set_last_compute_starting_time(time)
        # this is just to avoid the reload.
        # But this change will not be propagated across processes
        self.last_compute_starting_time = time
        # update directly on the DB
        update_query = { '$set' => { last_compute_starting_time: time } }
        Dataflow::Nodes::ComputeNode.where(_id: _id)
                                    .find_one_and_update(update_query)
      end

      ##############################
      # Dependency validations
      ##############################

      def ensure_no_cyclic_dependencies
        node_map = Dataflow::Nodes::ComputeNode.all.map { |n| [n._id, n] }.to_h

        dep_ids = (dependency_ids || [])
        dep_ids.each do |dependency_id|
          next unless has_dependency_in_hierarchy?(node_map[dependency_id], dependency_id, node_map)
          error_msg = "Dependency to node #{dependency_id} ('#{node_map[dependency_id].name}') is cylic."
          errors.add(:dependency_ids, error_msg)
        end
      end

      def has_dependency_in_hierarchy?(node, dependency_id, node_map)
        return false if node.blank?
        # if we're reach a node that has no more deps, then we did not find
        # the given dependency_id in the hierarchy
        return true if (node.dependency_ids || []).include?(dependency_id)
        (node.dependency_ids || []).any? do |dep_id|
          has_dependency_in_hierarchy?(node_map[dep_id], dependency_id, node_map)
        end
      end

      def ensure_no_cyclic_dependencies!
        ensure_no_cyclic_dependencies
        raise_dependendy_errors_if_needed!
      end

      def ensure_exact_dependencies(count:)
        # we need to use .size, not .count
        # for the mongo relation to work as expected
        current_count = (dependency_ids || []).size
        return if current_count == count

        error_msg = "Expecting exactly #{count} dependencies. Has #{current_count} dependencies."
        errors.add(:dependency_ids, error_msg)
      end

      def ensure_at_least_dependencies(count:)
        # we need to use .size, not .count
        # for the mongo relation to work as expected
        current_count = (dependency_ids || []).size
        return if current_count >= count

        error_msg = "Expecting at least #{count} dependencies. Has #{current_count} dependencies."
        errors.add(:dependency_ids, error_msg)
      end

      def ensure_at_most_dependencies(count:)
        # we need to use .size, not .count
        # for the mongo relation to work as expected
        current_count = (dependency_ids || []).size
        return if current_count <= count

        error_msg = "Expecting at most #{count} dependencies. Has #{current_count} dependencies."
        errors.add(:dependency_ids, error_msg)
      end

      def ensure_keys_are_set
        required_keys = self.class.properties.select { |_k, opts| opts[:required_for_computing] }
        required_keys.each do |key, opts|
          errors.add(key, "#{self.class}.#{key} must be set for computing.") if self[key].nil?
          if opts[:values].is_a?(Array)
            # make sure the key's value is one of the possible values
            errors.add(key, "#{self.class}.#{key} must be set to one of #{opts[:values].join(', ')}. Given: #{self[key]}") unless opts[:values].include?(self[key])
          end
        end
      end

      def ensure_data_node_exists
        if data_node_id.blank?
          error_msg = 'Expecting a data node to be set.'
          errors.add(:data_node_id, error_msg)
          return
        end

        # the data node id is present. Check if it found
        Dataflow::Nodes::DataNode.find(data_node.id)
      rescue Mongoid::Errors::DocumentNotFound
        # it was not found:
        error_msg = "No data node was found for Id: '#{data_node_id}'."
        errors.add(:data_node_id, error_msg)
      end

      def parallel_each(itr)
        # before fork: always disconnect currently used connections.
        disconnect_db_clients

        # set to true to debug code in the iteration
        is_debugging_impl = ENV['DEBUG_DATAFLOW']
        opts = if is_debugging_impl
                 # this will turn of the parallel processing
                 { in_processes: 0 }
               elsif max_parallel_processes > 0
                 { in_processes: max_parallel_processes }
               else
                 {}
               end

        Parallel.each(itr, opts) do |*args|
          yield(*args)
          disconnect_db_clients
        end
      end

      def disconnect_db_clients
        Dataflow::Adapters::SqlAdapter.disconnect_clients
        Dataflow::Adapters::MongoDbAdapter.disconnect_clients
        Mongoid.disconnect_clients
      end

      def logger
        @logger ||= Dataflow::Logger.new(prefix: 'Dataflow')
      end
    end # class ComputeNode
  end # module Nodes
end # module Dataflow
