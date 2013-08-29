class Mechanize
  # this is an extended method to rebuild the browser state from the database
  def rebuild_page(url, cookie_jar, body)
    # cookie jar is assumed to be serialized into YAML
    self.cookie_jar = YAML.load(cookie_jar)

    p = Mechanize::Page.new(URI.parse(url), {'content-type' => 'text/html'}, body, 200, self)

    add_to_history(p)
  end

  def get_form_node_by_css(selector)
    # get form by traversing up from a given selector
    begin
      form = page.search(selector).first
      return form if form.name == 'form'
      while form.name != 'form'
        form = form.parent
      end
    rescue NoMethodError
      # got to the top of the tree, or the selector isn't on the page
      form = nil
    end
    raise "#{selector} is not nested in a form" unless form.present?
    form
  end

  def get_form_by_css(selector)
    return Mechanize::Form.new(get_form_node_by_css(selector), self, page)
  end
end