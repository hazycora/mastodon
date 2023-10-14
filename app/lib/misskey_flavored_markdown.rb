# frozen_string_literal: true

class MisskeyFlavoredMarkdown
  include ERB::Util
  include JsonLdHelper
  include RoutingHelper

  # sparkle tags are ignored because they require adding new elements to the DOM and I simply don't want to deal with that right now
  MFM_TAGS = %w(sparkle small crop tada jelly twitch spin jump bounce font fade shake rainbow flip x2 x3 x4 blur rotate position scale fg bg).freeze
  MFM_XML_TAGS_NORMAL = %w(small center).freeze
  MFM_XML_TAGS = (MFM_XML_TAGS_NORMAL + %w(plain)).freeze
  NORMAL_STATES = ([:in_tag, :in_link_text, :in_xml_tag, 'i_', 'i*', 'b', 's'] + MFM_XML_TAGS_NORMAL).freeze
  MFM_TOKEN_OPENER_RE = /\A\$\[(?<tag>#{Regexp.union(MFM_TAGS)})(?:\.(?<opt>\S+))?[\s\u3000]\z/
  POST_TAGS = %w(Hashtag Mention).freeze
  ANCHOR_URL_ALLOWED_RE = %r{\Ahttps?://[a-z0-9\/\._~:?#\[\]@!$&()hn+%=]+\z}i
  MARKDOWN_FORMATTING_SYMBOLS = %w(* _ ~ `).freeze

  PUNCTUATION_RE_S = '\u0021-\u002f\u003A-\u0040\u005B-\u0060\u007B-\u007E\p{P}'
  WHITESPACE_RE_S = '\u0009\u000A\u000C\u000D\p{Zs}'

  PUNCTUATION_RE = Regexp.new("[#{PUNCTUATION_RE_S}]")
  WHITESPACE_RE = Regexp.new("[#{WHITESPACE_RE_S}]|$|^")
  EITHER_RE = Regexp.new("[#{PUNCTUATION_RE_S}#{WHITESPACE_RE_S}]|$|^")
  NEITHER_RE = Regexp.new("[^#{PUNCTUATION_RE_S}#{WHITESPACE_RE_S}]")

  # \A..[^\u0021-\u002f\u003A-\u0040\u005B-\u0060\u007B-\u007E\p{P}\u0009\u000A\u000C\u000D\p{Zs}]\z
  LEFT_FLANKING_RE = Regexp.union(/\A..#{NEITHER_RE}\z/, /\A#{EITHER_RE}.#{PUNCTUATION_RE}\z/)
  # \A[^\u0021-\u002f\u003A-\u0040\u005B-\u0060\u007B-\u007E\p{P}\u0009\u000A\u000C\u000D\p{Zs}]..\z
  # \A[\u0021-\u002f\u003A-\u0040\u005B-\u0060\u007B-\u007E\p{P}].[\u0021-\u002f\u003A-\u0040\u005B-\u0060\u007B-\u007E\p{P}\u0009\u000A\u000C\u000D\p{Zs}]\z
  RIGHT_FLANKING_RE = Regexp.union(/\A#{NEITHER_RE}..\z/, /\A#{PUNCTUATION_RE}.#{EITHER_RE}\z/)

  def initialize(text, tags: [])
    @text = text
    @tags = tags || []
    @states = []
    @link = nil
  end

  def to_html
    html = []
    text = @text.dup

    skip_to_i = 0

    each_char = lambda do |char, i|
      next if skip_to_i > i

      command = handle_char(char, { text: text, i: i })
      if command[:closes]
        state_i = @states.length
        html.reverse_each do |token|
          next if token.is_a?(String)

          next if token[:state_i] != state_i

          token[:string] = token[:html] if token[:html]
          break
        end
        @states.pop
      end
      skip_to_i = i + command[:skip] if command[:skip]
      @states = command[:states] if command[:states]

      next if command[:string].nil?

      if @link.nil?
        html << (command[:html].nil? ? command[:string] : { string: command[:string], html: command[:html], state_i: @states.length })
      else
        @link[:text] << command[:string]
      end
    end

    text.chars.each_with_index do |char, i|
      each_char.call(char, i)
    end

    each_char.call('', text.length)

    return '' if html.blank?

    html = join_tokens(html)

    html = rewrite(html) do |entity|
      if entity[:tag_type] == 'Hashtag'
        link_to_hashtag(entity)
      elsif entity[:tag_type] == 'Mention'
        link_to_mention(entity)
      elsif entity[:url]
        link_to_url(entity)
      end
    end

    html.html_safe # rubocop:disable Rails/OutputSafety
  end

  private

  def join_tokens(tokens)
    strings = tokens.map { |token| token.is_a?(String) ? token : token[:string] }
    strings.join
  end

  def rewrite(html)
    src = html.gsub(Sanitize::REGEX_UNSUITABLE_CHARS, '')
    tree = Nokogiri::HTML5.fragment(src)
    document = tree.document

    tree.xpath('.//text()[not(ancestor::a | ancestor::code | ancestor::plain)] | text()').each do |text_node|
      # Iterate over text elements and build up their replacements.
      content = text_node.content
      replacement = Nokogiri::XML::NodeSet.new(document)
      processed_index = 0
      extract_entities_with_indices(
        content
      ) do |entity|
        # Iterate over entities in this text node.
        advance = entity[:indices].first - processed_index
        if advance.positive?
          # Text node for content which precedes entity.
          replacement << Nokogiri::XML::Text.new(
            content[processed_index, advance],
            document
          )
        end
        template = yield(entity)
        replacement << Nokogiri::HTML5.fragment(template)
        processed_index = entity[:indices].last
      end
      if processed_index < content.size
        # Text node for remaining content.
        replacement << Nokogiri::XML::Text.new(
          content[processed_index, content.size - processed_index],
          document
        )
      end
      text_node.replace(replacement)
    end

    tree.xpath('.//plain').each do |node|
      node.name = 'span'
    end

    tree.to_html
  end

  def link_to_url(entity)
    url = entity[:url]

    <<~HTML.squish
      <a href="#{h(url)}">#{h(url)}</a>
    HTML
  end

  def link_to_hashtag(entity)
    text = entity[:text]
    url = entity[:url]

    <<~HTML.squish
      <a href="#{h(url)}" rel="tag">#{h(text)}</a>
    HTML
  end

  def link_to_mention(entity)
    url = entity[:url]
    screen_name = entity[:text].delete_prefix('@')
    username, domain = screen_name.split('@')
    domain = Addressable::URI.parse(url).host if domain.nil?

    domain = if tag_manager.local_domain?(domain) || tag_manager.web_domain?(domain)
               nil
             else
               tag_manager.normalize_domain(domain)
             end

    mentioned_account = entity_cache.mention(username, domain)
    mentioned_account ||= Account.select(:id, :username, :domain, :uri, :url).find_by(uri: url)
    url = mentioned_account['url'] || short_account_url(mentioned_account) unless mentioned_account.nil?

    <<~HTML.squish
      <a href="#{h(url)}" class="u-url mention">@#{h(screen_name)}</a>
    HTML
  end

  def extract_entities_with_indices(text, &block)
    entities = Extractor.extract_urls_with_indices(text, extract_url_without_protocol: false) +
               extract_tags_with_indices(text)

    return [] if entities.empty?

    entities = Extractor.remove_overlapping_entities(entities)
    entities.each(&block) if block
    entities
  end

  def extract_tags_with_indices(text, _options = {})
    possible_entries = []

    @tags.each do |tag|
      hash = {
        text: tag['name'],
        url: tag['href'],
        tag_type: tag['type'],
      }
      next unless POST_TAGS.include?(hash[:tag_type])

      text.scan(tag['name']) do
        match_data = $LAST_MATCH_INFO
        start_position = match_data.char_begin(0)
        end_position   = match_data.char_end(0)
        hash[:indices] = [start_position, end_position]
        possible_entries << hash
      end
    end

    if block_given?
      possible_entries.each do |tag|
        yield tag[:text], tag[:url], tag[:tag_type], tag[:indices].first, tag[:indices].last
      end
    end

    possible_entries
  end

  def token_opener_to_html(token, match)
    tag = match[:tag]
    # if tag isn't supported, just return the token string as-is
    return token unless MFM_TAGS.include?(tag)

    opt = match[:opt]&.split(',')&.map do |string|
      key_value = string.split('=')
      "mfm-#{h(key_value[0])}=\"#{h(key_value[1])}\""
    end&.join(' ')

    <<~HTML.squish
      <span class="mfm mfm-#{h(tag)}" mfm-tag="#{h(tag)}" #{opt}>
    HTML
  end

  MD_FORMATTING_CODES = {
    'b' => {
      logic: lambda { |this_run, _previous_char, _next_char|
        left_flanking = this_run.match?(LEFT_FLANKING_RE)
        right_flanking = this_run.match?(RIGHT_FLANKING_RE)
        {
          can_open: left_flanking,
          can_close: right_flanking,
        }
      },
      code: '**',
      open: '<b>',
      close: '</b>',
    },
    'i*' => {
      logic: lambda { |this_run, _previous_char, _next_char|
        left_flanking = this_run.match?(LEFT_FLANKING_RE)
        right_flanking = this_run.match?(RIGHT_FLANKING_RE)
        {
          can_open: left_flanking,
          can_close: right_flanking,
        }
      },
      code: '*',
      open: '<i>',
      close: '</i>',
    },
    'i_' => {
      logic: lambda { |this_run, previous_char, next_char|
        left_flanking = this_run.match?(LEFT_FLANKING_RE)
        right_flanking = this_run.match?(RIGHT_FLANKING_RE)
        Rails.logger.info "this_run: #{this_run}, left_flanking: #{left_flanking}, right_flanking: #{right_flanking}"
        {
          can_open: left_flanking && (!right_flanking || previous_char.match?(PUNCTUATION_RE)),
          can_close: right_flanking && (!left_flanking || next_char.match?(PUNCTUATION_RE)),
        }
      },
      code: '_',
      open: '<i>',
      close: '</i>',
    },
    's' => { code: '~', open: '<s>', close: '</s>' },
    'code' => { code: '`', open: '<code>', close: '</code>' },
    'precode' => { code: '```', open: '<pre><code>', close: '</code></pre>' },
  }.to_h do |index, hash|
    hash[:state] = index
    [index, hash]
  end.freeze

  def md_formatting_char(char, context, state)
    i = context[:i]
    text = context[:text]
    double_previous_char = i - 2 >= 0 ? text[i - 2] : ' '
    previous_char = i - 1 >= 0 ? text[i - 1] : ' '
    next_char = i + 1 < text.length ? text[i + 1] : ' '
    md = nil
    this_run = "#{previous_char}#{char}#{next_char}"

    case char
    when '*'
      return {} if next_char == char

      if previous_char == char
        this_run = "#{double_previous_char}#{char}#{next_char}"
        md = MD_FORMATTING_CODES['b']
      else
        md = MD_FORMATTING_CODES['i*']
      end
    when '_'
      md = MD_FORMATTING_CODES['i_']
    when '~'
      return {} if next_char == char || previous_char != char

      md = MD_FORMATTING_CODES['s']
    when '`'
      return {} if next_char == char

      md = double_previous_char == char && previous_char == char ? MD_FORMATTING_CODES['precode'] : MD_FORMATTING_CODES['code']
    end

    logic = md[:logic].nil? ? { can_open: true, can_close: true } : md[:logic].call(this_run, previous_char, next_char)

    if state == md[:state]
      return { string: md[:code] } unless logic[:can_close]

      return { closes: true, string: md[:close] }
    end
    return { string: md[:code] } unless logic[:can_open]

    @states << md[:state]
    { string: md[:code], html: md[:open] }
  end

  def normal_state
    state = @states[-1]
    state.nil? || NORMAL_STATES.include?(state)
  end

  def handle_md(char, context)
    state = @states[-1]

    if MARKDOWN_FORMATTING_SYMBOLS.include?(char) && (normal_state || MD_FORMATTING_CODES.each_value { |format| format[:state] }.include?(state))
      md = md_formatting_char(char, context, state)
      return md unless md.nil?
    end

    return unless %w(code precode).include?(state)

    { string: h(char) }
  end

  def get_remaining_text(context)
    text = context[:text]
    i = context[:i]
    i >= text.length - 1 ? '' : text[i + 1..]
  end

  def handle_xml_tag(char, context)
    state = @states[-1]

    return unless char == '<' && (normal_state || state == 'plain')

    remaining_text = get_remaining_text(context)
    closing = remaining_text[0] == '/'
    tag_name = remaining_text.delete_prefix('/').split('>')[0]
    if MFM_XML_TAGS.include?(tag_name) && (!closing || state != tag_name)
      @states << tag_name
      xml_tag = "<#{h(tag_name)}>"
      { skip: xml_tag.length, string: h(xml_tag), html: xml_tag }
    elsif closing && state == tag_name
      xml_tag = "</#{h(tag_name)}>"
      { skip: xml_tag.length, closes: true, string: xml_tag }
    end
  end

  def handle_mfm_tag(char, context)
    return unless normal_state && char == '$'

    remaining_text = get_remaining_text(context)
    return unless remaining_text.start_with?('[')

    tag_options = remaining_text.delete_prefix('[').split(/[ \t\u3000]/)[0]
    space = remaining_text[tag_options.length + 1]
    src = "$[#{tag_options}#{space}"
    match = MFM_TOKEN_OPENER_RE.match(src)
    return if match.nil?

    @states << :in_tag
    { skip: src.length, string: src, html: token_opener_to_html(src, match) }
  end

  def handle_link_href(_char, context)
    @states.pop
    remaining_text = get_remaining_text(context)
    return unless remaining_text.start_with?('(') && remaining_text.include?(')')

    url = remaining_text.delete_prefix('(').split(')')[0]

    return unless url.match?(ANCHOR_URL_ALLOWED_RE)

    text = @link[:text]
    @link = nil
    { skip: "](#{url})".length, string: "<a href=\"#{url}\">#{join_tokens(text)}</a>" }
  end

  def handle_char(char, context)
    md = handle_md(char, context) || handle_xml_tag(char, context) || handle_mfm_tag(char, context)
    return md unless md.nil?

    state = @states[-1]
    # difference compared to state == :in_link_text is that in_link_text is true even if there have been tags inside the link text
    in_link_text = @states.include?(:in_link_text)

    case char
    when "\n"
      return { string: '<br>' }
    when '['
      if normal_state && !in_link_text
        @states << :in_link_text
        @link = { text: [], url: '' }
        return {}
      end
    when ']'
      if state == :in_tag
        return { closes: true, string: '</span>' }
      elsif state == :in_link_text
        link = handle_link_href(char, context)

        return link unless link.nil?

        link_text = @link[:text]
        @link = nil
        return { string: "[#{join_tokens(link_text)}]" }
      end
    end
    handle_char_fallback(char)
  end

  def handle_char_fallback(char)
    case @states[-1]
    when :in_link_text
      @link = { text: [], url: '' } if @link.nil?
      @link[:text] << char
    else
      return { string: h(char) }
    end
    {}
  end

  def tag_manager
    @tag_manager ||= TagManager.instance
  end

  def entity_cache
    @entity_cache ||= EntityCache.instance
  end

  delegate :local_domain?, to: :tag_manager
  delegate :web_domain?, to: :tag_manager
end

# https://github.com/twitter/twitter-text/blob/30e2430d90cff3b46393ea54caf511441983c260/rb/lib/twitter-text/extractor.rb#L8-L49

# this cop crashes rubocop so it's disabled
# rubocop:disable Performance/RedundantStringChars
class String
  # Helper function to count the character length by first converting to an
  # array.  This is needed because with unicode strings, the return value
  # of length may be incorrect
  def codepoint_length
    chars.is_a?(Enumerable) ? chars.to_a.size : chars.size
  end

  # Helper function to convert this string into an array of unicode code points.
  def to_codepoint_a
    if chars.is_a?(Enumerable)
      chars.to_a
    else
      codepoint_array = []
      0.upto(codepoint_length - 1) do |i|
        codepoint_array << [self[i].chars].pack('U')
      end
      codepoint_array
    end
  end
end
# rubocop:enable Performance/RedundantStringChars

# Helper functions to return code point offsets instead of byte offsets.
class MatchData
  def char_begin(num)
    string[0, self.begin(num)].codepoint_length
  end

  def char_end(num)
    string[0, self.end(num)].codepoint_length
  end
end
