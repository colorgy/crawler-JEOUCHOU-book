require 'iconv'
require 'crawler_rocks'
require 'json'
require 'isbn'
require 'pry'

require 'thread'
require 'thwait'

class JeouchouBookCrawler
  include CrawlerRocks::DSL

  def initialize
    @index_url = "http://www.jcbooks.com.tw/"
    @ic = Iconv.new("utf-8//translit//IGNORE","big5")
  end

  def books
    @books = {}

    r = RestClient.get @index_url
    doc = Nokogiri::HTML(@ic.iconv(r))

    category_urls = doc.css('a') \
                      .map{ |a| a[:href] }
                      .select{ |href| href.include?('booklist.aspx?KNDCD') }
                      .uniq
                      .map{ |href| URI.join(@index_url, href).to_s }

    category_urls.each_with_index do |start_url, cat_index|
      @threads = []
      begin
        r = RestClient.get start_url
      rescue Exception => e
        next
      end
      doc = Nokogiri::HTML(@ic.iconv(r))

      @book_count = doc.css('#ctl00_ContentPlaceHolder1_lbTotal').text.to_i
      page_num = @book_count / 20 + 1
      @finish_book_count = 0

      parse_page(doc)

      if page_num > 1
        (2..page_num).each { |i|
          paginated_url = "#{start_url}&startno=#{20*i}"
          r = RestClient.get paginated_url
          doc = Nokogiri::HTML(@ic.iconv(r))

          parse_page(doc)
        }
      end
      print "category: #{cat_index} / #{category_urls.count}\n"
      ThreadsWait.all_waits(*@threads)
    end

    @books.values
  end

  def parse_page doc
    doc.xpath('//table[@id="ctl00_ContentPlaceHolder1_dlResult"]/tr').each do |row|
      datas = row.css('td')

      internal_code = datas[4] && datas[4].text.strip
      url = "http://www.jcbooks.com.tw/BookDetail.aspx?bokno=#{internal_code}"

      isbn = nil;
      begin
        isbn = datas[5] && !datas[5].text.strip.empty? && ISBN.thirteen(datas[5].text.strip)
      rescue Exception => e
        print "#{datas[5]}\n"
      end


      @books[internal_code] = {
        name: datas[1] && datas[1].text.strip,
        author: datas[2] && datas[2].text.strip,
        isbn: isbn,
        internal_code: internal_code,
        price: datas[6] && datas[6].text.strip.gsub(/[^\s]/, '').to_i,
        url: url
      }

      sleep(1) until (
        @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        @threads.count < (ENV['MAX_THREADS'] || 50)
      )
      @threads << Thread.new do
        r = RestClient.get url
        doc = Nokogiri::HTML(@ic.iconv(r))

        external_image_url = doc.xpath("//img[contains(@src, '#{internal_code}')]//@src").to_s
        external_image_url = external_image_url && URI.join(@index_url, external_image_url).to_s
        @books[internal_code][:external_image_url] = external_image_url

        @finish_book_count += 1
        print "#{@finish_book_count} / #{@book_count}\n"
      end # end Thread do
    end
  end
end

cc = JeouchouBookCrawler.new
File.write('jeouchou_books.json', JSON.pretty_generate(cc.books))
