# frozen_string_literal: true

#
# Copyright (C) 2015 - present Instructure, Inc.
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

class ToDoListPresenter
  ASSIGNMENT_LIMIT = 100
  VISIBLE_LIMIT = 5

  attr_reader :needs_grading, :needs_moderation, :needs_submitting, :needs_reviewing

  def initialize(view, user, contexts)
    @view = view
    @user = user
    @contexts = contexts

    if user
      @needs_grading = assignments_needing(:grading)
      # at this point, we also have to check all sub_assignments that need submitting
      sub_assignments_needing_grading = assignments_needing(:grading, is_sub_assignment: true)
      if discussion_checkpoints_enabled_somewhere(sub_assignments_needing_grading)
        @needs_grading += sub_assignments_needing_grading
        @needs_grading.sort_by! { |a| a.due_at || a.updated_at }
      end
      @needs_moderation = assignments_needing(:moderation)
      @needs_submitting = assignments_needing(:submitting, include_ungraded: true)
      @needs_submitting += ungraded_quizzes_needing_submitting
      # at this point, we also have to check all sub_assignments that need submitting
      sub_assignments_needing_submitting = assignments_needing(:submitting, include_ungraded: true, is_sub_assignment: true)
      if discussion_checkpoints_enabled_somewhere(sub_assignments_needing_submitting)
        @needs_submitting += sub_assignments_needing_submitting
      end
      @needs_submitting.sort_by! { |a| a.due_at || a.updated_at }

      assessment_requests = user.submissions_needing_peer_review(contexts:, limit: ASSIGNMENT_LIMIT)
      @needs_reviewing = assessment_requests.filter_map do |ar|
        AssessmentRequestPresenter.new(view, ar, user) if ar.asset.assignment.published?
      end

      # we need a complete list of courses first because we only care about the courses
      # from the assignments involved. not just the contexts handed in.
      deduped_courses = (@needs_grading.map(&:context) + @needs_moderation.map(&:context) +
        @needs_submitting.map(&:context) + @needs_reviewing.map(&:context)).uniq
      course_to_permissions = @user.precalculate_permissions_for_courses(deduped_courses, [:manage_grades])

      @needs_grading = @needs_grading.select do |assignment|
        if course_to_permissions
          course_to_permissions[assignment.context.global_id]&.fetch(:manage_grades, false)
        else
          assignment.context.grants_right?(@user, :manage_grades)
        end
      end
    else
      @needs_grading = []
      @needs_moderation = []
      @needs_submitting = []
      @needs_reviewing = []
    end
  end

  def discussion_checkpoints_enabled_somewhere(assignment_presenter_array)
    assignment_presenter_array&.any? { |ap| ap.assignment.discussion_checkpoints_enabled? } || false
  end

  def assignments_needing(type, opts = {})
    if @user
      @user.send(:"assignments_needing_#{type}", contexts: @contexts, limit: ASSIGNMENT_LIMIT, **opts).map do |assignment|
        AssignmentPresenter.new(@view, assignment, @user, type)
      end
    else
      []
    end
  end

  def ungraded_quizzes_needing_submitting
    @user.ungraded_quizzes(contexts: @contexts, limit: ASSIGNMENT_LIMIT, needing_submitting: true).map do |quiz|
      AssignmentPresenter.new(@view, quiz, @user, :submitting)
    end
  end

  def any_assignments?
    @user && (
      @needs_grading.present? ||
      @needs_moderation.present? ||
      @needs_submitting.present? ||
      @needs_reviewing.present?
    )
  end

  # False when there's only one context (no point in showing its name beneath each assignment), true otherwise.
  def show_context?
    @contexts.nil? || @contexts.length > 1
  end

  def visible_limit
    VISIBLE_LIMIT
  end

  def hidden_count_for(items)
    if items.length > visible_limit
      items.length - visible_limit
    else
      0
    end
  end

  def hidden_count
    @hidden_count ||= [needs_grading, needs_moderation, needs_submitting, needs_reviewing].sum do |items|
      hidden_count_for(items)
    end
  end

  class AssignmentPresenter
    attr_reader :assignment

    delegate :title, :submission_action_string, :points_possible, :due_at, :updated_at, :peer_reviews_due_at, :context, :sub_assignment_tag, to: :assignment

    def initialize(view, assignment, user, type)
      @view = view
      @assignment = assignment
      @assignment = @assignment.overridden_for(user) if type == :submitting
      @user = user
      @type = type
    end

    def needs_moderation_icon_data
      @view.icon_data(context: assignment.context, current_user: @user, recent_event: assignment)
    end

    def needs_submitting_icon_data
      @view.icon_data(context: assignment.context, current_user: @user, recent_event: assignment, student_only: true)
    end

    def context_name
      @assignment.context.nickname_for(@user)
    end

    def short_context_name
      @assignment.context.nickname_for(@user, :short_name)
    end

    def needs_grading_count
      @needs_grading_count ||= Assignments::NeedsGradingCountQuery.new(@assignment, @user).count
    end

    def needs_grading_badge
      if needs_grading_count > 999
        I18n.t("%{more_than}+", more_than: 999)
      else
        needs_grading_count
      end
    end

    def needs_grading_label
      if needs_grading_count > 999
        I18n.t("More than 999 submissions need grading")
      else
        I18n.t({ one: "1 submission needs grading", other: "%{count} submissions need grading" }, count: assignment.needs_grading_count)
      end
    end

    def gradebook_path
      assignment_id = sub_assignment? ? assignment.parent_assignment.id : assignment.id
      @view.speed_grader_course_gradebook_path(assignment.context_id, assignment_id:)
    end

    def moderate_path
      @view.course_assignment_moderate_path(assignment.context_id, assignment)
    end

    def assignment_path
      if assignment.is_a?(Quizzes::Quiz)
        @view.course_quiz_path(assignment.context_id, assignment.id)
      elsif assignment.is_a?(SubAssignment)
        @view.course_assignment_path(assignment.context_id, assignment.parent_assignment_id)
      else
        @view.course_assignment_path(assignment.context_id, assignment.id)
      end
    end

    def ignore_url
      @view.todo_ignore_api_url(@type, @assignment)
    end

    def ignore_title
      case @type
      when :grading
        I18n.t("Ignore until new submission")
      when :moderation
        I18n.t("Ignore until new mark")
      when :submitting
        I18n.t("Ignore this assignment")
      end
    end

    def ignore_sr_message
      case @type
      when :grading
        I18n.t("Ignore %{item} until new submission", item: title)
      when :moderation
        I18n.t("Ignore %{item} until new mark", item: title)
      when :submitting
        I18n.t("Ignore %{item}", item: title)
      end
    end

    def ignore_flash_message
      case @type
      when :grading
        I18n.t("This item will reappear when a new submission is made.")
      when :moderation
        I18n.t("This item will reappear when there are new grades to moderate.")
      end
    end

    def formatted_due_date
      @view.due_at(assignment, @user)
    end

    def formatted_peer_review_due_date
      if assignment.peer_reviews_due_at
        @view.datetime_string(assignment.peer_reviews_due_at)
      else
        I18n.t("No Due Date")
      end
    end

    def sub_assignment?
      assignment.is_a?(SubAssignment)
    end

    def required_replies
      assignment.parent_assignment.discussion_topic.reply_to_entry_required_count
    end
  end

  class AssessmentRequestPresenter
    delegate :context, :context_name, :short_context_name, to: :assignment_presenter
    attr_reader :assignment

    include ApplicationHelper
    include AssignmentsHelper
    include Rails.application.routes.url_helpers

    def initialize(view, assessment_request, user)
      @view = view
      @assessment_request = assessment_request
      @user = user
      @assignment = assessment_request.asset.assignment
    end

    def published?
      @assessment_request.asset.assignment.published?
    end

    def assignment_presenter
      AssignmentPresenter.new(@view, @assignment, @user, :reviewing)
    end

    def submission_path
      student_peer_review_url(@assignment.context, @assignment, @assessment_request)
    end

    def ignore_url
      @view.todo_ignore_api_url("reviewing", @assessment_request)
    end

    def ignore_title
      I18n.t("Ignore this assignment")
    end

    def ignore_sr_message
      I18n.t("Ignore %{assignment}", assignment: @assignment.title)
    end

    def ignore_flash_message; end

    def submission_author_name
      @view.submission_author_name_for(@assessment_request, "#{I18n.t("user")}: ")
    end
  end
end
