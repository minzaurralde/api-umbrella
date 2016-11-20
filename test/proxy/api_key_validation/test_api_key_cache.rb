require_relative "../../test_helper"

class TestProxyApiKeyValidationApiKeyCache < Minitest::Test
  include ApiUmbrellaTestHelpers::Setup
  include ApiUmbrellaTestHelpers::ExerciseAllWorkers

  def setup
    setup_server
  end

  def test_caches_keys_inside_workers_for_couple_seconds
    user = FactoryGirl.create(:api_user, :settings => {
      :rate_limit_mode => "unlimited",
    })

    # Make requests against all the workers processes so the key is cache
    # locally inside each worker.
    responses = exercise_all_workers("/api/info/", {
      :headers => { "X-Api-Key" => user.api_key },
      :params => { :step => "pre" },
    })
    responses.each do |response|
      assert_equal(200, response.code, response.body)
    end

    # Disable the API key
    user.disabled_at = Time.now.utc
    user.save!

    # Immediately make more requests. These should still succeed due to the
    # local cache.
    responses = exercise_all_workers("/api/info/", {
      :headers => { "X-Api-Key" => user.api_key },
      :params => { :step => "post-save" },
    })
    responses.each do |response|
      assert_equal(200, response.code, response.body)
    end

    # Wait for the cache to expire
    sleep 2.1

    # With the cache expired, now all requests should be rejected due to the
    # disabled key.
    responses = exercise_all_workers("/api/info/", {
      :headers => { "X-Api-Key" => user.api_key },
      :params => { :step => "post-timeout" },
    })
    responses.each do |response|
      assert_equal(403, response.code, response.body)
      assert_match("API_KEY_DISABLED", response.body)
    end
  end

  def test_keys_across_parallel_hits_with_key_caching
    user = FactoryGirl.create(:api_user, :settings => {
      :rate_limit_mode => "unlimited",
    })

    hydra = Typhoeus::Hydra.new
    requests = Array.new(20) do
      request = Typhoeus::Request.new("http://127.0.0.1:9080/api/hello", http_options.deep_merge({
        :headers => { "X-Api-Key" => user.api_key },
      }))
      hydra.queue(request)
      request
    end
    hydra.run

    requests.each do |request|
      assert_equal(200, request.response.code, request.response.body)
      assert_equal("Hello World", request.response.body)
    end
  end

  def test_keys_across_repated_hits_with_key_caching
    user = FactoryGirl.create(:api_user, :settings => {
      :rate_limit_mode => "unlimited",
    })

    20.times do
      response = Typhoeus.get("http://127.0.0.1:9080/api/hello", http_options.deep_merge({
        :headers => { "X-Api-Key" => user.api_key },
      }))
      assert_equal(200, response.code, response.body)
      assert_equal("Hello World", response.body)
    end
  end

  def test_key_caching_disabled
    override_config({
      "gatekeeper" => {
        "api_key_cache" => false,
      },
    }, "--router") do
      user = FactoryGirl.create(:api_user, :settings => {
        :rate_limit_mode => "unlimited",
      })

      # Make requests against all the workers processes.
      responses = exercise_all_workers("/api/info/", {
        :headers => { "X-Api-Key" => user.api_key },
        :params => { :step => "pre" },
      })
      responses.each do |response|
        assert_equal(200, response.code, response.body)
      end

      # Disable the API key
      user.disabled_at = Time.now.utc
      user.save!

      # Immediately make more requests. These should still immediately be
      # rejected since the key caching is disabled.
      responses = exercise_all_workers("/api/info/", {
        :headers => { "X-Api-Key" => user.api_key },
        :params => { :step => "post-save" },
      })
      responses.each do |response|
        assert_equal(403, response.code, response.body)
        assert_match("API_KEY_DISABLED", response.body)
      end
    end
  end
end
