# Hamlet Deploy Executor Bash

This is the Hamlet Deploy Executor primarily written in bash.

See https://docs.hamlet.io for more info on Hamlet Deploy

## Installation

The bash executor is included as part of the official [hamlet base engine](https://github.com/hamlet-io/hamlet-engine-base/) so it will be included as part of your hamlet installation if you are using the [hamlet cli](https://pypi.org/project/hamlet-cli/)

### Alternative Method

If you aren't using the hamlet engine or would like to contribute to the bash executor we recommend using the local clone method

#### Local clone

```bash
git clone https://github.com/hamlet-io/executor-bash.git
```

The following environment variables should be set to align with the location of the local clone

To update the executor run a `git pull` from the directory where you have cloned the executor

##### Mandatory Variables

These options must be set in order for Hamlet Deploy Executor to function correctly. Each of the variables point to different sections of the repo

| Variable                | Value                                  |
|-------------------------|----------------------------------------|
| AUTOMATION_BASE_DIR     | `<clone dir>/automation`               |
| AUTOMATION_DIR          | `<clone dir>automation/jenkins/aws`    |
| GENERATION_BASE_DIR     | `<clone dir>`                          |
| GENERATION_DIR          | `<clone dir>/cli`                      |

##### Optional Variables

The following optional variables will further configure the Hamlet Deploy Executor.

| Variable            | Value                                                               |
|---------------------|---------------------------------------------------------------------|
| AZURE_EXTENSION_DIR | A filepath to the directory containing extensions to the Azure CLI. |

## Usage

Though typical use of the Executor is performed through the Hamlet Deploy CLI, scripts within the Executor may be manually invoked.

Documentation for many individual scripts in the Executor available by providing the `-h` argument.

Scripts without documentation via this argument are intended to be sourced into other scripts and are not for external use.

### Contributing

#### Submitting Changes

Changes to the plugin are made through pull requests to this repo and all commits should use the [conventional commit](https://www.conventionalcommits.org/en/v1.0.0/) format
This allows us to generate changelogs automatically and to understand what changes have been made
