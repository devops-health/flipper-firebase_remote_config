# Stand-ins for googleauth credential objects, used to exercise the client's
# token refresh logic without a network or a real service account.
class FakeCredentials
  attr_reader :fetch_count, :applied
  attr_accessor :access_token

  def initialize(access_token: nil, expiring: false)
    @access_token = access_token
    @expiring     = expiring
    @fetch_count  = 0
    @applied      = []
  end

  # Mirrors Google::Auth::BaseClient#apply!, which refreshes the token before
  # writing the header. Without that, a client calling apply! outside its own
  # mutex looks correctly serialized in specs when it isn't.
  def apply!(headers)
    @applied << headers
    fetch_access_token! if @access_token.nil? || expires_within?(60)
    headers['authorization'] = "Bearer #{@access_token}"
  end

  def fetch_access_token!
    @fetch_count += 1
    @access_token = "token-#{@fetch_count}"
  end

  # Mirrors Signet::OAuth2::Client#expires_within?.
  def expires_within?(_seconds)
    @expiring
  end
end

# Credentials that predate (or simply don't implement) expires_within?, to
# confirm the client degrades to a presence check instead of blowing up.
class FakeCredentialsWithoutExpiry
  attr_reader :fetch_count
  attr_accessor :access_token

  def initialize(access_token: nil)
    @access_token = access_token
    @fetch_count  = 0
  end

  def apply!(headers); end

  def fetch_access_token!
    @fetch_count += 1
    @access_token = "token-#{@fetch_count}"
  end
end
