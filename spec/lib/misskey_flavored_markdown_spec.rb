# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MisskeyFlavoredMarkdown do
  describe '#to_html' do
    subject { described_class.new(text).to_html }

    context 'when given plain text' do
      let(:text) { 'Beep boop' }

      it 'keeps the plain text' do
        expect(subject).to include 'Beep boop'
      end
    end

    context 'when given text surrounded by underscores' do
      let(:text) { '_my italic text_' }

      it 'adds italics' do
        expect(subject).to include '<i>my italic text</i>'
      end
    end

    context 'when given text surrounded by an underscore only on one side' do
      let(:text) { '_my not-italic text' }

      it 'keeps underscore' do
        expect(subject).to include '_my not-italic text'
      end
    end

    context 'when given text surrounded by underscores inside a sentence' do
      let(:text) { 'This is _my italic text_ can you believe it?' }

      it 'adds italics' do
        expect(subject).to include '<i>my italic text</i>'
      end
    end

    context 'when given text surrounded by underscores next to punctuation' do
      let(:text) { 'This is:_my italic text_!' }

      it 'adds italics' do
        expect(subject).to include ':<i>my italic text</i>!'
      end
    end

    context 'when given snake case text' do
      let(:text) { 'my_snake_case' }

      it 'does not use italics' do
        expect(subject).to include 'my_snake_case'
      end
    end

    context 'when given snake case mentions' do
      let(:text) { '@yassie_j@0w0.is' }

      it 'does not use italics' do
        # mentions only get linked when tags are provided to MisskeyFlavoredMarkdown#new
        expect(subject).to include '@yassie_j@0w0.is'
      end
    end

    context 'when given snake case hashtags' do
      let(:text) { '#my_snake_case' }

      it 'does not use italics' do
        # hashtags only get linked when tags are provided to MisskeyFlavoredMarkdown#new
        expect(subject).to include '#my_snake_case'
      end
    end

    context 'when given text surrounded by asterisks' do
      let(:text) { '*my italic text*' }

      it 'adds italics' do
        expect(subject).to include '<i>my italic text</i>'
      end
    end

    context 'when given text surrounded by an asterisk only on one side' do
      let(:text) { 'this *should stay as-is' }

      it 'keeps asterisk' do
        expect(subject).to include 'this *should stay as-is'
      end
    end

    context 'when given text surrounded by double asterisks' do
      let(:text) { '**my bold text**' }

      it 'adds bold' do
        expect(subject).to include '<b>my bold text</b>'
      end
    end

    context 'when given text surrounded by double asterisks inside a word' do
      let(:text) { 'This text is**bold**ed, can you believe it?' }

      it 'adds bold' do
        expect(subject).to include 'is<b>bold</b>ed'
      end
    end

    context 'when given MFM tags' do
      let(:text) { '$[x2 BIG!]' }

      it 'adds a span with the tag' do
        expect(subject).to include '<span class="mfm mfm-x2" mfm-tag="x2">BIG!</span>'
      end
    end

    context 'when given MFM tags with options' do
      let(:text) { '$[fg.color=FF00FF PINK!]' }

      it 'adds a span with the tag and options' do
        expect(subject).to include '<span class="mfm mfm-fg" mfm-tag="fg" mfm-color="FF00FF">PINK!</span>'
      end
    end

    context 'when given nested MFM tags' do
      let(:text) { '$[x2 $[fg.color=FF00FF PINK!]]' }

      it 'generates nested span tags' do
        expect(subject).to include '<span class="mfm mfm-x2" mfm-tag="x2"><span class="mfm mfm-fg" mfm-tag="fg" mfm-color="FF00FF">PINK!</span></span>'
      end
    end

    context 'when given an unfinished MFM tag' do
      let(:text) { '$[x2 Oops!' }

      it 'writes plain text' do
        expect(subject).to include '$[x2 Oops!'
      end
    end

    context 'when given a plain url' do
      let(:text) { 'https://example.com' }

      it 'adds an anchor tag' do
        expect(subject).to include '<a href="https://example.com">https://example.com</a>'
      end
    end

    context 'when given an anchor link' do
      let(:text) { '[link](https://example.com)' }

      it 'adds an anchor tag' do
        expect(subject).to include '<a href="https://example.com">link</a>'
      end
    end
  end

  describe '#to_html with tags' do
    subject { described_class.new(text, tags: tags).to_html }

    context 'when given hashtags' do
      let(:text) { '#mfm' }
      let(:tags) { [{ 'type' => 'Hashtag', 'name' => '#mfm', 'href' => 'https://kitty.social/tags/mfm' }] }

      it 'linkifies the hashtag' do
        expect(subject).to include '<a href="https://kitty.social/tags/mfm" rel="tag">#mfm</a>'
      end
    end

    context 'when given mentions' do
      let(:text) { '@julia@eepy.moe' }
      let(:tags) { [{ 'type' => 'Mention', 'name' => '@julia@eepy.moe', 'href' => 'https://eepy.moe/users/9i25fxu2sro3sa2y' }] }

      it 'linkifies the mention' do
        expect(subject).to include '<a href="https://eepy.moe/users/9i25fxu2sro3sa2y" class="u-url mention">@julia@eepy.moe</a>'
      end
    end
  end
end
