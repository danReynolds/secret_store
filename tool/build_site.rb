#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "digest"
require "fileutils"
require "kramdown"
require "kramdown-parser-gfm"
require "pathname"
require "rouge"

ROOT = File.expand_path("..", __dir__)
SITE_SOURCE = File.join(ROOT, "site")
OUTPUT = File.expand_path(ARGV.fetch(0, "build/site"), ROOT)
BASE_PATH = ENV.fetch("SITE_BASE_PATH", "/keybay").sub(%r{/+$}, "")
SITE_URL = "https://danreynolds.github.io/keybay"
REPOSITORY = "https://github.com/danReynolds/keybay"
PUBLIC_FILES = %w[index.html styles.css 404.html robots.txt].freeze
PROJECT_PUBLIC_FILES = %w[assets/keybay-mark.svg].freeze

DOCUMENTS = [
  {source: "packages/keybay_cli/README.md", route: "docs/cli/", label: "CLI", summary: "Commit a small manifest, store project-qualified values locally, and launch exactly one process with resolved environment variables."},
  {source: "doc/sdk.md", route: "docs/guide/", label: "Dart & Flutter SDK", summary: "Install the SDK, open a store with one appId, and understand the supported runtime and threat-model boundaries."},
  {source: "doc/platforms/ios.md", route: "docs/platforms/ios/", label: "iOS", summary: "Native Data Protection Keychain items with a fixed device-bound, non-synchronizing accessibility policy."},
  {source: "doc/platforms/android.md", route: "docs/platforms/android/", label: "Android", summary: "An authenticated app-private file whose store key is wrapped by Android Keystore on Android 12 and newer."},
  {source: "doc/platforms/macos.md", route: "docs/platforms/macos/", label: "macOS", summary: "Native Data Protection Keychain items for entitled apps; an authenticated file with a login-Keychain key otherwise."},
  {source: "doc/platforms/linux.md", route: "docs/platforms/linux/", label: "Linux", summary: "An authenticated local file whose store key is kept by an unlocked Secret Service provider."},
  {source: "doc/architecture.md", route: "docs/architecture/", label: "Architecture", summary: "Two storage shapes, one automatic production resolver, and an explicit test-backend hatch."},
  {source: "doc/design.md", route: "docs/design/", label: "Cryptography and design", summary: "The container format, FFI boundaries, threat model, concurrency, supply-chain controls, and design rationale."},
  {source: "SECURITY.md", route: "docs/security/", label: "Security policy", summary: "The supported threat model, cryptographic primitives, dependency posture, and private vulnerability-reporting route."},
  {source: "doc/cli-recovery.md", route: "docs/recovery/", label: "CLI recovery", summary: "Preserve evidence, diagnose platform-store failures, and deliberately re-provision an unreadable local CLI store."},
  {source: "doc/ecosystem-comparison.md", route: "docs/comparison/", label: "Choosing Keybay", summary: "Choose the smallest tool that matches whether you need local storage, provider portability, team sharing, or encrypted files."},
].freeze

# Every source above remains rendered and linkable. The permanent navigation is
# intentionally smaller: source-backed does not mean globally prominent.
PRIMARY_NAVIGATION = [
  {
    group: "Use",
    links: [
      {label: "CLI", route: "docs/cli/"},
      {label: "Dart & Flutter SDK", route: "docs/guide/", fragment: "sdk-quickstart"},
    ],
  },
  {
    group: "Understand",
    links: [
      {label: "Storage by platform", route: "docs/", fragment: "platforms"},
      {label: "Architecture", route: "docs/architecture/"},
      {label: "Security design", route: "docs/design/"},
    ],
  },
].freeze

def command_output(*command)
  IO.popen(command, chdir: ROOT, err: File::NULL, &:read).strip
rescue SystemCallError
  ""
end

COMMIT = ENV.fetch("GITHUB_SHA", "").strip.then do |sha|
  sha.empty? ? command_output("git", "rev-parse", "HEAD") : sha
end.then { |sha| sha.empty? ? "main" : sha }

ROUTES_BY_SOURCE = DOCUMENTS.to_h { |document| [document[:source], document[:route]] }.freeze
FORMATTER = Rouge::Formatters::HTML.new

def escape(value)
  CGI.escapeHTML(value.to_s)
end

