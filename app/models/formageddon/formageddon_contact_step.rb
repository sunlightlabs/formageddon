module Formageddon
  class FormageddonContactStep < ActiveRecord::Base
    belongs_to :formageddon_recipient, :polymorphic => true
    has_one :formageddon_form, :dependent => :destroy

    accepts_nested_attributes_for :formageddon_form
    attr_accessor :error_msg, :captcha_image

    after_save :ensure_index

    @@contact_fields = [
      :title, :first_name, :last_name, :email, :address1, :address2, :zip5, :zip4, :city, :state, :state_house,
      :phone, :issue_area, :subject, :message, :submit_button, :leave_blank, :captcha_solution
    ]
    def self.contact_fields
      @@contact_fields
    end

    def has_captcha?
      command =~ /submit_form/ && formageddon_form.has_captcha?
    end

    def execute(browser, options = {})
      raise "Browser is nil!" if browser.nil?

      Rails.logger.debug "Executing Contact Step ##{self.step_number} for #{self.formageddon_recipient}..."

      begin
        save_states = options[:save_states].nil? ? true : options[:save_states]

        if save_states
          delivery_attempt = options[:delivery_attempt]
          delivery_attempt.letter_contact_step = self.step_number unless delivery_attempt.nil?
          delivery_attempt.save
        end

        case self.command
        when /^visit::/
          command, url = self.command.split(/::/)

          begin
            browser.get(url) do |page|
              # remove some bad html that appears on some pages
              # TODO: Why is this here? what problems could clearing divs be causing?
              page.body = page.body.gsub(/<div class="clear"\/> <\/div>/, '')
              page.body = page.body.gsub(/<div class="clear"\/><\/div>/, '')
            end
          rescue Timeout::Error
            save_after_error($!, options[:letter], delivery_attempt, save_states)

            return false
          rescue
            save_after_error($!, options[:letter], delivery_attempt, save_states)

            return false
          end

          return true
        when /^submit_form/
          raise "Must submit :letter to execute!" if options[:letter].nil?
          letter = options[:letter]

          delivery_attempt.save_before_browser_state(browser) if save_states

          if formageddon_form.has_captcha? and letter.captcha_solution.nil?
            letter.status = 'CAPTCHA_REQUIRED'
            letter.save

            if save_states
               delivery_attempt.result = 'CAPTCHA_REQUIRED'
               delivery_attempt.save
            end

            begin
              save_captcha_image(browser, letter)
            rescue Timeout::Error
              save_after_error("Saving captcha: #{$!}", options[:letter], delivery_attempt, save_states)

              delivery_attempt.save_after_browser_state(browser) if save_states
            end
            return false
          end

          formageddon_form.formageddon_form_fields.each do |ff|
            field = browser.page.search(ff.css_selector).first
            raise "#{ff.value.titleize} field (#{ff.css_selector}) not found!" if ff.nil?

            puts letter if letter.is_a? Hash
            field.value = letter[ff.value] and next if letter.is_a? Hash

            # Any proceeding iteration should be with a FormageddonLetter
            raise "#{letter} is not a valid FormageddonLetter!" unless letter.is_a? FormageddonLetter

            # Email fields need special handling due to the possiblity that a plus sign is disallowed.
            # Specifically, we want to receive emails to the site, not the user's email address, but
            # can't in 100% of instances.
            if (ff.value == 'email' &&
                !Formageddon::configuration.reply_domain.nil? &&
                !formageddon_form.use_real_email_address?)
              field.value = "formageddon+#{letter.formageddon_thread.id}@#{Formageddon::configuration.reply_domain}"

            elsif ff.value == 'want_response'
              if field.is_a? Mechanize::Form::SelectList
                option_field = field.options_with(:value => /(y(es)?|true)/i).first
                if option_field.present?
                  option_field.select
                else
                  # 3 options means the first one is probably null
                  if field.options.length == 3
                    field.options[1].select
                  else
                    # Select the first one, which is less than great and needs more research.
                    # Previously this selected at random, which seems way worse.
                    field.options[0].select
                  end
                end

              elsif field.is_a? Mechanize::Form::CheckBox
                if ff.value == 'leave_blank' && field.checked?
                  field.uncheck
                elsif ff.value != 'leave_blank' && field.unchecked?
                  field.check
                end
              elsif field.is_a? Mechanize::Form::RadioButton
                if ff.value != 'leave_blank' && field.unchecked?
                  field.check
                end
              else
                field.value = 'Yes'
              end
            elsif ff.value == 'title'
              title = letter.value_for(ff.value)
              if field.is_a? Mechanize::Form::SelectList
                # the chop value has no period
                option_field = field.options_with(:value => /#{title}/i).first ||
                               field.options_with(:value => /#{title.chop}/i).first

                if option_field.present?
                  option_field.select
                else
                # select a random one.  not ideal.
                  field.options[rand(field.options.size-1)+1].select
                end
              else
                field.value = title
              end
            elsif ff.value == 'issue_area'
              # TODO: Ack! There is no handling of issue area mapping!
              value = letter.value_for(ff.value)
              if field.is_a? Mechanize::Form::SelectList
                option_field = field.options_with(:value => value).first
                option_field = field.options_with(:value => /(other|general)/i).first if option_field.nil?
                if option_field.present?
                  option_field.select
                else
                  # Boooo random
                  field.options[rand(field.options.size-1)+1].select
                end
              else
                field.value = value
              end
            elsif ff.value == 'state_house'
              state = State.find_by_abbreviation(letter.value_for(:state))
              field.value = "#{state.abbreviaion}#{state.name}"
            else
              value = letter.value_for(ff.value)
              if field.is_a? Mechanize::Form::SelectList
                option_field = field.options_with(:value => value).first
                option_field.select if option_field.present?
              elsif field.is_a? Mechanize::Form::CheckBox
                if ff.value == 'leave_blank' && field.checked?
                  field.uncheck
                elsif ff.value != 'leave_blank' && field.unchecked?
                  field.check
                end
              elsif field.is_a? Mechanize::Form::RadioButton
                if ff.value != 'leave_blank' && field.unchecked?
                  field.check
                end
              else
                begin
                  field.value = value unless ff.not_changeable?
                rescue NoMethodError
                  raise "#{ff.value} can't be set to #{value} on field with name: #{field.attr('name')}"
                end
              end
            end
          end

          # check to see if there are any default params to force
          unless Formageddon::configuration.default_params.empty?
            Formageddon::configuration.default_params.keys.each do |k|
              fields = browser.page.search("[name='#{k}']")
              fields.each do |field|
                field.value = Formageddon::configuration.default_params[k]
              end
            end
          end

          begin
            browser.page.search(formageddon_form.submit_css_selector).first.click
          rescue Timeout::Error
            save_after_error($!, options[:letter], delivery_attempt, save_states)

            delivery_attempt.save_after_browser_state(browser) if save_states

            return false
          rescue
            save_after_error($!, options[:letter], delivery_attempt, save_states)

            delivery_attempt.save_after_browser_state(browser) if save_states

            return false
          end

          if ((!formageddon_form.success_string.blank? and (browser.page.parser.to_s =~ /#{formageddon_form.success_string}/)) or generic_confirmation?(browser.page.parser.to_s))
            if letter.kind_of? Formageddon::FormageddonLetter
              letter.status = 'SENT'
              letter.save
            end

            if save_states
              delivery_attempt.result = 'SUCCESS'
              delivery_attempt.save

              # save on success for now, just in case we start getting false positives here
              delivery_attempt.save_after_browser_state(browser)
            end

            return true

          elsif formageddon_form.success_string.blank?
            formageddon_form.success_string.blank? and !generic_confirmation?(browser.page.parser.to_s)

            if letter.kind_of? Formageddon::FormageddonLetter
              letter.status = 'WARNING: Confirmation message is blank. Unable to confirm delivery.'
              letter.save
            end

            if save_states
              delivery_attempt.save_after_browser_state(browser)

              delivery_attempt.result = 'WARNING: Confirmation message is blank. Unable to confirm delivery.'
              delivery_attempt.save
            end

            return true
          else
            # save the browser state in the delivery attempt
            delivery_attempt.save_after_browser_state(browser) if save_states

            if letter.status == 'TRYING_CAPTCHA'
              # assume that the captcha was wrong?
              letter.status = 'CAPTCHA_REQUIRED'
              save_captcha_image(browser, letter)

              if save_states
                delivery_attempt.result = 'CAPTCHA_WRONG'
                delivery_attempt.save
              end
            else
              letter.status = "WARNING: Confirmation message not found."

              delivery_attempt.result = "WARNING: Confirmation message not found." if save_states
            end

            letter.save
            delivery_attempt.save if save_states


            return false
          end
        end
      rescue
        if letter.kind_of? Formageddon::FormageddonLetter
          letter.status = "ERROR: #{$!}: #{$@[0]}"
          letter.save
        end

        if save_states
          delivery_attempt.result = "ERROR: #{$!}: #{$@[0]}"
          delivery_attempt.save
        end
      end
    end

    def save_captcha_image(browser, letter)
      captcha_node = browser.page.search(formageddon_form.formageddon_form_captcha_image.css_selector).first
      if captcha_node
        @captcha_image = browser.page.image_urls.select{ |ui| ui =~ /#{Regexp.escape(captcha_node.attributes['src'].value)}/ }.first
      end

      unless @captcha_image.blank?
        # turn following into method
        uri = URI.parse(@captcha_image)
        Net::HTTP.start(uri.host, uri.port) { |http|
          resp = http.get(uri.path)
          open("#{Formageddon::configuration.tmp_captcha_dir}#{letter.id}.jpg", "wb") { |file|
            file.write(resp.body)
           }
        }
      end
    end

    def save_after_error(ex, letter = nil, delivery_attempt = nil, save_states = true)
      @error_msg = "ERROR: #{ex}: #{$@[0]}"

      unless letter.nil?
        if letter.kind_of? Formageddon::FormageddonLetter
          letter.status = @error_msg
          letter.save
        end

        if save_states
          delivery_attempt.result = @error_msg
          delivery_attempt.save
        end
      end
    end

    def generic_confirmation?(content)
      if content =~ /thank you/i or content =~ /message sent/i
        return true
      end

      return false
    end

    def ensure_index
      unless step_number.present?
        self.update_attribute(:step_number, (formageddon_recipient.formageddon_contact_steps.index(self) + 1)) rescue nil
      end
    end
  end
end