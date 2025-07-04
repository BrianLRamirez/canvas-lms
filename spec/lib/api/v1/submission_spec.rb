# frozen_string_literal: true

#
# Copyright (C) 2017 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

describe Api::V1::Submission do
  subject(:fake_controller) do
    Class.new do
      include Api
      include Api::V1::Submission
      include Rails.application.routes.url_helpers

      attr_writer :current_user

      private

      def default_url_options
        { host: :localhost }
      end
    end.new
  end

  let(:user) { User.create! }
  let(:course) { Course.create! }
  let(:assignment) { course.assignments.create! }
  let(:teacher) do
    teacher = User.create!
    course.enroll_teacher(teacher)
    teacher
  end
  let(:session) { {} }
  let(:context) { nil }
  let(:params) { { includes: [field] } }
  let(:submission) { assignment.submissions.create!(user:) }
  let(:provisional_grade) { submission.provisional_grades.create!(scorer: teacher) }

  describe "#provisional_grade_json" do
    describe "speedgrader_url" do
      it "links to SpeedGrader for a student's submission" do
        expect(assignment).to receive(:can_view_student_names?).with(user).and_return true
        json = fake_controller.provisional_grade_json(
          course:,
          assignment:,
          submission:,
          provisional_grade:,
          current_user: user
        )
        path = "/courses/#{course.id}/gradebook/speed_grader"
        query = { assignment_id: assignment.id, student_id: user.id }
        expect(json.fetch("speedgrader_url")).to match_path(path).and_query(query)
      end

      it "links to SpeedGrader for a student's anonymous submission when grader cannot view student names" do
        expect(assignment).to receive(:can_view_student_names?).with(user).and_return false
        json = fake_controller.provisional_grade_json(
          course:,
          assignment:,
          submission:,
          provisional_grade:,
          current_user: user
        )
        path = "/courses/#{course.id}/gradebook/speed_grader"
        query = { assignment_id: assignment.id, anonymous_id: submission.anonymous_id }
        expect(json.fetch("speedgrader_url")).to match_path(path).and_query(query)
      end
    end
  end

  describe "#submission_json" do
    context "when file_association_access feature flag is enabled" do
      let(:attachment) { attachment_model(content_type: "application/pdf", context: teacher) }

      before do
        attachment.root_account.enable_feature!(:file_association_access)
        fake_controller.instance_variable_set(:@domain_root_account, attachment.root_account)
      end

      it "should add asset location tag to all other fields of the json for online_upload" do
        student = course_with_user("StudentEnrollment", course:, active_all: true, name: "Student").user
        attachment = attachment_model(content_type: "application/pdf", context: student)
        submission = assignment.submit_homework(student, submission_type: "online_upload", attachments: [attachment])
        submission.versioned_attachments = [attachment]
        submission.save!
        submission.media_comment_id = 1
        submission.media_comment_type = "video/mp4"
        fake_controller.current_user = student
        json = fake_controller.submission_json(submission, assignment, teacher, session, context)

        expect(json["attachments"].first["url"]).to include("location=#{submission.asset_string}")
        expect(json["media_comment"]["url"]).to include("location=#{submission.asset_string}")
      end

      it "should add asset location tag to all other fields of the json for online_text_entry" do
        student = course_with_user("StudentEnrollment", course:, active_all: true, name: "Student").user
        submission = assignment.submit_homework(student, submission_type: "online_text_entry", body: "<img src='/users/#{teacher.id}/files/#{attachment.id}'>", attachments: [attachment])
        json = fake_controller.submission_json(submission, assignment, teacher, session, context)

        expect(json["body"]).to include("location=#{submission.asset_string}")
      end
    end

    context "when discussion_checkpoints feature flag is enabled" do
      let(:field) { "sub_assignment_submissions" }

      before :once do
        Account.site_admin.enable_feature!(:discussion_checkpoints)
      end

      it "includes sub_assignment_submissions for checkpointed assignments" do
        student = course_with_user("StudentEnrollment", course:, active_all: true, name: "Student").user

        parent_assignment = course.assignments.create!(title: "Assignment 1", has_sub_assignments: true)
        parent_submission = parent_assignment.submissions.find_by(user_id: student.id)
        parent_assignment.sub_assignments.create!(context: parent_assignment.context, sub_assignment_tag: CheckpointLabels::REPLY_TO_TOPIC, points_possible: 5, due_at: 3.days.from_now)
        parent_assignment.sub_assignments.create!(context: parent_assignment.context, sub_assignment_tag: CheckpointLabels::REPLY_TO_ENTRY, points_possible: 10, due_at: 5.days.from_now)

        json = fake_controller.submission_json(parent_submission, parent_assignment, teacher, session, parent_assignment.context, field, params)
        expect(json["has_sub_assignment_submissions"]).to be true
        sas = json["sub_assignment_submissions"]

        # the following are properties we expect in the response
        expect(sas.pluck("sub_assignment_tag")).to match_array([CheckpointLabels::REPLY_TO_TOPIC, CheckpointLabels::REPLY_TO_ENTRY])
        expect(sas.pluck("id")).to match_array([nil, nil])
        expect(sas.pluck("missing")).to match_array([false, false])
        expect(sas.pluck("late")).to match_array([false, false])
        expect(sas.pluck("excused")).to match_array([nil, nil])
        expect(sas.pluck("score")).to match_array([nil, nil])
        expect(sas.pluck("grade")).to match_array([nil, nil])
        expect(sas.pluck("entered_score")).to match_array([nil, nil])
        expect(sas.pluck("entered_grade")).to match_array([nil, nil])
        expect(sas.pluck("user_id")).to match_array([student.id, student.id])

        # the following are properties we do not expect in the response since these are sub_assignments already
        expect(sas.pluck("has_sub_assignment_submissions")).to match_array([nil, nil])
        expect(sas.pluck("sub_assignment_submissions")).to match_array([nil, nil])
        expect(sas.pluck("submission_type")).to match_array([nil, nil])
        expect(sas.pluck("submitted_at")).to match_array([nil, nil])
        expect(sas.pluck("points_deducted")).to match_array([nil, nil])
        expect(sas.pluck("has_postable_comments")).to match_array([nil, nil])
        expect(sas.pluck("workflow_state")).to match_array([nil, nil])
        expect(sas.pluck("assignment_id")).to match_array([nil, nil])
        expect(sas.pluck("redo_request")).to match_array([nil, nil])
      end

      it "has false sub_assignment_submissions info for non-checkpointed assignments" do
        student = course_with_user("StudentEnrollment", course:, active_all: true, name: "Student").user
        assignment = course.assignments.create!(title: "Assignment 1", has_sub_assignments: false)
        submission = assignment.submissions.find_by(user_id: student.id)

        json = fake_controller.submission_json(submission, assignment, teacher, session, assignment.context, field, params)
        expect(json["has_sub_assignment_submissions"]).to be false
        expect(json["sub_assignment_submissions"]).to be_empty
      end

      it "sets needs grading fields if a submission checkpoint needs grading" do
        student = course_with_user("StudentEnrollment", course:, active_all: true, name: "Student").user
        parent_assignment = course.assignments.create!(title: "Assignment 1", has_sub_assignments: true, submission_types: "discussion_topics")
        parent_submission = parent_assignment.submissions.find_by(user_id: student.id)
        topic_sub_assignment = parent_assignment.sub_assignments.create!(context: parent_assignment.context, sub_assignment_tag: CheckpointLabels::REPLY_TO_TOPIC, points_possible: 5, due_at: 3.days.from_now, submission_types: "discussion_topics")
        parent_assignment.sub_assignments.create!(context: parent_assignment.context, sub_assignment_tag: CheckpointLabels::REPLY_TO_ENTRY, points_possible: 10, due_at: 5.days.from_now, submission_types: "discussion_topics")
        topic_sub_assignment.submit_homework(student, submission_type: "discussion_topics")

        json = fake_controller.submission_json(parent_submission, parent_assignment, teacher, session, parent_assignment.context, field, params)
        # gradebook uses these fields to determine a submission needs grading
        expect(json["workflow_state"]).to  eq("pending_review")
        expect(json["submission_type"]).to eq("discussion_topics")
      end

      it "respects submission_type if submission.needs_grading" do
        student = course_with_user("StudentEnrollment", course:, active_all: true, name: "Student").user
        assignment = course.assignments.create!(title: "Assignment 1", has_sub_assignments: true)
        submission = assignment.submit_homework(student, submission_type: "online_text_entry", body: "pay attention to me")

        json = fake_controller.submission_json(submission, assignment, teacher, session, assignment.context, field, params)
        expect(json["submission_type"]).to eq("online_text_entry")
      end
    end

    describe "anonymous_id" do
      let(:field) { "anonymous_id" }
      let(:submission) { assignment.submissions.build(user:) }
      let(:json) do
        fake_controller.submission_json(submission, assignment, user, session, context, [field], params)
      end

      context "when not an account user" do
        it "does not include anonymous_id by default" do
          expect(json).not_to have_key "anonymous_id"
        end

        it "includes anonymous_id when passed anonymize_user_id: true" do
          params[:anonymize_user_id] = true
          expect(json["anonymous_id"]).to eq submission.anonymous_id
        end

        it "excludes user_id when passed anonymize_user_id: true" do
          params[:anonymize_user_id] = true
          expect(json).not_to have_key "user_id"
        end
      end

      context "when an account user" do
        let(:user) do
          user = User.create!
          Account.default.account_users.create!(user:)
          user
        end

        it "does include anonymous_id" do
          expect(json.fetch("anonymous_id")).to eql submission.anonymous_id
        end
      end
    end

    describe "submission status" do
      let(:field) { "submission_status" }
      let(:submission) { assignment.submissions.build(user:) }
      let(:submission_status) do
        lambda do |submission|
          json = fake_controller.submission_json(submission, assignment, user, session, context, [field], params)
          json.fetch(field)
        end
      end

      it "can be Resubmitted" do
        submission.submission_type = "online_text_entry"
        submission.grade_matches_current_submission = false
        submission.workflow_state = "submitted"
        expect(submission_status.call(submission)).to be :resubmitted
      end

      it "can be Missing" do
        assignment.update!(due_at: 1.week.ago, submission_types: "online_text_entry")
        submission.cached_due_date = 1.week.ago
        expect(submission_status.call(submission)).to be :missing
      end

      it "can be Late" do
        assignment.update!(due_at: 1.week.ago)
        submission.submission_type = "online_text_entry"
        submission.cached_due_date = assignment.due_at
        submission.submitted_at = Time.zone.now
        expect(submission_status.call(submission)).to be :late
      end

      it "can be Unsubmitted by workflow state" do
        submission.workflow_state = "unsubmitted"
        expect(submission_status.call(submission)).to be :unsubmitted
      end

      it "is Submitted by default" do
        expect(submission_status.call(submission)).to be :submitted
      end

      it "can be Submitted by workflow state" do
        # make it not submitted first, since submission is already submitted? => true
        submission.workflow_state = "deleted"
        expect do
          submission.workflow_state = "submitted"
        end.to change { submission_status.call(submission) }.from(:unsubmitted).to(:submitted)
      end

      it "can be Submitted by submission type" do
        submission.workflow_state = "deleted"
        submission.submission_type = "online_text_entry"
        expect(submission_status.call(submission)).to be :submitted
      end

      it "can be Submitted by quiz" do
        submission.workflow_state = "deleted"
        submission.submission_type = "online_quiz"
        quiz_submission = instance_double(Quizzes::QuizSubmission, completed?: true, versions: [])
        allow(submission).to receive(:quiz_submission).and_return(quiz_submission)
        expect(submission_status.call(submission)).to be :submitted
      end

      describe "ordinality" do
        describe "Resubmitted before all others," do
          it "is Resubmitted when it was first Missing" do
            # make a missing assignment
            assignment.update!(due_at: 1.week.ago, submission_types: "online_text_entry")
            submission.cached_due_date = 1.week.ago
            # make it resubmitted
            submission.submission_type = "online_text_entry"
            submission.grade_matches_current_submission = false
            submission.workflow_state = "submitted"
            expect(submission_status.call(submission)).to be :resubmitted
          end

          it "is Resubmitted when it was first Late" do
            # make a late assignment
            assignment.update!(due_at: 1.week.ago)
            submission.submission_type = "online_text_entry"
            submission.cached_due_date = assignment.due_at
            submission.submitted_at = Time.zone.now
            # make it resubmitted
            submission.submission_type = "online_text_entry"
            submission.grade_matches_current_submission = false
            submission.workflow_state = "submitted"
            expect(submission_status.call(submission)).to be :resubmitted
          end

          it "is Resubmitted when it was first Submitted" do
            # make a submitted assignment
            submission.workflow_state = "submitted"
            # make it resubmitted
            submission.submission_type = "online_text_entry"
            submission.grade_matches_current_submission = false
            submission.workflow_state = "submitted"
            expect(submission_status.call(submission)).to be :resubmitted
          end

          it "is Resubmitted when it was first Unsubmitted" do
            # make an unsubmitted assignment
            submission.workflow_state = "unsubmitted"
            # make it resubmitted
            submission.submission_type = "online_text_entry"
            submission.grade_matches_current_submission = false
            submission.workflow_state = "submitted"
            expect(submission_status.call(submission)).to be :resubmitted
          end
        end

        describe "Missing before Late, Unsubmitted, and Submitted" do
          it "is Missing when it was first Late" do
            # make a late assignment
            assignment.update!(due_at: 1.week.ago, submission_types: "online_text_entry")
            submission.submission_type = "online_text_entry"
            submission.cached_due_date = assignment.due_at
            submission.submitted_at = Time.zone.now
            # make it missing
            submission.submitted_at = nil
            submission.submission_type = nil
            expect(submission_status.call(submission)).to be :missing
          end

          it "is Missing when it was first Submitted" do
            # make a submission with a submitted label
            submission.workflow_state = "submitted"
            # make it missing
            assignment.update!(due_at: 1.week.ago, submission_types: "online_text_entry")
            submission.assignment = assignment
            submission.cached_due_date = assignment.due_at
            expect(submission_status.call(submission)).to be :missing
          end

          it "is Missing when it was first Unsubmitted" do
            # make an unsubmitted assignment
            submission.workflow_state = "unsubmitted"
            # make it missing
            assignment.update!(due_at: 1.week.ago, submission_types: "online_text_entry")
            submission.assignment = assignment
            submission.cached_due_date = assignment.due_at
            expect(submission_status.call(submission)).to be :missing
          end
        end

        describe "Late before Unsubmitted, and Submitted," do
          it "is Late when it was first Submitted" do
            # make a submitted submission
            submission.workflow_state = "submitted"
            # make it late
            assignment.update!(due_at: 1.week.ago)
            submission.assignment = assignment
            submission.cached_due_date = assignment.due_at
            submission.submission_type = "online_text_entry"
            submission.submitted_at = Time.zone.now
            expect(submission_status.call(submission)).to be :late
          end

          it "is Late when it was first Unsubmitted" do
            # make an unsubmitted assignment
            submission.workflow_state = "unsubmitted"
            # make it late
            assignment.update!(due_at: 1.week.ago)
            submission.assignment = assignment
            submission.cached_due_date = assignment.due_at
            submission.submission_type = "online_text_entry"
            submission.submitted_at = Time.zone.now
            expect(submission_status.call(submission)).to be :late
          end
        end

        it "is Unsubmitted when it was first submitted" do
          # make a submitted submission
          submission.workflow_state = "submitted"
          # make it unsubmitted
          submission.workflow_state = "unsubmitted"
          expect(submission_status.call(submission)).to be :unsubmitted
        end
      end
    end

    describe "grading status" do
      let(:field) { "grading_status" }
      let(:grading_status) do
        lambda do |submission|
          json = fake_controller.submission_json(submission, assignment, user, session, context, [field], params)
          json.fetch(field)
        end
      end

      it "can be Excused" do
        submission.excused = true
        expect(grading_status.call(submission)).to be :excused
      end

      it "can be Needs Review" do
        submission.workflow_state = "pending_review"
        expect(grading_status.call(submission)).to be :needs_review
      end

      it "can be Needs Grading" do
        submission.submission_type = "online_text_entry"
        submission.workflow_state = "submitted"
        expect(grading_status.call(submission)).to be :needs_grading
      end

      it "can be Graded" do
        submission.score = 10
        submission.workflow_state = "graded"
        expect(grading_status.call(submission)).to be :graded
      end

      it "otherwise returns nil" do
        submission.workflow_state = "deleted"
        expect(grading_status.call(submission)).to be_nil
      end

      describe "ordinality" do
        describe "Excused before all others," do
          it "is Excused when it was first Pending Review" do
            # make a submission that is pending review
            submission.workflow_state = "pending_review"
            # make it excused
            submission.excused = true
            expect(grading_status.call(submission)).to be :excused
          end

          it "is Excused when it was first Needs Grading" do
            # make a submission that needs grading
            submission.submission_type = "online_text_entry"
            submission.workflow_state = "submitted"
            # make it excused
            submission.excused = true
            expect(grading_status.call(submission)).to be :excused
          end

          it "is Excused when it was first graded" do
            # make a submission graded
            submission.workflow_state = "graded"
            submission.score = 10
            # make it excused
            submission.excused = true
            expect(grading_status.call(submission)).to be :excused
          end

          it "is Excused when it was first nil" do
            # make a submission with a nil label
            submission.workflow_state = "deleted"
            # make it excused
            submission.excused = true
            expect(grading_status.call(submission)).to be :excused
          end
        end

        describe "Needs Review before Needs Grading, Graded, and nil," do
          it "is Needs Review when it was first Needs Grading" do
            # make a submission that needs grading
            submission.submission_type = "online_text_entry"
            submission.workflow_state = "submitted"
            # make it needs_review
            submission.workflow_state = "pending_review"
            expect(grading_status.call(submission)).to be :needs_review
          end

          it "is Needs Review when it was first graded" do
            # make a submission graded
            submission.workflow_state = "graded"
            submission.score = 10
            # make it needs_review
            submission.workflow_state = "pending_review"
            expect(grading_status.call(submission)).to be :needs_review
          end

          it "is Needs Review when it was first nil" do
            # make a submission with a nil label
            submission.workflow_state = "deleted"
            # make it needs_review
            submission.workflow_state = "pending_review"
            expect(grading_status.call(submission)).to be :needs_review
          end
        end

        describe "Needs Grading before Graded and nil," do
          it "is Needs Grading when it was first graded" do
            # make a submission graded
            submission.workflow_state = "graded"
            submission.score = 10
            # make it needs_grading
            submission.submission_type = "online_text_entry"
            submission.workflow_state = "submitted"
            expect(grading_status.call(submission)).to be :needs_grading
          end

          it "is Needs Grading when it was first nil" do
            # make a submission with a nil label
            submission.workflow_state = "deleted"
            # make it needs_grading
            submission.submission_type = "online_text_entry"
            submission.workflow_state = "submitted"
            expect(grading_status.call(submission)).to be :needs_grading
          end
        end

        it "is Graded when it was first nil" do
          # make a submission with a nil label
          submission.workflow_state = "deleted"
          # make it graded
          submission.workflow_state = "graded"
          submission.score = 10
          expect(grading_status.call(submission)).to be :graded
        end
      end
    end

    describe "canvadoc url" do
      let(:course) { Course.create! }
      let(:assignment) { course.assignments.create! }
      let(:teacher) { course_with_user("TeacherEnrollment", course:, active_all: true, name: "Teacher").user }
      let(:student) { course_with_user("StudentEnrollment", course:, active_all: true, name: "Student").user }
      let(:attachment) { attachment_model(content_type: "application/pdf", context: student) }
      let(:submission) { assignment.submit_homework(student, submission_type: "online_upload", attachments: [attachment]) }
      let(:json) { fake_controller.submission_json(submission, assignment, teacher, session) }

      before do
        allow(Canvadocs).to receive_messages(annotations_supported?: true, enabled?: true)
        Canvadoc.create!(document_id: "abc123#{attachment.id}", attachment_id: attachment.id)
      end

      it "includes the submission id in the attachment's preview url" do
        expect(json.fetch(:attachments).first.fetch(:preview_url)).to include("submission_id%22:#{submission.id}")
      end
    end

    describe "Quizzes.Next" do
      before do
        allow(assignment).to receive(:quiz_lti?).and_return(true)
        url_grades.each do |h|
          grade = "#{TextHelper.round_if_whole(h[:grade] * 100)}%"
          grade, score = assignment.compute_grade_and_score(grade, nil)
          submission.grade = grade
          submission.score = score
          submission.submission_type = "basic_lti_launch"
          submission.workflow_state = "submitted"
          submission.submitted_at = Time.zone.now
          submission.url = h[:url]
          submission.grader_id = -1
          submission.with_versioning(explicit: true) { submission.save! }
        end
      end

      let(:field) { "submission_history" }

      let(:submission) { assignment.submissions.build(user:) }

      let(:json) do
        fake_controller.submission_json(submission, assignment, user, session, context, [field], params)
      end

      let(:urls) do
        %w[
          https://abcdef.com/uuurrrlll00
          https://abcdef.com/uuurrrlll01
          https://abcdef.com/uuurrrlll02
          https://abcdef.com/uuurrrlll03
        ]
      end

      let(:url_grades) do
        [
          # url 0 group
          { url: urls[0], grade: 0.11 },
          { url: urls[0], grade: 0.12 },
          # url 1 group
          { url: urls[1], grade: 0.22 },
          { url: urls[1], grade: 0.23 },
          { url: urls[1], grade: 0.24 },
          # url 2 group
          { url: urls[2], grade: 0.33 },
          # url 3 group
          { url: urls[3], grade: 0.44 },
          { url: urls[3], grade: 0.45 },
          { url: urls[3], grade: 0.46 },
          { url: urls[3], grade: 0.47 },
          { url: urls[3], grade: 0.48 }
        ]
      end

      it "outputs submission histories only for distinct urls with not null grade and score" do
        fields = json.fetch(field)
        expect(fields.count).to be 4
        fields.each do |field|
          expect(field["grade"]).not_to be_nil
          expect(field["score"]).not_to be_nil
        end
      end

      it "outputs submission histories only for distinct urls with null grade and score" do
        assignment.ensure_post_policy(post_manually: true)
        fields = json.fetch(field)
        expect(fields.count).to be 4
        fields.each do |field|
          expect(field["grade"]).to be_nil
          expect(field["score"]).to be_nil
        end
      end
    end

    describe "posted_at" do
      let(:field) { "posted_at" }
      let(:submission) { assignment.submissions.build(user:) }
      let(:json) do
        fake_controller.submission_json(submission, assignment, user, session, context, [field], params)
      end

      it "is included" do
        posted_at = Time.zone.now
        submission.update!(posted_at:)

        expect(json.fetch("posted_at")).to eq posted_at
      end
    end

    describe "body" do
      let(:field) { "body" }

      it "is included if the submission is not quiz-based" do
        assignment.update!(submission_types: "online_text_entry")
        assignment.submit_homework(user, submission_type: "online_text_entry", body: "pay attention to me")

        submission = assignment.submission_for_student(user)
        submission_json = fake_controller.submission_json(submission, assignment, user, session, context, [field], params)
        expect(submission_json.fetch(field)).to eq "pay attention to me"
      end

      context "when the submission is quiz-based" do
        # quiz_with_submission returns a QuizSubmission, but we want the
        # attached (non-quiz) Submission object instead
        let(:submission_for_quiz) { quiz_with_submission.submission }

        let(:quiz_assignment) { submission_for_quiz.assignment }
        let(:quiz) { quiz_assignment.quiz }
        let(:course) { quiz_assignment.course }

        it "is included if the caller has permission to see the user's grade" do
          submission_json = fake_controller.submission_json(submission_for_quiz, quiz_assignment, teacher, session, course, [field], params)
          # submissions for quizzes set the "body" field to a string of the form
          # user: <id>, quiz: <id>, score: <score>, time: <time graded>
          expect(submission_json.fetch(field)).to include("quiz: #{quiz.id}")
        end

        it "is not included if the caller does not have permission to see the user's grade" do
          submission_json = fake_controller.submission_json(submission_for_quiz, quiz_assignment, user, session, course, [field], params)
          expect(submission_json.fetch(field)).to be_nil
        end
      end
    end

    describe "read_state" do
      let(:field) { "read_state" }

      before do
        submission.mark_unread(user)
      end

      it "is included when requested by include[]=read_state" do
        submission_json = fake_controller.submission_json(submission, assignment, user, session, course, [field], params)
        expect(submission_json.fetch(field)).to eq("unread")
      end

      it "is marked as read after being queried" do
        fake_controller.submission_json(submission, assignment, user, session, course, [field], params)
        expect(submission).to be_read(user)
      end
    end

    it "submission json returns video when media comment type is a specific video mime type" do
      submission = assignment.submission_for_student(user)
      submission.media_comment_id = 1
      submission.media_comment_type = "video/mp4"
      fake_controller.current_user = user
      submission_json = fake_controller.submission_json(submission, assignment, user, session, context)
      expect(submission_json.fetch("media_comment")["media_type"]).to eq "video"
    end

    describe "include submission_comments" do
      before do
        @submission_comment = submission.submission_comments.create!
        @submission_comment.comment = "<div>My html comment</div>"
        @submission_comment.save!
      end

      it "returns submission comments without html tags" do
        submission = assignment.submission_for_student(user)
        fake_controller.current_user = user
        submission_json = fake_controller.submission_json(submission, assignment, user, session, context, ["submission_comments"])
        expect(submission_json.fetch("submission_comments").first["comment"]).to eq "My html comment"
      end
    end

    describe "include submission_html_comments" do
      before do
        @submission_comment = submission.submission_comments.create!
        @submission_comment.comment = "<div>My html comment</div>"
        @submission_comment.save!
      end

      it "returns submission comments with html tags" do
        submission = assignment.submission_for_student(user)
        fake_controller.current_user = user
        submission_json = fake_controller.submission_json(submission, assignment, user, session, context, ["submission_html_comments"])
        expect(submission_json.fetch("submission_html_comments").first["comment"]).to eq "<div>My html comment</div>"
      end
    end
  end

  describe "#submission_zip" do
    let(:attachment) { fake_controller.submission_zip(assignment) }

    it "locks the attachment if the assignment anonymizes students" do
      allow(assignment).to receive(:anonymize_students?).and_return(true)
      expect(attachment).to be_locked
    end

    it "does not lock the attachment if the assignment is not anonymous" do
      allow(assignment).to receive(:anonymize_students?).and_return(false)
      expect(attachment).not_to be_locked
    end

    it "does not blow up when a quiz has a prior attachment" do
      qsub = quiz_with_submission
      quiz = qsub.quiz
      quiz.attachments.create!(
        display_name: "submissions.zip",
        uploaded_data: default_uploaded_data,
        workflow_state: "zipped",
        user_id: user.id,
        locked: quiz.anonymize_students?
      )
      fake_controller.current_user = user
      expect(fake_controller.submission_zip(quiz)).to be_truthy
    end
  end
end
