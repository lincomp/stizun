#encoding: utf-8
require "spec_helper"

describe ContactMailer, :type => :feature do


  before(:all) do
    ActionMailer::Base.delivery_method = :test
    ActionMailer::Base.perform_deliveries = true
  end

  before(:each) do
    ActionMailer::Base.deliveries.clear
    @default_to = APP_CONFIG['default_to_email'] || 'stizun@localhost'
    @from = "email@example.com"
  end

  it "should set the right subject" do
    data = {:reason => 'question', :subject => 'Foo', :body => 'Bar'}

    email = ContactMailer.send_email(@from, data).deliver_now
    expect(email.from).to eq [@from]
    expect(email.to).to eq [@default_to]
    expect(email.subject).to eq "[Frage] Foo"
    expect(ActionMailer::Base.deliveries.size).to eq 1
  end

  it "should set 'Kein Betreff' if no subject was given" do
    data = {:subject => nil, :body => 'Foo'}
    email = ContactMailer.send_email(@from, data).deliver_now
    expect(email.subject).to eq "[Kontakt] Kein Betreff"
    expect(ActionMailer::Base.deliveries.size).to eq 1
  end

  it "should set a default prefix of '[Kontakt]' if none was selected" do
    data = {:reason => 'unknown', :subject => 'Something', :body => 'Foo'}
    email = ContactMailer.send_email(@from, data).deliver_now
    expect(email.subject).to eq "[Kontakt] Something"
    expect(ActionMailer::Base.deliveries.size).to eq 1
  end

  it "should include the right text in the message" do
    data = {:body => 'Foo'}
    email = ContactMailer.send_email(@from, data).deliver_now
    expect(email.body.to_s).to eq "Liebe Lincomp\r\n\r\nIch habe folgendes Anliegen:\r\n\r\nFoo\r\n\r\nDanke für die Beantwortung und freundliche Grüsse\r\n"
    expect(ActionMailer::Base.deliveries.size).to eq 1
  end

  it "should work when used in a web form" do
    visit "/page/contact"
    fill_in "from", with: "john.doe@example.org"
    fill_in "subject", with: "this is a test"
    fill_in "body", with: "this is also a test"
    click_button("Anfrage abschicken")
    expect(page).to have_content("Danke für Ihre Mitteilung")
  end


end
