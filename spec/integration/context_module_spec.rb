# frozen_string_literal: true

#
# Copyright (C) 2011 - present Instructure, Inc.
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

require "nokogiri"

describe ContextModule do
  def course_module
    course_with_student_logged_in(active_all: true)
    @module = @course.context_modules.create!(name: "some module")
  end

  describe "index" do
    it "requires manage_course_content_edit permission before showing add controls" do
      course_with_teacher_logged_in active_all: true
      get "/courses/#{@course.id}/modules"
      doc = Nokogiri::HTML5(response.body)
      expect(doc.at_css(".add_module_link")).not_to be_nil

      @course.account.role_overrides.create!(
        role: ta_role,
        permission: "manage_course_content_add",
        enabled: false
      )
      course_with_ta course: @course
      user_session(@ta)
      get "/courses/#{@course.id}/modules"
      doc = Nokogiri::HTML5(response.body)
      expect(doc.at_css(".add_module_link")).to be_nil
    end
  end

  it "clears the page cache on individual tag change" do
    enable_cache do
      course_with_teacher_logged_in(active_all: true)
      context_module = @course.context_modules.create!
      content_tag = context_module.add_item type: "context_module_sub_header", title: "My Sub Header Title"
      ContextModule.where(id: context_module).update_all(updated_at: 1.hour.ago)
      get "/courses/#{@course.id}/modules"
      expect(response.body).to match(/My Sub Header Title/)

      content_tag.update(title: "My New Title")

      get "/courses/#{@course.id}/modules"
      expect(response.body).to match(/My New Title/)
    end
  end

  describe "must_contribute" do
    before do
      course_module
      @module.require_sequential_progress = true
      @module.save!
    end

    def before_after
      @module.completion_requirements = { @tag.id => { type: "must_contribute" } }
      @module.save!

      @progression = @module.evaluate_for(@user)
      expect(@progression).not_to be_nil
      expect(@progression).not_to be_completed
      expect(@progression).to be_unlocked
      expect(@progression.current_position).to eql(@tag.position)
      yield
      @progression = @module.evaluate_for(@user)
      expect(@progression).to be_completed
      expect(@progression.current_position).to eql(@tag.position)
    end

    it "progresses for discussions" do
      @discussion = @course.discussion_topics.create!(title: "talk")
      @tag = @module.add_item(type: "discussion_topic", id: @discussion.id)
      before_after do
        post "/courses/#{@course.id}/discussion_entries", params: { discussion_entry: { message: "ohai", discussion_topic_id: @discussion.id } }
        expect(response).to be_redirect
      end
    end

    it "progresses for wiki pages" do
      @page = @course.wiki_pages.create!(title: "talk page", body: "ohai", editing_roles: "teachers,students")
      @tag = @module.add_item(type: "wiki_page", id: @page.id)
      before_after do
        put "/api/v1/courses/#{@course.id}/pages/#{@page.url}", params: { wiki_page: { body: "i agree", title: "talk page" } }
      end
    end

    it "progresses for assignment discussions" do
      @assignment = @course.assignments.create!(title: "talk assn", submission_types: "discussion_topic")
      @tag = @module.add_item(type: "assignment", id: @assignment.id)
      before_after do
        post "/courses/#{@course.id}/discussion_entries", params: { discussion_entry: { message: "ohai", discussion_topic_id: @assignment.discussion_topic.id } }
        expect(response).to be_redirect
      end
    end
  end

  describe "progressing before job is run" do
    def progression_testing(progress_by_item_link)
      enable_cache do
        @is_attachment = false
        course_with_student_logged_in(active_all: true)
        @quiz = @course.quizzes.create!(title: "new quiz", shuffle_answers: true)
        @quiz.publish!

        # separate timestamps so touch_context will actually invalidate caches
        Timecop.freeze(4.seconds.ago) do
          @mod1 = @course.context_modules.create!(name: "some module")
          @mod1.require_sequential_progress = true
          @mod1.save!
          @tag1 = @mod1.add_item(type: "quiz", id: @quiz.id)
          @mod1.completion_requirements = { @tag1.id => { type: "min_score", min_score: 1 } }
          @mod1.save!
        end

        Timecop.freeze(2.seconds.ago) do
          @mod2 = @course.context_modules.create!(name: "dependant module")
          @mod2.prerequisites = "module_#{@mod1.id}"
          @mod2.save!
        end

        # all modules, tags, etc need to be published
        expect(@mod1).to be_published
        expect(@mod2).to be_published
        expect(@quiz).to be_published
        expect(@tag1).to be_published

        yield '<div id="test_content">yay!</div>'
        expect(@tag2).to be_published

        # verify the second item is locked (doesn't display)
        get @test_url
        if @test_url.match?("files")
          expect(response).to have_http_status(:forbidden)
        else
          expect(response).to be_successful
        end
        html = Nokogiri::HTML5(response.body)
        expect(html.css("#test_content").length).to eq(@test_content_length || 0)

        # complete first module's requirements
        p1 = @mod1.evaluate_for(@student)
        expect(p1.workflow_state).to eq "unlocked"

        @quiz_submission = @quiz.generate_submission(@student)
        Quizzes::SubmissionGrader.new(@quiz_submission).grade_submission
        @quiz_submission.workflow_state = "complete"
        @quiz_submission.manually_scored = true
        @quiz_submission.kept_score = 1
        @quiz_submission.save!

        # navigate to the second item (forcing update to progression)
        next_link = if progress_by_item_link
                      "/courses/#{@course.id}/modules/items/#{@tag2.id}"
                    else
                      "/courses/#{@course.id}/modules/#{@mod2.id}/items/first"
                    end
        get next_link
        expect(response).to be_redirect
        expect(response.location.ends_with?("module_item_id=#{@tag2.id}")).to be_truthy

        # verify the second item is accessible
        get @test_url
        expect(response).to be_successful
        html = Nokogiri::HTML5(response.body)
        if @is_attachment
          expect(html.at_css("#file_content")["src"]).to match(/#{@test_url.split("?").first}/)
        elsif @is_wiki_page
          expect(html.css("#wiki_page_show").length).to eq 1
        elsif @test_url.match?("discussion_topics")
          expect(html.css("#test_content").length).to eq 0
        else
          expect(html.css("#test_content").length).to eq 1
        end
      end
    end

    it "progresses to assignment" do
      [true, false].each do |progress_type|
        progression_testing(progress_type) do |content|
          asmnt = @course.assignments.create!(title: "assignment", description: content)
          @test_url = "/courses/#{@course.id}/assignments/#{asmnt.id}"
          @tag2 = @mod2.add_item(type: "assignment", id: asmnt.id)
          expect(@tag2).to be_published
        end
      end
    end

    it "progresses to discussion topic" do
      [true, false].each do |progress_type|
        progression_testing(progress_type) do |content|
          discussion = @course.discussion_topics.create!(title: "topic", message: content)
          @test_url = "/courses/#{@course.id}/discussion_topics/#{discussion.id}"
          @tag2 = @mod2.add_item(type: "discussion_topic", id: discussion.id)
          expect(@tag2).to be_published
        end
      end
    end

    it "progresses to a quiz" do
      [true, false].each do |progress_type|
        progression_testing(progress_type) do |content|
          quiz = @course.quizzes.create!(title: "quiz", description: content)
          quiz.publish!
          @test_url = "/courses/#{@course.id}/quizzes/#{quiz.id}"
          @tag2 = @mod2.add_item(type: "quiz", id: quiz.id)
          expect(@tag2).to be_published
        end
      end
    end

    it "progresses to a wiki page" do
      [true, false].each do |progress_type|
        progression_testing(progress_type) do |content|
          page = @course.wiki_pages.create!(title: "wiki", body: content)
          @test_url = "/courses/#{@course.id}/pages/#{page.url}"
          @tag2 = @mod2.add_item(type: "wiki_page", id: page.id)
          expect(@tag2).to be_published
          @is_wiki_page = true
        end
      end
    end

    it "progresses to an attachment" do
      [true, false].each do |progress_type|
        progression_testing(progress_type) do |content|
          @is_attachment = true
          att = Attachment.create!(filename: "test.html", display_name: "test.html", uploaded_data: StringIO.new(content), folder: Folder.unfiled_folder(@course), context: @course)
          @test_url = "/courses/#{@course.id}/files/#{att.id}?fd_cookie_set=1"
          @tag2 = @mod2.add_item(type: "attachment", id: att.id)
          expect(@tag2).to be_published
        end
      end
    end
  end

  describe "caching" do
    it "caches the view separately for each time zone" do
      enable_cache do
        course_factory active_all: true

        mod = @course.context_modules.create!
        mod.unlock_at = Time.utc(2014, 12, 25, 12, 0)
        mod.save!

        teacher1 = teacher_in_course(active_all: true).user
        teacher1.time_zone = "America/Los_Angeles"
        teacher1.save!

        teacher2 = teacher_in_course(active_all: true).user
        teacher2.time_zone = "America/New_York"
        teacher2.save!

        user_session teacher1
        get "/courses/#{@course.id}/modules"
        expect(response).to be_successful
        body1 = Nokogiri::HTML5(response.body)

        user_session teacher2
        get "/courses/#{@course.id}/modules"
        expect(response).to be_successful
        body2 = Nokogiri::HTML5(response.body)

        expect(body1.at_css("#context_module_content_#{mod.id} .unlock_details").text).to match(/4am/)
        expect(body2.at_css("#context_module_content_#{mod.id} .unlock_details").text).to match(/7am/)
      end
    end
  end
end
