## Hamlet Deploy Executor Bash

This is the Hamlet Deploy Executor primarily written in bash.

See https://docs.hamlet.io for more info on Hamlet Deploy

### Installation

```bash
git clone https://github.com/hamlet-io/executor-bash.git
```

### Configuration

The Executor requires configuration through Environment Variables prior to use.

#### Mandatory Variables

These options must be set in order for Hamlet Deploy Executor to function correctly.

| Variable                | Value                                                                                                        |
|-------------------------|--------------------------------------------------------------------------------------------------------------|
| AUTOMATION_BASE_DIR     | Full filepath to the root of the Hamlet Executor's ./automation directory                                    |
| GENERATION_BASE_DIR     | The fully qualified filepath to the Executor itself.                                                         |
| GENERATION_DIR          | Fully qualified filepath to the Executor's `./cli` directory.                                                |
| GENERATION_ENGINE_DIR   | A fully qualified filepath to a local copy of the Hamlet Deploy Engine Core repository.                      |
| GENERATION_PATTERNS_DIR | A fully qualified filepath to a local copy of the Hamlet Deploy Patterns repository.                         |
| GENERATION_PLUGIN_DIRS  | A semicolon delimited list of fully qualified filepaths, each to a local instance of a Hamlet Deploy Plugin. |
| GENERATION_STARTUP_DIR  | A fully qualified filepath to a local copy of the Hamlet Deploy Startup repository.                          |


#### Optional Variables

The following optional variables will further configure the Hamlet Deploy Executor.

#### AZURE_EXTENSION_DIR

| Variable            | Value                                                               |
|---------------------|---------------------------------------------------------------------|
| AZURE_EXTENSION_DIR | A filepath to the directory containing extensions to the Azure CLI. |

### Update

No build process is necesary for the Executor Bash. Manual updates are performed by retrieving the latest files from source.

```bash
git pull
```

### Usage

Though typical use of the Executor is performed through the Hamlet Deploy CLI, scripts within the Executor may be manually invoked.

Documentation for many individual scripts in the Executor available by providing the `-h` argument.

Scripts without documentation via this argument are intended to be sourced into other scripts and are not for external use.

### Contribute

1. fork the repository
2. update your changes in a feature branch
3. Push to your fork's origin
4. Create a Pull Request from your Fork to the Upstream master.

```bash
# fork the repository on Github.
# https://github.com/hamlet-io/executor-bash.git

# add your upstream repo
git remote add upstream https://github.com/hamlet-io/executor-bash.git

# create your working branch
git checkout -b feat/my-feature-branch

# make your changes / updates / fixes in as many commits as necessary.

# rebase your work into only relevant commit messages
# example: I've made 3 commits, but two of them are fixups.
# git rebase -i HEAD~3
# mark the fixups and save the commits
git rebase -i HEAD~<number of commits since HEAD>

# push your feature branch to your origin (the fork)
git push --set-upstream origin feat/my-feature-branch

# on Github, create a PR from your fork/feature-branch to upstream/master.
# make sure you complete any Issue/PR templates provided.
```
