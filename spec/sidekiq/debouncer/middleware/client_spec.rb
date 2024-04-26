# frozen_string_literal: true

require "spec_helper"
require_relative "../../../support/context"
require_relative "../../../support/test_workers"
require_relative "../../../support/test_middlewares"

describe Sidekiq::Debouncer::Middleware::Client do
  include_context "sidekiq"

  context "task with debounce" do
    context "1 task" do
      it "executes it after 5 minutes" do
        TestWorker.perform_async("A", "job 1")

        expect(schedule_set.size).to eq(1)

        set_item = schedule_set.first
        expect(set_item.value).to eq("debounce/TestWorker/A")
        expect(set_item.score).to eq((time_start + 5 * 60).to_i)
      end

      it "doesnt land in queue" do
        TestWorker.perform_async("A", "job 1")

        expect(queue.size).to eq(0)
      end

      it "saves job in stream" do
        TestWorker.perform_async("A", "job 1")

        Sidekiq.redis do |connection|
          expect(connection.call("XRANGE", "debounce/TestWorker/A", "-", "+")).to eq([["1451649900-0", ["args", '["A","job 1"]']]])
        end
      end

      it "executes it after 5 minutes for symbol debounce" do
        expect(TestWorkerWithSymbolAsDebounce).to receive(:debounce_method).with(["A", "job 1"]).once.and_call_original
        TestWorkerWithSymbolAsDebounce.perform_async("A", "job 1")

        expect(schedule_set.size).to eq(1)

        set_item = schedule_set.first
        expect(set_item.value).to eq("debounce/TestWorkerWithSymbolAsDebounce/A")
        expect(set_item.score).to eq((time_start + 5 * 60).to_i)
      end

      it "executes the rest of middleware stack" do
        TestWorker.perform_async("AB", "job 33")

        expect(schedule_set.size).to eq(1)

        Sidekiq.redis do |connection|
          expect(connection.call("XRANGE", "debounce/TestWorker/ABC", "-", "+")).to eq([["1451649900-0", ["args", '["ABC","job 34"]']]])
        end
      end
    end

    context "1 task, 3 minutes break, 1 task" do
      it "executes both tasks after 8 minutes for multiple arguments" do
        TestWorkerWithMultipleArguments.perform_async(1, 5)

        Timecop.freeze(time_start + 3 * 60)
        TestWorkerWithMultipleArguments.perform_async(3, 3)

        expect(schedule_set.size).to eq(1)

        set_item = schedule_set.first
        expect(set_item.value).to eq("debounce/TestWorkerWithMultipleArguments/6")
        expect(set_item.score).to eq((time_start + 8 * 60).to_i)

        expect(queue.size).to eq(0)
      end

      it "executes both tasks after 8 minutes" do
        TestWorker.perform_async("A", "job 1")

        Timecop.freeze(time_start + 3 * 60)
        TestWorker.perform_async("A", "job 2")

        expect(schedule_set.size).to eq(1)

        set_item = schedule_set.first
        expect(set_item.value).to eq("debounce/TestWorker/A")
        expect(set_item.score).to eq((time_start + 8 * 60).to_i)

        expect(queue.size).to eq(0)
      end

      it "executes both tasks after 8 minutes for symbol debounce" do
        TestWorkerWithSymbolAsDebounce.perform_async("A", "job 1")

        Timecop.freeze(time_start + 3 * 60)
        TestWorkerWithSymbolAsDebounce.perform_async("A", "job 2")

        expect(schedule_set.size).to eq(1)

        set_item = schedule_set.first
        expect(set_item.value).to eq("debounce/TestWorkerWithSymbolAsDebounce/A")
        expect(set_item.score).to eq((time_start + 8 * 60).to_i)

        expect(queue.size).to eq(0)
      end
    end

    context "1 task, 3 minutes break, 1 task, 6 minutes break, 2 tasks" do
      it "executes two tasks after 8 minutes, the last one in 14 minutes" do
        TestWorker.perform_async("A", "job 1")

        Timecop.freeze(time_start + 3 * 60)
        TestWorker.perform_async("A", "job 2")

        Timecop.freeze(time_start + 9 * 60)
        puller.enqueue

        TestWorker.perform_async("A", "job 3")
        expect(schedule_set.size).to eq(1)

        queue_job = queue.first
        expect(queue_job.args).to eq([["A", "job 1"], ["A", "job 2"]])

        processor.process_one
        TestWorker.perform_async("A", "job 4")
        expect(schedule_set.size).to eq(1)

        set_item = schedule_set.first
        expect(set_item.value).to eq("debounce/TestWorker/A")
        expect(set_item.score).to eq((time_start + 14 * 60).to_i)
      end
    end

    context "1 task, 6 minutes break, 1 task" do
      it "executes first task, the second one in 11 minutes" do
        TestWorker.perform_async("A", "job 1")

        Timecop.freeze(time_start + 6 * 60)
        puller.enqueue

        TestWorker.perform_async("A", "job 2")

        queue_job = queue.first

        expect(queue_job.args).to eq([["A", "job 1"]])
        processor.process_one

        set_item = schedule_set.first
        expect(set_item.value).to eq("debounce/TestWorker/A")
        expect(set_item.score).to eq((time_start + 11 * 60).to_i)

        Timecop.freeze(time_start + 12 * 60)
        puller.enqueue

        queue_job = queue.first
        expect(queue_job.args).to eq([["A", "job 2"]])
      end
    end

    context "call using perform_in" do
      it "raises error" do
        expect { TestWorker.perform_in(30, "abc") }.to raise_error(Sidekiq::Debouncer::NotSupportedError)
      end
    end

    context "call using perform_at" do
      it "raises error" do
        expect { TestWorker.perform_at(Time.now.to_i + 30, "abc") }.to raise_error(Sidekiq::Debouncer::NotSupportedError)
      end
    end

    context "invalid attributes" do
      it "raises error" do
        expect { InvalidWorker.perform_async("abc") }.to raise_error(Sidekiq::Debouncer::MissingArgumentError)
      end
    end

    context "debounce method" do
      it "works like perform_async" do
        TestWorker.debounce("A", "job 1")

        expect(schedule_set.size).to eq(1)

        set_item = schedule_set.first
        expect(set_item.value).to eq("debounce/TestWorker/A")
        expect(set_item.score).to eq((time_start + 5 * 60).to_i)
      end
    end

    context "multiprocess safety" do
      it "is safe" do
        Parallel.each((1..1000).to_a, in_processes: 10) do |i|
          TestWorker.perform_async("A", i)
        end

        expect(schedule_set.size).to eq(1)

        set_item = schedule_set.first
        expect(set_item.value).to eq("debounce/TestWorker/A")

        Sidekiq.redis do |connection|
          args = connection.call("XRANGE", "debounce/TestWorker/A", "-", "+")
          expect(args.map { Sidekiq.load_json(_1[1][1])[1] }).to match_array((1..1000).to_a)
        end

        expect(queue.size).to eq(0)
      end

      # TODO: add a spec to check if enquing new job while pulling is going to work correctly
    end

    context "sidekiq testing fake mode" do
      it "uses standard sidekiq flow" do
        Sidekiq::Testing.fake! do
          TestWorker.debounce("A", "job 1")

          expect(schedule_set.size).to eq(0)
          expect(TestWorker.jobs.size).to eq(1)

          expect_any_instance_of(TestWorker).to receive(:perform).with([["A", "job 1"]])
          TestWorker.drain
        end
      end
    end

    context "sidekiq testing inline mode" do
      it "uses standard sidekiq flow" do
        Sidekiq::Testing.inline! do
          expect_any_instance_of(TestWorker).to receive(:perform).with([["A", "job 1"]])

          TestWorker.debounce("A", "job 1")

          expect(schedule_set.size).to eq(0)
          expect(TestWorker.jobs.size).to eq(0)
        end
      end
    end
  end

  context "normal job" do
    it "ignores debounce logic" do
      NormalWorker.perform_async("abc")

      expect(schedule_set.size).to eq(0)
      expect(queue.first["debounce_key"]).to be_nil
    end
  end
end
