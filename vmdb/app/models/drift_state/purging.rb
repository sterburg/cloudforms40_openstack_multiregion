module DriftState::Purging
  extend ActiveSupport::Concern

  module ClassMethods
    def purge_mode_and_value
      value = VMDB::Config.new("vmdb").config.fetch_path(:drift_states, :history, :keep_drift_states)
      mode  = (value.nil? || value.number_with_method?) ? :date : :remaining
      value = (value || 6.months).to_i_with_method.seconds.ago.utc if mode == :date
      return mode, value
    end

    def purge_window_size
      VMDB::Config.new("vmdb").config.fetch_path(:drift_states, :history, :purge_window_size) || 10000
    end

    def purge_timer
      purge_queue(*purge_mode_and_value)
    end

    def purge_queue(mode, value)
      MiqQueue.put_or_update(
        :class_name  => name,
        :method_name => "purge",
      ) { |_msg, item| item.merge(:args => [mode, value]) }
    end

    def purge_count(mode, value)
      send("purge_count_by_#{mode}", value)
    end

    def purge(mode, value, window = nil, &block)
      send("purge_by_#{mode}", value, window, &block)
    end

    private

    #
    # By Remaining
    #

    def purge_count_by_remaining(remaining)
      purge_counts_for_remaining(remaining).values.sum
    end

    def purge_by_remaining(remaining, window = nil, &block)
      _log.info("Purging drift states older than last #{remaining} results...")

      window ||= purge_window_size
      total = 0
      purge_ids_for_remaining(remaining).each do |resource, id|
        resource_type, resource_id = *resource
        conditions = [{:resource_type => resource_type, :resource_id => resource_id}, arel_table[:id].lt(id)]
        total += purge_in_batches(conditions, window, total, &block)
      end

      _log.info("Purging drift states older than last #{remaining} results...Complete - Deleted #{total} records")
    end

    def purge_counts_for_remaining(remaining)
      purge_ids_for_remaining(remaining).each_with_object({}) do |(resource, id), h|
        resource_type, resource_id = *resource
        h[resource] = where(:resource_type => resource_type, :resource_id => resource_id).where(arel_table[:id].lt(id)).count
      end
    end

    def purge_ids_for_remaining(remaining)
      # TODO: This can probably be done in a single query using group-bys or subqueries
      select("DISTINCT resource_type, resource_id").each_with_object({}) do |s, h|
        results = select(:id).where(:resource_type => s.resource_type, :resource_id => s.resource_id).order("id DESC").limit(remaining + 1)
        h[[s.resource_type, s.resource_id]] = results[-2].id if results.length == remaining + 1
      end
    end

    #
    # By Date
    #

    def purge_count_by_date(older_than)
      conditions = arel_table[:timestamp].lt(older_than)
      where(conditions).count
    end

    def purge_by_date(older_than, window = nil, &block)
      _log.info("Purging drift states older than [#{older_than}]...")

      window ||= purge_window_size
      conditions = arel_table[:timestamp].lt(older_than)
      total = purge_in_batches(conditions, window, &block)

      _log.info("Purging drift states older than [#{older_than}]...Complete - Deleted #{total} records")
    end

    #
    # Common methods
    #

    def purge_in_batches(conditions, window, total = 0)
      query = select(:id).limit(window)
      [conditions].flatten.each { |c| query = query.where(c) }

      until (batch = query.dup.to_a).empty?
        ids = batch.collect(&:id)

        _log.info("Purging #{ids.length} drift states.")
        count  = delete_all(:id => ids)
        total += count

        purge_associated_records(ids) if self.respond_to?(:purge_associated_records)

        yield(count, total) if block_given?
      end
      total
    end
  end
end