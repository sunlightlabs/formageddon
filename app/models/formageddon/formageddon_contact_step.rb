module Formageddon
  class FieldNotFound < Exception; end

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

    def set_browser(browser)
      @browser = browser
    end

    def get_elements(selector, options={})
      unless options[:scope]
        options[:scope] = @browser.page
      end
      options[:scope].search(selector) rescue []
    end

    def get_element(selector, options={})
      el = get_elements(selector, options).first
      raise FieldNotFound "Field (#{ff.css_selector}) not found!" if el.nil?
      el
    end

    # The following methods alter the browser page state via nokogiri, to then be loaded
    # in as a Mechanize::Form and submitted later
    def fill_in(selector, options={})
      element = get_element(selector)
      if element.name == 'textarea'
        element.inner_html = options[:with]
      else
        get_element(selector)['value'] = options[:with]
      end
    end

    def select(selector, options = {})
      selection = nil
      select = get_element selector
      select.children.each do |option|
        option.remove_attribute('selected') rescue nil
        if option['value'] == options[:value]
          selection = option
        end
      end
      if selection.nil?
        value_options = select.children.reject {|o| o['value'].blank? }
        if options[:default] == :random
          return select(selector, :value => value_options[rand(value_options.length)]['value'])
        elsif options[:default] == :first_with_value
          return select(selector, :value => value_options.first['value'])
        elsif options[:default] == :first
          selection = select.children.first
        end
      end
      selection['selected'] = 'selected' if selection.present?
      selection
    end

    def check(selector, options = {})
      element = get_element(selector)
      form = @browser.get_form_node_by_css(selector)
      form.search("[name='#{element['name']}']").each do |el|
        el.remove_attribute('checked') rescue nil
      end
      begin
        get_element(selector)['checked'] = 'checked'
      rescue FieldNotFound
        if options[:is_retry]
          raise FieldNotFound "Failed to find an appropriate element for #{selector}, giving up."
        end
        # This clause takes the value out of the passed-in selector (if there's no value we shouldn't be here)
        # And checks either the first, first_with_value, or a random choice from the children
        selector = selector.gsub(/\[value=[^\]]+\]/, '')
        choices = get_elements(selector)
        if options[:default] == :random
          check("#{selector}[value='#{choices[rand(choices.length)]['value']}']", :is_retry => true)
        else
          check("#{selector}[value='#{choices.first['value']}'", :is_retry => true)
        end
      end
    end

    def uncheck(selector, options = {})
      get_element(selector).remove_attribute('checked') rescue nil
    end

    # TODO: returning value only won't delegate well when values are meaningless
    def select_options_for(selector)
      select = get_element selector
      select.children.filter{|o| o.name.downcase == 'option' }.map{|o| o['value']}
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
    def radio_options_for(selector)
      radios = get_elements selector
      # If this returns a single element, we might have gotten a specific item's selector. Instead we should grab all inputs with this name.
      if radios.length == 1
        selector = "input[type='radio'][name='#{radios.first.attr('name')}']"
        radios = get_elements(selector, :scope => @browser.get_form_node_by_css(selector))
      end
      elements.map{|o| o['value']}
    end

    # This creates the browser and iterates over the various form fields
    def execute(browser, options = {})
      set_browser(browser)
      raise "Browser is invalid!" unless @browser.kind_of? Mechanize

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
            @browser.get(url) do |page|
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

          delivery_attempt.save_before_browser_state(@browser) if save_states

          if formageddon_form.has_captcha? and letter.captcha_solution.nil?
            letter.status = 'CAPTCHA_REQUIRED'
            letter.save

            if save_states
               delivery_attempt.result = 'CAPTCHA_REQUIRED'
               delivery_attempt.save
            end

            begin
              save_captcha_image(@browser, letter)
            rescue Timeout::Error
              save_after_error("Saving captcha: #{$!}", options[:letter], delivery_attempt, save_states)

              delivery_attempt.save_after_browser_state(@browser) if save_states
            end
            return false
          end

          formageddon_form.formageddon_form_fields.each do |ff|
            # TODO: This handles the step (re)building process. Probably should just be deprecated.
            fill_in(ff.css_selector, :with => letter[ff.value]) and next if letter.is_a? Hash
            raise "#{letter} is not a valid FormageddonLetter!" unless letter.is_a? FormageddonLetter

            options = nil
            value = nil
            field = nil

            # Email fields need special handling due to the possiblity that a plus sign is disallowed.
            # Specifically, we want to receive emails to the site, not the user's email address, but
            # can't in 100% of instances.
            if (ff.value == 'email' &&
                !Formageddon::configuration.reply_domain.nil? &&
                !formageddon_form.use_real_email_address?)
              fill_in(ff.css_selector, :with => "formageddon+#{letter.formageddon_thread.id}@#{Formageddon::configuration.reply_domain}")

            elsif ff.value == 'want_response'
              field = get_element(ff.css_selector)
              if field.name == 'select'
                # get the option list and start with anything named y, yes or true
                options = select_options_for(ff.css_selector)
                value = options.select{|o| o =~ /(y(es)?|true)/i }.first['value']
                # if a delegator is set to handle this, use that value instead
                begin
                  value = delegate_choice_value(:letter => letter, :option_list => options, :type => :want_response, :default => value)
                rescue NotImplementedError; end
                #select whatever option we ended up with
                options = { :value => value }
                options[:default] = :first_with_value if ff.required?
                select(ff.css_selector, options)
              elsif field.name == "input" && field['type'] =~ /(checkbox|radio)/
                check(ff.css_selector)
              else
                fill_in(ff.css_selector, :with => 'Yes')
              end

            elsif ff.value == 'title'
              field = get_element(ff.css_selector)
              value = letter.value_for(ff.value)
              if field.name == 'select'
                options = select_options_for(ff.css_selector)
                begin
                  value = delegate_choice_value(:letter => letter, :option_list => options, :type => :title, :default => value)
                rescue NotImplementedError; end
                select(ff.css_selector, :value => value, :default => :random)
              else
                fill_in(ff.css_selector, :with => value)
              end

            elsif ff.value == 'issue_area'
              value = letter.value_for(ff.value)
              field = get_element(ff.css_selector)
              if field.name == 'select' || (field.name == 'input' && field.attr('type') == 'radio')
                if field.name == 'select'
                  options = select_options_for(ff.css_selector)
                else
                  options = radio_options_for(ff.css_selector)
                end
                begin
                  value = delegate_choice_value(:letter => letter, :option_list => options, :type => :issue_area, :default => value)
                rescue NotImplementedError; end
                if value.blank?
                  generic_options = options.select{|o| o =~ /(general|other)/i }
                  value = generic_options.first
                end
                if field.name == 'select'
                  select(ff.css_selector, :value => value, :default => :random)
                else
                  check("input[name=#{field.attr('name')}][value='#{value}']", :default => :random)
                end
              else
                fill_in(ff.css_selector, value)
              end

            elsif ff.value == 'state_house'
              # TODO: Only one instance of this here, seems to have to do with old writerep house forms
              state = State.find_by_abbreviation(letter.value_for(:state))
              field.value = "#{state.abbreviaion}#{state.name}"

            else
              value = letter.value_for(ff.value)
              field = get_element(ff.css_selector)
              if field.name == 'select'
                options = select_options_for(ff.css_selector)
                begin
                  value = delegate_choice_value(:letter => letter, :option_list => options, :type => ff.value.to_sym, :default => value)
                rescue NotImplementedError; end
                opts = {:value => value}
                opts[:default] = :first_with_value if ff.required?
                select(ff.css_selector, opts)
              elsif field.name == 'input' && field['type'] == 'checkbox'
                if ff.value == 'leave_blank' && field['checked'] == 'checked'
                  uncheck(ff.css_selector)
                elsif ff.value != 'leave_blank' && field['checked'] != 'checked'
                  check(ff.css_selector)
                end
              elsif field.name == 'input' && field['type'] == 'radio'
                if ff.value != 'leave_blank' && field.unchecked?
                  field.check
                end
              else
                fill_in(ff.css_selector, :with => value) unless ff.not_changeable?
              end
            end
          end

          # check to see if there are any default params to force
          unless Formageddon::configuration.default_params.empty?
            Formageddon::configuration.default_params.keys.each do |k|
              fields = @browser.page.search("[name='#{k}']")
              fields.each do |field|
                field['value'] = Formageddon::configuration.default_params[k]
              end
            end
          end

          # Submit the form.
          begin
            form = @browser.get_form_by_css(formageddon_form.submit_css_selector)
            form.submit
          rescue Timeout::Error
            save_after_error($!, options[:letter], delivery_attempt, save_states)

            delivery_attempt.save_after_browser_state(@browser) if save_states

            return false
          rescue
            save_after_error($!, options[:letter], delivery_attempt, save_states)

            delivery_attempt.save_after_browser_state(@browser) if save_states

            return false
          end

          if ((!formageddon_form.success_string.blank? and (@browser.page.parser.to_s =~ /#{formageddon_form.success_string}/)) or generic_confirmation?(@browser.page.parser.to_s))
            if letter.kind_of? Formageddon::FormageddonLetter
              letter.status = 'SENT'
              letter.save
            end

            if save_states
              delivery_attempt.result = 'SUCCESS'
              delivery_attempt.save

              # save on success for now, just in case we start getting false positives here
              delivery_attempt.save_after_browser_state(@browser)
            end

            return true

          elsif formageddon_form.success_string.blank?
            formageddon_form.success_string.blank? and !generic_confirmation?(@browser.page.parser.to_s)

            if letter.kind_of? Formageddon::FormageddonLetter
              letter.status = 'WARNING: Confirmation message is blank. Unable to confirm delivery.'
              letter.save
            end

            if save_states
              delivery_attempt.save_after_browser_state(@browser)

              delivery_attempt.result = 'WARNING: Confirmation message is blank. Unable to confirm delivery.'
              delivery_attempt.save
            end

            return true
          else
            # save the browser state in the delivery attempt
            delivery_attempt.save_after_browser_state(@browser) if save_states

            if letter.status == 'TRYING_CAPTCHA'
              # assume that the captcha was wrong?
              letter.status = 'CAPTCHA_REQUIRED'
              save_captcha_image(@browser, letter)

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