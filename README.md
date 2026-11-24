# Appcircle Tuist Commands 

This step runs specific [Tuist](https://tuist.io/) commands that you provide as input. 

## Required Input Variable
- `$AC_TUIST_PATH`: The path to the directory of Tuist project. By default, it is set to the root directory of the cloned repository.
- `$AC_TUIST_COMMANDS`: The commands of Tuist, you can specify the specific Tuist command to run. For example; `tuist build` or `tuist install`.
## Running tests

Requires the [RSpec](https://rspec.info) gem and the Ruby standard library (Coverage). No Gemfile or Bundler needed.

```bash
ruby test/test_main.rb
```

A coverage report is printed at the end of each run. The tests never run the real `tuist`: `Open3.popen3` is stubbed in-process, and the subprocess tests put a fake `tuist` first on `PATH` inside a temporary directory.
