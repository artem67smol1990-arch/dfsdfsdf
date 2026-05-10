# frozen_string_literal: true

module WebConsole
  # A session lets you persist an +Evaluator+ instance in memory associated
  # with multiple bindings.
  #
  # Each newly created session is persisted into memory and you can find it
  # later by its +id+.
  #
  # A session may be associated with multiple bindings. This is used by the
  # error pages only, as currently, this is the only client that needs to do
  # that.
  class Session
    # In-memory store of recent sessions, keyed by id. Bounded by
    # +max_sessions+ to prevent unbounded growth in long-running development
    # processes: every captured session retains stack-frame +Binding+ objects
    # which pin the entire lexical scope (including +Rails.application.routes+
    # via the controller +self+), so leaving the store unbounded leaks a full
    # route tree generation per dev-mode exception.
    cattr_reader :inmemory_storage, default: {}

    # Maximum number of concurrently retained sessions. When this many
    # sessions are stored, inserting a new one evicts the oldest by
    # insertion order (Ruby Hashes preserve insertion order).
    #
    # Set to a positive Integer to bound retention, or +nil+ to disable
    # eviction entirely (legacy behaviour, leaks indefinitely).
    cattr_accessor :max_sessions, default: 5

    INMEMORY_STORAGE_MUTEX = Mutex.new
    private_constant :INMEMORY_STORAGE_MUTEX

    class << self
      # Finds a persisted session in memory by its id.
      #
      # Returns a persisted session if found in memory.
      # Raises NotFound error unless found in memory.
      def find(id)
        INMEMORY_STORAGE_MUTEX.synchronize { inmemory_storage[id] }
      end

      # Create a Session from an binding or exception in a storage.
      #
      # The storage is expected to respond to #[]. The binding is expected in
      # :__web_console_binding and the exception in :__web_console_exception.
      #
      # Can return nil, if no binding or exception have been preserved in the
      # storage.
      def from(storage)
        if exc = storage[:__web_console_exception]
          new(ExceptionMapper.follow(exc))
        elsif binding = storage[:__web_console_binding]
          new([[binding]])
        end
      end
    end

    # An unique identifier for every REPL.
    attr_reader :id

    def initialize(exception_mappers)
      @id = SecureRandom.hex(16)

      @exception_mappers = exception_mappers
      @evaluator         = Evaluator.new(@current_binding = exception_mappers.first.first)

      store_into_memory
    end

    # Evaluate +input+ on the current Evaluator associated binding.
    #
    # Returns a string of the Evaluator output.
    def eval(input)
      @evaluator.eval(input)
    end

    # Switches the current binding to the one at specified +index+.
    #
    # Returns nothing.
    def switch_binding_to(index, exception_object_id)
      bindings = ExceptionMapper.find_binding(@exception_mappers, exception_object_id)

      @evaluator = Evaluator.new(@current_binding = bindings[index.to_i])
    end

    # Returns context of the current binding
    def context(objpath)
      Context.new(@current_binding).extract(objpath)
    end

    private

      def store_into_memory
        INMEMORY_STORAGE_MUTEX.synchronize do
          inmemory_storage[id] = self
          evict_oldest_sessions
        end
      end

      def evict_oldest_sessions
        limit = self.class.max_sessions
        return unless limit && limit > 0

        excess = inmemory_storage.size - limit
        excess.times { inmemory_storage.shift } if excess > 0
      end
  end
end
