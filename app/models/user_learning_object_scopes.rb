# frozen_string_literal: true

#
# Copyright (C) 2018 - present Instructure, Inc.
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

module UserLearningObjectScopes
  ULOS_DEFAULT_LIMIT = 15

  # This is a helper method for converting a method call's regular parameters
  # and named parameters into a hash. `opts` is considered to be a keyword that
  # contains the rest of the named parameters passed to the method. The `opts`
  # parameter is merged into the return value.
  #
  # This is useful for using the parameters as a cache key and for forwarding
  # named parameters to another method.
  def _params_hash(parent_binding)
    caller_method = method(caller_locations(1, 1).first.base_label)
    caller_param_names = caller_method.parameters.map(&:last)
    param_values = caller_param_names.index_with { |v| parent_binding.local_variable_get(v) }
    opts = param_values[:opts]
    param_values = param_values.except(:opts).merge(opts) if opts
    param_values
  end

  def ignore_item!(asset, purpose, permanent = false)
    asset.ignores.upsert(
      { user_id: id, purpose:, permanent: },
      unique_by: %i[asset_id asset_type user_id purpose],
      update_only: :permanent
    )

    touch
  end

  def assignments_visible_in_course(course)
    return course.active_assignments if course.grants_any_right?(self,
                                                                 :read_as_admin,
                                                                 :manage_grades,
                                                                 *RoleOverride::GRANULAR_MANAGE_ASSIGNMENT_PERMISSIONS)

    published_visible_assignments = course.active_assignments.published
    DifferentiableAssignment.scope_filter(published_visible_assignments,
                                          self,
                                          course,
                                          is_teacher: false)
  end

  # everything is relative to the user's shard
  def course_ids_for_todo_lists(permission_type, course_ids: nil, contexts: nil, include_concluded: false)
    return [] if course_ids&.empty?
    return [] if contexts&.empty?

    shard.activate do
      GuardRail.activate(:secondary) do
        result = if include_concluded
                   all_course_ids
                 else
                   case permission_type
                   when :student
                     participating_student_course_ids
                   else
                     manageable_enrollments_by_permission(permission_type).map(&:course_id)
                   end
                 end

        result &= course_ids if course_ids
        result &= Array.wrap(contexts).select { |c| c.is_a?(Course) }.map(&:id) if contexts
        result
      end
    end
  end

  # everything is relative to the user's shard
  def group_ids_for_todo_lists(group_ids: nil, contexts: nil)
    return [] if group_ids&.empty?
    return [] if contexts&.empty?

    shard.activate do
      result = cached_current_group_memberships_by_date.map(&:group_id)
      result &= group_ids if group_ids
      result &= Array.wrap(contexts).select { |g| g.is_a?(Group) }.map(&:id) if contexts
      result
    end
  end

  def objects_needing(
    object_type,
    purpose,
    participation_type,
    params,
    expires_in,
    limit: ULOS_DEFAULT_LIMIT,
    scope_only: false,
    course_ids: nil,
    group_ids: nil,
    contexts: nil,
    include_concluded: false,
    include_ignored: false,
    include_ungraded: false
  )
    original_shard = Shard.current
    shard.activate do
      course_ids = course_ids_for_todo_lists(participation_type,
                                             course_ids:,
                                             contexts:,
                                             include_concluded:)
      group_ids = group_ids_for_todo_lists(group_ids:, contexts:)
      ids_by_shard = Hash.new({ course_ids: [].freeze, group_ids: [].freeze }.freeze)
      Shard.partition_by_shard(course_ids) do |shard_course_ids|
        ids_by_shard[Shard.current] = { course_ids: shard_course_ids, group_ids: [] }
      end
      Shard.partition_by_shard(group_ids) do |shard_group_ids|
        ids_by_shard[Shard.current] = ids_by_shard[Shard.current].merge(group_ids: shard_group_ids)
      end

      if scope_only
        original_shard.activate do
          # only provide scope on current shard
          shard_course_ids = ids_by_shard.dig(original_shard, :course_ids)
          shard_group_ids = ids_by_shard.dig(original_shard, :group_ids)
          if shard_course_ids.present? || shard_group_ids.present?
            return yield(*arguments_for_objects_needing(
              object_type,
              purpose,
              shard_course_ids,
              shard_group_ids,
              participation_type,
              include_ignored:,
              include_ungraded:
            ))
          end
          return object_type.constantize.none # fallback
        end
      else
        course_ids_cache_key = Digest::SHA256.hexdigest(course_ids.sort.join("/"))
        params_cache_key = Digest::SHA256.hexdigest(ActiveSupport::Cache.expand_cache_key(params))
        cache_key = [self, "#{object_type}_needing_#{purpose}", course_ids_cache_key, params_cache_key].cache_key

        Rails.cache.fetch_with_batched_keys(cache_key, expires_in:, batch_object: self, batched_keys: :todo_list) do
          result = GuardRail.activate(:secondary) do
            ids_by_shard.flat_map do |shard, shard_hash|
              shard.activate do
                yield(*arguments_for_objects_needing(
                  object_type,
                  purpose,
                  shard_hash[:course_ids],
                  shard_hash[:group_ids],
                  participation_type,
                  include_ignored:,
                  include_ungraded:
                ))
              end
            end
          end
          result = result[0...limit] if limit # limit is sometimes passed in as nil explicitly
          result
        end
      end
    end
  end

  def arguments_for_objects_needing(
    object_type,
    purpose,
    shard_course_ids,
    shard_group_ids,
    participation_type,
    include_ignored: false,
    include_ungraded: false
  )
    scope = object_type.constantize
    scope = scope.not_ignored_by(self, purpose) unless include_ignored
    scope = scope.for_course(shard_course_ids) if ["Assignment", "Quizzes::Quiz"].include?(object_type)

    course_ids_by_account_id = Course.where(id: shard_course_ids).group(:account_id).pluck(Arel.sql("account_id, ARRAY_AGG(id)")).to_h
    accounts_with_checkpoints, accounts_without_checkpoints = Account.where(id: course_ids_by_account_id.keys).partition(&:discussion_checkpoints_enabled?)
    course_ids_with_checkpoints_enabled = accounts_with_checkpoints.flat_map { |account| course_ids_by_account_id[account.id] }
    course_ids_with_checkpoints_disabled = accounts_without_checkpoints.flat_map { |account| course_ids_by_account_id[account.id] }

    scope = scope.for_course(course_ids_with_checkpoints_enabled) if object_type == "SubAssignment"

    if ["Assignment", "SubAssignment"].include?(object_type)
      scope = (participation_type == :student) ? scope.published : scope.active
      scope = scope.expecting_submission unless include_ungraded

      if object_type == "Assignment"
        # if checkopoints is enabled for a course, only include non-checkpointed assignments
        # if checkpoints is disabled, include all assignments
        scope = scope.for_course(course_ids_with_checkpoints_enabled).where(has_sub_assignments: false)
                     .or(scope.for_course(course_ids_with_checkpoints_disabled))
      end
    end
    [scope, shard_course_ids, shard_group_ids]
  end

  def assignments_for_student(
    purpose,
    limit: ULOS_DEFAULT_LIMIT,
    due_after: 2.weeks.ago,
    due_before: 2.weeks.from_now,
    cache_timeout: 120.minutes,
    include_locked: false,
    is_sub_assignment: false,
    **opts # arguments that are just forwarded to objects_needing
  )
    params = _params_hash(binding)
    object_type = is_sub_assignment ? "SubAssignment" : "Assignment"
    objects_needing(object_type,
                    purpose,
                    :student,
                    params,
                    cache_timeout,
                    limit:,
                    **opts) do |assignment_scope|
      assignments = assignment_scope.due_between_for_user(due_after, due_before, self)

      if opts[:course_ids].present?
        active_enrollment_course_ids = Enrollment.where(Enrollment.active_student_conditions)
                                                 .where(user_id: id, course_id: opts[:course_ids]).pluck(:course_id)
        assignments = assignments.visible_to_students_in_course_with_da([id], active_enrollment_course_ids, nil, opts[:include_concluded])
      end

      assignments = assignments.need_submitting_info(id, limit) if purpose == "submitting"
      assignments = assignments.having_submissions_for_user(id) if purpose == "submitted"
      assignments = assignments.without_suppressed_assignments
      if purpose == "submitting"
        assignments = assignments.submittable.or(assignments.where("assignments.user_due_date > ?", Time.zone.now))
      end
      assignments = assignments.not_locked unless include_locked
      assignments
    end
  end

  def assignments_needing_submitting(
    due_after: 4.weeks.ago,
    due_before: 1.week.from_now,
    scope_only: false,
    include_concluded: false,
    is_sub_assignment: false,
    **opts # forward args to assignments_for_student
  )
    opts[:cache_timeout] = 15.minutes
    params = _params_hash(binding)
    assignments = assignments_for_student("submitting", **params)
    return assignments if scope_only

    select_available_assignments(assignments, include_concluded:)
  end

  def submitted_assignments(
    scope_only: false,
    include_concluded: false,
    **opts # forward args to assignments_for_student
  )
    params = _params_hash(binding)
    assignments = assignments_for_student("submitted", **params)
    return assignments if scope_only

    select_available_assignments(assignments, include_concluded:)
  end

  def ungraded_quizzes(
    limit: ULOS_DEFAULT_LIMIT,
    due_after: Time.zone.now,
    due_before: 1.week.from_now,
    needing_submitting: false,
    scope_only: false,
    include_locked: false,
    include_concluded: false,
    **opts # arguments that are just forwarded to objects_needing
  )
    params = _params_hash(binding)
    opts.merge!(params.slice(:limit, :scope_only, :include_concluded))
    objects_needing("Quizzes::Quiz", "viewing", :student, params, 15.minutes, **opts) do |quiz_scope|
      quizzes = quiz_scope.available
      quizzes = quizzes.not_locked unless include_locked
      quizzes = quizzes
                .ungraded_due_between_for_user(due_after, due_before, self)
                .preload(:context)
      quizzes = quizzes.need_submitting_info(id, limit) if needing_submitting
      return quizzes if scope_only

      select_available_assignments(quizzes, include_concluded:)
    end
  end

  def submissions_needing_peer_review(
    limit: ULOS_DEFAULT_LIMIT,
    due_after: 2.weeks.ago,
    due_before: 2.weeks.from_now,
    scope_only: false,
    include_ignored: false,
    **opts # arguments that are just forwarded to objects_needing
  )
    params = _params_hash(binding)
    opts.merge!(params.slice(:limit, :scope_only, :include_ignored))
    objects_needing("AssessmentRequest", "reviewing", :student, params, 15.minutes, **opts) do |ar_scope, shard_course_ids|
      ar_scope = ar_scope.joins(submission: :assignment)
                         .joins("INNER JOIN #{Submission.quoted_table_name} AS assessor_asset ON assessment_requests.assessor_asset_id = assessor_asset.id
               AND assessor_asset.assignment_id = assignments.id")
                         .where(assessor_id: id)
                         .where(assessor_asset: { course_id: shard_course_ids })
                         .joins("INNER JOIN #{Enrollment.quoted_table_name} AS enrollments ON enrollments.user_id = assessment_requests.user_id
               AND enrollments.course_id = assessor_asset.course_id AND enrollments.workflow_state NOT IN ('rejected', 'completed', 'deleted', 'inactive')")
      ar_scope = ar_scope.incomplete unless scope_only
      ar_scope = ar_scope.for_courses(shard_course_ids)

      # The below merging of scopes mimics a portion of the behavior for checking the access policy
      # for the submissions, ensuring that the user has access and can read & comment on them.
      # The check for making sure that the user is a participant in the course is already made
      # by using `course_ids_for_todo_lists` through `objects_needing`
      ar_scope = ar_scope.merge(Submission.active)
                         .merge(Assignment.published.where(peer_reviews: true))

      if due_before
        ar_scope = ar_scope.where(assessor_asset: { cached_due_date: ..due_before })
      end

      if due_after
        ar_scope = ar_scope.where("assessor_asset.cached_due_date > ?", due_after)
      end

      if scope_only
        ar_scope
      else
        result = limit ? ar_scope.take(limit) : ar_scope.to_a
        result
      end
    end
  end

  # opts forwaded to course_ids_for_todo_lists
  def submissions_needing_grading_count(**)
    if ::DynamicSettings.find(tree: :private, cluster: Shard.current.database_server.id)["disable_needs_grading_queries", failsafe: false]
      return 0
    end

    course_ids = course_ids_for_todo_lists(:manage_grades, **)
    Submission.active
              .needs_grading
              .joins("INNER JOIN #{Enrollment.quoted_table_name} AS grader_enrollments ON assignments.context_id = grader_enrollments.course_id")
              .where(assignments: { context_id: course_ids })
              .merge(Assignment.expecting_submission)
              .merge(Assignment.published)
              .where(grader_enrollments: { workflow_state: "active", user_id: self, type: ["TeacherEnrollment", "TaEnrollment"] })
              .where("grader_enrollments.limit_privileges_to_course_section = 'f'
        OR grader_enrollments.course_section_id = enrollments.course_section_id")
              .where.not(
                Ignore.where(asset_type: "Assignment",
                             user_id: self,
                             purpose: "grading").where("asset_id=submissions.assignment_id")
                           .arel.exists
              ).count
  end

  def assignments_needing_grading(limit: ULOS_DEFAULT_LIMIT, scope_only: false, is_sub_assignment: false, **opts)
    if ::DynamicSettings.find(tree: :private, cluster: Shard.current.database_server.id)["disable_needs_grading_queries", failsafe: false]
      scope = is_sub_assignment ? SubAssignment.none : Assignment.none
      return scope_only ? scope : []
    end

    params = _params_hash(binding)
    params.delete(:is_sub_assignment)
    # not really any harm in extending the expires_in since we touch the user anyway when grades change
    object_type = is_sub_assignment ? "SubAssignment" : "Assignment"
    objects_needing(object_type, "grading", :manage_grades, params, 120.minutes, **params) do |assignment_scope|
      if Setting.get("assignments_needing_grading_new_style", "true") == "true"
        submissions_needing_grading = Submission.select(:assignment_id, :user_id)
                                                .joins("INNER JOIN (#{assignment_scope.to_sql}) assignments ON assignment_id=assignments.id")
                                                .where(Submission.needs_grading_conditions)
        student_enrollments = Enrollment.from("#{Enrollment.quoted_table_name} student_enrollments")
                                        .select("1")
                                        .where("student_enrollments.course_id=assignments.context_id")
                                        .where("student_enrollments.user_id=submissions_needing_grading.user_id AND student_enrollments.workflow_state='active'")
                                        .where("(enrollments.limit_privileges_to_course_section='f' OR student_enrollments.course_section_id=enrollments.course_section_id)")
        as = assignment_scope.joins("INNER JOIN (#{submissions_needing_grading.to_sql}) AS submissions_needing_grading ON assignments.id=submissions_needing_grading.assignment_id")
                             .where(student_enrollments.arel.exists)
      else
        as = assignment_scope
             .where("EXISTS (#{grader_visible_submissions_sql})")
      end
      as = as.joins("INNER JOIN #{Enrollment.quoted_table_name} ON enrollments.course_id = assignments.context_id")
             .where(enrollments: { user_id: self, workflow_state: "active", type: ["TeacherEnrollment", "TaEnrollment"] })
             .group("assignments.id")
             .order("assignments.due_at")
             .preload(:context)
      if scope_only
        as # This needs the below `select` somehow to work
      else
        GuardRail.activate(:secondary) do
          as.lazy.reject { |a| Assignments::NeedsGradingCountQuery.new(a, self).count == 0 }.take(limit).to_a
        end
      end
    end
  end

  def grader_visible_submissions_sql
    "SELECT submissions.id
       FROM #{Submission.quoted_table_name}
       INNER JOIN #{Enrollment.quoted_table_name} AS student_enrollments ON student_enrollments.user_id = submissions.user_id
                                                                        AND student_enrollments.course_id = submissions.course_id
      WHERE submissions.assignment_id = assignments.id
        AND (enrollments.limit_privileges_to_course_section = 'f'
         OR enrollments.course_section_id = student_enrollments.course_section_id)
        AND #{Submission.needs_grading_conditions}
        AND student_enrollments.workflow_state = 'active'"
  end

  def assignments_needing_moderation(
    limit: ULOS_DEFAULT_LIMIT,
    scope_only: false,
    **opts # arguments that are just forwarded to objects_needing
  )
    params = _params_hash(binding)
    objects_needing("Assignment", "moderation", :select_final_grade, params, 120.minutes, **params) do |assignment_scope|
      scope = assignment_scope.active
                              .expecting_submission
                              .where(final_grader: self, moderated_grading: true)
                              .where(assignments: { grades_published_at: nil })
                              .where(id: ModeratedGrading::ProvisionalGrade.joins(:submission)
          .where("submissions.assignment_id=assignments.id")
          .where(Submission.needs_grading_conditions).distinct.select(:assignment_id))
                              .preload(:context)
      if scope_only
        scope # Also need to check the rights like below
      else
        scope.lazy.select { |a| a.permits_moderation?(self) }.take(limit).to_a
      end
    end
  end

  # rubocop:disable Style/ArgumentsForwarding -- _params_hash needs the binding
  def discussion_topics_needing_viewing(
    due_after:,
    due_before:,
    **opts # arguments that are just forwarded to objects_needing
  )
    params = _params_hash(binding)
    objects_needing("DiscussionTopic", "viewing", :student, params, 120.minutes, **opts) do |topics_context, shard_course_ids, shard_group_ids|
      topics_context
        .active
        .published
        .for_courses_and_groups(shard_course_ids, shard_group_ids)
        .todo_date_between(due_after, due_before)
        .visible_to_ungraded_discussion_student_visibilities(self)
        # announcements are not shown if lock_at is in the past
        .where.not("discussion_topics.type IS NOT NULL AND discussion_topics.type = 'Announcement' AND discussion_topics.lock_at IS NOT NULL AND discussion_topics.lock_at < ?", Time.zone.now)
    end
  end

  def wiki_pages_needing_viewing(
    due_after:,
    due_before:,
    **opts # arguments that are just forwarded to objects_needing
  )
    params = _params_hash(binding)
    objects_needing("WikiPage", "viewing", :student, params, 120.minutes, **opts) do |wiki_pages_context, shard_course_ids, shard_group_ids|
      wiki_pages_context
        .available_to_planner
        .visible_to_user_in_courses_and_groups(self, shard_course_ids, shard_group_ids)
        .todo_date_between(due_after, due_before)
    end
  end
  # rubocop:enable Style/ArgumentsForwarding
end
