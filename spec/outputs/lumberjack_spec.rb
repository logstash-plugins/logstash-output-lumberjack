# encoding: utf-8
require "logstash/outputs/lumberjack"
require "logstash/event"
require "logstash/devutils/rspec/spec_helper"
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
  let(:input) { LogStash::Outputs::Lumberjack.new(client_options) }

  context "when the server closes the connection" do
    before do
      File.open(certificate_file_crt, "a") { |f| f.write(certificate.first) }
      File.open(certificate_file_key, "a") { |f| f.write(certificate.last) }

      server = Lumberjack::Server.new(:port => port,
                                      :address => host,
                                      :ssl_certificate => certificate_file_crt,
                                      :ssl_key => certificate_file_key)

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

      input.register
    end

    after do
      FileUtils.rm_rf(certificate_file_crt)
      FileUtils.rm_rf(certificate_file_key)
    end

    it "reconnects and resend the payload" do
      # We guarantee at least once, 
      # duplicates can happen in this scenario.
      batch_payload.each do |event|
        input.receive(event)
      end

      try(10) { expect(queue.size).to be >= batch_size }
      expect(queue.map { |e| e["line"] }).to include(*batch_payload.map(&:to_s))
    end
  end
end
