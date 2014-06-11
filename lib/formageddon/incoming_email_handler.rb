require 'rufus/mnemo'
require 'nokogiri'
require File.expand_path('../null_object', __FILE__)

module Formageddon
  class IncomingEmailHandler < ActionMailer::Base
    include NullObject::Conversions

    def receive(email)
      to_email = email.to.select{|e| e =~ /_thread/ }.first
      return nil if to_email.nil?

      recipient, domain = to_email.split(/@/)
      thread_id, tag = recipient.split(/_/)

      thread_id = Rufus::Mnemo.to_i(thread_id)
      thread = FormageddonThread.find_by_id(thread_id)
      return nil if thread.nil?

      letter = FormageddonLetter.new
      letter.status = 'RECEIVED'
      letter.direction = 'TO_SENDER'

      letter.subject = email.subject

      body_parts = [Maybe(email.text_part).body.decoded,
                    formatted_text_for_html(Maybe(email.html_part).body.decoded.to_s),
                    Maybe(email.body).decoded,
                    "[Email text was unprocessable]"]
      letter.message = body_parts.select{|part| Actual(part)}.first

      letter.formageddon_thread = thread
      unless letter.save
        if Formageddon.configuration.log_with_sentry && defined?(Raven)
          message = <<-EOM
          Failed to save letter:
          #{letter.errors.full_messages.to_sentence}

          text part: #{email.text_part.body.decoded rescue nil}

          html part: #{email.html_part.body.decoded rescue nil}

          body: #{email.body.decoded rescue nil}

          email: #{email}
          EOM
          Raven.capture_message(message)
        end
      end

      letter
    rescue
      # RuntimeError is raised if the identifier word can't be decoded
      nil
    end

    protected

    def formatted_text_for_html(html)
      # Returns plain text with break tags converted to newlines,
      # or nil if the result is empty
      text = Nokogiri::HTML(html.gsub(/<br[^>]*>/, "\n")).text
      text.length ? text : nil
    end
  end
end