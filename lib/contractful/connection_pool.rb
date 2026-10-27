# frozen_string_literal: true

# Root namespace; this file adds the persistent-connection pool.
module Contractful
  # A small thread-safe pool for reusing started Net::HTTP connections
  # (HTTP keep-alive / persistent connections) across requests.
  #
  # The pool is deliberately simple: there is no limit on the number of
  # simultaneously checked-out connections (a concurrent request that cannot
  # reuse an idle connection simply opens a new one, exactly like a
  # non-persistent request would), but at most `max_idle` connections are
  # retained per pool key once they are returned. Connections are checked out
  # exclusively, so a connection is never shared by two threads at once.
  #
  # Requests opt in per request with `persistent: true`; the pool itself is
  # process-wide and available as `Contractful.connection_pool` (for example
  # call `Contractful.connection_pool.clear!` before forking, or after a
  # network topology change).
  class ConnectionPool
    attr_reader :max_idle

    def initialize(max_idle: 8)
      unless max_idle.is_a?(Integer) && max_idle >= 0
        raise ArgumentError.new(
          ":max_idle must be a non-negative Integer, got #{max_idle.inspect}"
        )
      end

      @max_idle = max_idle
      @mutex = Mutex.new
      @idle = Hash.new { |hash, key| hash[key] = [] }
      @checked_out = Hash.new(0)
    end

    # Check a connection out for `key`. The `builder` block is invoked (outside
    # the pool lock) to create a new connection when no idle one is available.
    #
    # @return the checked-out connection
    #
    def checkout(key, &builder)
      raise ArgumentError.new('builder block is required') unless block_given?

      conn = nil
      @mutex.synchronize { conn = @idle[key].shift }

      if conn && !revive(conn)
        # Idle connection was closed or otherwise unusable; close it
        # before discarding the reference so any half-opened socket is
        # released immediately rather than waiting for GC to finalize
        # the Net::HTTP object.
        shutdown(conn)
        conn = nil
      end

      conn ||= builder.call

      @mutex.synchronize { @checked_out[key] += 1 }
      conn
    end

    # Return a healthy connection to the pool for future reuse. If the pool is
    # already retaining `max_idle` connections for this key, the connection is
    # closed instead.
    #
    # Guard the counter decrement against drift: invalidate() decrements
    # conditionally (only if positive), but checkin() previously decremented
    # unconditionally, which would push the count below zero on a
    # double-checkin or checkin-without-checkout. Both methods now share the
    # same guard.
    def checkin(key, conn)
      keep = checkin_under_lock(key, conn)
      shutdown(conn) unless keep
      nil
    end

    # @api private
    def checkin_under_lock(key, conn)
      @mutex.synchronize do
        return nil unless @checked_out[key].positive?

        @checked_out[key] -= 1
        if @idle[key].size < @max_idle
          @idle[key].push(conn)
          true
        else
          false
        end
      end
    end

    # Discard a connection whose state may no longer be trusted (for example
    # after a network error). The connection is closed and never reused.
    def invalidate(key, conn)
      @mutex.synchronize do
        @checked_out[key] -= 1 if @checked_out[key].positive?
      end
      shutdown(conn)
      nil
    end

    # Close all idle connections and forget them. Connections that are
    # currently checked out cannot be closed here; they will be discarded or
    # reused normally when returned.
    def clear!
      conns = []
      @mutex.synchronize do
        @idle.each_value do |idle_conns| 
          conns.concat(idle_conns)
                                         idle_conns.clear
end
      end
      conns.each { |conn| shutdown(conn) }
      nil
    end

    # @return [Hash] counts of idle and checked-out connections
    def stats
      @mutex.synchronize do
        {
          idle: @idle.values.reduce(0) { |sum, idle_conns| sum + idle_conns.size },
          checked_out: @checked_out.values.reduce(0, :+)
        }
      end
    end

    private

    # Prepare an idle connection for reuse. Returns true if the connection is
    # started (possibly after re-establishing it), false if it is unusable and
    # a new connection should be built instead.
    def revive(conn)
      return true if conn.started?

      conn.start
      true
    rescue StandardError
      false
    end

    def shutdown(conn)
      conn.finish if conn.started?
    rescue StandardError
      nil
    end
  end

  # The process-wide connection pool used by requests created with
  # `persistent: true`.
  #
  # Initialized eagerly at module load. The previous `||=` form was not
  # atomic: two threads racing on first use both observed @connection_pool
  # as nil and each built a fresh pool — one was discarded, and its idle
  # connections' sockets leaked until GC finalized the Net::HTTP objects
  # (Net::HTTP has no finalizer that closes them). The same pattern exists
  # in Contractful::CircuitBreaker.registry and Contractful::Pacer.registry
  # — those modules share the same fix shape.
  @connection_pool = ConnectionPool.new

  def self.connection_pool
    @connection_pool
  end

  def self.connection_pool=(pool)
    @connection_pool = pool
  end
end
