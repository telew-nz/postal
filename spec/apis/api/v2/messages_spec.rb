# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Management API Messages", type: :request do
  let(:user) { create(:user) }
  let(:token) { create(:user_api_token, user: user) }
  let(:organization) { create_organization(user) }
  let(:server) { create(:server, organization: organization) }

  def base
    "/api/v2/organizations/#{organization.permalink}/servers/#{server.permalink}/messages"
  end

  # A message which has had its raw content removed, which is what happens once
  # the retention period configured for the server has elapsed.
  def expired_message
    message = server.message_db.new_message
    message.scope = "outgoing"
    message.rcpt_to = "expired@example.com"
    message.mail_from = "test@example.com"
    message.status = "Sent"
    message.timestamp = Time.now.to_f
    message.save(queue_on_create: false)
    message
  end

  describe "GET .../messages" do
    it "returns the outgoing messages for the server" do
      outgoing = MessageFactory.outgoing(server)
      MessageFactory.incoming(server)

      get base, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_data.first).to include("id" => outgoing.id, "scope" => "outgoing", "raw_message" => true)
    end

    it "returns the incoming messages when the scope is incoming" do
      MessageFactory.outgoing(server)
      incoming = MessageFactory.incoming(server)

      get base, headers: api_headers(token), params: { scope: "incoming" }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([incoming.id])
    end

    it "filters by recipient" do
      MessageFactory.outgoing(server) { |m| m.rcpt_to = "alice@example.com" }
      wanted = MessageFactory.outgoing(server) { |m| m.rcpt_to = "bob@example.com" }

      get base, headers: api_headers(token), params: { to: "bob@example.com" }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([wanted.id])
    end

    it "filters by sender" do
      MessageFactory.outgoing(server) { |m| m.mail_from = "one@example.com" }
      wanted = MessageFactory.outgoing(server) { |m| m.mail_from = "two@example.com" }

      get base, headers: api_headers(token), params: { from: "two@example.com" }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([wanted.id])
    end

    it "filters by status" do
      MessageFactory.outgoing(server) { |m| m.status = "Pending" }
      wanted = MessageFactory.outgoing(server) { |m| m.status = "Sent" }

      get base, headers: api_headers(token), params: { status: "Sent" }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([wanted.id])
    end

    it "filters by token" do
      MessageFactory.outgoing(server)
      wanted = MessageFactory.outgoing(server)

      get base, headers: api_headers(token), params: { token: wanted.token }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([wanted.id])
      expect(parsed_data.first["token"]).to eq(wanted.token)
    end

    it "filters by message ID" do
      MessageFactory.outgoing(server) { |_message, mail| mail.message_id = "one@example.com" }
      wanted = MessageFactory.outgoing(server) { |_message, mail| mail.message_id = "two@example.com" }

      # The message ID is taken from the headers of the raw message rather than
      # from the attribute which was set before it was saved.
      expect(wanted.message_id).to eq("two@example.com")

      get base, headers: api_headers(token), params: { message_id: wanted.message_id }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([wanted.id])
    end

    it "finds a message by its ID regardless of its scope when the message ID filter is used" do
      incoming = MessageFactory.incoming(server) { |_message, mail| mail.message_id = "shared@example.com" }

      get base, headers: api_headers(token), params: { message_id: incoming.message_id }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([incoming.id])
    end

    it "filters by tag" do
      MessageFactory.outgoing(server) { |m| m.tag = "alpha" }
      wanted = MessageFactory.outgoing(server) { |m| m.tag = "beta" }

      get base, headers: api_headers(token), params: { tag: "beta" }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([wanted.id])
    end

    it "filters by the internal message ID" do
      MessageFactory.outgoing(server)
      wanted = MessageFactory.outgoing(server)

      get base, headers: api_headers(token), params: { id: wanted.id }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([wanted.id])
    end

    it "excludes spam by default" do
      MessageFactory.outgoing(server)
      MessageFactory.outgoing(server) { |m| m.spam = 1 }

      get base, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_data.first["spam"]).to be(false)
    end

    it "returns only spam when the spam filter is set" do
      MessageFactory.outgoing(server)
      spam = MessageFactory.outgoing(server) { |m| m.spam = 1 }

      get base, headers: api_headers(token), params: { spam: "true" }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([spam.id])
      expect(parsed_data.first["spam"]).to be(true)
    end

    it "returns the newest messages first by default" do
      old = MessageFactory.outgoing(server) { |m| m.timestamp = 1_600_000_000.0 }
      new = MessageFactory.outgoing(server) { |m| m.timestamp = 1_700_000_000.0 }

      get base, headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([new.id, old.id])
    end

    it "returns the oldest messages first when asked to" do
      old = MessageFactory.outgoing(server) { |m| m.timestamp = 1_600_000_000.0 }
      new = MessageFactory.outgoing(server) { |m| m.timestamp = 1_700_000_000.0 }

      get base, headers: api_headers(token), params: { order: "oldest-first" }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([old.id, new.id])
    end

    it "filters by a timestamp using an explicit date" do
      old = MessageFactory.outgoing(server) { |m| m.timestamp = 1_000_000_000.0 }
      new = MessageFactory.outgoing(server) { |m| m.timestamp = 1_700_000_000.0 }

      get base, headers: api_headers(token), params: { after: "2010-01-01" }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([new.id])

      get base, headers: api_headers(token), params: { before: "2010-01-01" }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([old.id])
    end

    it "filters by a timestamp using a date and a time" do
      MessageFactory.outgoing(server) { |m| m.timestamp = 1_300_000_000.0 }
      wanted = MessageFactory.outgoing(server) { |m| m.timestamp = 1_700_000_000.0 }

      get base, headers: api_headers(token), params: { after: "2015-01-01 00:00", before: "2030-01-01 00:00" }

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([wanted.id])
    end

    it "returns a 422 when the before filter cannot be parsed" do
      get base, headers: api_headers(token), params: { before: "zzzz-not-a-time" }

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("TimeUndetermined")
      expect(parsed_error["message"]).to include("before")
    end

    it "returns a 422 when the after filter cannot be parsed" do
      get base, headers: api_headers(token), params: { after: "zzzz-not-a-time" }

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("TimeUndetermined")
      expect(parsed_error["message"]).to include("after")
    end

    it "ignores parameters which cannot be used to filter" do
      MessageFactory.outgoing(server)

      get base, headers: api_headers(token), params: { evil: "value", page: 1 }

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
    end

    it "paginates the messages" do
      3.times { |i| MessageFactory.outgoing(server) { |m| m.timestamp = 1_600_000_000.0 + i } }

      get base, headers: api_headers(token), params: { page: 2, per_page: 2 }

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_pagination).to include("page" => 2, "per_page" => 2, "total" => 3, "total_pages" => 2)
    end

    it "caps the number of messages per page using the configured maximum" do
      MessageFactory.outgoing(server)

      get base, headers: api_headers(token), params: { per_page: Postal::Config.api.max_per_page + 100 }

      expect(response.status).to eq(200)
      expect(parsed_pagination["per_page"]).to eq(Postal::Config.api.max_per_page)
    end

    it "returns a 404 for a server in another organization" do
      other = create(:server)

      get "/api/v2/organizations/#{organization.permalink}/servers/#{other.permalink}/messages", headers: api_headers(token)

      expect(response.status).to eq(404)
    end
  end

  describe "GET .../messages/held" do
    it "returns only the messages which are being held" do
      MessageFactory.outgoing(server)
      held = MessageFactory.outgoing(server) do |m|
        m.status = "Held"
        m.held = 1
      end

      get "#{base}/held", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.map { |m| m["id"] }).to eq([held.id])
      expect(parsed_data.first).to include("held" => true, "status" => "Held")
    end

    it "returns an empty collection when nothing is held" do
      MessageFactory.outgoing(server)

      get "#{base}/held", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to eq([])
    end
  end

  describe "GET .../messages/:id" do
    let(:message) do
      MessageFactory.outgoing(server) do |_msg, mail|
        mail.subject = "A detailed message"
        mail.html_part = Mail::Part.new do
          content_type "text/html; charset=UTF-8"
          body "<html><body><p>hello</p></body></html>"
        end
      end
    end

    it "returns the message including its content" do
      get "#{base}/#{message.id}", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to include(
        "id" => message.id,
        "scope" => "outgoing",
        "rcpt_to" => "john@example.com",
        "mail_from" => "test@example.com",
        "subject" => "A detailed message",
        "raw_message" => true
      )
      expect(parsed_data["headers"]).to be_a(Hash)
      expect(parsed_data["html_body"]).to include("hello")
      expect(parsed_data["attachments"]).to eq([])
      expect(parsed_data["timestamp"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    it "returns a 404 for a message which does not exist" do
      message = MessageFactory.outgoing(server)

      get "#{base}/#{message.id + 100}", headers: api_headers(token)

      expect(response.status).to eq(404)
      expect(parsed_error["code"]).to eq("NotFound")
    end
  end

  describe "GET .../messages/:id/deliveries" do
    it "returns the delivery attempts for the message" do
      message = MessageFactory.outgoing(server)
      message.create_delivery("Sent", details: "Message sent")

      get "#{base}/#{message.id}/deliveries", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_data.first).to include(
        "message_id" => message.id,
        "status" => "Sent",
        "details" => "Message sent"
      )
      expect(parsed_data.first["timestamp"]).to be_present
    end
  end

  describe "GET .../messages/:id/activity" do
    it "returns the deliveries, clicks and loads for the message" do
      message = MessageFactory.outgoing(server)
      message.create_delivery("Sent")

      get "#{base}/#{message.id}/activity", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.size).to eq(1)
      expect(parsed_data.first).to include("type" => "Delivery", "status" => "Sent")
    end
  end

  describe "GET .../messages/:id/spam_checks" do
    it "returns the spam checks sorted by score" do
      message = MessageFactory.outgoing(server)
      server.message_db.insert(:spam_checks, message_id: message.id, code: "LOW_SCORE", score: 1.5, description: "A low score")
      server.message_db.insert(:spam_checks, message_id: message.id, code: "HIGH_SCORE", score: 9.5, description: "A high score")

      get "#{base}/#{message.id}/spam_checks", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data.map { |c| c["code"] }).to eq(%w[HIGH_SCORE LOW_SCORE])
      expect(parsed_data.first).to include("message_id" => message.id, "description" => "A high score")
      expect(parsed_data.first["score"]).to eq(9.5)
    end

    it "returns an empty collection when the message has not been inspected" do
      message = MessageFactory.outgoing(server)

      get "#{base}/#{message.id}/spam_checks", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to eq([])
    end
  end

  describe "GET .../messages/:id/plain" do
    it "returns the plain text body" do
      message = MessageFactory.outgoing(server)

      get "#{base}/#{message.id}/plain", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["body"]).to include("Hello world!")
    end
  end

  describe "GET .../messages/:id/html" do
    it "returns the HTML body when there is one" do
      message = MessageFactory.outgoing(server) do |_msg, mail|
        mail.html_part = Mail::Part.new do
          content_type "text/html; charset=UTF-8"
          body "<html><body>hi</body></html>"
        end
      end

      get "#{base}/#{message.id}/html", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["body"]).to include("hi")
    end

    it "returns no body when the message has no HTML part" do
      message = MessageFactory.outgoing(server)

      get "#{base}/#{message.id}/html", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["body"]).to be_nil
    end
  end

  describe "GET .../messages/:id/headers" do
    it "returns the headers for the message" do
      message = MessageFactory.outgoing(server)

      get "#{base}/#{message.id}/headers", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["headers"]).to be_a(Hash)
      expect(parsed_data["headers"]["subject"]).to include("An example message")
    end
  end

  describe "GET .../messages/:id/attachments" do
    it "returns the metadata for each attachment" do
      message = MessageFactory.outgoing(server) do |_msg, mail|
        mail.attachments["example.txt"] = "Some content"
      end

      get "#{base}/#{message.id}/attachments", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["attachments"].size).to eq(1)
      expect(parsed_data["attachments"].first).to include("filename" => "example.txt", "content_type" => "text/plain")
      expect(parsed_data["attachments"].first["size"]).to be > 0
    end

    it "returns an empty collection when there are no attachments" do
      message = MessageFactory.outgoing(server)

      get "#{base}/#{message.id}/attachments", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data["attachments"]).to eq([])
    end
  end

  describe "GET .../messages/:id/attachment" do
    it "returns the content of the attachment at the given position" do
      message = MessageFactory.outgoing(server) do |_msg, mail|
        mail.attachments["example.txt"] = "Some content"
      end

      get "#{base}/#{message.id}/attachment", headers: api_headers(token), params: { attachment: 0 }

      expect(response.status).to eq(200)
      expect(response.body).to be_present
      expect(response.headers["Content-Type"]).to include("text/plain")
      expect(response.headers["Content-Disposition"]).to include("example.txt")
    end

    it "returns a 404 when there is no attachment at that position" do
      message = MessageFactory.outgoing(server)

      get "#{base}/#{message.id}/attachment", headers: api_headers(token), params: { attachment: 5 }

      expect(response.status).to eq(404)
      expect(parsed_error["code"]).to eq("NotFound")
    end
  end

  describe "GET .../messages/:id/download" do
    it "returns the raw message as an eml file" do
      message = MessageFactory.outgoing(server)

      get "#{base}/#{message.id}/download", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(response.headers["Content-Type"]).to include("text/plain")
      expect(response.headers["Content-Disposition"]).to include(".eml")
      expect(response.body).to include("Hello world!")
    end

    it "returns a 404 when the raw message is no longer stored" do
      message = expired_message

      get "#{base}/#{message.id}/download", headers: api_headers(token)

      expect(response.status).to eq(404)
      expect(parsed_error["code"]).to eq("NotFound")
    end
  end

  describe "POST .../messages/:id/retry" do
    it "adds the message to the queue when it is not queued" do
      message = MessageFactory.outgoing(server)

      expect do
        post "#{base}/#{message.id}/retry", headers: api_headers(token)
      end.to change(QueuedMessage, :count).by(1)

      expect(response.status).to eq(200)
      expect(QueuedMessage.last.manual).to be(true)
      expect(parsed_data).to include("id" => message.id)
    end

    it "retries the message immediately when it is already queued" do
      message = MessageFactory.outgoing(server)
      queued_message = create(:queued_message, :retry_in_future, message: message)

      post "#{base}/#{message.id}/retry", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(queued_message.reload.retry_after).to be_nil
    end

    it "returns a 422 when the raw message is no longer stored" do
      message = expired_message

      expect do
        post "#{base}/#{message.id}/retry", headers: api_headers(token)
      end.not_to change(QueuedMessage, :count)

      expect(response.status).to eq(422)
      expect(parsed_error["code"]).to eq("MessageUnavailable")
    end
  end

  describe "POST .../messages/:id/cancel_hold" do
    it "releases the hold on a message" do
      message = MessageFactory.outgoing(server) do |m|
        m.status = "Held"
        m.held = 1
      end

      post "#{base}/#{message.id}/cancel_hold", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to include("status" => "HoldCancelled", "held" => false)
    end

    it "does nothing when the message is not held" do
      message = MessageFactory.outgoing(server)

      post "#{base}/#{message.id}/cancel_hold", headers: api_headers(token)

      expect(response.status).to eq(200)
      expect(parsed_data).to include("id" => message.id)
    end
  end

  describe "DELETE .../messages/:id/remove_from_queue" do
    it "removes the message from the queue" do
      message = MessageFactory.outgoing(server)
      queued_message = create(:queued_message, message: message)

      delete "#{base}/#{message.id}/remove_from_queue", headers: api_headers(token)

      expect(response.status).to eq(204)
      expect(parsed_body).to be_nil
      expect(QueuedMessage.exists?(queued_message.id)).to be(false)
    end

    it "leaves a message which is being processed by a worker in the queue" do
      message = MessageFactory.outgoing(server)
      queued_message = create(:queued_message, :locked, message: message)

      delete "#{base}/#{message.id}/remove_from_queue", headers: api_headers(token)

      expect(response.status).to eq(204)
      expect(QueuedMessage.exists?(queued_message.id)).to be(true)
    end

    it "is idempotent when the message is not in the queue" do
      message = MessageFactory.outgoing(server)

      delete "#{base}/#{message.id}/remove_from_queue", headers: api_headers(token)

      expect(response.status).to eq(204)
    end
  end

  describe "suppressions" do
    def suppressions_path
      "#{base}/suppressions"
    end

    describe "GET .../messages/suppressions" do
      it "returns the suppression list" do
        server.message_db.suppression_list.add("recipient", "blocked@example.com", reason: "Hard failed")

        get suppressions_path, headers: api_headers(token)

        expect(response.status).to eq(200)
        expect(parsed_data.size).to eq(1)
        expect(parsed_data.first).to include("type" => "recipient", "address" => "blocked@example.com", "reason" => "Hard failed", "expired" => false)
        expect(parsed_data.first["keep_until"]).to be_present
      end

      it "paginates the suppression list" do
        3.times { |i| server.message_db.suppression_list.add("recipient", "blocked#{i}@example.com") }

        get suppressions_path, headers: api_headers(token), params: { page: 2, per_page: 2 }

        expect(response.status).to eq(200)
        expect(parsed_data.size).to eq(1)
        expect(parsed_pagination).to include("page" => 2, "per_page" => 2, "total" => 3, "total_pages" => 2)
      end
    end

    describe "POST .../messages/suppressions" do
      it "adds a suppression" do
        post suppressions_path, headers: api_headers(token), params: { type: "recipient", address: "blocked@example.com", reason: "Manual" }.to_json

        expect(response.status).to eq(201)
        expect(parsed_data).to include("type" => "recipient", "address" => "blocked@example.com", "reason" => "Manual")
        expect(server.message_db.suppression_list.get("recipient", "blocked@example.com")).to be_present
      end

      it "honours the number of days the suppression should be kept for" do
        post suppressions_path, headers: api_headers(token), params: { type: "recipient", address: "blocked@example.com", days: 1 }.to_json

        expect(response.status).to eq(201)
        expect(Time.parse(parsed_data["keep_until"])).to be_within(1.minute).of(1.day.from_now)
      end

      it "returns a 400 when the type is missing" do
        post suppressions_path, headers: api_headers(token), params: { address: "blocked@example.com" }.to_json

        expect(response.status).to eq(400)
        expect(parsed_error["code"]).to eq("ParameterMissing")
      end

      it "returns a 400 when the address is missing" do
        post suppressions_path, headers: api_headers(token), params: { type: "recipient" }.to_json

        expect(response.status).to eq(400)
        expect(parsed_error["code"]).to eq("ParameterMissing")
      end

      it "returns a 422 when the type is not recognised" do
        post suppressions_path, headers: api_headers(token), params: { type: "sender", address: "blocked@example.com" }.to_json

        expect(response.status).to eq(422)
        expect(parsed_error["code"]).to eq("ValidationError")
        expect(parsed_error["details"].join(" ")).to include("Type must be one of: recipient")
      end
    end

    describe "DELETE .../messages/suppressions/:type/:address" do
      it "removes a suppression" do
        server.message_db.suppression_list.add("recipient", "blocked@example.com")

        delete "#{suppressions_path}/recipient/blocked@example.com", headers: api_headers(token)

        expect(response.status).to eq(204)
        expect(parsed_body).to be_nil
        expect(server.message_db.suppression_list.get("recipient", "blocked@example.com")).to be_nil
      end

      it "returns a 404 when there is no matching suppression" do
        delete "#{suppressions_path}/recipient/nobody@example.com", headers: api_headers(token)

        expect(response.status).to eq(404)
        expect(parsed_error["code"]).to eq("NotFound")
      end
    end
  end
end
