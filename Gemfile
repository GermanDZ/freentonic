source "https://rubygems.org"

gemspec

# Ruby 3.4+ moved several libraries from stdlib to default gems. They still
# ship with Ruby (so freentonic keeps zero *runtime* gem dependencies), but
# Bundler refuses to autoload default gems that aren't declared here. We
# only list them in the dev environment so the gemspec stays dep-free.
group :development, :test do
  gem "minitest", "~> 5.20"
  gem "rake", "~> 13.0"
  gem "base64"
  gem "csv"
  gem "bigdecimal"
end
