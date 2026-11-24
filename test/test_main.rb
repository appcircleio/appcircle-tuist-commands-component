# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'stringio'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

# If the top-level guard is ever lost, requiring main.rb runs the step and its
# `abort` would end this suite before a single test runs. Fail loudly instead.
begin
  require MAIN_RB
rescue SystemExit => e
  abort "main.rb ran its step on require (exit #{e.status}); top-level code must stay inside `if __FILE__ == $PROGRAM_NAME`."
end

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Every variable the step reads.
STEP_ENV_KEYS = %w[AC_TUIST_PATH AC_TUIST_COMMANDS].freeze

# Saves and clears every variable the step reads, runs the block, then restores them.
def with_clean_env
  old = STEP_ENV_KEYS.to_h { |k| [k, ENV[k]] }
  STEP_ENV_KEYS.each { |k| ENV.delete(k) }
  yield
ensure
  STEP_ENV_KEYS.each { |k| ENV.delete(k) }
  old.each { |k, v| ENV[k] = v unless v.nil? }
end

def fake_status(success)
  double('Process::Status', success?: success)
end

# Stubs Open3.popen3 so no real command runs. Each call records the command and
# yields fake stdin/stdout/stderr streams plus a wait thread. The handler maps
# the command to [stdout, stderr, success]; without one every command succeeds
# silently.
def stub_popen3(recorder: nil, &handler)
  allow(Open3).to receive(:popen3) do |cmd, &block|
    recorder&.<<(cmd)
    stdout, stderr, success = handler ? handler.call(cmd) : ['', '', true]
    wait_thr = double('Process::Waiter', value: fake_status(success))
    block.call(StringIO.new, StringIO.new(stdout), StringIO.new(stderr), wait_thr)
  end
end

# Runs the block with $stdout and $stderr captured.
# Returns [stdout, stderr, SystemExit or nil].
def capture_io
  old_out = $stdout
  old_err = $stderr
  $stdout = StringIO.new
  $stderr = StringIO.new
  exit_error = nil
  begin
    yield
  rescue SystemExit => e
    exit_error = e
  end
  [$stdout.string, $stderr.string, exit_error]
ensure
  $stdout = old_out
  $stderr = old_err
end

# Ruby's Coverage resets a file's counters on every `load`, so a snapshot is
# taken before each load and summed into the final report.
COVERAGE_SNAPSHOTS = []

def snapshot_coverage
  return unless defined?(Coverage) && Coverage.running?

  data = Coverage.peek_result[MAIN_RB]
  COVERAGE_SNAPSHOTS << data if data
end

# Runs main.rb's step body in-process with the given ENV and Open3.popen3
# already stubbed by the caller. Returns { out:, err:, error: } where error is
# the SystemExit or other exception the step ended with (nil on success).
def run_step(env)
  result = nil
  with_clean_env do
    env.each { |k, v| ENV[k] = v }
    old_program_name = $PROGRAM_NAME
    $PROGRAM_NAME = MAIN_RB
    snapshot_coverage
    begin
      raised = nil
      out, err, exit_error = capture_io do
        load MAIN_RB
      rescue StandardError => e
        raised = e
      end
      result = { out: out, err: err, error: exit_error || raised }
    ensure
      $PROGRAM_NAME = old_program_name
    end
  end
  result
end

