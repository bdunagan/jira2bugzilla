#!/usr/bin/ruby

# jira2bugzilla.rb: Download JIRA issues and attachments and transform them into Bugzilla-compatible XML files.

# A couple notes:
# * This script is not going to "just work". It's a template.
# * No notion of QA contact. Leave it off so that a per-project/component default is used.
# * Ensure all products and components are available in the Bugzilla instance. If either are missing, the import script will use the default product and component.
# * No severity in JIRA, so assign "Sev2".

# Import libraries.
require 'rubygems'
require 'nokogiri'
require 'open-uri'
require 'time'
require 'base64'

class String
  def sanitize
    self.gsub("&","&amp;").gsub("<","&lt;").gsub(">","&gt;")
  end
end

# Extract JIRA issues. (Figure out how many issues to include.)
(1..1000).each do |i|
  # Use curl with credentials to extract each JIRA issue's XML.
  xml = %x[curl -u username:password https://jira.example.com/si/jira.issueviews:issue-xml/BUG-#{i}/BUG-#{i}.xml]
  # Save the XML to a file.
  f=File.new("BUG-#{i}.xml","w")
  f.write(xml)
  f.close
end

# Download all the JIRA attachments. We'll need to convert them to base64 and provide them inline to Bugzilla.
Dir.mkdir("attachments") if !Dir.exists?("attachments")
(1..1000).each do |i|
  puts i
  # Open the JIRA issue.
  doc = Nokogiri::XML(open(File.expand_path("BUG-#{i}.xml")))
  # Find all the attachment references.
  doc.xpath("//attachment").each do |attachment|
    # Get the attachment ID and file name.
    attachment_id = attachment.attributes["id"].value
    file_name = attachment.attributes["name"].value
    # Get the attachment contents using curl.
    contents = %x[curl -u username:password https://jira.example.com/secure/attachment/#{attachment_id}/#{file_name}]
    # Save the attachment.
    Dir.mkdir("attachments/BUG-#{i}") if !Dir.exists?("attachments/BUG-#{i}")
    f=File.new("attachments/BUG-#{i}/#{attachment_id}_#{file_name}","w")
    f.write(contents)
    f.close
  end
end

# Map status enum.
STATUS={
  "1" => "NEW",
  "2" => "",
  "3" => "NEW",
  "4" => "REOPENED",
  "5" => "RESOLVED",
  "6" => "CLOSED",
  "10000" => "WAITING"
}

# Map resolution strings.
RESOLUTION = {
  "Fixed" => "FIXED",
  "Unresolved" => "",
  "Won't Fix" => "WONTFIX",
  "Duplicate" => "DUPLICATE",
  "Incomplete" => "INVALID",
  "Cannot Reproduce" => "WORKSFORME",
  "Not a bug" => "INVALID"
}

# Map people.
PEOPLE_NAMES = {
  "john_doe" => "John Doe"
}

PEOPLE_EMAIL = {
  "john_doe" => "john.doe@example.com"
}

# Map versions.
VERSIONS = {
  "Example 1.0" => "Example",
}

# Use the combined version:component string as a lookup.
COMPONENTS = {
  "Example:Component" => "Component"
}

# Skip versions you don't care about.
SKIP_VERSIONS = ["Example 2.0"]

# Loop through all the known issues.
(1..1000).each do |i|
  # Open each JIRA issue.
  doc = Nokogiri::XML(open(File.expand_path("BUG-#{i}.xml")))
  puts "JIRA #{i}"
  # Skip missing issues.
  next if doc.xpath("//h1[contains(.,'Could not find issue with issue key')]").count > 0
  # Skip existing Bugzilla bugs that have no updates.
  updated = Time.parse(doc.xpath("//item/updated")[0].text).strftime("%Y-%m-%d")
  # Check for resolution.
  resolution = (doc.xpath("//item/resolution")[0].text) if !doc.xpath("//item/resolution")[0].nil?
  resolution_xml = "<resolution>#{RESOLUTION[resolution]}</resolution>" if !resolution.nil? && !resolution.empty?
  # Figure out people.
  reporter = doc.xpath("//item/reporter/@username").text
  reporter_name = PEOPLE_NAMES[reporter] || PEOPLE_NAMES["default"]
  reporter_email = PEOPLE_EMAIL[reporter] || PEOPLE_EMAIL["default"]
  reporter_xml = "<reporter name='#{reporter_name}'>#{reporter_email}</reporter>"
  assigned_to = doc.xpath("//item/assignee/@username").text
  assigned_to_name = PEOPLE_NAMES[assigned_to] || PEOPLE_NAMES["default"]
  assigned_to_email = PEOPLE_EMAIL[assigned_to] || PEOPLE_EMAIL["default"]
  assigned_to_xml = "<assigned_to name='#{assigned_to_name}'>#{assigned_to_email}</assigned_to>"
  # Figure out the product. JIRA might specify "version" and/or "fixVersion" for the product. Default to "fixVersion".
  version = doc.xpath("//item/fixVersion")[0].text if !doc.xpath("//item/fixVersion")[0].nil?
  version = doc.xpath("//item/version")[0].text if !doc.xpath("//item/version")[0].nil? && version.nil?
  version = VERSIONS[version] if !VERSIONS[version].nil?
  next if SKIP_VERSIONS.include?(version)
  # Figure out the component.
  component = doc.xpath("//item/component")[0].text
  component = COMPONENTS["#{version}:#{component}"] if !COMPONENTS["#{version}:#{component}"].nil?
  # First comment is the description.
  comments = []
  comments << "<long_desc isprivate='0'>
    <who name='#{reporter_name}'>#{reporter_email}</who>
    <bug_when>#{Time.parse(doc.xpath("//item/updated")[0].text).strftime("%Y-%m-%d %H:%M:%S")}</bug_when>
    <thetext>#{doc.xpath("//item/description")[0].text.sanitize}</thetext></long_desc>"
  # Other comments are the comments.
  doc.xpath("//comment").each do |comment|
    author = comment.attributes["author"].value.downcase
    author_name = PEOPLE_NAMES[author] || PEOPLE_NAMES["default"]
    author_email = PEOPLE_EMAIL[author] || PEOPLE_EMAIL["default"]
    created = Time.parse(comment.attributes["created"].value).strftime("%Y-%m-%d")
    text = comment.text
    comments << "<long_desc isprivate='0'>
      <who name='#{author_name}'>#{author_email}</who>
      <bug_when>#{created}</bug_when>
      <thetext>#{text.sanitize}</thetext></long_desc>"
  end
  # Encode any attachments.
  bug_id = doc.xpath("//item/key")[0].text.sanitize
  attachments = []
  doc.xpath("//attachment").each do |attachment|
    attachment_id = attachment.attributes["id"].value
    file_name = attachment.attributes["name"].value
    author = PEOPLE_EMAIL[attachment.attributes["author"].value.downcase]
    created = Time.parse(attachment.attributes["created"].value).strftime("%Y-%m-%d %H:%M:%S")
    attachment_path = "BUG/#{bug_id}/#{attachment_id}_#{file_name}"
    (puts "=> MISSING FILE #{attachment_path}"; next) if !File.exists?(attachment_path)
    encoded_file = Base64.encode64(IO.read("#{attachment_path}"))
    attachments << "<attachment isobsolete='0' ispatch='0' isprivate='0'>
      <attachid>#{attachment_id}</attachid>
      <date>#{created}</date>
      <filename>#{file_name}</filename>
      <desc>#{file_name}</desc>
      <type>application/octet-stream</type>
      <attacher>#{author}</attacher>
      <data encoding='base64'>#{encoded_file}</data></attachment>"
  end

  # Create the new Bugzilla bug.
  bug_text = "<?xml version='1.0' standalone='yes'?>
<!DOCTYPE bugzilla SYSTEM 'http://example.com/bugzilla/bugzilla.dtd'>
<bugzilla version='3.2' urlbase='https://jira.example.com/browse/' maintainer='john.doe@example.com' exporter='john.doe@example.com'>
  <bug>
    <bug_id>#{bug_id}</bug_id>
    <creation_ts>#{Time.parse(doc.xpath("//item/created")[0].text).strftime("%Y-%m-%d %H:%M")}</creation_ts>
    <short_desc>#{doc.xpath("//item/title")[0].text.sanitize}</short_desc>
    <delta_ts>#{Time.parse(doc.xpath("//item/updated")[0].text).strftime("%Y-%m-%d %H:%M:%S")}</delta_ts>
    <reporter_accessible>1</reporter_accessible>
    <cclist_accessible>1</cclist_accessible>
    <classification_id>1</classification_id>
    <classification>Unclassified</classification>
    <product>#{version}</product>
    <component>#{component}</component>
    <version>unspecified</version>
    <rep_platform>All</rep_platform>
    <op_sys>All</op_sys>
    <bug_status>#{STATUS[doc.xpath("//item/status/@id").text]}</bug_status>
    #{resolution_xml}
    #{reporter_xml}
    #{assigned_to_xml}
    <status_whiteboard>N/A</status_whiteboard>
    <priority>P#{doc.xpath("//item/priority/@id").text}</priority>
    <bug_severity>Sev2</bug_severity>
    <target_milestone>unspecified</target_milestone>
    <everconfirmed>1</everconfirmed>
    #{comments.join("\n")}
    #{attachments.join("\n")}
  </bug>
</bugzilla>
"

  # Write new file.
  f=File.new("BUG-#{"%04d" % i}.xml","w")
  f.write(bug_text)
  f.close
end
