require "./spec_helper"

describe AsyncHttp do
  it "makes HTTP::Client concurrently safe" do
    connection = HTTP::Client.new URI.parse "https://gorest.co.in/"
    connection.connect_timeout = 5
    channel = Channel(Int32).new

    10.times do
      spawn simple_request(channel, connection)
    end

    10.times do
      channel.receive.should eq(200)
    end
  end
end

describe AsyncHttp::Client do
  it "works with static number of connections" do
    connection = AsyncHttp::Client.new URI.parse("https://gorest.co.in/"), keep: 5
    connection.connect_timeout = 5
    channel = Channel(Int32).new

    10.times do
      spawn simple_request(channel, connection)
    end

    10.times do
      channel.receive.should eq(200)
    end
  end

  it "works with dynamic number of connections" do
    connection = AsyncHttp::Client.new URI.parse("https://gorest.co.in/"), keep: 5, dynamic: true, capacity: 7
    connection.connect_timeout = 5.seconds
    channel = Channel(Int32).new

    100.times do
      spawn simple_request(channel, connection)
    end

    100.times do
      channel.receive.should eq(200)
    end
  end
end

def simple_request(channel : Channel(Int32), connection)
  res = connection.get "/public/v2/users"
  channel.send res.status_code
rescue e
  puts e.inspect_with_backtrace
  channel.send -1
  raise e
end