# Writes a fake `tuist` executable into bin_dir. It appends its arguments to
# $FAKE_TOOL_LOG and never runs the real toolchain.
#   FAKE_TUIST_FAIL=1 -> prints an error to stderr and exits 1
def write_fake_tuist(bin_dir)
  FileUtils.mkdir_p(bin_dir)
  path = File.join(bin_dir, 'tuist')
  File.write(path, <<~SH)
    #!/bin/sh
    echo "tuist $*" >> "$FAKE_TOOL_LOG"
    if [ "$FAKE_TUIST_FAIL" = "1" ]; then
      echo "tuist: error: Manifest not found at path" >&2
      exit 1
    fi
    echo "Fake tuist ran: $*"
  SH
  File.chmod(0o755, path)
  bin_dir
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe '#env_has_key' do
  around do |example|
    old = ENV['_TEST_VAR']
    example.run
    old.nil? ? ENV.delete('_TEST_VAR') : ENV['_TEST_VAR'] = old
  end

  context 'positive path' do
    it 'returns the value when the key is set' do
      ENV['_TEST_VAR'] = '/work/App'
      expect(env_has_key('_TEST_VAR')).to eq('/work/App')
    end

    it 'returns a multi-word command value unchanged' do
      ENV['_TEST_VAR'] = 'tuist install && tuist build'
      expect(env_has_key('_TEST_VAR')).to eq('tuist install && tuist build')
    end

    it 'keeps whitespace-only values as-is (not treated as missing)' do
      ENV['_TEST_VAR'] = '  '
      expect(env_has_key('_TEST_VAR')).to eq('  ')
    end
  end

  context 'negative path' do
    it 'aborts with "Missing <key>." when the key is missing' do
      ENV.delete('_TEST_VAR')
      _out, err, error = capture_io { env_has_key('_TEST_VAR') }
      expect(error).to be_a(SystemExit)
      expect(error.status).to eq(1)
      expect(error.message).to eq('Missing _TEST_VAR.')
      expect(err).to eq("Missing _TEST_VAR.\n")
    end

    it 'aborts with "Missing <key>." when the value is an empty string' do
      ENV['_TEST_VAR'] = ''
      _out, err, error = capture_io { env_has_key('_TEST_VAR') }
      expect(error).to be_a(SystemExit)
      expect(error.status).to eq(1)
      expect(error.message).to eq('Missing _TEST_VAR.')
      expect(err).to eq("Missing _TEST_VAR.\n")
    end

    it 'raises SystemExit (not a return value) so callers never see nil' do
      ENV.delete('_TEST_VAR')
      old_err = $stderr
      $stderr = StringIO.new
      begin
        expect { env_has_key('_TEST_VAR') }.to raise_error(SystemExit) { |e| expect(e.success?).to be(false) }
      ensure
        $stderr = old_err
      end
    end

    it 'raises TypeError for a nil key' do
      expect { env_has_key(nil) }.to raise_error(TypeError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#runCommand' do
  let(:commands) { [] }

  context 'positive path' do
    it 'passes the command string to Open3.popen3 unchanged' do
      stub_popen3(recorder: commands)
      capture_io { runCommand('tuist build -p /work/App') }
      expect(commands).to eq(['tuist build -p /work/App'])
    end

    it 'logs the command and streams stdout line by line' do
      stub_popen3 { ["Resolving dependencies\nBuild succeeded\n", '', true] }
      out, _err, error = capture_io { runCommand('tuist build -p /work/App') }
      expect(error).to be_nil
      expect(out).to eq("@@[command] tuist build -p /work/App\nResolving dependencies\nBuild succeeded\n")
    end

    it 'prints only the command log when the command succeeds silently' do
      stub_popen3
      out, _err, _error = capture_io { runCommand('true') }
      expect(out).to eq("@@[command] true\n")
    end

    it 'does not raise when a successful command writes to stderr' do
      stub_popen3 { ['ok', 'warning: deprecated flag', true] }
      expect { capture_io { runCommand('tuist install -p .') } }.not_to raise_error
    end

    it 'returns nil on success' do
      stub_popen3
      result = nil
      capture_io { result = runCommand('tuist clean -p .') }
      expect(result).to be_nil
    end
  end

  context 'negative path' do
    it 'raises RuntimeError with stderr when the command fails' do
      stub_popen3 { ['', 'tuist: error: Manifest not found at path /work/App', false] }
      expect { capture_io { runCommand('tuist build -p /work/App') } }
        .to raise_error(RuntimeError, 'tuist: error: Manifest not found at path /work/App')
    end

    it 'still prints stdout produced before the failure' do
      stub_popen3 { ["partial output\n", 'boom', false] }
      old_out = $stdout
      $stdout = StringIO.new
      begin
        expect { runCommand('tuist build -p .') }.to raise_error(RuntimeError, 'boom')
        out = $stdout.string
      ensure
        $stdout = old_out
      end
      expect(out).to eq("@@[command] tuist build -p .\npartial output\n")
    end

    it 'raises RuntimeError with an empty message when a failing command has empty stderr' do
      stub_popen3 { ['', '', false] }
      expect { capture_io { runCommand('false') } }.to raise_error(RuntimeError, '')
    end

    it 'propagates errors raised by Open3.popen3 (e.g. executable not found)' do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT, 'tuist')
      expect { capture_io { runCommand('tuist build -p .') } }.to raise_error(Errno::ENOENT)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'step execution (in-process)' do
  let(:commands) { [] }
  let(:base_env) { { 'AC_TUIST_PATH' => '/work/App', 'AC_TUIST_COMMANDS' => 'tuist build' } }

  context 'positive path' do
    before { stub_popen3(recorder: commands) { ["done\n", '', true] } }

    it 'runs "<AC_TUIST_COMMANDS> -p <AC_TUIST_PATH>" exactly once' do
      result = run_step(base_env)
      expect(result[:error]).to be_nil
      expect(commands).to eq(['tuist build -p /work/App'])
      expect(result[:out]).to eq("@@[command] tuist build -p /work/App\ndone\n")
    end

    it 'passes any tuist subcommand through (tuist install)' do
      run_step(base_env.merge('AC_TUIST_COMMANDS' => 'tuist install'))
      expect(commands).to eq(['tuist install -p /work/App'])
    end

    it 'passes subcommand flags through and appends -p last' do
      run_step(base_env.merge('AC_TUIST_COMMANDS' => 'tuist test --no-selective-testing'))
      expect(commands).to eq(['tuist test --no-selective-testing -p /work/App'])
    end

    it 'keeps a relative project path as given' do
      run_step(base_env.merge('AC_TUIST_PATH' => '.'))
      expect(commands).to eq(['tuist build -p .'])
    end

    it 'does not quote a path containing spaces' do
      run_step(base_env.merge('AC_TUIST_PATH' => '/work/My App'))
      expect(commands).to eq(['tuist build -p /work/My App'])
    end

    it 'accepts whitespace-only values (passes the presence check)' do
      result = run_step(base_env.merge('AC_TUIST_PATH' => ' '))
      expect(result[:error]).to be_nil
      expect(commands).to eq(['tuist build -p  '])
    end
  end

  context 'negative path – missing / empty inputs' do
    before { stub_popen3(recorder: commands) }

    {
      'AC_TUIST_PATH missing' => [{ 'AC_TUIST_COMMANDS' => 'tuist build' }, 'AC_TUIST_PATH'],
      'AC_TUIST_PATH empty' => [{ 'AC_TUIST_PATH' => '', 'AC_TUIST_COMMANDS' => 'tuist build' }, 'AC_TUIST_PATH'],
      'AC_TUIST_COMMANDS missing' => [{ 'AC_TUIST_PATH' => '/work/App' }, 'AC_TUIST_COMMANDS'],
      'AC_TUIST_COMMANDS empty' => [{ 'AC_TUIST_PATH' => '/work/App', 'AC_TUIST_COMMANDS' => '' }, 'AC_TUIST_COMMANDS']
    }.each do |label, (env, key)|
      it "#{label} → aborts with \"Missing #{key}.\" and runs no command" do
        result = run_step(env)
        expect(result[:error]).to be_a(SystemExit)
        expect(result[:error].status).to eq(1)
        expect(result[:err]).to eq("Missing #{key}.\n")
        expect(commands).to be_empty
      end
    end

    it 'reports AC_TUIST_PATH first when both inputs are missing' do
      result = run_step({})
      expect(result[:err]).to eq("Missing AC_TUIST_PATH.\n")
      expect(commands).to be_empty
    end
  end

  context 'negative path – tuist command fails' do
    it 'raises RuntimeError carrying the command stderr' do
      stub_popen3(recorder: commands) { ['', 'tuist: error: Manifest not found at path /work/App', false] }
      result = run_step(base_env)
      expect(result[:error]).to be_a(RuntimeError)
      expect(result[:error].message).to eq('tuist: error: Manifest not found at path /work/App')
      expect(commands).to eq(['tuist build -p /work/App'])
    end

    it 'propagates Errno::ENOENT when the command executable does not exist' do
      allow(Open3).to receive(:popen3).and_raise(Errno::ENOENT, 'tuist')
      result = run_step(base_env)
      expect(result[:error]).to be_a(Errno::ENOENT)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation (subprocess)' do
  let(:tmpdir)   { Dir.mktmpdir('tuist_commands_step') }
  let(:bin_dir)  { write_fake_tuist(File.join(tmpdir, 'bin')) }
  let(:tool_log) { File.join(tmpdir, 'tool.log') }
  let(:base_env) do
    {
      'AC_TUIST_PATH' => '/work/App',
      'AC_TUIST_COMMANDS' => 'tuist build',
      'PATH' => "#{bin_dir}:#{ENV['PATH']}",
      'FAKE_TOOL_LOG' => tool_log
    }
  end

  after { FileUtils.rm_rf(tmpdir) }

  # Runs main.rb in a subprocess from tmpdir. Step variables not in env are
  # unset (nil unsets in the child) so the ambient environment cannot leak in.
  def main(env)
    clean = STEP_ENV_KEYS.to_h { |k| [k, nil] }
    Open3.capture3(clean.merge(env), "ruby #{MAIN_RB}", chdir: tmpdir)
  end

  def tool_calls
    File.exist?(tool_log) ? File.read(tool_log).lines.map(&:chomp) : []
  end

  %w[AC_TUIST_PATH AC_TUIST_COMMANDS].each do |key|
    context "required variable: #{key}" do
      it 'when missing → exits 1 with "Missing <key>." and runs nothing' do
        _out, err, status = main(base_env.merge(key => nil))
        expect(status.exitstatus).to eq(1)
        expect(err).to eq("Missing #{key}.\n")
        expect(tool_calls).to be_empty
      end

      it 'when an empty string → exits 1 with "Missing <key>." and runs nothing' do
        _out, err, status = main(base_env.merge(key => ''))
        expect(status.exitstatus).to eq(1)
        expect(err).to eq("Missing #{key}.\n")
        expect(tool_calls).to be_empty
      end
    end
  end

  context 'all variables set' do
    it 'runs the fake tuist with the composed arguments and exits 0' do
      out, err, status = main(base_env)
      expect(err).to eq('')
      expect(status.exitstatus).to eq(0)
      expect(out).to eq("@@[command] tuist build -p /work/App\nFake tuist ran: build -p /work/App\n")
      expect(tool_calls).to eq(['tuist build -p /work/App'])
    end

    it 'runs chained commands through the shell, -p applies to the last one only' do
      out, _err, status = main(base_env.merge('AC_TUIST_COMMANDS' => 'tuist install && tuist build'))
      expect(status.exitstatus).to eq(0)
      expect(out).to start_with("@@[command] tuist install && tuist build -p /work/App\n")
      expect(tool_calls).to eq(['tuist install', 'tuist build -p /work/App'])
    end
  end

  context 'toolchain failures' do
    it 'exits non-zero and reports tuist stderr when the command fails' do
      _out, err, status = main(base_env.merge('FAKE_TUIST_FAIL' => '1'))
      expect(status.success?).to be(false)
      expect(err).to include('tuist: error: Manifest not found at path')
      expect(err).to include('RuntimeError')
      expect(tool_calls).to eq(['tuist build -p /work/App'])
    end

    it 'exits non-zero when the command executable does not exist' do
      _out, err, status = main(base_env.merge('AC_TUIST_COMMANDS' => 'definitely-not-a-real-tool-xyz'))
      expect(status.success?).to be(false)
      expect(err).to match(/ENOENT|No such file or directory/)
      expect(tool_calls).to be_empty
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'loading main.rb' do
  it 'does not execute the step when required from another script' do
    out, err, status = Open3.capture3(STEP_ENV_KEYS.to_h { |k| [k, nil] },
                                      "ruby -e 'require %q(#{MAIN_RB}); puts :loaded'")
    expect(status.exitstatus).to eq(0)
    expect(err).to eq('')
    expect(out.strip).to eq('loaded')
  end

  it 'defines env_has_key and runCommand' do
    expect(respond_to?(:env_has_key, true)).to be(true)
    expect(respond_to?(:runCommand, true)).to be(true)
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data      = COVERAGE_SNAPSHOTS.reduce(result[main_path]) do |acc, snap|
    acc.zip(snap).map { |a, b| a.nil? ? nil : a + b.to_i }
  end
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
