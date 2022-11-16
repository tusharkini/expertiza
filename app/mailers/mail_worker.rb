require 'sidekiq'

class MailWorker
  include Sidekiq::Worker
  # ActionMailer in Rails 4 submits jobs in mailers queue instead of default queue. Rails 5 and onwards
  # ActionMailer will submit mailer jobs to default queue. We need to remove the line below in that case!
  sidekiq_options queue: 'mailers'
  attr_accessor :assignment_id
  attr_accessor :deadline_type
  attr_accessor :due_at

  def perform(assignment_id, deadline_type, due_at)
    self.assignment_id = assignment_id
    # deadline_type can represent several different fields, and can trigger different actions seen below
    # - drop_one_member_topics = Remove topics that only contain a single teammate/user
    # - drop_outstanding_reviews = Remove assignments that require a review that haven't yet been given to a requesting peer for review from the outstanding
    #   queue once it has been assigned to a peer/user
    # - compare_files_with_simicheck = Stage that causes plagiarism to be searched for once this deadline has passed
    self.deadline_type = deadline_type
    self.due_at = due_at

    assignment = Assignment.find(self.assignment_id)
    participant_emails = find_participant_emails

    if %w[drop_one_member_topics drop_outstanding_reviews compare_files_with_simicheck].include?(self.deadline_type)
      drop_one_member_topics if self.deadline_type == 'drop_outstanding_reviews' && assignment.team_assignment
      drop_outstanding_reviews if self.deadline_type == 'drop_outstanding_reviews'
      perform_simicheck_comparisons(self.assignment_id) if self.deadline_type == 'compare_files_with_simicheck'
    else
      # Can we rename deadline_type(metareview) to "teammate review". If, yes then we do not need this if clause below!
      deadline_text = self.deadline_type == 'metareview' ? 'teammate review' : self.deadline_type
      email_reminder(participant_emails, deadline_text) unless participant_emails.empty?
    end
  end

  # email_reminder creates and sends an email reminder to the recipient email with pertinent information regarding the following
  # - due date
  # - link to access assignment
  def email_reminder(emails, deadline_type)
    assignment = Assignment.find(assignment_id)
    subject = "Message regarding #{deadline_type} for assignment #{assignment.name}"

    # Defining the body of mail
    body = "This is a reminder to complete #{deadline_type} for assignment #{assignment.name}.\n"

    emails.each do |mail|
      # Since the email is not unique fetching the first instance in results returned when searching via email
      user = User.where(email: mail).first

      # Finding the mapping between participant and assignment so that it can be sent as a query param
      participant_assignment_id = Participant.where(user_id: user.id.to_s, parent_id: self.assignment_id.to_s).first.id

      # This is the link which User can use to navigate
      link_to_destination = "Please follow the link: http://expertiza.ncsu.edu/student_task/view?id=#{participant_assignment_id}\n"
      body += link_to_destination + "Deadline is #{self.due_at}. If you have already done the #{deadline_type}, then please ignore this mail.";

      # Send mail to the user
      @mail = Mailer.delayed_message(bcc: mail, subject: subject, body: body)
      @mail.deliver_now
      Rails.logger.info mail
    end
  end

  # collect an array of all of the participating students' emails for this assignment
  # used in the perform() function to gather all of the emails needed for reminders
  def find_participant_emails
    emails = []
    participants = Participant.where(parent_id: assignment_id)
    participants.each do |participant|
      # Add the user to the array unless the user isn't valid
      emails << participant.user.email unless participant.user.nil?
    end
    emails
  end

  # remove topics containing only 1 participant
  def drop_one_member_topics
    teams = TeamsUser.all.group(:team_id).count(:team_id)
    teams.keys.each do |team_id|
      if teams[team_id] == 1
        topic_to_drop = SignedUpTeam.where(team_id: team_id).first
        topic_to_drop.delete if topic_to_drop # check if the one-person-team has signed up a topic
      end
    end
  end

  # remove reviews from outstanding reviews list, once they've been started
  def drop_outstanding_reviews
    reviews = ResponseMap.where(reviewed_object_id: assignment_id)
    reviews.each do |review|
      review_has_begun = Response.where(map_id: review.id)
      if review_has_begun.size.zero?
        review_to_drop = ResponseMap.where(id: review.id)
        review_to_drop.first.destroy
      end
    end
  end

  # plagiarism check
  def perform_simicheck_comparisons(assignment_id)
    PlagiarismCheckerHelper.run(assignment_id)
  end
end