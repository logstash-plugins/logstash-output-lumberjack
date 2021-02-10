# encoding: utf-8
require "logstash/devutils/rspec/spec_helper"
require "logstash/outputs/lumberjack"
require "logstash/errors"
require "logstash/event"
require "lumberjack/server"
require "flores/pki"
require "stud/temporary"
require "fileutils"

describe "Sending events" do
  let(:batch_size) { Flores::Random.integer(20..100) }
  let(:batch_payload) do
    batch_size.times.collect { |n| LogStash::Event.new({ "message" => "foobar #{n}" }) }
  end

  let(:number_of_crash) { Flores::Random.integer(1..10) }
  let(:certificate) { Flores::PKI.generate }
  let(:certificate_file_crt) { Stud::Temporary.pathname }
  let(:certificate_file_key) { Stud::Temporary.pathname }
  let(:port) { Flores::Random.integer(1024..65535) }
  let(:host) { "127.0.0.1" }
  let(:queue) { [] }
  let(:client_options) {
    {
      "hosts" => [host],
      "port" => port,
      "ssl_certificate" => certificate_file_crt,
      "flush_size" => batch_size
    }
  }

  let(:output) { LogStash::Outputs::Lumberjack.new(client_options) }

  let(:server) { 
    Lumberjack::Server.new(:port => port,
                           :address => host,
                           :ssl_certificate => certificate_file_crt,
                           :ssl_key => certificate_file_key)

  }


  before do
    File.open(certificate_file_crt, "a") { |f| f.write(certificate.first) }
    File.open(certificate_file_key, "a") { |f| f.write(certificate.last) }
  end

  after do
    FileUtils.rm_rf(certificate_file_crt)
    FileUtils.rm_rf(certificate_file_key)
  end

  context "when the server closes the connection" do
    before do
      crashed_count = 0

      @server = Thread.new do
        begin
          server.run do |data|
            if crashed_count < number_of_crash
              crashed_count += 1
              raise "crashed"
            end

            queue << data
          end
        rescue
        end
      end

      output.register
    end

    it "reconnects and resend the payload" do
      # We guarantee at least once, 
      # duplicates can happen in this scenario.
      batch_payload.each { |event| output.receive(event) }

      try(10) { expect(queue.size).to be >= batch_size }
      expect(queue.map { |e| e["line"] }).to include(*batch_payload.map(&:to_s))
    end
  end

  context "when shutting down" do
    let(:queue) { [] }
    let(:event) { LogStash::Event.new("line" => "Hello") }
    let(:number_of_events) { 50 }

    before do 
      @server = Thread.new do
        server.run do |data|
          queue << data
        end
      end

      output.register
    end

    it "flushes the events in the buffer" do
      number_of_events.times { output.receive(event) }
      output.close
      expect(queue.size).to eq(number_of_events)
    end
  end
end
