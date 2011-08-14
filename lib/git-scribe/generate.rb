class GitScribe
  module Generate
    # generate the new media
    def gen(args = [])
      @done = {}  # what we've generated already

      type = first_arg(args) || 'all'
      prepare_output_dir

      gather_and_process

      types = type == 'all' ? OUTPUT_TYPES : [type]

      ret = false
      output = []
      Dir.chdir("output") do
        types.each do |out_type|
          call = 'do_' + out_type
          if self.respond_to? call
            ret = self.send call
          else
            die "NOT A THING: #{call}"
          end
        end
        # clean up
        `rm #{BOOK_FILE}`
        ret
      end
    end

    def prepare_output_dir
      Dir.mkdir('output') rescue nil
      Dir.chdir('output') do
        Dir.mkdir('stylesheets') rescue nil
        from_stdir = File.join(SCRIBE_ROOT, 'stylesheets')
        FileUtils.cp_r from_stdir, '.'
      end
    end

    def a2x(type)
      "a2x -f #{type} -d book "
    end

    def a2x_wss(type)
      a2x(type) + " --stylesheet=stylesheets/scribe.css"
    end

    def do_docbook
      return true if @done['docbook']
      info "GENERATING DOCBOOK"

      if ex("asciidoc -b docbook --doctype book -v #{BOOK_FILE}")
        @done['docbook'] = true
        'book.xml'
      end
    end

    def do_pdf
      info "GENERATING PDF"
      do_docbook
      # TODO: syntax highlighting (fop?)
      strparams = {'callout.graphics' => 0,
                   'navig.graphics' => 0,
                   'admon.textlabel' => 1,
                   'admon.graphics' => 0,
                   'page.width' => '7.5in',
                   'page.height' => '9in',
                   'initial-page-number' => 'auto-odd'
      }
      param = strparams.map { |k, v| "--stringparam #{k} #{v}" }.join(' ')
      cmd = "xsltproc  --nonet #{param} --output #{local('book.fo')} #{base('docbook-xsl/fo.xsl')} #{local('book.xml')}"
      ex(cmd)
      cmd = "fop -fo #{local('book.fo')} -pdf #{local('book.pdf')}"
      ex(cmd)
      if $?.exitstatus == 0
        'book.pdf'
      end
    end

    def do_epub
      return true
      return true if @done['epub']

      info "GENERATING EPUB"

      generate_docinfo
      # TODO: look for custom stylesheets
      cmd = "#{a2x_wss('epub')} -a docinfo -k -v #{BOOK_FILE}"
      return false unless ex(cmd)

      @done['epub'] = true
    end

    def do_mobi
      return true if @done['mobi']

      do_epub

      info "GENERATING MOBI"

      decorate_epub_for_mobi

      cmd = "kindlegen -verbose book_for_mobi.epub -o book.mobi"
      return false unless ex(cmd)

      @done['mobi'] = true
    end

    def do_html
      return true if @done['html']
      info "GENERATING HTML"

      # TODO: look for custom stylesheets
      cmd = "#{a2x_wss('xhtml')} -a docinfo -v #{BOOK_FILE}"
      return false if ex(cmd)

      clean_html('book.html')
      @done['html'] = true
    end

    def clean_html(file)
      content = File.read(file)
      File.open(file, 'w') do |f|
        f.write content.
          gsub(%r"<li(.*?)>\s*(.+?)\s*</li>"m, '<li\1>\2</li>').
          gsub(%r'<h([23] class="title".*?)><a (id=".+?")></a>'m, '<h\1 \2>')
      end
    end

    def do_site
      info "GENERATING SITE"
      # TODO: check if html was already done
      ex("asciidoc -b docbook #{BOOK_FILE}")
      xsldir = base('docbook-xsl/xhtml')
      ex("xsltproc --stringparam html.stylesheet stylesheets/scribe.css --nonet #{xsldir}/chunk.xsl book.xml")

      source = File.read('index.html')
      html = Nokogiri::HTML.parse(source, nil, 'utf-8')

      sections = []
      c = -1

      # each chapter
      html.css('.toc > dl').each do |section|
        section.children.each do |item|
          if item.name == 'dt' # section
            c += 1
            sections[c] ||= {'number' => c}
            link = item.css('a').first
            sections[c]['title'] = title = link.text
            sections[c]['href'] = href = link['href']
            clean_title = title.downcase.gsub(/[^a-z0-9\-_]+/, '_') + '.html'
            sections[c]['link'] = clean_title
            if href[0, 10] == 'index.html'
              sections[c]['link'] = 'title.html'
            end
            sections[c]['sub'] = []
          end
          if item.name == 'dd' # subsection
            item.css('dt').each do |sub|
              link = sub.css('a').first
              data = {}
              data['title'] = title = link.text
              data['href'] = href = link['href']
              data['link'] = sections[c]['link'] + '#' + href.split('#').last
              sections[c]['sub'] << data
            end
          end
        end
      end

      book_title = html.css('head > title').text
      content = html.css('body > div')[1]
      content.css('.toc').first.remove
      content = content.inner_html

      sections.each do |s|
        content.gsub!(s['href'], s['link'])
      end

      template_dir = File.join(SCRIBE_ROOT, 'site', 'default')

      # copy the template files in
      files = Dir.glob(template_dir + '/*')
      FileUtils.cp_r files, '.'

      index_template = liquid_template('index.html')
      page_template = liquid_template('page.html')

      # write the index page
      main_data = {
        'book_title' => book_title,
        'sections' => sections
      }
      File.open('index.html', 'w+') do |f|
        f.puts index_template.render( main_data )
      end

      # write the title page
      File.open('title.html', 'w+') do |f|
        data = {
          'title' => sections.first['title'],
          'sub' => sections.first['sub'],
          'prev' => {'link' => 'index.html', 'title' => "Main"},
          'home' => {'link' => 'index.html', 'title' => "Home"},
          'next' => sections[1],
          'content' => content
        }
        data.merge!(main_data)
        f.puts page_template.render( data )
      end

      # write the other pages
      sections.each_with_index do |section, i|

        if i > 0 # skip title page
          source = File.read(section['href'])
          html = Nokogiri::HTML.parse(source, nil, 'utf-8')

          content = html.css('body > div')[1].to_html
          sections.each do |s|
            content.gsub!(s['href'], s['link'])
          end

          File.open(section['link'], 'w+') do |f|
            next_section = nil
            if i <= sections.size
              next_section = sections[i+1]
            end
            data = {
              'title' => section['title'],
              'sub' => section['sub'],
              'prev' => sections[i-1],
              'home' => {'link' => 'index.html', 'title' => "Home"},
              'next' => next_section,
              'content' => content
            }
            data.merge!(main_data)
            f.puts page_template.render( data )
          end
          #File.unlink(section['href'])

          info i
          info section['title']
          info section['href']
          info section['link']
        end

        #File.unlink
      end
      sections
    end

    def generate_docinfo
      docinfo_template = liquid_template('book-docinfo.xml')
      File.open('book-docinfo.xml', 'w+') do |f|
        cover  = @config['cover'] || 'images/cover.jpg'
        data = {'title'       => book_title,
                'cover_image' => cover}
        f.puts docinfo_template.render( data )
      end
    end

    def book_title
      do_html

      source = File.read("book.html")
      t = /\<title>(.*?)<\/title\>/.match(source)

      t ? t[1] : 'Title'
    end


    def decorate_epub_for_mobi
      add_epub_etype
      add_epub_toc
      flatten_ncx
      zip_epub_for_mobi
    end

    def add_epub_etype
      Dir.chdir('book.epub.d') do
        FileUtils.cp 'mimetype', 'etype'
      end
    end

    def add_epub_toc
      build_html_toc
      add_html_toc_to_opf
    end

    def build_html_toc
      Dir.chdir('book.epub.d/OEBPS') do
        ncx = File.read('toc.ncx')
        titles = ncx.scan(%r{^          <ncx:text>(.+?)</ncx:text>}m).flatten
        urls = ncx.scan(%r{^        <ncx:content src="(.+?)"/>}m).flatten

        titles_and_urls = titles.zip(urls).reject { |entry|
          entry[1].match(/^pr\d+.html$/) &&
          !entry[0].match(/introduction/i)
        }

        File.open("toc.html", 'w') do |f|
          f.puts('<?xml version="1.0" encoding="UTF-8"?>')
          f.puts('<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Table of Contents</title></head><body>')
          titles_and_urls.each do |entry|
            f.puts <<_EOM
