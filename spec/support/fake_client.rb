# In-memory stand-in for Flipper::Adapters::FirebaseRemoteConfig::Client used
# by the test suite. Models the template as a plain Hash (the same shape the
# real REST API returns) and enforces ETag-based optimistic concurrency so we
# can exercise the adapter's retry path.
class FakeClient
  attr_reader :publish_calls

  def initialize
    @template = { 'parameters' => {} }
    @etag     = 'etag-0'
    @counter  = 0
    @publish_calls = 0
    @mutex = Mutex.new
  end

  def fetch_template
    @mutex.synchronize { [deep_dup(@template), @etag] }
  end

  def publish_template(template, etag)
    @mutex.synchronize do
      @publish_calls += 1
      raise Flipper::Adapters::FirebaseRemoteConfig::ETagMismatch, 'stale' if etag != @etag

      @template = deep_dup(template)
      @counter += 1
      @etag = "etag-#{@counter}"
    end
  end

  # Mirrors listVersions: the version number rises with every publish.
  def latest_version
    @mutex.synchronize { @counter }
  end

  # Simulate another process publishing in the background between the
  # adapter's fetch and write.
  def bump_etag!
    @counter += 1
    @etag = "etag-#{@counter}"
  end

  private

  def deep_dup(value)
    JSON.parse(JSON.generate(value))
  end
end
