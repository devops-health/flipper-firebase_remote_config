# Minimal Net::HTTP stand-in for the client's `http:` injection seam.
class FakeHttp
  attr_reader :requests

  def initialize(response)
    @response = response
    @requests = []
  end

  def request(req)
    @requests << req
    @response
  end
end

class FakeResponse
  attr_reader :code, :body

  def initialize(code: 200, body: '{}', etag: 'etag-1')
    @code = code
    @body = body
    @etag = etag
  end

  def [](header)
    @etag if header == 'ETag'
  end
end