<div>
<span class="chapter">
<a href="#{entry[1]}">#{entry[0]}</a>
</span>
</div>
_EOM
          end
          f.puts('</body></html>')
        end
      end
    end

    def add_html_toc_to_opf
      Dir.chdir('book.epub.d/OEBPS') do
        opf = File.read('content.opf')
        opf = add_html_toc_to_opf_manifest(opf)
        opf = add_html_toc_to_opf_spine(opf)
        opf = add_html_toc_to_opf_guide(opf)
        File.open('content.opf', 'w') do |f|
          f.puts opf
        end
      end
    end

    def add_html_toc_to_opf_manifest(opf)
      opf.sub(/<item id="ncxtoc".+?>/) { |s|
        s + "\n" +
          %q|    <item id="htmltoc" | +
                    %q|media-type="application/xhtml+xml" | +
                    %q|href="toc.html"/>| }
    end
    def add_html_toc_to_opf_spine(opf)
      opf.sub(/<itemref idref="cover".+?>/) { |s|
        s + "\n" +
          %q|    <itemref idref="htmltoc" linear="no"/>| }
    end
    def add_html_toc_to_opf_guide(opf)
      opf.sub(/<\/guide>/) { |s|
        "  " +
        %q|<reference href="toc.html" type="toc" title="Table of Contents"/>| +
        "\n  " +
        s }
    end

    def flatten_ncx
      nav_points = ncx_nav_points.map { |x| x.gsub(/^\s+/, '') }

      Dir.chdir('book.epub.d/OEBPS') do
        ncx = File.read('toc.ncx')

        File.open("toc.ncx", 'w') do |f|
          f.write ncx.sub(
            /<ncx:navMap>.+<\/ncx:navMap>/m,
            "<ncx:navMap>\n#{nav_points.join("\n")}\n</ncx:navMap>"
          )
        end
      end
    end

    def ncx_nav_points
      nav_points = []

      Dir.chdir('book.epub.d/OEBPS') do
        nav_points = File.read('toc.ncx').
          scan(%r{<ncx:navPoint.+?<ncx:content src=.+?/>}m)
      end

      nav_points.
        flatten.
        map { |x| x + "\n</ncx:navPoint>" }
    end

    def zip_epub_for_mobi
      Dir.chdir('book.epub.d') do
        ex("zip ../book_for_mobi.epub . -r")
      end
    end


    def generate_toc_files
      extract_toc
      build_ncx
      add_ncx_to_opf
    end


    def extract_toc
      content = File.read("book.html")

      File.open("book.html", 'w') do |f|
        f.write content.sub(%r|<div class="toc">.+?</dl></div>|m, '')
      end

      toc = Regexp.last_match[0].
        gsub(/href="#/, 'href="book.html#')

      File.open("toc.html", 'w') do |f|
        f.puts('<?xml version="1.0" encoding="UTF-8"?>')
        f.puts('<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Table of Contents</title></head><body>')
        f.puts toc
        f.puts('</body></html>')
      end
    end

    def build_ncx
      # read book table of contents
      toc = []
      source = File.read("book.html")

      source.scan(/\<h([2|3]) class="title".*?id=\"(.*?)\".*?>(.*?)\<\/h[2|3]\>/).each do |header|
        sec = {'id' => header[1], 'name' => header[2]}
        if header[0] == '2'
          toc << {'section' => sec, 'subsections' => []}
        else
          toc[toc.size - 1]['subsections'] << sec
        end
      end

      # write ncx table of contents
      ncx = File.open('book.ncx', 'w+')
      ncx.puts('<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN"
	"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">

<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="en-US">
<head>
<meta name="dtb:depth" content="2"/>
<meta name="dtb:totalPageCount" content="0"/>
<meta name="dtb:maxPageNumber" content="0"/>
</head>
<docTitle><text>Title</text></docTitle>
<docAuthor><text>Author</text></docAuthor>
<navMap>')

      chapters = 0
      toc.each do |section|
        ch = section['section']
        next unless (chapters > 0 || ch['name'].to_s =~ /Introduction/i)

        chapters += 1
        ncx.puts('<navPoint class="chapter" id="' + ch['id'].to_s + '" playOrder="' + (chapters).to_s + '">')
        # else
        #   ncx.puts('<navPoint class="chapter">')
        # end
        ncx.puts('<navLabel><text>' + ch['name'].to_s + '</text></navLabel>')
        ncx.puts('<content src="book.html#' + ch['id'].to_s + '"/>')
        ncx.puts('</navPoint>')
      end
      ncx.puts('</navMap></ncx>')
      ncx.close
    end

    def build_opf
      opf_template = liquid_template('book.opf')
      File.open('book.opf', 'w+') do |f|
        lang   = @config['language'] || 'en'
        author = @config['author'] || 'Author'
        cover  = @config['cover'] || 'images/cover.jpg'
        data = {'title'    => book_title,
                'language' => lang,
                'author'   => author,
                'pubdate'  => Time.now.strftime("%Y-%m-%d"),
                'cover_image' => cover}
        f.puts opf_template.render( data )
      end
    end

    def liquid_template(file)
      template_dir = File.join(SCRIBE_ROOT, 'site', 'default')
      Liquid::Template.parse(File.read(File.join(template_dir, file)))
    end


    # create a new file by concatenating all the ones we find
    def gather_and_process
      files = Dir.glob("book/*")
      FileUtils.cp_r files, 'output'
    end

    def ex(command)
      out = `#{command} 2>&1`
      info out
      $?.exitstatus == 0
    end

  end
end