def site_path(route = "")
  normalized = route.sub(%r{\A/+}, "")
  path = [BASE_PATH, normalized].reject(&:empty?).join("/")
  path = "/#{path}" unless path.start_with?("/")
  path.end_with?("/") || File.extname(path) != "" ? path : "#{path}/"
end

def source_markdown(document)
  path = File.join(ROOT, document[:source])
  raise "Missing documentation source: #{document[:source]}" unless File.file?(path)

  File.read(path, encoding: "UTF-8")
end

def document_title(markdown, source)
  markdown[/^#\s+(.+)$/, 1]&.strip || File.basename(source, ".md").tr("-_", " ")
end

def plain_markdown(value)
  value
    .gsub(/!\[([^\]]*)\]\([^)]*\)/, '\\1')
    .gsub(/\[([^\]]+)\]\([^)]*\)/, '\\1')
    .gsub(/`([^`]+)`/, '\\1')
    .gsub(/\*\*([^*]+)\*\*/, '\\1')
    .gsub(/\*([^*]+)\*/, '\\1')
    .gsub(/~~([^~]+)~~/, '\\1')
    .gsub(/<[^>]+>/, "")
    .gsub(/\s+/, " ")
    .strip
end

def concise(value, limit: 240)
  return value if value.length <= limit

  "#{value[0...limit].sub(/\s+\S*\z/, "")}…"
end

def document_summary(document, markdown)
  return document[:summary] if document[:summary]

  markdown.split(/\n{2,}/).filter_map do |paragraph|
    stripped = paragraph.strip
    next if stripped.empty? || stripped.start_with?("#", "```", "|", ">") || stripped.include?("[![")
    next if stripped.scan(/\]\(/).length >= 2

    text = plain_markdown(stripped)
    next if text.length < 45

    concise(text)
  end.first || "Canonical Keybay documentation."
end

def relative_target(source, target)
  path, fragment = target.split("#", 2)
  return [nil, fragment] if path.nil? || path.empty?

  resolved = Pathname.new(File.dirname(source)).join(path).cleanpath.to_s
  [resolved, fragment]
end

def rewrite_target(attribute, target, source)
  if attribute == "href" && (match = target.match(%r{\A#{Regexp.escape(REPOSITORY)}/blob/(?:main|#{Regexp.escape(COMMIT)})/([^#]+)(?:#(.+))?\z}))
    if (route = ROUTES_BY_SOURCE[match[1]])
      return "#{site_path(route)}#{match[2] ? "##{match[2]}" : ""}"
    end
  end

  return target if target.match?(%r{\A(?:[a-z][a-z0-9+.-]*:|//|/|#)}i)

  resolved, fragment = relative_target(source, target)
  return target if resolved.nil?

  if (route = ROUTES_BY_SOURCE[resolved])
    return "#{site_path(route)}#{fragment ? "##{fragment}" : ""}"
  end

  absolute = File.join(ROOT, resolved)
  raise "Broken relative link in #{source}: #{target}" unless File.exist?(absolute)

  if attribute == "src"
    "https://raw.githubusercontent.com/danReynolds/keybay/#{COMMIT}/#{resolved}"
  else
    kind = File.directory?(absolute) ? "tree" : "blob"
    "#{REPOSITORY}/#{kind}/#{COMMIT}/#{resolved}#{fragment ? "##{fragment}" : ""}"
  end
end

def rewrite_links(html, source)
  html.gsub(/\b(href|src)="([^"]+)"/) do
    attribute = Regexp.last_match(1)
    target = CGI.unescapeHTML(Regexp.last_match(2))
    %(#{attribute}="#{escape(rewrite_target(attribute, target, source))}")
  end
end

def render_markdown(markdown, source)
  html = Kramdown::Document.new(
    markdown,
    input: "GFM",
    auto_ids: true,
    hard_wrap: false,
    syntax_highlighter: "rouge",
    syntax_highlighter_opts: {
      block: {line_numbers: false},
      span: {},
    },
  ).to_html
  rewrite_links(html, source)
end

def strip_rendered_h1(html)
  html.sub(/\A\s*<h1\b[^>]*>.*?<\/h1>\s*/m, "")
end

def table_of_contents(html)
  html.scan(/<h2 id="([^"]+)">(.*?)<\/h2>/m).map do |id, heading|
    [id, CGI.unescapeHTML(heading.gsub(/<[^>]+>/, "")).strip]
  end
end

def document_navigation(active_route = nil)
  PRIMARY_NAVIGATION.map do |section|
    links = section[:links].map do |link|
      current = link[:route] == active_route ? ' aria-current="page"' : ""
      fragment = link[:fragment] ? "##{link[:fragment]}" : ""
      %(<a href="#{site_path(link[:route])}#{fragment}"#{current}>#{escape(link[:label])}</a>)
    end.join("\n")
    <<~HTML
      <div class="docs-nav-section">
        <p>#{escape(section[:group])}</p>
        #{links}
      </div>
    HTML
  end.join
end

def page_contents_navigation(headings)
  return "" if headings.empty?

  links = headings.map { |id, label| %(<a href="##{escape(id)}">#{escape(label)}</a>) }.join("\n")
  <<~HTML
    <nav class="on-this-page" aria-label="On this page">
      <p>On this page</p>
      #{links}
    </nav>
  HTML
end

def mobile_document_navigation(active_route, headings)
  contents = if headings.empty?
    ""
  else
    links = headings.map { |id, label| %(<a href="##{escape(id)}">#{escape(label)}</a>) }.join("\n")
    <<~HTML
      <nav class="docs-mobile-toc" aria-label="On this page">
        <p>On this page</p>
        #{links}
      </nav>
    HTML
  end

  <<~HTML
    <details class="docs-mobile-menu">
      <summary>Browse documentation</summary>
      <div class="docs-mobile-menu-inner">
        <nav aria-label="Documentation">
          #{document_navigation(active_route)}
        </nav>
        #{contents}
      </div>
    </details>
  HTML
end

def shared_head(title:, description:, canonical:)
  <<~HTML
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="theme-color" content="#f4f3ed">
    <meta name="description" content="#{escape(description)}">
    <link rel="canonical" href="#{escape(canonical)}">
    <title>#{escape(title)} — Keybay</title>
    <link rel="icon" href="#{site_path("assets/keybay-mark.svg")}" type="image/svg+xml">
    <link rel="stylesheet" href="#{site_path("styles.css")}">
  HTML
end

def site_header
  <<~HTML
    <a class="skip-link" href="#main">Skip to content</a>
    <header class="site-header">
      <div class="shell header-inner">
        <a class="brand" href="#{site_path}" aria-label="Keybay home"><img src="#{site_path("assets/keybay-mark.svg")}" alt="" width="24" height="24">keybay</a>
        <nav aria-label="Main navigation">
          <a href="#{site_path}">Overview</a>
          <a href="#{site_path("docs/")}">Docs</a>
          <a href="#{REPOSITORY}">GitHub ↗</a>
        </nav>
      </div>
    </header>
  HTML
end

def site_footer
  <<~HTML
    <footer>
      <div class="shell footer-inner">
        <span>keybay · MIT</span>
        <span><a href="#{site_path("docs/")}">Docs</a> · <a href="#{site_path("docs/security/")}#reporting">Report a vulnerability</a> · <a href="#{REPOSITORY}">GitHub</a></span>
      </div>
    </footer>
  HTML
end

def document_page(document, markdown)
  title = document_title(markdown, document[:source])
  summary = document_summary(document, markdown)
  digest = Digest::SHA256.hexdigest(markdown)
  content = strip_rendered_h1(render_markdown(markdown, document[:source]))
  headings = table_of_contents(content)
  canonical = "#{SITE_URL}/#{document[:route]}"
  commit_label = COMMIT == "main" ? COMMIT : COMMIT[0, 7]
  source_url = "#{REPOSITORY}/blob/#{COMMIT}/#{document[:source]}"

  <<~HTML
    <!doctype html>
    <html lang="en">
      <head>
        #{shared_head(title: title, description: summary, canonical: canonical)}
      </head>
      <body>
        #{site_header}
        <main id="main" class="docs-main">
          <div class="shell docs-layout">
            <aside class="docs-sidebar">
              <div class="docs-menu">
                <p class="docs-menu-title">Documentation</p>
                <nav aria-label="Documentation">
                  #{document_navigation(document[:route])}
                </nav>
              </div>
              #{page_contents_navigation(headings)}
            </aside>
            <article class="doc" data-source="#{escape(document[:source])}" data-source-digest="#{digest}">
              <header class="doc-header">
                <h1>#{escape(title)}</h1>
              </header>
              #{mobile_document_navigation(document[:route], headings)}
              <div class="doc-content">
                #{content}
              </div>
              <footer class="doc-provenance">
                <p>Source: <a href="#{escape(source_url)}"><code>#{escape(document[:source])}</code></a> at <a href="#{REPOSITORY}/commit/#{COMMIT}"><code>#{escape(commit_label)}</code></a>.</p>
              </footer>
            </article>
          </div>
        </main>
        #{site_footer}
      </body>
    </html>
  HTML
end

def documentation_index(metadata)
  by_route = metadata.to_h { |item| [item[:document][:route], item] }
  list = lambda do |routes|
    routes.map do |route|
      item = by_route.fetch(route)
      document = item[:document]
      <<~HTML
        <li>
          <a href="#{site_path(route)}">#{escape(document[:label])}</a>
          <p>#{escape(item[:summary])}</p>
        </li>
      HTML
    end.join
  end

  <<~HTML
    <!doctype html>
    <html lang="en">
      <head>
        #{shared_head(title: "Documentation", description: "Canonical Keybay guides, architecture, security design, recovery, and platform notes generated from the repository.", canonical: "#{SITE_URL}/docs/")}
      </head>
      <body>
        #{site_header}
        <main id="main" class="docs-main">
          <article class="shell doc doc-index">
            <header class="doc-header">
              <h1>Documentation</h1>
              <p class="doc-index-lede">Choose the path that matches what you need to do.</p>
            </header>

            <nav class="doc-starts" aria-label="Start with Keybay">
              <a href="#{site_path("docs/cli/")}"><strong>Local-process CLI →</strong><span>Resolve a committed manifest into one process.</span></a>
              <a href="#{site_path("docs/guide/")}#sdk-quickstart"><strong>Dart & Flutter SDK →</strong><span>Store and read secrets directly.</span></a>
              <a href="#{site_path("docs/design/")}"><strong>Evaluate security →</strong><span>Inspect the cryptography, threat model, and limits.</span></a>
            </nav>

            <section class="doc-index-group" id="platforms">
              <h2>Storage by platform</h2>
              <ul>#{list.call(%w[docs/platforms/ios/ docs/platforms/android/ docs/platforms/macos/ docs/platforms/linux/])}</ul>
            </section>

            <section class="doc-index-group">
              <h2>Reference</h2>
              <ul>#{list.call(%w[docs/architecture/ docs/recovery/ docs/comparison/ docs/security/])}</ul>
            </section>

            <p class="doc-index-provenance">Every page is generated from its repository source and links to the exact deployed commit.</p>
          </article>
        </main>
        #{site_footer}
      </body>
    </html>
  HTML
end

def highlight_static_code(html)
  html.gsub(/<pre><code(?<attributes>[^>]*)>(?<code>.*?)<\/code><\/pre>/m) do |match|
    attributes = Regexp.last_match(:attributes)
    code = Regexp.last_match(:code)
    language = attributes[/\bdata-language="([^"]+)"/, 1]
    next match unless language

    source = CGI.unescapeHTML(code)
    lexer = Rouge::Lexer.find_fancy(language, source) || Rouge::Lexers::PlainText.new
    highlighted = FORMATTER.format(lexer.lex(source))
    clean_attributes = attributes.gsub(/\s*data-language="[^"]+"/, "")
    %(<pre><code#{clean_attributes} data-highlighted="#{escape(language)}">#{highlighted}</code></pre>)
  end
end

def write_page(relative_path, content)
  destination = File.join(OUTPUT, relative_path)
  FileUtils.mkdir_p(File.dirname(destination))
  File.write(destination, content, mode: "w", encoding: "UTF-8")
end

def sitemap
  routes = ["", "docs/", *DOCUMENTS.map { |document| document[:route] }]
  entries = routes.map do |route|
    location = route.empty? ? "#{SITE_URL}/" : "#{SITE_URL}/#{route}"
    "  <url><loc>#{escape(location)}</loc></url>"
  end.join("\n")
  <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{entries}
    </urlset>
  XML
end

def artifact_target(page, target)
  decoded = CGI.unescapeHTML(target)
  return [nil, nil] if decoded.match?(%r{\A(?:[a-z][a-z0-9+.-]*:|//)}i)

  path, fragment = decoded.split("#", 2)
  clean = path.to_s.split("?", 2).first.to_s
  return [page, fragment] if clean.empty?

  if clean.start_with?("/")
    prefix = BASE_PATH.empty? ? "/" : "#{BASE_PATH}/"
    return ["index.html", fragment] if clean == BASE_PATH || clean == prefix
    return [nil, nil] unless clean.start_with?(prefix)

    relative = clean.delete_prefix(prefix)
  else
    relative = Pathname.new(File.dirname(page)).join(clean).cleanpath.to_s
  end

  relative = File.join(relative, "index.html") if clean.end_with?("/")
  [relative, fragment]
end

def validate_internal_links
  Dir.glob(File.join(OUTPUT, "**/*.html")).each do |path|
    page = Pathname.new(path).relative_path_from(Pathname.new(OUTPUT)).to_s
    html = File.read(path, encoding: "UTF-8")
    html.scan(/\b(?:href|src)="([^"]+)"/).flatten.each do |target|
      artifact, fragment = artifact_target(page, target)
      next if artifact.nil?

      destination = File.join(OUTPUT, artifact)
      raise "Broken generated link in #{page}: #{target}" unless File.file?(destination)
      next if fragment.nil? || fragment.empty? || File.extname(destination) != ".html"

      destination_html = File.read(destination, encoding: "UTF-8")
      escaped_fragment = Regexp.escape(escape(CGI.unescape(fragment)))
      unless destination_html.match?(/\bid="#{escaped_fragment}"/)
        raise "Broken generated fragment in #{page}: #{target}"
      end
    end
  end
end

def validate_output(metadata)
  index = File.read(File.join(OUTPUT, "index.html"), encoding: "UTF-8")
  raise "Missing Keybay mark" unless File.file?(File.join(OUTPUT, "assets/keybay-mark.svg"))
  raise "Homepage does not reference the Keybay mark" unless index.include?("assets/keybay-mark.svg")
  raise "Homepage code examples were not highlighted" if index.scan(/<span class="/).length < 8
  raise "Homepage contains executable JavaScript" if index.match?(%r{<script(?! type="application/ld\+json")})

  metadata.each do |item|
    path = File.join(OUTPUT, item[:document][:route], "index.html")
    html = File.read(path, encoding: "UTF-8")
    raise "Missing source digest in #{path}" unless html.include?(%(data-source-digest="#{item[:digest]}"))
    raise "Generated docs do not reference the Keybay mark: #{path}" unless html.include?("assets/keybay-mark.svg")
    raise "Generated docs contain executable JavaScript: #{path}" if html.include?("<script")
  end

  design = File.read(File.join(OUTPUT, "docs/design/index.html"), encoding: "UTF-8")
  raise "Generated Markdown code was not highlighted" unless design.include?("highlighter-rouge")
  validate_internal_links
end

FileUtils.rm_rf(OUTPUT)
FileUtils.mkdir_p(OUTPUT)
PUBLIC_FILES.each do |file|
  source = File.join(SITE_SOURCE, file)
  raise "Missing site source: site/#{file}" unless File.file?(source)

  FileUtils.cp(source, File.join(OUTPUT, file))
end
PROJECT_PUBLIC_FILES.each do |file|
  source = File.join(ROOT, file)
  destination = File.join(OUTPUT, file)
  raise "Missing project asset: #{file}" unless File.file?(source)

  FileUtils.mkdir_p(File.dirname(destination))
  FileUtils.cp(source, destination)
end

homepage_path = File.join(OUTPUT, "index.html")
File.write(homepage_path, highlight_static_code(File.read(homepage_path, encoding: "UTF-8")), encoding: "UTF-8")

metadata = DOCUMENTS.map do |document|
  markdown = source_markdown(document)
  page = document_page(document, markdown)
  write_page(File.join(document[:route], "index.html"), page)
  {
    document: document,
    title: document_title(markdown, document[:source]),
    summary: document_summary(document, markdown),
    digest: Digest::SHA256.hexdigest(markdown),
  }
end

write_page("docs/index.html", documentation_index(metadata))
write_page("sitemap.xml", sitemap)
validate_output(metadata)

puts "Built #{metadata.length} source-backed documentation pages in #{Pathname.new(OUTPUT).relative_path_from(Pathname.new(ROOT))}"
