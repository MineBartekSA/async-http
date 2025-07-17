require "http/client"

module AsyncHttp
  VERSION = "0.1.0"

  class ::HTTP::Client
    @mutex = Mutex.new

    def_around_exec do |request|
      @mutex.lock
      yield request
    ensure
      @mutex.unlock
    end
  end

  class Client
    @connections : Array(HTTP::Client)
    @mutex = Mutex.new
    @release : Channel(Nil)

    getter uri : URI

    @dynamic : Bool
    @keep : UInt32
    @capacity : UInt32

    @clean_after : UInt32
    @closing = false
    @close_mutex = Mutex.new

    macro timeout(name)
      @{{ name.id }}_timeout : Float64?
      {% for add, type in {to_f: Number, total_seconds: Time::Span} %}
        def {{ name.id }}_timeout=({{ name.id }}_timeout : {{ type.id }})
          @{{ name.id }}_timeout = {{ name.id }}_timeout.{{ add.id }}
          @mutex.synchronize do
            @connections.each { |c| c.{{ name.id }}_timeout = @{{ name.id }}_timeout.not_nil! }
          end
        end
      {% end %}
    end

    getter? compress : Bool = true
    def compress=(@compress)
      @mutex.synchronize do
        @connections.each { |c| c.compress = @compress }
      end
    end

    timeout connect
    timeout read
    timeout write

    private def new_client : HTTP::Client
      new = HTTP::Client.new @uri
      new.compress = @compress
      @connect_timeout.try { |t| new.connect_timeout = t }
      @read_timeout.try { |t| new.read_timeout = t }
      @write_timeout.try { |t| new.write_timeout = t }
      new
    end

    def initialize(@uri, @dynamic = false, @keep = 2, capacity : UInt32? = nil, @clean_after : UInt32 = 5)
      @capacity = (@dynamic ? capacity : @keep) || (@dynamic ? @keep*2 : @keep)
      @connections = Array(HTTP::Client).new
      @release = Channel(Nil).new @capacity.to_i
      @keep.times do
        @connections << new_client
      end
    end

    private def aquire_client
      @release.send nil
      @mutex.synchronize do
        if @dynamic
          if @connections.size == 0
            @connections << new_client
            spawn end_overkeep
          end
        end
        @connections.pop
      end
    end

    private def release_client(client)
      @mutex.synchronize do
        @release.receive?
        @connections << client
      end
    end

    def exec(request : HTTP::Request) : HTTP::Client::Response
      client = aquire_client
      begin
        client.exec request
      ensure
        release_client client
      end
    end

    def exec(request : HTTP::Request, &block)
      client = aquire_client
      begin
        client.exec(request) do |response|
          yield response
        end
      ensure
        release_client client
      end
    end

    private def end_overkeep
      return if @close_mutex.synchronize do
        return true if @closing
        !(@closing = true)
      end
      loop do
        sleep @clean_after.seconds
        @mutex.lock
        dirty = false
        while @connections.size > @keep
          client = @connections.pop
          client.close
          dirty = true
        end
        @mutex.unlock
        break unless dirty
      end
      @close_mutex.synchronize { @closing = false }
    end

    {% for method in %w(get post put head delete patch options) %}
      def {{ method.id }}(path, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
        exec HTTP::Request.new({{ method.upcase }}, path, headers, body)
      end

      def {{ method.id }}(path, headers : HTTP::Headers? = nil, body : HTTP::Client::BodyType = nil)
        exec HTTP::Request.new({{ method.upcase }}, path, headers, body) do |response|
          yield response
        end
      end
    {% end %}
  end
end
