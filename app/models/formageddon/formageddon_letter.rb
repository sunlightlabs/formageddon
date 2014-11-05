require_dependency 'renders_templates'

module Formageddon
  class FormageddonLetter < ActiveRecord::Base
    include RendersTemplates
    include Faxable
    include ActionView::Helpers::TextHelper

    belongs_to :formageddon_thread
    has_many :formageddon_delivery_attempts, -> { order('created_at ASC') }

    attr_accessor :captcha_solution

    delegate :formageddon_recipient_id,:to => 'Formageddon::FormageddonThread'

    PRINT_TEMPLATE = "contact_congress_letters/print"

    validates_presence_of :subject, :message => "You must enter a letter subject."
    validates_presence_of :message, :message => "You must enter some content in your message."
    validates_length_of :subject, :maximum => 1000, :message => 'Please shorten the subject of your letter.'
    validates_length_of :message, :maximum => 25000, :message => 'Please shorten the body of your letter.'

    before_create :truncate_subject

    def send_letter(options = {})
      recipient = self.formageddon_thread.formageddon_recipient

      if recipient.nil? || recipient.formageddon_contact_steps.empty?
        unless self.status =~ /^(SENT|RECEIVED|ERROR)/  # These statuses don't depend on a proper set of contact steps
          self.status = 'ERROR: Recipient not configured for message delivery!'
          self.save
        end
        return false if recipient.nil?
      end

      browser = Mechanize.new
      browser.user_agent_alias = "Windows IE 7"
      browser.follow_meta_refresh = true
  
      case status
      when 'START', 'RETRY'
        return recipient.execute_contact_steps(browser, self)
      when 'TRYING_CAPTCHA', 'RETRY_STEP'
        attempt = formageddon_delivery_attempts.last

        if status == 'TRYING_CAPTCHA' and ! %w(CAPTCHA_REQUIRED CAPTCHA_WRONG).include? attempt.result
          # weird state, abort
          return false
        end

        browser = (attempt.result == 'CAPTCHA_WRONG') ? attempt.rebuild_browser(browser, 'after') : attempt.rebuild_browser(browser, 'before')

        if options[:captcha_solution]
          @captcha_solution = options[:captcha_solution]
          @captcha_browser_state = attempt.captcha_browser_state
        end

        return recipient.execute_contact_steps(browser, self, attempt.letter_contact_step)
      when /^ERROR:/
        if recipient.fax
          return send_fax :error_msg => status
        end
      end
    end

    def send_fax(options={})
      recipient = options.fetch(:recipient, formageddon_thread.formageddon_recipient)
      if recipient.fax.present?
        if defined? Settings.force_fax_recipient
          send_as_fax(Settings.force_fax_recipient)
        else
          send_as_fax(recipient.fax)
        end
        self.status = "SENT_AS_FAX"
        self.status += ": Error was, #{options[:error_msg]}" if options[:error_msg].present?
        self.save!
        return @fax # TODO: This sucks, why did I do this?
      else
        return false
      end
    end

    def as_html
      @rendered ||= render_to_string(:partial => PRINT_TEMPLATE, :locals => { :letter => self })
    end

    def value_for(field)
      case (field.to_sym rescue nil)
      when :message
        return self.message
      when :subject
        return self.subject
      when :issue_area
        return self.issue_area
      when :full_name
        return "#{self.formageddon_thread.sender_first_name} #{self.formageddon_thread.sender_last_name}"
      when :captcha_solution
        return @captcha_solution
      else
        return self.formageddon_thread.send("sender_#{field.to_s}") rescue field.to_s
      end
    end

    protected

    def truncate_subject(length=255)
      self.subject = truncate(subject, :length => length, :omission => '...')
    end
  end
end
