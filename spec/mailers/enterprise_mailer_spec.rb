require 'spec_helper'

describe EnterpriseMailer do
  before do
    @enterprise = create(:enterprise)
    ActionMailer::Base.deliveries = []
  end

  it "should send an email when given an enterprise" do
    EnterpriseMailer.creation_confirmation(@enterprise).deliver
    ActionMailer::Base.deliveries.count.should == 1
  end
end