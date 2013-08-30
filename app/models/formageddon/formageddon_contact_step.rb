module Formageddon
  class FieldNotFound < Exception; end

  class FormageddonContactStep < ActiveRecord::Base
    belongs_to :formageddon_recipient, :polymorphic => true
    has_one :formageddon_form, :dependent => :destroy

    accepts_nested_attributes_for :formageddon_form
    attr_accessor :error_msg, :captcha_image

    after_save :ensure_index

    def self.contact_fields
      @@contact_fields ||= %w(
        title first_name last_name email address1 address2 zip5 zip4
        city state state_house phone issue_area subject message
        submit_button leave_blank captcha_solution
      ).map(&:to_sym)
    end

    def has_captcha?
      command =~ /submit_form/ && formageddon_form.has_captcha?
    end

    def get_elements(browser, selector, options={})
      unless options[:scope]
        options[:scope] = browser.page
      end
      options[:scope].search(selector) rescue []
    end

    def get_element(browser, selector, options={})
      el = get_elements(browser, selector, options).first
      raise FieldNotFound.new "Field (#{selector}) not found!" if el.nil?
      el
    end

    # The following methods alter the browser page state via nokogiri, to then be loaded
    # in as a Mechanize::Form and submitted later
    def fill_in(browser, selector, options={})
      element = get_element(browser, selector)
      if element.name == 'textarea'
        element.inner_html = options[:with]
      else
        get_element(browser, selector)['value'] = options[:with]
      end
    end

    def select(browser, selector, options = {})
      selection = nil
      select = get_element(browser, selector)
      select.children.each do |option|
        option.remove_attribute('selected') rescue nil
        if option['value'] == options[:value]
          selection = option
        end
      end
      if selection.nil?
        value_options = select.children.reject {|o| o['value'].blank? }
        if options[:default] == :random
          return select(browser, selector, :value => value_options[rand(value_options.length)]['value'])
        elsif options[:default] == :first_with_value
          return select(browser, selector, :value => value_options.first['value'])
        elsif options[:default] == :first
          selection = select.children.first
        end
      end
      selection['selected'] = 'selected' if selection.present?
      selection
    end

    def check(browser, selector, options = {})
      element = get_element(browser, selector)
      form = browser.get_form_node_by_css(selector)
      form.search("[name='#{element['name']}']").each do |el|
        el.remove_attribute('checked') rescue nil
      end
      begin
        get_element(browser, selector)['checked'] = 'checked'
      rescue FieldNotFound
        if options[:is_retry]
          raise FieldNotFound.new "Failed to find an appropriate element for #{selector}, giving up."
        end
        # This clause takes the value out of the passed-in selector (if there's no value we shouldn't be here)
        # And checks either the first, first_with_value, or a random choice from the children
        selector = selector.gsub(/\[value=[^\]]+\]/, '')
        choices = get_elements(browser, selector)
        if options[:default] == :random
          check(browser, "#{selector}[value='#{choices[rand(choices.length)]['value']}']", :is_retry => true)
        else
          check(browser, "#{selector}[value='#{choices.first['value']}'", :is_retry => true)
        end
      end
    end

    def uncheck(browser, selector, options = {})
      get_element(browser, selector).remove_attribute('checked') rescue nil
    end

    # TODO: returning value only won't delegate well when values are meaningless
    def select_options_for(browser, selector)
      select = get_element(browser, selector)
      select.children.select{|o| o.name.downcase == 'option' }.map{|o| o['value']}
    end

    ###
    # Override this method to implement a select-box or radio button solver
    # Gets these options:
    #
    # :letter => An instance of the letter being sent
    # :option_list => The possible choices, one of which the implementation of delegate_choice_value should return
    # :type => The normalized name of the form field that's being filled out
    # :default => The result to return if no appropriate match is found
    def delegate_choice_value(options = {})
      raise NotImplementedError
    end

    # TODO: returning value only won't delegate well when values are meaningless
    def radio_options_for(browser, selector)
      radios = get_elements(browser, selector)
      # If this returns a single element, we might have gotten a specific item's selector. Instead we should grab all inputs with this name.
      if radios.length == 1
        selector = "input[type='radio'][name='#{radios.first.attr('name')}']"
        radios = get_elements(browser, selector, :scope => browser.get_form_node_by_css(selector))
      end
      elements.map{|o| o['value']}
    end

    # This creates the browser and iterates over the various form fields
    def execute(browser, options = {})
      raise "Browser is invalid!" unless browser.kind_of? Mechanize

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
              save_captcha_image(browser, letter, delivery_attempt)
            rescue Timeout::Error
              save_after_error("Saving captcha: #{$!}", options[:letter], delivery_attempt, save_states)

              delivery_attempt.save_after_browser_state(browser) if save_states
            end
            return false
          end

          # Do the recaptcha dance if a solution was supplied to a recaptcha form.
          if formageddon_form.has_recaptcha? and letter.captcha_solution.present?
            solution = solve_recaptcha(browser, :letter => letter, :delivery_attempt => delivery_attempt, :save_states => save_states)
            Rails.logger.info("Recaptcha solution was #{solution}")
          end

          formageddon_form.formageddon_form_fields.each do |ff|
            # Recaptcha is already dealt with by the time we get here.
            next if ff.css_selector == '#recaptcha_response_field'

            # TODO: This handles the step (re)building process. Probably should just be deprecated.
            fill_in(browser, ff.css_selector, :with => letter[ff.value]) and next if letter.is_a? Hash
            raise "#{letter} is not a valid FormageddonLetter!" unless letter.is_a? FormageddonLetter

            choices = nil
            value = nil
            field = nil

            # Email fields need special handling due to the possiblity that a plus sign is disallowed.
            # Specifically, we want to receive emails to the site, not the user's email address, but
            # can't in 100% of instances.
            if (ff.value == 'email' &&
                !Formageddon::configuration.reply_domain.nil? &&
                !formageddon_form.use_real_email_address?)
              fill_in(browser, ff.css_selector, :with => "formageddon+#{letter.formageddon_thread.id}@#{Formageddon::configuration.reply_domain}")

            elsif ff.value == 'want_response'
              field = get_element(browser, ff.css_selector)
              if field.name == 'select'
                # get the option list and start with anything named y, yes or true
                choices = select_options_for(browser, ff.css_selector)
                value = choices.select{|o| o =~ /(y(es)?|true)/i }.first['value']
                # if a delegator is set to handle this, use that value instead
                begin
                  value = delegate_choice_value(:letter => letter, :option_list => choices, :type => :want_response, :default => value)
                rescue NotImplementedError; end
                #select whatever option we ended up with
                select_params = { :value => value }
                select_params[:default] = :first_with_value if ff.required?
                select(browser, ff.css_selector, select_params)
              elsif field.name == "input" && field['type'] =~ /(checkbox|radio)/
                check(browser, ff.css_selector)
              else
                fill_in(browser, ff.css_selector, :with => 'Yes')
              end

            elsif ff.value == 'title'
              field = get_element(browser, ff.css_selector)
              value = letter.value_for(ff.value)
              if field.name == 'select'
                choices = select_options_for(browser, ff.css_selector)
                begin
                  value = delegate_choice_value(:letter => letter, :option_list => choices, :type => :title, :default => value)
                rescue NotImplementedError; end
                select(browser, ff.css_selector, :value => value, :default => :random)
              else
                fill_in(browser, ff.css_selector, :with => value)
              end

            elsif ff.value == 'issue_area'
              value = letter.value_for(ff.value)
              field = get_element(browser, ff.css_selector)
              if field.name == 'select' || (field.name == 'input' && field.attr('type') == 'radio')
                if field.name == 'select'
                  choices = select_options_for(browser, ff.css_selector)
                else
                  choices = radio_options_for(ff.css_selector)
                end
                begin
                  value = delegate_choice_value(:letter => letter, :option_list => choices, :type => :issue_area, :default => value)
                rescue NotImplementedError; end
                if value.blank?
                  generic_choices = choices.select{|o| o =~ /(general|other)/i }
                  value = generic_choices.first
                end
                if field.name == 'select'
                  select(browser, ff.css_selector, :value => value, :default => :random)
                else
                  check(browser, "input[name=#{field.attr('name')}][value='#{value}']", :default => :random)
                end
              else
                fill_in(browser, ff.css_selector, value)
              end

            elsif ff.value == 'state_house'
              # TODO: Only one instance of this here, seems to have to do with old writerep house forms
              state = State.find_by_abbreviation(letter.value_for(:state))
              field.value = "#{state.abbreviaion}#{state.name}"

            else
              value = letter.value_for(ff.value)
              field = get_element(browser, ff.css_selector)
              if field.name == 'select'
                choices = select_options_for(browser, ff.css_selector)
                begin
                  value = delegate_choice_value(:letter => letter, :option_list => choices, :type => ff.value.to_sym, :default => value)
                rescue NotImplementedError; end
                select_params = {:value => value}
                select_params[:default] = :first_with_value if ff.required?
                select(browser, ff.css_selector, select_params)
              elsif field.name == 'input' && field['type'] == 'checkbox'
                if ff.value == 'leave_blank' && field['checked'] == 'checked'
                  uncheck(browser, ff.css_selector)
                elsif ff.value != 'leave_blank' && field['checked'] != 'checked'
                  check(browser, ff.css_selector)
                end
              elsif field.name == 'input' && field['type'] == 'radio'
                if ff.value != 'leave_blank' && field['checked'] != 'checked'
                  check(browser, ff.css_selector)
                end
              else
                fill_in(browser, ff.css_selector, :with => value) unless ff.not_changeable?
              end
            end
          end

          # check to see if there are any default params to force
          unless Formageddon::configuration.default_params.empty?
            Formageddon::configuration.default_params.keys.each do |k|
              fields = browser.page.search("[name='#{k}']")
              fields.each do |field|
                field['value'] = Formageddon::configuration.default_params[k]
              end
            end
          end

          # Submit the form.
          begin
            form = browser.get_form_by_css(formageddon_form.submit_css_selector)
            form.submit
          rescue Timeout::Error
            Rails.logger.warn('Timeout! Saving after state...')
            save_after_error($!, options[:letter], delivery_attempt, save_states)

            delivery_attempt.save_after_browser_state(browser) if save_states

            return false
          rescue
            Rails.logger.warn($!)
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
              save_captcha_image(browser, letter, delivery_attempt)

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

    def save_captcha_image(browser, letter, delivery_attempt)
      captcha_node = browser.page.search(formageddon_form.formageddon_form_captcha_image.css_selector).first
      Rails.logger.warn("Getting captcha from #{formageddon_form.formageddon_form_captcha_image.css_selector}")
      if captcha_node
        @captcha_image = browser.page.image_urls.select{ |ui| ui =~ /#{Regexp.escape(captcha_node.attributes['src'].value)}/ }.first
        Rails.logger.warn("Captcha found. Picked out #{@captcha_image} from #{browser.page.image_urls * '\n'}")
      elsif formageddon_form.has_recaptcha?
        @captcha_image = get_recaptcha_image(delivery_attempt)
      end

      unless @captcha_image.blank?
        # turn following into method
        Rails.logger.warn("Writing image to file: #{Formageddon::configuration.tmp_captcha_dir}#{letter.id}.jpg")
        uri = URI.parse(@captcha_image)
        Net::HTTP.start(uri.host, uri.port) { |http|
          resp = http.get("#{uri.path}?#{uri.query}")
          open("#{Formageddon::configuration.tmp_captcha_dir}#{letter.id}.jpg", "wb") { |file|
            file.write(resp.body)
          }
        }
      end
    end

    def get_recaptcha_image(delivery_attempt)
      captcha_form = formageddon_form.formageddon_recaptcha_form
      url = captcha_form.url
      return false if url.nil?
      captcha_browser = Mechanize.new
      captcha_browser.get url
      img = captcha_browser.page.search(captcha_form.image_css_selector)[0].attr('src')
      delivery_attempt.save_captcha_browser_state(captcha_browser)
      "#{url.split(/\/[\w\d-]+\/?\?/)[0]}/#{img}"
    end

    def solve_recaptcha(browser, options = {})
      save_states = options[:save_states]
      delivery_attempt = options[:delivery_attempt]
      letter = options[:letter]
      captcha_form = formageddon_form.formageddon_recaptcha_form
      return false if (letter.nil? || letter.captcha_solution.nil?)
      captcha_browser = Mechanize.new
      delivery_attempt.rebuild_browser(captcha_browser, 'captcha')
      fill_in(captcha_browser, captcha_form.response_field_css_selector, :with => letter.captcha_solution)
      form = captcha_browser.get_form_by_css(captcha_form.response_field_css_selector)
      begin
        form.submit
        code = captcha_browser.page.search('textarea').first.text
        fill_in(browser, "textarea[name=recaptcha_challenge_field]", :with => code)
      rescue Timeout::Error
        save_after_error($!, options[:letter], delivery_attempt, save_states)
      rescue
        save_captcha_image(browser, letter, delivery_attempt)
        if save_states
          delivery_attempt.result = 'CAPTCHA_WRONG'
          delivery_attempt.save
        end
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